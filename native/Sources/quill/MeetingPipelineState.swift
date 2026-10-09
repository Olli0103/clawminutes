import Foundation

/// Durable stage and recovery instructions. Artifacts and verified receipts
/// remain the evidence for successful delivery and irreversible audio removal.
struct MeetingPipelineState: Codable, Sendable {
    static let maximumBytes = 131_072
    enum Stage: String, Codable, Sendable {
        case capturing, recorded, interrupted, waitingForModel, transcribing, transcribed
        case delivering, delivered, exported, audioRemoved, needsAttention
    }
    struct Attempt: Codable, Sendable {
        var count = 0
        var nextAttemptAt: Double = 0
        var lastError: DeliveryFailure?
        var lastErrorAt: Double? = nil
        var transcriptSHA256: String? = nil
        var completionAttempts: Int? = nil
        var recoveryID: String? = nil
        var budgetUnverified: Bool? = nil
    }
    /// Recognition checkpoints never prove final transcription or delivery.
    /// One background attempt per closed file. The final job retains its own budget.
    struct ChunkAttempt: Codable, Sendable {
        var count: Int
        var checkpointSHA256: String? = nil
    }
    struct ExportAttempt: Codable, Equatable, Sendable {
        var count = 0
        var nextAttemptAt: Double = 0
        var lastError: DeliveryFailure?
        var lastErrorAt: Double?
        func mayAttempt(at now: Double) -> Bool { count < 3 && lastError?.retryable != false && nextAttemptAt <= now }
    }
    struct LegacySnapshot: Codable, Equatable, Sendable {
        var retrySHA256: String?
        var recoverySHA256: String?
        static func read(_ directory: URL) throws -> Self {
            func digest(_ name: String) throws -> String? {
                let file = directory.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: file.path)
                    || (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) != nil else { return nil }
                let data = try ArchiveBacklog.read(file)
                guard data.count <= 16_384 else { throw invalidState }
                return AudioRetention.digest(data)
            }
            return try Self(retrySHA256: digest("archive-retry.json"), recoverySHA256: digest("notes-recovery.json"))
        }
    }
    var schemaVersion = 2
    let recordingIdentity: String
    var revision = 1
    var stage: Stage
    var transcription = Attempt()
    var delivery = Attempt()
    var localExport: ExportAttempt? = nil
    var recognitionChunks: [String: ChunkAttempt]? = nil
    var updatedAt: Double
    var generation: Int? = nil
    var legacySnapshot: LegacySnapshot? = nil
    var notesRecovery: NotesRecovery.Intent? = nil
    // Compare the bytes actually loaded, including old schema records. This is
    // process-local concurrency metadata, never a second persisted authority.
    private var loadedStateSHA256: String? = nil
    init(recordingIdentity: String, stage: Stage, updatedAt: Double) {
        self.recordingIdentity = recordingIdentity; self.stage = stage; self.updatedAt = updatedAt
    }
    enum CodingKeys: String, CodingKey {
        case schemaVersion, recordingIdentity, revision, stage, transcription, delivery, updatedAt
        case generation, legacySnapshot, notesRecovery, localExport, recognitionChunks
    }
    var deliveryRetry: ArchiveBacklog.Retry? {
        guard delivery.count > 0, let hash = delivery.transcriptSHA256 else { return nil }
        let armed = [notesRecovery?.request, notesRecovery?.previousRequest].compactMap { $0 }.first { $0.id == delivery.recoveryID }
        let issue = delivery.budgetUnverified == true && armed?.kind != .transcriptOnly ? Self.legacyBudgetUnverified : delivery.lastError
        return ArchiveBacklog.Retry(attempts: delivery.count, nextAttemptAt: delivery.nextAttemptAt, transcriptSHA256: hash,
            completionAttempts: delivery.completionAttempts, lastError: issue, recoveryID: delivery.recoveryID)
    }
    static let legacyBudgetUnverified = DeliveryFailure(code: "legacy_attempts_unverified",
        detail: "This meeting's earlier AI attempt history is incomplete. Review delivery or explicitly save transcript-only notes. Audio is retained.",
        retryable: false, completionAttempted: false)
    static func identity(_ directory: URL) throws -> String {
        let properties = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard properties.isDirectory == true, properties.isSymbolicLink != true else { throw invalidState }
        let meta = try ArchiveBacklog.object(directory.appendingPathComponent("meta.json"))
        return AudioRetention.digest(Data(((meta["started"] as? String ?? "") + "\n"
            + (meta["recording_id"] as? String ?? directory.lastPathComponent)).utf8))
    }
    static func validFailure(_ value: DeliveryFailure?) -> Bool {
        guard let value else { return true }
        return value.code.range(of: #"^[a-z][a-z0-9_]{0,79}$"#, options: .regularExpression) != nil
            && !value.detail.isEmpty && value.detail.count <= 512
            && !value.detail.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    static func validHash(_ value: String?) -> Bool {
        value == nil || value!.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil
    }
    private func validateAttempts() throws {
        for attempt in [transcription, delivery] {
            guard (0...1000).contains(attempt.count), attempt.nextAttemptAt.isFinite,
                  attempt.lastErrorAt.map({ $0.isFinite }) ?? true,
                  Self.validFailure(attempt.lastError), Self.validHash(attempt.transcriptSHA256),
                  attempt.completionAttempts.map({ (0...3).contains($0) }) ?? true,
                  attempt.recoveryID.map({ UUID(uuidString: $0) != nil }) ?? true else { throw Self.invalidState }
        }
    }
    private func validate() throws {
        try validateAttempts()
        if let attempt = localExport {
            guard (0...1000).contains(attempt.count), attempt.nextAttemptAt.isFinite,
                  attempt.lastErrorAt.map({ $0.isFinite }) ?? true,
                  Self.validFailure(attempt.lastError) else { throw Self.invalidState }
        }
        if let chunks = recognitionChunks {
            guard chunks.count <= 256, chunks.allSatisfy({ file, attempt in
                SessionMeta.validTrackFile(file) && attempt.count == 1
                    && Self.validHash(attempt.checkpointSHA256)
            }) else { throw Self.invalidState }
        }
        guard schemaVersion == 2, updatedAt.isFinite, (generation ?? 0) >= 0, (generation ?? 0) < Int.max,
              transcription.transcriptSHA256 == nil, transcription.completionAttempts == nil, transcription.recoveryID == nil,
              delivery.count == 0 || (delivery.transcriptSHA256 != nil && (delivery.completionAttempts != nil || delivery.budgetUnverified == true)),
              legacySnapshot != nil else { throw Self.invalidState }
        if let recovery = notesRecovery {
            try NotesRecovery.validate(recovery, identity: recordingIdentity, transcriptHash: delivery.transcriptSHA256)
        }
        if let id = delivery.recoveryID {
            guard notesRecovery?.request.id == id || notesRecovery?.previousRequest?.id == id else { throw Self.invalidState }
        }
    }
    static func load(_ directory: URL, inspected: ArchiveBacklog.Item? = nil,
                     now: Double = Date().timeIntervalSince1970) throws -> Self {
        let identity = try identity(directory)
        let metadata = try ArchiveBacklog.object(directory.appendingPathComponent("meta.json"))
        let revision = try MeetingRevisions.descriptor(meta: metadata, directory: directory)?.number ?? 1
        let snapshot = try LegacySnapshot.read(directory)
        let file = directory.appendingPathComponent("state.json")
        var value: Self
        if FileManager.default.fileExists(atPath: file.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) != nil {
            let data = try ArchiveBacklog.read(file)
            guard data.count <= Self.maximumBytes else { throw invalidState }
            value = try JSONDecoder().decode(Self.self, from: data)
            guard [1, 2].contains(value.schemaVersion), value.recordingIdentity == identity, value.revision == revision else { throw invalidState }
            value.loadedStateSHA256 = AudioRetention.digest(data)
            if value.schemaVersion == 2 {
                guard (value.generation ?? 0) >= 1, value.legacySnapshot == snapshot else { throw invalidState }
                try value.validate()
                return value
            }
            // Validate the original mirror before a newer retry ledger replaces
            // any delivery fields. Migration cannot sanitize malformed evidence.
            guard value.updatedAt.isFinite else { throw invalidState }
            try value.validateAttempts()
        } else {
            let stage: Stage = metadata["status"] as? String == "recording" ? .capturing
                : metadata["status"] as? String == "interrupted" ? .interrupted : .recorded
            value = Self(recordingIdentity: identity, stage: stage, updatedAt: now)
            value.revision = revision
        }
        // Read-only import. Only an authorized pipeline write publishes schema 2.
        // Legacy bytes stay in place as evidence and cannot later override it.
        value.schemaVersion = 2; value.generation = 0; value.legacySnapshot = snapshot
        if snapshot.retrySHA256 != nil {
            let retry = try JSONDecoder().decode(ArchiveBacklog.Retry.self, from: ArchiveBacklog.read(directory.appendingPathComponent("archive-retry.json")))
            guard retry.attempts > 0, retry.attempts <= 1000, retry.attempts >= value.delivery.count,
                  retry.nextAttemptAt.isFinite, validHash(retry.transcriptSHA256), validFailure(retry.lastError),
                  retry.completionAttempts == nil || (0...3).contains(retry.completionAttempts!),
                  retry.recoveryID == nil || UUID(uuidString: retry.recoveryID!) != nil else { throw invalidState }
            value.delivery = Attempt(count: retry.attempts, nextAttemptAt: retry.nextAttemptAt, lastError: retry.lastError,
                transcriptSHA256: retry.transcriptSHA256, completionAttempts: retry.completionAttempts,
                recoveryID: retry.recoveryID, budgetUnverified: retry.completionAttempts == nil && metadata["notes_mode"] as? String == "ai")
        } else if value.delivery.count > 0 {
            value.delivery.transcriptSHA256 = AudioRetention.digest(try ArchiveBacklog.read(directory.appendingPathComponent("transcript.json")))
            value.delivery.budgetUnverified = metadata["notes_mode"] as? String == "ai"
        }
        if value.delivery.count > 0, value.delivery.completionAttempts == nil, value.delivery.budgetUnverified != true { value.delivery.completionAttempts = 0 }
        if snapshot.recoverySHA256 != nil {
            value.notesRecovery = try NotesRecovery.readLegacy(directory,
                transcriptData: ArchiveBacklog.read(directory.appendingPathComponent("transcript.json")))
        }
        if let inspected { value.reconcile(inspected, now: now) }
        try value.validate()
        return value
    }
    static var invalidState: DeliveryFailure {
        DeliveryFailure(code: "pipeline_state_invalid", detail: "This meeting's recovery state could not be verified. Local files are preserved.", retryable: false, completionAttempted: false)
    }
    static let conflictingState = DeliveryFailure(code: "pipeline_state_conflict",
        detail: "This meeting's progress changed while it was being updated. Reload it before retrying. Existing attempt counts and files are preserved.",
        retryable: false, completionAttempted: false)
    mutating func write(_ directory: URL) throws {
        guard try Self.identity(directory) == recordingIdentity else { throw Self.invalidState }
        let metadata = try ArchiveBacklog.object(directory.appendingPathComponent("meta.json"))
        guard (try MeetingRevisions.descriptor(meta: metadata, directory: directory)?.number ?? 1) == revision else { throw Self.invalidState }
        guard let lock = try AppRunLock.acquire(at: directory.appendingPathComponent("state.lock")) else { throw Self.conflictingState }
        defer { withExtendedLifetime(lock) {} }
        let file = directory.appendingPathComponent("state.json")
        let exists = FileManager.default.fileExists(atPath: file.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) != nil
        let current = exists ? try ArchiveBacklog.read(file) : nil
        guard current.map(AudioRetention.digest) == loadedStateSHA256 else { throw Self.conflictingState }
        guard legacySnapshot == (try LegacySnapshot.read(directory)) else { throw Self.invalidState }
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        if try encoder.encode(self) == current { return }
        var committed = self
        committed.generation = (generation ?? 0) + 1
        let data = try encoder.encode(committed)
        guard data.count <= Self.maximumBytes else { throw Self.invalidState }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        committed.loadedStateSHA256 = AudioRetention.digest(data)
        self = committed
        PipelineEvents.record(self)
    }
    mutating func reconcile(_ item: ArchiveBacklog.Item, now: Double) {
        let oldTranscriptionError = transcription.lastError, oldDeliveryError = delivery.lastError
        let oldExportError = localExport?.lastError
        if item.verifiedText != nil {
            transcription.lastError = nil; transcription.lastErrorAt = nil
        }
        if item.verifiedText?.includesDelivery == true {
            delivery.lastError = nil; delivery.lastErrorAt = nil
        }
        if item.verifiedText == .exported {
            localExport?.lastError = nil; localExport?.lastErrorAt = nil
        }
        let previousStage = stage
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
            delivery.lastError = nil; delivery.lastErrorAt = nil
            transcription.lastError = nil; transcription.lastErrorAt = nil
        case .needsReview, .fixture:
            stage = transcription.lastError?.code == "local_model_missing" ? .waitingForModel : .needsAttention
        }
        if previousStage != stage || oldTranscriptionError != transcription.lastError || oldDeliveryError != delivery.lastError || oldExportError != localExport?.lastError { updatedAt = now }
    }
    func mayTranscribe(at now: Double) -> Bool {
        transcription.count < 3 && transcription.lastError?.retryable != false && transcription.nextAttemptAt <= now
    }
    mutating func reserveTranscription(at now: Double) throws {
        guard mayTranscribe(at: now) else { throw transcription.lastError ?? Self.invalidState }
        transcription.count += 1
        transcription.nextAttemptAt = now + ArchiveBacklog.Retry.delay(attempt: transcription.count)
        transcription.lastError = nil; transcription.lastErrorAt = nil
        stage = .transcribing; updatedAt = now
    }
    mutating func transcriptionFailed(_ error: Error, at now: Double) {
        let issue: DeliveryFailure
        if let typed = error as? SpeechRecognitionIssue { issue = typed.failure }
        else { issue = DeliveryFailure(code: "speech_recognition_failed", detail: "Speech recognition did not finish. Audio is retained; it will retry up to three times.", retryable: true, completionAttempted: false) }
        transcription.lastError = transcription.count >= 3 && issue.retryable
            ? DeliveryFailure(code: "speech_retry_limit", detail: "Speech recognition stopped after three attempts. Audio is retained. Review this meeting before retrying.", retryable: false, completionAttempted: false)
            : issue
        transcription.lastErrorAt = now
        stage = issue.code == "local_model_missing" ? .waitingForModel : .needsAttention
        updatedAt = now
    }
    mutating func speechCredentialsInstalled(at now: Double) {
        guard transcription.lastError?.code == "speech_credentials_missing" else { return }
        transcription.lastError = nil; transcription.lastErrorAt = nil; transcription.count = 0; transcription.nextAttemptAt = now
        stage = .recorded; updatedAt = now
    }
    mutating func localModelInstalled(at now: Double) {
        guard transcription.lastError?.code == "local_model_missing" else { return }
        transcription.lastError = nil; transcription.lastErrorAt = nil; transcription.count = 0; transcription.nextAttemptAt = now
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
