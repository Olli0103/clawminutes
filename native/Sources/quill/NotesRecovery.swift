import Foundation

/// Explicit recovery of failed AI notes. Transcript, original metadata, attempt
/// counts and prior failures remain intact. An intent alone never grants a retry.
enum NotesRecovery {
    enum Kind: String, Codable, Sendable, Identifiable {
        case retryAI = "retry_ai", transcriptOnly = "transcript_only"
        var id: String { rawValue }
    }
    struct Request: Codable, Equatable, Sendable {
        let kind: Kind
        let id: String
        var json: [String: String] { ["kind": kind.rawValue, "id": id] }
        static func decode(_ value: Any) throws -> Self {
            guard let fields = value as? [String: Any], Set(fields.keys) == ["kind", "id"] else { throw invalid }
            let request = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: value))
            guard UUID(uuidString: request.id) != nil else { throw invalid }
            return request
        }
    }
    struct History: Codable, Sendable {
        let request: Request
        let at: Double
        let failure: DeliveryFailure
    }
    struct Intent: Codable, Sendable {
        let schemaVersion: Int
        let recordingIdentity: String
        let transcriptSHA256: String
        let request: Request
        let history: [History]
        var previousRequest: Request? = nil
    }
    static let aiFailureCodes: Set<String> = ["ai_invalid_output", "ai_completion_failed", "ai_input_too_large", "ai_tool_attempt",
        "notes_model_unavailable", "notes_owner_required", "notes_retry_consumed", "ai_retry_limit", "notes_cache_failed", "legacy_attempts_unverified"]
    static var invalid: DeliveryFailure {
        DeliveryFailure(code: "notes_recovery_unavailable", detail: "This meeting's recovery request could not be verified. Original files and attempt limits are preserved.", retryable: false, completionAttempted: false)
    }
    static func permits(_ kind: Kind, failure: DeliveryFailure?, completions: Int) -> Bool {
        guard let failure, aiFailureCodes.contains(failure.code) else { return false }
        if kind == .transcriptOnly { return true }
        return completions < 3 && !["ai_retry_limit", "notes_cache_failed", "ai_input_too_large", "legacy_attempts_unverified"].contains(failure.code)
    }
    static func validate(_ value: Intent, identity: String, transcriptHash: String?) throws {
        guard value.schemaVersion == 1, value.recordingIdentity == identity,
              value.transcriptSHA256 == transcriptHash, MeetingPipelineState.validHash(transcriptHash),
              UUID(uuidString: value.request.id) != nil,
              value.previousRequest == nil || UUID(uuidString: value.previousRequest!.id) != nil,
              value.history.count <= 10, value.history.allSatisfy({ $0.at.isFinite && UUID(uuidString: $0.request.id) != nil
                  && aiFailureCodes.contains($0.failure.code) && MeetingPipelineState.validFailure($0.failure) }) else { throw invalid }
    }
    static func readLegacy(_ directory: URL, transcriptData: Data) throws -> Intent? {
        let file = directory.appendingPathComponent("notes-recovery.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try ArchiveBacklog.read(file)
        guard data.count <= 16_384 else { throw invalid }
        let value = try JSONDecoder().decode(Intent.self, from: data)
        try validate(value, identity: MeetingPipelineState.identity(directory), transcriptHash: AudioRetention.digest(transcriptData))
        return value
    }
    static func read(_ directory: URL, transcriptData: Data) throws -> Intent? {
        let state = try MeetingPipelineState.load(directory)
        guard let value = state.notesRecovery else { return nil }
        try validate(value, identity: state.recordingIdentity, transcriptHash: AudioRetention.digest(transcriptData))
        return value
    }
    static func active(_ directory: URL, retry: ArchiveBacklog.Retry?, transcriptData: Data) throws -> Request? {
        let intent = try read(directory, transcriptData: transcriptData)
        if let id = retry?.recoveryID {
            if intent?.request.id == id { return intent?.request }
            if intent?.previousRequest?.id == id { return intent?.previousRequest }
            throw invalid
        }
        return nil
    }
    static func prepare(_ directory: URL, kind: Kind, now: Double = Date().timeIntervalSince1970,
                        activityLockPath: URL = HelperWorkLease.path) throws -> Request {
        let lease = try HelperWorkLease.acquire(at: activityLockPath)
        defer { withExtendedLifetime(lease) {} }
        guard try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
              try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw invalid }
        guard let archiveLock = try AppRunLock.acquire(at: directory.appendingPathComponent("archive.lock")) else {
            throw TranscriptionFailure("This meeting is being saved. Wait for it to finish before retrying.")
        }
        defer { withExtendedLifetime(archiveLock) {} }
        guard ArchiveBacklog.isFinished(directory),
              !FileManager.default.fileExists(atPath: directory.appendingPathComponent("archive-receipt.json").path),
              try ArchiveBacklog.object(directory.appendingPathComponent("meta.json"))["notes_mode"] as? String == "ai" else { throw invalid }
        let item = ArchiveBacklog.inspect(directory)
        guard item.state == .needsReview, let retry = item.retry,
              permits(kind, failure: retry.lastError, completions: retry.completionAttempts ?? 0), let failure = retry.lastError else { throw invalid }
        var state = try MeetingPipelineState.load(directory, inspected: item, now: now)
        let data = try ArchiveBacklog.read(directory.appendingPathComponent("transcript.json"))
        let previous = try read(directory, transcriptData: data)
        let armed = try active(directory, retry: retry, transcriptData: data)
        let request = Request(kind: kind, id: UUID().uuidString.lowercased())
        let history = Array(((previous?.history ?? []) + [History(request: request, at: now, failure: failure)]).suffix(10))
        let intent = Intent(schemaVersion: 1, recordingIdentity: try MeetingPipelineState.identity(directory),
                            transcriptSHA256: AudioRetention.digest(data), request: request, history: history, previousRequest: armed)
        // Intent and authorization become visible together. A stale writer cannot
        // replace a newer budget, and no second file can arm half a recovery.
        state.notesRecovery = intent
        state.delivery.recoveryID = request.id
        state.delivery.lastError = nil; state.delivery.lastErrorAt = nil
        state.delivery.nextAttemptAt = now
        state.stage = .transcribed; state.updatedAt = now
        try state.write(directory)
        MeetingLog.append(directory, "Explicit notes recovery requested [\(kind.rawValue)]; earlier attempt counts preserved")
        return request
    }
}
