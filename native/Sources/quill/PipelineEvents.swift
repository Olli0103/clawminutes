import Foundation

/// A bounded operational log. It never accepts meeting titles, speech,
/// participant names, paths, provider responses or free-form error messages.
enum PipelineEvents {
    struct Event: Codable, Sendable {
        let schemaVersion: Int
        let time: Double
        let recordingRef: String
        let stage: MeetingPipelineState.Stage
        let transcriptionAttempts: Int
        let deliveryAttempts: Int
        let errorCode: String?
        let localExportAttempts: Int?
        let localExportErrorCode: String?
        let completionAttempts: Int?
        let paidBudgetUnverified: Bool?
    }
    static let maximumBytes = 1_000_000
    static let knownCodes: Set<String> = [
        "local_model_missing", "speech_credentials_missing", "speech_recognition_failed", "speech_retry_limit",
        "pipeline_state_invalid", "pipeline_state_conflict", "legacy_attempts_unverified", "sign_in_required", "network_unavailable", "plugin_unavailable",
        "gateway_unavailable", "plugin_update_needed", "local_save_failed", "local_save_unverified", "local_export_failed", "local_export_retry_limit", "revision_conflict", "revision_parent_unavailable",
        "ai_retry_limit", "ai_invalid_output", "ai_completion_failed", "ai_input_too_large", "ai_tool_attempt",
        "notes_model_unavailable", "notes_owner_required", "notes_cache_failed", "notes_state_conflict", "notes_recovery_unavailable", "notes_retry_consumed",
        "archive_integrity", "content_type_required", "invalid_payload", "method_not_allowed",
        "payload_too_large", "save_in_progress"
    ]
    static func safeCode(_ value: String?) -> String? {
        value.map { knownCodes.contains($0) ? $0 : "unclassified_error" }
    }
    @discardableResult static func record(_ state: MeetingPipelineState,
                                          at root: URL = Config.path.deletingLastPathComponent()) -> Bool {
        do {
            let event = Event(schemaVersion: 2, time: state.updatedAt,
                              recordingRef: AudioRetention.digest(Data(state.recordingIdentity.utf8)).prefix(24).description,
                              stage: state.stage, transcriptionAttempts: state.transcription.count,
                              deliveryAttempts: state.delivery.count,
                              errorCode: safeCode(state.transcription.lastError?.code ?? state.delivery.lastError?.code ?? state.localExport?.lastError?.code),
                              localExportAttempts: state.localExport?.count,
                              localExportErrorCode: safeCode(state.localExport?.lastError?.code),
                              completionAttempts: state.delivery.completionAttempts,
                              paidBudgetUnverified: state.delivery.budgetUnverified)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let lock = root.appendingPathComponent("events.lock")
            let descriptor = open(lock.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { return false }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
            defer { flock(descriptor, LOCK_UN) }
            let file = root.appendingPathComponent("events.jsonl")
            if FileManager.default.fileExists(atPath: file.path) {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { return false }
                if values.fileSize ?? 0 >= maximumBytes {
                    let previous = root.appendingPathComponent("events.previous.jsonl")
                    guard rename(file.path, previous.path) == 0 else { return false }
                }
            }
            let output = open(file.path, O_CREAT | O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard output >= 0 else { return false }
            defer { close(output) }
            guard fstat(output, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return false }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let line = try encoder.encode(event) + Data("\n".utf8)
            return line.withUnsafeBytes { Darwin.write(output, $0.baseAddress, $0.count) == $0.count }
        } catch { return false }
    }
    static func recent(at root: URL, limit: Int = 100) -> [Event] {
        var result: [Event] = []
        for name in ["events.previous.jsonl", "events.jsonl"] {
            let file = root.appendingPathComponent(name)
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= maximumBytes + 4096,
                  let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) else { continue }
            result += text.split(separator: "\n").compactMap { line in
                guard let event = try? JSONDecoder().decode(Event.self, from: Data(line.utf8)),
                      [1, 2].contains(event.schemaVersion), event.time.isFinite,
                      event.recordingRef.range(of: #"^[0-9a-f]{24}$"#, options: .regularExpression) != nil,
                      (0...1000).contains(event.transcriptionAttempts), (0...1000).contains(event.deliveryAttempts),
                      event.localExportAttempts.map({ (0...1000).contains($0) }) ?? true,
                      event.completionAttempts.map({ (0...3).contains($0) }) ?? true,
                      event.errorCode == safeCode(event.errorCode),
                      event.localExportErrorCode == safeCode(event.localExportErrorCode) else { return nil }
                return event
            }
        }
        return Array(result.suffix(max(0, min(limit, 100))))
    }
}
