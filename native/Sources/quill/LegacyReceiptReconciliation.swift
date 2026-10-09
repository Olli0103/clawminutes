import Foundation

/// An explicit, text-only canonical readback. Unknown AI budgets are preserved.
enum LegacyReceiptReconciliation {
    static let reason = "Saved receipt lacks a complete source fingerprint; verify delivery before retry"
    static func receiptAbsent(_ directory: URL) -> Bool {
        var info = stat()
        return lstat(directory.appendingPathComponent("archive-receipt.json").path, &info) != 0 && errno == ENOENT
    }
    static func needsVerification(_ receipt: [String: Any]) -> Bool {
        receipt["localTranscriptSHA256"] == nil || receipt["localEnvelopeSHA256"] == nil
    }
    static func declaredFingerprintsMatch(_ receipt: [String: Any], directory: URL, meta: [String: Any], transcriptData: Data) -> Bool {
        if let declared = receipt["localTranscriptSHA256"], declared as? String != AudioRetention.digest(transcriptData) { return false }
        if let declared = receipt["localEnvelopeSHA256"] {
            guard let hash = declared as? String, hash == (try? GatewayArchive.sourceFingerprint(directory, meta: meta, transcriptData: transcriptData)) else { return false }
        }
        return true
    }
    struct Plan: Sendable {
        let directory: URL, exportRoot: URL
        let directoryIdentity: String
        let snapshot: [String: String]
        let body: Data
        let transcriptSHA256: String
        let sessionID: String
        let utterances: Int
        var receiptWasMissing: Bool { snapshot["archive-receipt.json"] == "absent" }
    }
    struct Result: Sendable { let exported: Bool; let detail: String }
    static let changed = TranscriptionFailure("Meeting files changed after review. Review again before verifying delivery.")
    static func detail(_ error: Error) -> String {
        if let known = error as? TranscriptionFailure { return known.description }
        if let known = error as? DeliveryFailure { return known.detail }
        return "Verification or local repair did not finish. Check the Gateway connection and this meeting's files before reviewing again."
    }
    static let inputs = ["meta.json", "transcript.json", "archive-receipt.json", "participants.json", "state.json",
        "archive-retry.json", "notes-recovery.json", "notes-export-path.txt", "notes-export-location.json"]
    private static func snapshot(_ directory: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for name in inputs {
            let file = directory.appendingPathComponent(name)
            var info = stat()
            if lstat(file.path, &info) != 0, errno == ENOENT { result[name] = "absent" }
            else { result[name] = AudioRetention.digest(try ArchiveBacklog.read(file)) }
        }
        return result
    }
    static func prepare(_ directory: URL, notesRoot: URL = MeetingNotesSettings.folder) throws -> Plan {
        guard ArchiveBacklog.isFinished(directory) else { throw TranscriptionFailure("Finish this recording before verifying delivery.") }
        let identity = try NotesMigration.destinationIdentity(directory)
        let initial = try snapshot(directory)
        let state = try MeetingPipelineState.load(directory)
        let meta = try ArchiveBacklog.object(directory.appendingPathComponent("meta.json"))
        let data = try ArchiveBacklog.read(directory.appendingPathComponent("transcript.json"))
        guard state.delivery.transcriptSHA256 == nil || state.delivery.transcriptSHA256 == AudioRetention.digest(data) else {
            throw TranscriptionFailure("The earlier local delivery fingerprint differs. Review the original source before reconciling this receipt. Existing budgets and files remain unchanged.")
        }
        let transcript = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let body = try GatewayArchive.deliveryEnvelope(directory, meta: meta, transcriptData: data)
        let id = "teams-" + state.recordingIdentity.prefix(24)
        if initial["archive-receipt.json"] != "absent" {
            let receipt = try ArchiveBacklog.object(directory.appendingPathComponent("archive-receipt.json"))
            guard needsVerification(receipt),
                  declaredFingerprintsMatch(receipt, directory: directory, meta: meta, transcriptData: data),
                  ArchiveBacklog.receiptIdentityMatches(receipt, transcriptData: data, meta: meta, directory: directory),
                  receipt["sessionId"] as? String == id else {
                throw TranscriptionFailure("A matching legacy saved receipt was not found. Local files are preserved.")
            }
        }
        let root = try MeetingDocuments.exportRoot(recording: directory, fallbackRoot: notesRoot,
            missingReceiptSessionID: initial["archive-receipt.json"] == "absent" ? id : nil)
        guard try snapshot(directory) == initial else { throw changed }
        return Plan(directory: directory, exportRoot: root, directoryIdentity: identity, snapshot: initial, body: body,
            transcriptSHA256: AudioRetention.digest(data), sessionID: id, utterances: (transcript["segments"] as? [Any])?.count ?? 0)
    }
    static func apply(_ plan: Plan,
        transport: @Sendable (Data) async throws -> Data = { try await GatewayArchive.request(body: $0, verifying: true) },
        capabilityTransport: @Sendable () async throws -> Data = { try await GatewayArchive.request() },
        activityLockPath: URL = HelperWorkLease.path) async throws -> Result {
        // A stale review must not create a lock through a replaced directory.
        guard try NotesMigration.destinationIdentity(plan.directory) == plan.directoryIdentity else { throw changed }
        let work = try HelperWorkLease.acquire(at: activityLockPath)
        defer { withExtendedLifetime(work) {} }
        guard let lock = try AppRunLock.acquire(at: plan.directory.appendingPathComponent("archive.lock")) else {
            throw TranscriptionFailure("This meeting is being processed. Wait, then review again.")
        }
        defer { withExtendedLifetime(lock) {} }
        func validate() throws {
            guard try NotesMigration.destinationIdentity(plan.directory) == plan.directoryIdentity,
                  try snapshot(plan.directory) == plan.snapshot, ArchiveBacklog.isFinished(plan.directory) else { throw changed }
            _ = try MeetingPipelineState.load(plan.directory)
        }
        try validate()
        let capabilities = try GatewayCapabilities.verify(await capabilityTransport())
        guard capabilities.capabilities.receiptVerification == 1 else { throw GatewayCapabilities.unsupported }
        try capabilities.verifyCaptureEvidence(in: plan.body)
        let data = try await transport(plan.body)
        guard data.count <= 20_000_000, var receipt = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let proof = receipt["verification"] as? [String: Any], proof["version"] as? Int == 1,
              proof["mode"] as? String == "canonical_readback", proof["requestSHA256"] as? String == AudioRetention.digest(plan.body),
              receipt["saved"] as? Bool == true, receipt["sessionId"] as? String == plan.sessionID,
              receipt["utteranceCount"] as? Int == plan.utterances, receipt["documents"] is [String: Any] else {
            throw TranscriptionFailure("The Gateway did not verify this exact transcript. Local files are preserved.")
        }
        _ = try MeetingDocuments.validateDocuments(receipt)
        try validate()
        if !plan.receiptWasMissing {
            let old = try ArchiveBacklog.read(plan.directory.appendingPathComponent("archive-receipt.json"))
            let backup = plan.directory.appendingPathComponent("archive-receipt.legacy-" + AudioRetention.digest(old) + ".json")
            if FileManager.default.fileExists(atPath: backup.path) {
                guard try ArchiveBacklog.read(backup) == old else { throw changed }
            } else {
                try old.write(to: backup, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            }
        }
        receipt["localTranscriptSHA256"] = plan.transcriptSHA256
        receipt["localEnvelopeSHA256"] = try GatewayArchive.envelopeFingerprint(plan.body)
        let file = plan.directory.appendingPathComponent("archive-receipt.json")
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        do {
            let destination = try MeetingDocuments.export(receipt: receipt, root: plan.exportRoot, recording: plan.directory)
            try MeetingDocuments.rememberExport(destination, root: plan.exportRoot, recording: plan.directory, sessionID: plan.sessionID)
            var state = try MeetingPipelineState.load(plan.directory)
            state.reconcile(ArchiveBacklog.inspect(plan.directory, notesRoot: plan.exportRoot), now: Date().timeIntervalSince1970)
            try state.write(plan.directory)
            return Result(exported: true, detail: "Gateway delivery verified. Local receipt and notes location repaired. Existing edits and audio remain.")
        } catch {
            return Result(exported: false, detail: "Gateway delivery verified and local receipt repaired. Local export or progress still needs review. Retrying the verified export does not call the model. Audio remains.")
        }
    }
}
