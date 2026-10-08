import Foundation

/// Files remain the delivery queue. Receipts must describe this exact transcript.
enum ArchiveBacklog {
    enum VerifiedText: String, Codable, Sendable {
        case transcript, archive, exported
        var includesDelivery: Bool { self == .archive || self == .exported }
    }
    enum State: String, Codable, Sendable {
        case recording, transcriptionPending, archivePending, exportPending, saved, needsReview, fixture
    }
    struct Item: Codable, Sendable {
        let directory: URL
        let state: State
        let reason: String
        var retry: Retry?
        var verifiedText: VerifiedText? = nil
        var exportRetry: MeetingPipelineState.ExportAttempt? = nil
        var nextAttemptAt: Double { verifiedText == .archive ? exportRetry?.nextAttemptAt ?? 0 : retry?.nextAttemptAt ?? 0 }
        var pending: Bool { state == .archivePending || state == .exportPending }
    }
    struct Retry: Codable, Equatable, Sendable {
        var attempts: Int
        var nextAttemptAt: TimeInterval
        var transcriptSHA256: String
        var completionAttempts: Int? = nil
        var lastError: DeliveryFailure? = nil
        var recoveryID: String? = nil
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
        guard let sourceHash = receipt["localEnvelopeSHA256"] as? String else { return false }
        return receiptIdentityMatches(receipt, transcriptData: transcriptData, meta: meta, directory: directory)
            && receipt["localTranscriptSHA256"] as? String == AudioRetention.digest(transcriptData)
            && sourceHash == (try? GatewayArchive.sourceFingerprint(directory, meta: meta, transcriptData: transcriptData))
    }
    static func inspect(_ dir: URL, notesRoot: URL = MeetingNotesSettings.folder) -> Item {
        var verifiedText: VerifiedText?
        var exportRetry: MeetingPipelineState.ExportAttempt?
        func item(_ state: State, _ reason: String, retry: Retry? = nil) -> Item {
            Item(directory: dir, state: state, reason: reason, retry: retry, verifiedText: verifiedText, exportRetry: exportRetry)
        }
        do {
            let values = try dir.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { return item(.needsReview, "Linked or invalid recording folder") }
            let meta = try object(dir.appendingPathComponent("meta.json"))
            if meta["status"] as? String == "recording" { return item(.recording, "Capture still active") }
            if meta["fixture"] as? Bool == true { return item(.fixture, "Synthetic capture excluded from automatic delivery") }
            guard isFinished(dir) else { return item(.needsReview, "Recording is not confirmed finished") }
            let transcriptURL = dir.appendingPathComponent("transcript.json")
            guard FileManager.default.fileExists(atPath: transcriptURL.path) else {
                let pending = item(.transcriptionPending, "Waiting to transcribe")
                let stateFile = dir.appendingPathComponent("state.json")
                if FileManager.default.fileExists(atPath: stateFile.path) {
                    let state = try MeetingPipelineState.load(dir, inspected: pending)
                    if let failure = state.transcription.lastError {
                        return item(!failure.retryable || state.transcription.count >= 3 ? .needsReview : .transcriptionPending, failure.detail)
                    }
                    if state.transcription.count >= 3 { return item(.needsReview, "Speech recognition stopped after three attempts. Audio is retained.") }
                }
                return pending
            }
            let data = try read(transcriptURL)
            guard let transcript = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  transcript["segments"] is [[String: Any]] else { return item(.needsReview, "Transcript is invalid") }
            verifiedText = .transcript
            let state = try MeetingPipelineState.load(dir)
            let retry = state.deliveryRetry
            exportRetry = state.localExport
            if let retry, retry.transcriptSHA256 != AudioRetention.digest(data) {
                return item(.needsReview, "Transcript changed after a delivery attempt. Create a new revision before sending it again.")
            }
            func pendingDelivery(_ reason: String) throws -> Item {
                let recovery = try NotesRecovery.active(dir, retry: retry, transcriptData: data)
                if retry?.lastError?.retryable == false || ((retry?.completionAttempts ?? 0) >= 3 && recovery?.kind != .transcriptOnly) {
                    return item(.needsReview, retry?.lastError?.detail ?? "AI notes stopped after three attempts", retry: retry)
                }
                return item(.archivePending, reason, retry: retry)
            }
            let savedReceipt = try? object(dir.appendingPathComponent("archive-receipt.json"))
            if let receipt = savedReceipt, receipt["saved"] as? Bool == true,
               !LegacyReceiptReconciliation.declaredFingerprintsMatch(receipt, directory: dir, meta: meta, transcriptData: data) {
                return item(.needsReview, "This meeting differs from its saved receipt. Review it and create a new revision before sending changes.")
            }
            if let receipt = savedReceipt, LegacyReceiptReconciliation.needsVerification(receipt),
               receiptIdentityMatches(receipt, transcriptData: data, meta: meta, directory: dir) {
                return item(.needsReview, LegacyReceiptReconciliation.reason)
            }
            guard let receipt = savedReceipt,
                  receiptMatches(receipt, transcriptData: data, meta: meta, directory: dir) else {
                if savedReceipt?["saved"] as? Bool == true {
                    return item(.needsReview, "This meeting differs from its saved receipt. Review it and create a new revision before sending changes.")
                }
                return try pendingDelivery("No verified receipt for this transcript")
            }
            guard (try? MeetingDocuments.validateDocuments(receipt)) != nil else {
                return item(.needsReview, "Saved receipt has incomplete meeting documents. Review the Gateway archive before retrying.")
            }
            verifiedText = .archive
            func pendingExport(_ reason: String) -> Item {
                let blocked = exportRetry.map { $0.count >= 3 || $0.lastError?.retryable == false } ?? false
                return item(blocked ? .needsReview : .exportPending, exportRetry?.lastError?.detail ?? reason, retry: retry)
            }
            guard let text = try? String(data: read(dir.appendingPathComponent("notes-export-path.txt")), encoding: .utf8),
                  text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") else {
                return pendingExport("Meeting documents not exported")
            }
            let destination = URL(fileURLWithPath: text.trimmingCharacters(in: .whitespacesAndNewlines))
            guard let notesRoot = try? MeetingDocuments.exportRoot(recording: dir, fallbackRoot: notesRoot) else {
                return item(.needsReview, "Saved notes folder needs review. Gateway notes are preserved.", retry: retry)
            }
            let base = notesRoot.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            guard destination.standardizedFileURL.path.hasPrefix(notesRoot.standardizedFileURL.path + "/"),
                  destination.resolvingSymlinksInPath().path.hasPrefix(base),
                  (try? read(destination.appendingPathComponent("notes.md"))) != nil,
                  (try? read(destination.appendingPathComponent("transcript.md"))) != nil,
                  let metadata = try? object(destination.appendingPathComponent("metadata.json")),
                  metadata["sessionId"] as? String == receipt["sessionId"] as? String else {
                return pendingExport("Export files missing or do not match the saved meeting")
            }
            verifiedText = .exported
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
        guard let lock = try AppRunLock.acquire(at: item.directory.appendingPathComponent("archive.lock")) else { throw MeetingPipelineState.conflictingState }
        defer { withExtendedLifetime(lock) {} }
        guard item.state == .archivePending, inspect(item.directory).state == .archivePending else { throw MeetingPipelineState.conflictingState }
        var state = try MeetingPipelineState.load(item.directory)
        let data = try read(item.directory.appendingPathComponent("transcript.json"))
        guard state.deliveryRetry == item.retry,
              state.delivery.transcriptSHA256 == nil || state.delivery.transcriptSHA256 == AudioRetention.digest(data),
              state.delivery.count < 1000 else { throw MeetingPipelineState.conflictingState }
        state.delivery.count += 1
        state.delivery.nextAttemptAt = now + Retry.delay(attempt: state.delivery.count)
        state.delivery.transcriptSHA256 = AudioRetention.digest(data)
        if state.delivery.budgetUnverified != true, state.delivery.completionAttempts == nil { state.delivery.completionAttempts = 0 }
        state.stage = .delivering; state.updatedAt = now
        try state.write(item.directory)
    }

    /// Reconnection permits one authenticated send. Compatibility failures need
    /// a verified handshake. Model errors and paid limits remain blocked.
    static func rearmConnection(_ item: Item, now: TimeInterval, capabilities: GatewayCapabilities? = nil) throws {
        guard item.verifiedText == .transcript else { return }
        let cause = item.retry?.lastError?.code
        guard cause == "sign_in_required" || (cause == "plugin_update_needed" && capabilities != nil) else { return }
        var state = try MeetingPipelineState.load(item.directory)
        guard state.deliveryRetry == item.retry else { throw MeetingPipelineState.conflictingState }
        let transcriptOnly = try NotesRecovery.active(item.directory, retry: state.deliveryRetry,
            transcriptData: read(item.directory.appendingPathComponent("transcript.json")))?.kind == .transcriptOnly
        guard (state.delivery.completionAttempts ?? 0) < 3 || transcriptOnly else { return }
        guard state.delivery.budgetUnverified != true || transcriptOnly else { return }
        state.delivery.lastError = nil; state.delivery.lastErrorAt = nil
        state.delivery.nextAttemptAt = now; state.stage = .transcribed; state.updatedAt = now
        try state.write(item.directory)
    }

    static func recordFailure(_ error: Error, directory: URL) throws {
        var state = try MeetingPipelineState.load(directory)
        let data = try read(directory.appendingPathComponent("transcript.json"))
        guard state.delivery.count > 0, state.delivery.transcriptSHA256 == AudioRetention.digest(data) else { throw MeetingPipelineState.invalidState }
        var failure = DeliveryFailure.classify(error)
        if failure.completionAttempted { state.delivery.completionAttempts = min((state.delivery.completionAttempts ?? 0) + 1, 3) }
        let transcriptOnly = try NotesRecovery.active(directory, retry: state.deliveryRetry, transcriptData: data)?.kind == .transcriptOnly
        if (state.delivery.completionAttempts ?? 0) >= 3 && !transcriptOnly {
            failure = DeliveryFailure(code: "ai_retry_limit", detail: "AI notes stopped after three attempts. Review this meeting or save transcript-only notes.", retryable: false, completionAttempted: failure.completionAttempted)
        }
        state.delivery.lastError = failure; state.delivery.lastErrorAt = Date().timeIntervalSince1970
        state.stage = failure.retryable ? .transcribed : .needsAttention
        state.updatedAt = state.delivery.lastErrorAt!
        try state.write(directory)
    }
}
