import Foundation

/// Files remain the delivery queue. Receipts must describe this exact transcript.
enum ArchiveBacklog {
    enum State: String, Codable, Sendable {
        case recording, transcriptionPending, archivePending, exportPending, saved, needsReview, fixture
    }
    struct Item: Codable, Sendable {
        let directory: URL
        let state: State
        let reason: String
        var retry: Retry?
        var pending: Bool { state == .archivePending || state == .exportPending }
    }
    struct Retry: Codable, Sendable {
        var attempts: Int
        var nextAttemptAt: TimeInterval
        var transcriptSHA256: String
        var completionAttempts: Int? = nil
        var lastError: DeliveryFailure? = nil
        static func delay(attempt: Int) -> TimeInterval {
            [30.0, 120, 600, 1800][max(0, min(attempt - 1, 3))]
        }
    }
    static func read(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 20_000_000 else {
            throw TranscriptionFailure("Archive check requires a regular local file.")
        }
        return try Data(contentsOf: url)
    }
    static func object(_ url: URL) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: read(url)) as? [String: Any] else {
            throw TranscriptionFailure("Archive check could not read metadata.")
        }
        return value
    }
    static func isFinished(_ dir: URL) -> Bool {
        guard let meta = try? object(dir.appendingPathComponent("meta.json")),
              let status = meta["status"] as? String else { return false }
        return status == "interrupted" || (status == "stopped" && !(meta["ended"] as? String ?? "").isEmpty)
    }
    static func receiptIdentityMatches(_ receipt: [String: Any], transcriptData: Data, meta: [String: Any], directory: URL) -> Bool {
        guard let transcript = (try? JSONSerialization.jsonObject(with: transcriptData)) as? [String: Any],
              let segments = transcript["segments"] as? [[String: Any]],
              let started = meta["started"] as? String, !started.isEmpty else { return false }
        let id = meta["recording_id"] as? String ?? directory.lastPathComponent
        let expected = "teams-" + AudioRetention.digest(Data((started + "\n" + id).utf8)).prefix(24)
        return receipt["saved"] as? Bool == true && receipt["sessionId"] as? String == expected
            && receipt["utteranceCount"] as? Int == segments.count
    }
    static func receiptMatches(_ receipt: [String: Any], transcriptData: Data, meta: [String: Any], directory: URL) -> Bool {
        receiptIdentityMatches(receipt, transcriptData: transcriptData, meta: meta, directory: directory)
            && receipt["localTranscriptSHA256"] as? String == AudioRetention.digest(transcriptData)
    }
    static func inspect(_ dir: URL, notesRoot: URL = MeetingNotesSettings.folder) -> Item {
        func item(_ state: State, _ reason: String) -> Item { Item(directory: dir, state: state, reason: reason) }
        do {
            let values = try dir.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { return item(.needsReview, "Linked or invalid recording folder") }
            let meta = try object(dir.appendingPathComponent("meta.json"))
            if meta["status"] as? String == "recording" { return item(.recording, "Capture still active") }
            if meta["fixture"] as? Bool == true { return item(.fixture, "Synthetic capture excluded from automatic delivery") }
            guard isFinished(dir) else { return item(.needsReview, "Recording is not confirmed finished") }
            let transcriptURL = dir.appendingPathComponent("transcript.json")
            guard FileManager.default.fileExists(atPath: transcriptURL.path) else { return item(.transcriptionPending, "Finished recording has no transcript") }
            let data = try read(transcriptURL)
            guard let transcript = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  transcript["segments"] is [[String: Any]] else { return item(.needsReview, "Transcript is invalid") }
            var retry: Retry?
            let retryURL = dir.appendingPathComponent("archive-retry.json")
            if FileManager.default.fileExists(atPath: retryURL.path) {
                let saved = try JSONDecoder().decode(Retry.self, from: read(retryURL))
                guard saved.attempts > 0, saved.nextAttemptAt.isFinite else { return item(.needsReview, "Retry metadata is invalid") }
                if saved.transcriptSHA256 == AudioRetention.digest(data) {
                    retry = saved
                    if saved.lastError?.retryable == false || (saved.completionAttempts ?? 0) >= 3 {
                        return Item(directory: dir, state: .needsReview, reason: saved.lastError?.detail ?? "AI notes stopped after three attempts", retry: retry)
                    }
                }
            }
            let savedReceipt = try? object(dir.appendingPathComponent("archive-receipt.json"))
            if let receipt = savedReceipt, receipt["localTranscriptSHA256"] == nil,
               receiptIdentityMatches(receipt, transcriptData: data, meta: meta, directory: dir) {
                return item(.needsReview, "Legacy saved receipt lacks a transcript hash; verify delivery before retry")
            }
            guard let receipt = savedReceipt,
                  receiptMatches(receipt, transcriptData: data, meta: meta, directory: dir) else {
                return Item(directory: dir, state: .archivePending, reason: "No verified receipt for this transcript", retry: retry)
            }
            guard receipt["documents"] is [String: Any] else {
                return Item(directory: dir, state: .archivePending, reason: "Gateway receipt has no meeting documents", retry: retry)
            }
            guard let text = try? String(data: read(dir.appendingPathComponent("notes-export-path.txt")), encoding: .utf8),
                  text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") else {
                return Item(directory: dir, state: .exportPending, reason: "Meeting documents not exported", retry: retry)
            }
            let destination = URL(fileURLWithPath: text.trimmingCharacters(in: .whitespacesAndNewlines))
            let notesRoot = try MeetingDocuments.exportRoot(recording: dir, fallbackRoot: notesRoot)
            let base = notesRoot.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            guard destination.standardizedFileURL.path.hasPrefix(notesRoot.standardizedFileURL.path + "/"),
                  destination.resolvingSymlinksInPath().path.hasPrefix(base),
                  (try? read(destination.appendingPathComponent("notes.md"))) != nil,
                  (try? read(destination.appendingPathComponent("transcript.md"))) != nil,
                  let metadata = try? object(destination.appendingPathComponent("metadata.json")),
                  metadata["sessionId"] as? String == receipt["sessionId"] as? String else {
                return Item(directory: dir, state: .exportPending, reason: "Export files missing or do not match the saved meeting", retry: retry)
            }
            if let gaps = transcript["capture_gaps"] as? [Any], !gaps.isEmpty {
                return item(.needsReview, "Notes and transcript saved with capture gaps. Review missing speech; audio is retained.")
            }
            return item(.saved, "Transcript receipt and local export verified")
        } catch { return item(.needsReview, "Recording or retry metadata could not be verified") }
    }
    static func scan(root: URL, notesRoot: URL = MeetingNotesSettings.folder) throws -> [Item] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("meta.json").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { inspect($0, notesRoot: notesRoot) }
    }
    static func reserve(_ item: Item, now: TimeInterval) throws {
        let data = try read(item.directory.appendingPathComponent("transcript.json"))
        let attempts = min((item.retry?.attempts ?? 0) + 1, 1000)
        let retry = Retry(attempts: attempts, nextAttemptAt: now + Retry.delay(attempt: attempts), transcriptSHA256: AudioRetention.digest(data),
                          completionAttempts: item.retry?.completionAttempts, lastError: item.retry?.lastError)
        let path = item.directory.appendingPathComponent("archive-retry.json")
        try JSONEncoder().encode(retry).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    /// Reconnection or an explicit Retry permits one new authenticated send.
    /// Invalid output, conflicts and paid-attempt limits remain blocked.
    static func rearmSignIn(_ item: Item, now: TimeInterval) throws {
        guard item.retry?.lastError?.code == "sign_in_required", (item.retry?.completionAttempts ?? 0) < 3 else { return }
        let file = item.directory.appendingPathComponent("archive-retry.json")
        var retry = try JSONDecoder().decode(Retry.self, from: read(file))
        guard retry.lastError?.code == "sign_in_required", retry.transcriptSHA256 == item.retry?.transcriptSHA256 else { return }
        retry.lastError = nil
        retry.nextAttemptAt = now
        try JSONEncoder().encode(retry).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func recordFailure(_ error: Error, directory: URL) throws {
        let path = directory.appendingPathComponent("archive-retry.json")
        var retry = try JSONDecoder().decode(Retry.self, from: read(path))
        var failure = DeliveryFailure.classify(error)
        if failure.completionAttempted { retry.completionAttempts = min((retry.completionAttempts ?? 0) + 1, 3) }
        if (retry.completionAttempts ?? 0) >= 3 {
            failure = DeliveryFailure(code: "ai_retry_limit", detail: "AI notes stopped after three attempts. Review this meeting or save transcript-only notes.", retryable: false, completionAttempted: failure.completionAttempted)
        }
        retry.lastError = failure
        try JSONEncoder().encode(retry).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
}
