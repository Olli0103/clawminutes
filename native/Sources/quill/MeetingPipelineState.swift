import Foundation

/// Durable stage and recovery instructions. Artifacts and verified receipts
/// remain the evidence for successful delivery and irreversible audio removal.
struct MeetingPipelineState: Codable, Sendable {
    enum Stage: String, Codable, Sendable {
        case capturing, recorded, interrupted, waitingForModel, transcribing, transcribed
        case delivering, delivered, exported, audioRemoved, needsAttention
    }
    struct Attempt: Codable, Sendable {
        var count = 0
        var nextAttemptAt: Double = 0
        var lastError: DeliveryFailure?
    }
    var schemaVersion = 1
    let recordingIdentity: String
    var revision = 1
    var stage: Stage
    var transcription = Attempt()
    var delivery = Attempt()
    var updatedAt: Double

    static func identity(_ directory: URL) throws -> String {
        let properties = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard properties.isDirectory == true, properties.isSymbolicLink != true else { throw invalidState }
        let meta = try ArchiveBacklog.object(directory.appendingPathComponent("meta.json"))
        return AudioRetention.digest(Data(((meta["started"] as? String ?? "") + "\n"
            + (meta["recording_id"] as? String ?? directory.lastPathComponent)).utf8))
    }
    static func load(_ directory: URL, inspected: ArchiveBacklog.Item? = nil,
                     now: Double = Date().timeIntervalSince1970) throws -> Self {
        let identity = try identity(directory)
        let file = directory.appendingPathComponent("state.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let data = try ArchiveBacklog.read(file)
            guard data.count <= 16_384 else { throw invalidState }
            let value = try JSONDecoder().decode(Self.self, from: data)
            guard value.schemaVersion == 1, value.recordingIdentity == identity, value.revision >= 1,
                  value.updatedAt.isFinite, [value.transcription, value.delivery].allSatisfy({
                      $0.count >= 0 && $0.count <= 1000 && $0.nextAttemptAt.isFinite
                  }) else { throw invalidState }
            return value
        }
        // Import legacy folders beside their artifacts; importing never deletes,
        // retranscribes, re-exports, or changes a saved document.
        let item = inspected ?? ArchiveBacklog.inspect(directory)
        var value = Self(recordingIdentity: identity, stage: .interrupted, updatedAt: now)
        value.reconcile(item, now: now)
        return value
    }
    static var invalidState: DeliveryFailure {
        DeliveryFailure(code: "pipeline_state_invalid", detail: "This meeting's recovery state could not be verified. Local files are preserved.", retryable: false, completionAttempted: false)
    }
    func write(_ directory: URL) throws {
        guard try Self.identity(directory) == recordingIdentity else { throw Self.invalidState }
        let file = directory.appendingPathComponent("state.json")
        if FileManager.default.fileExists(atPath: file.path) { _ = try ArchiveBacklog.read(file) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        if (try? ArchiveBacklog.read(file)) == data { return }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        PipelineEvents.record(self)
    }
    mutating func reconcile(_ item: ArchiveBacklog.Item, now: Double) {
        let previousStage = stage
        if let retry = item.retry {
            delivery = Attempt(count: retry.attempts, nextAttemptAt: retry.nextAttemptAt, lastError: retry.lastError)
        }
        switch item.state {
        case .recording: stage = .capturing
        case .transcriptionPending:
            if transcription.lastError?.code == "local_model_missing" { stage = .waitingForModel }
            else if transcription.count >= 3 || transcription.lastError != nil { stage = .needsAttention }
            else { stage = (try? ArchiveBacklog.object(item.directory.appendingPathComponent("meta.json"))["status"] as? String) == "interrupted" ? .interrupted : .recorded }
        case .archivePending: stage = .transcribed
        case .exportPending: stage = .delivered
        case .saved:
            stage = AudioRetention.explicitlyRemoved(item.directory) ? .audioRemoved : .exported
            delivery.lastError = nil; transcription.lastError = nil
        case .needsReview, .fixture:
            stage = transcription.lastError?.code == "local_model_missing" ? .waitingForModel : .needsAttention
        }
        if previousStage != stage { updatedAt = now }
    }
    func mayTranscribe(at now: Double) -> Bool {
        transcription.count < 3 && transcription.lastError?.retryable != false && transcription.nextAttemptAt <= now
    }
    mutating func reserveTranscription(at now: Double) throws {
        guard mayTranscribe(at: now) else { throw transcription.lastError ?? Self.invalidState }
        transcription.count += 1
        transcription.nextAttemptAt = now + ArchiveBacklog.Retry.delay(attempt: transcription.count)
        transcription.lastError = nil
        stage = .transcribing; updatedAt = now
    }
    mutating func transcriptionFailed(_ error: Error, at now: Double) {
        let issue: DeliveryFailure
        if let typed = error as? SpeechRecognitionIssue { issue = typed.failure }
        else { issue = DeliveryFailure(code: "speech_recognition_failed", detail: "Speech recognition did not finish. Audio is retained; it will retry up to three times.", retryable: true, completionAttempted: false) }
        transcription.lastError = transcription.count >= 3 && issue.retryable
            ? DeliveryFailure(code: "speech_retry_limit", detail: "Speech recognition stopped after three attempts. Audio is retained. Review this meeting before retrying.", retryable: false, completionAttempted: false)
            : issue
        stage = issue.code == "local_model_missing" ? .waitingForModel : .needsAttention
        updatedAt = now
    }
    mutating func speechCredentialsInstalled(at now: Double) {
        guard transcription.lastError?.code == "speech_credentials_missing" else { return }
        transcription.lastError = nil; transcription.count = 0; transcription.nextAttemptAt = now
        stage = .recorded; updatedAt = now
    }
    mutating func localModelInstalled(at now: Double) {
        guard transcription.lastError?.code == "local_model_missing" else { return }
        transcription.lastError = nil; transcription.count = 0; transcription.nextAttemptAt = now
        stage = .interrupted; updatedAt = now
    }
}

enum SpeechRecognitionIssue: Error, CustomStringConvertible {
    var description: String { failure.detail }
    case localModelMissing, cloudCredentialsMissing
    var failure: DeliveryFailure {
        switch self {
        case .localModelMissing:
            return DeliveryFailure(code: "local_model_missing", detail: "Download the local speech model to transcribe this meeting. Audio stays on this Mac.", retryable: false, completionAttempted: false)
        case .cloudCredentialsMissing:
            return DeliveryFailure(code: "speech_credentials_missing", detail: "Add your speech recognition API key, then retry this meeting. Audio is retained.", retryable: false, completionAttempted: false)
        }
    }
}
