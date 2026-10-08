import Foundation
import CryptoKit

/// Sends a closed text-only envelope. Never reads or sends audio files.
enum GatewayArchive {
    static var userAgent: String { "ClawMinutes/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development") CFNetwork" }
    enum ConnectionIssue: Error, CustomStringConvertible {
        case routeUnavailable
        var description: String { "The Teams transcription endpoint returned HTTP 404. Check the plugin route, enabled state, version, and proxy destination on the Gateway. This response does not establish whether the plugin is installed. Captured audio and transcripts are preserved on this Mac." }
    }
    private static let loginLock = NSLock()
    nonisolated(unsafe) private static var loginProcess: Process?
    static func cancelLogin() {
        loginLock.lock(); defer { loginLock.unlock() }
        if let process = loginProcess, process.isRunning { process.terminate() }
    }
    static func origin(_ value: String) throws -> URL {
        guard let url = URL(string: value), let host = url.host,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host))
        else { throw TranscriptionFailure("Enter a Gateway HTTPS origin, or loopback HTTP for a local Gateway.") }
        return url
    }

    static func tokenStore(_ url: URL) -> ElevenLabsKeychain {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return ElevenLabsKeychain(service: "ai.openclaw.teams-transcribe.gateway." + digest)
    }

    static func cloudflared() throws -> URL {
        let candidates = [Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/cloudflared").path,
                          "/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { throw TranscriptionFailure("The plugin helper bundle is missing cloudflared. Reinstall the bundled helper.") }
        return URL(fileURLWithPath: path)
    }

    /// Called only after a user chooses Sign in. Uses the system browser and
    /// cloudflared's application-scoped cache, never GitHub credentials.
    static func login(_ url: URL) throws {
        let task = Process()
        task.executableURL = try cloudflared()
        task.arguments = ["access", "login", "--quiet", "--auto-close", url.absoluteString]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        loginLock.lock(); loginProcess = task; loginLock.unlock()
        let timeout = DispatchWorkItem { cancelLogin() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: timeout)
        defer {
            timeout.cancel()
            loginLock.lock(); loginProcess = nil; loginLock.unlock()
        }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw TranscriptionFailure("Gateway sign-in did not finish. Try Connect Gateway again.") }
    }

    static func cloudflareToken(_ url: URL) throws -> String {
        let task = Process(), output = Pipe()
        task.executableURL = try cloudflared()
        task.arguments = ["access", "token", "--app", url.absoluteString]
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard task.terminationStatus == 0, token.count > 16, token.count < 16000,
              token.allSatisfy({ !$0.isWhitespace }), token.split(separator: ".").count == 3
        else { throw DeliveryFailure.signInRequired }
        let payload = token.split(separator: ".")[1]
        var base64 = String(payload).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let claims = Data(base64Encoded: base64).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
              let expiry = claims["exp"] as? Double, expiry > Date().timeIntervalSince1970 + 30 else {
            throw DeliveryFailure.signInRequired
        }
        return token
    }

    static func envelope(meta: [String: Any], transcript: [String: Any], recordingID: String) throws -> Data {
        var verifiedMeta = meta
        verifiedMeta["recording_id"] = recordingID
        _ = try MeetingRevisions.descriptor(meta: verifiedMeta, directory: URL(fileURLWithPath: "/unused"))
        if let recovery = meta["notes_recovery"] { _ = try NotesRecovery.Request.decode(recovery) }
        let metaKeys = ["started", "ended", "audio_started_at", "status", "fixture", "notes_mode", "note_template", "meeting_context", "participants", "revision", "notes_recovery"]
        let transcriptKeys = ["engine", "model", "created_at", "execution_machine", "execution_location", "segments", "capture_gaps"]
        let segmentKeys: Set<String> = ["speaker", "start_ms", "end_ms", "text", "source", "speaker_name", "attribution"]
        var text = transcript.filter { transcriptKeys.contains($0.key) }
        guard let segments = text["segments"] as? [[String: Any]] else { throw TranscriptionFailure("Transcript has no utterances") }
        text["segments"] = segments.map { $0.filter { segmentKeys.contains($0.key) } }
        if let gaps = text["capture_gaps"] as? [[String: Any]] {
            text["capture_gaps"] = gaps.map { $0.filter { ["source", "start_ms", "end_ms", "reason"].contains($0.key) } }
        }
        return try JSONSerialization.data(withJSONObject: ["recordingId": recordingID, "meta": meta.filter { metaKeys.contains($0.key) }, "transcript": text])
    }

    static func request(body: Data? = nil, verifying: Bool = false) async throws -> Data {
        let config = Config.gateway(), url = try origin(config["url"] ?? "")
        var request = URLRequest(url: url.appendingPathComponent("plugins/teams-transcribe/ingest"))
        if verifying {
            var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "mode", value: "verify")]
            request.url = components.url
        }
        request.timeoutInterval = body == nil ? 30 : 150
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if config["authentication"] == "cloudflare" {
            let token = try await Task.detached { try cloudflareToken(url) }.value
            request.setValue("CF_Authorization=" + token, forHTTPHeaderField: "Cookie")
        } else {
            guard let token = try await Task.detached(operation: { try tokenStore(url).read() }).value else {
                throw DeliveryFailure.signInRequired
            }
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: NoGatewayRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TranscriptionFailure("Gateway returned no HTTP response") }
        guard http.statusCode == 200, http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/json") == true else {
            throw DeliveryFailure.response(status: http.statusCode, data: data)
        }
        return data
    }

    static func status() async throws -> GatewayCapabilities {
        let data = try await request()
        return try GatewayCapabilities.verify(data)
    }

    static func deliveryMetadata(_ original: [String: Any], directory dir: URL) -> [String: Any] {
        var meta = original
        if let rosterData = try? ArchiveBacklog.read(dir.appendingPathComponent("participants.json")),
           let roster = try? JSONDecoder().decode(ParticipantRoster.self, from: rosterData) {
            let sources: Set<String> = ["meeting_roster", "meeting_tile", "meeting_ui", "accessibility_active_speaker", "meeting_tile_edge"]
            let joined = roster.participants.compactMap { member -> [String: Any]? in
                let evidence = member.sources.filter { sources.contains($0) }
                guard !evidence.isEmpty else { return nil }
                return ["name": member.name, "first_seen": member.first_seen, "last_seen": member.last_seen, "sources": evidence]
            }
            meta["participants"] = ["joined": joined, "coverage": joined.isEmpty ? "unavailable" : "partial", "invited": [], "invitees_status": "unavailable"]
        }
        return meta
    }

    static func deliveryEnvelope(_ directory: URL, meta: [String: Any], transcriptData: Data) throws -> Data {
        var metadata = deliveryMetadata(meta, directory: directory)
        let state = try MeetingPipelineState.load(directory)
        if let recovery = try NotesRecovery.active(directory, retry: state.deliveryRetry, transcriptData: transcriptData) {
            metadata["notes_recovery"] = recovery.json
        }
        let transcript = try JSONSerialization.jsonObject(with: transcriptData) as? [String: Any] ?? [:]
        return try envelope(meta: metadata, transcript: transcript,
            recordingID: meta["recording_id"] as? String ?? directory.lastPathComponent)
    }
    /// Object key ordering is not a source change. Array order remains significant.
    static func envelopeFingerprint(_ body: Data) throws -> String {
        AudioRetention.digest(try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: body), options: [.sortedKeys]))
    }
    static func sourceFingerprint(_ directory: URL, meta: [String: Any], transcriptData: Data) throws -> String {
        try envelopeFingerprint(deliveryEnvelope(directory, meta: meta, transcriptData: transcriptData))
    }

    /// Filesystem-only writer. Caller must own the lifecycle lease and archive.lock.
    /// Both fingerprints and document validation are required before exporting.
    static func exportVerifiedReceipt(_ dir: URL, fallbackRoot: URL = MeetingNotesSettings.folder) throws {
        guard ArchiveBacklog.isFinished(dir) else { throw MeetingPipelineState.invalidState }
        let receipt = try ArchiveBacklog.object(dir.appendingPathComponent("archive-receipt.json"))
        let meta = try ArchiveBacklog.object(dir.appendingPathComponent("meta.json"))
        let transcript = try ArchiveBacklog.read(dir.appendingPathComponent("transcript.json"))
        guard ArchiveBacklog.receiptMatches(receipt, transcriptData: transcript, meta: meta, directory: dir) else {
            throw MeetingPipelineState.invalidState
        }
        _ = try MeetingDocuments.validateDocuments(receipt)
        let root = try MeetingDocuments.exportRoot(recording: dir, fallbackRoot: fallbackRoot)
        let destination = try MeetingDocuments.export(receipt: receipt, root: root, recording: dir)
        try MeetingDocuments.rememberExport(destination, root: root, recording: dir, sessionID: receipt["sessionId"] as! String)
    }

    static func save(_ dir: URL,
                     transport: @Sendable (Data) async throws -> Data = { try await request(body: $0) },
                     capabilityTransport: @Sendable () async throws -> Data = { try await request() },
                     exportRootOverride: URL? = nil, activityLockPath: URL = HelperWorkLease.path) async throws {
        let workLease = try HelperWorkLease.acquire(at: activityLockPath)
        defer { withExtendedLifetime(workLease) {} }
        guard ArchiveBacklog.isFinished(dir) else { throw TranscriptionFailure("Active or incomplete recording left untouched.") }
        guard let archiveLease = try AppRunLock.acquire(at: dir.appendingPathComponent("archive.lock")) else {
            throw TranscriptionFailure("This meeting is already being saved. Recording preserved.")
        }
        defer { withExtendedLifetime(archiveLease) {} }
        guard ArchiveBacklog.isFinished(dir) else { throw TranscriptionFailure("Active or incomplete recording left untouched.") }
        let exportRoot = exportRootOverride ?? MeetingNotesSettings.folder
        let meta = try ArchiveBacklog.object(dir.appendingPathComponent("meta.json"))
        let transcriptData = try ArchiveBacklog.read(dir.appendingPathComponent("transcript.json"))
        let transcript = try JSONSerialization.jsonObject(with: transcriptData) as? [String: Any] ?? [:]
        if let data = try? ArchiveBacklog.read(dir.appendingPathComponent("archive-receipt.json")),
           let receipt = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], receipt["saved"] as? Bool == true,
           ArchiveBacklog.receiptMatches(receipt, transcriptData: transcriptData, meta: meta, directory: dir),
           receipt["documents"] != nil {
            try exportVerifiedReceipt(dir, fallbackRoot: exportRoot)
            return
        }
        if let receipt = try? ArchiveBacklog.object(dir.appendingPathComponent("archive-receipt.json")), receipt["saved"] as? Bool == true,
           !LegacyReceiptReconciliation.declaredFingerprintsMatch(receipt, directory: dir, meta: meta, transcriptData: transcriptData) {
            throw TranscriptionFailure("This meeting differs from its saved receipt. Review it and create a new revision before sending changes.")
        }
        if let receipt = try? ArchiveBacklog.object(dir.appendingPathComponent("archive-receipt.json")),
           LegacyReceiptReconciliation.needsVerification(receipt),
           ArchiveBacklog.receiptIdentityMatches(receipt, transcriptData: transcriptData, meta: meta, directory: dir) {
            throw TranscriptionFailure(LegacyReceiptReconciliation.reason)
        }
        if let receipt = try? ArchiveBacklog.object(dir.appendingPathComponent("archive-receipt.json")), receipt["saved"] as? Bool == true {
            throw TranscriptionFailure("This meeting differs from its saved receipt. Review it and create a new revision before sending changes.")
        }
        let retry = try MeetingPipelineState.load(dir).deliveryRetry
        guard retry == nil || retry?.transcriptSHA256 == AudioRetention.digest(transcriptData) else { throw MeetingPipelineState.invalidState }
        let body = try deliveryEnvelope(dir, meta: meta, transcriptData: transcriptData)
        let sourceHash = try envelopeFingerprint(body)
        // Verify before transmitting speech. Receipted local-export recovery
        // above remains usable offline and does not need this request.
        let capabilities = try GatewayCapabilities.verify(await capabilityTransport())
        try capabilities.verifyCaptureEvidence(in: body)
        let data = try await transport(body)
        guard var receipt = try JSONSerialization.jsonObject(with: data) as? [String: Any], receipt["saved"] as? Bool == true,
              let sessionID = receipt["sessionId"] as? String, sessionID.hasPrefix("teams-"),
              receipt["utteranceCount"] as? Int == (transcript["segments"] as? [Any])?.count else {
            throw TranscriptionFailure("Gateway archive readback receipt missing. Recording preserved.")
        }
        // Keep the receipt before exporting. A failed local export can be retried without losing the archive result.
        _ = try MeetingDocuments.validateDocuments(receipt)
        guard ArchiveBacklog.receiptIdentityMatches(receipt, transcriptData: transcriptData, meta: meta, directory: dir) else {
            throw TranscriptionFailure("Gateway returned a different meeting identity. Local files are preserved.")
        }
        guard (try? ArchiveBacklog.read(dir.appendingPathComponent("transcript.json"))) == transcriptData,
              (try? sourceFingerprint(dir, meta: ArchiveBacklog.object(dir.appendingPathComponent("meta.json")), transcriptData: transcriptData)) == sourceHash else {
            let evidence = dir.appendingPathComponent("delivery-conflict." + sourceHash + ".json")
            if !FileManager.default.fileExists(atPath: evidence.path) {
                let conflict: [String: Any] = ["request": try JSONSerialization.jsonObject(with: body), "receipt": receipt, "sourceSHA256": sourceHash]
                try JSONSerialization.data(withJSONObject: conflict, options: [.sortedKeys]).write(to: evidence, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: evidence.path)
            }
            throw DeliveryFailure(code: "saved_source_changed", detail: "Transcript or meeting details changed during delivery. The original request and Gateway response are kept for review. They do not verify the current version.", retryable: false, completionAttempted: false)
        }
        receipt["localTranscriptSHA256"] = AudioRetention.digest(transcriptData)
        receipt["localEnvelopeSHA256"] = sourceHash
        guard ArchiveBacklog.receiptMatches(receipt, transcriptData: transcriptData, meta: meta, directory: dir) else {
            throw TranscriptionFailure("Gateway receipt does not match this recording. Audio kept.")
        }
        try JSONSerialization.data(withJSONObject: receipt).write(to: dir.appendingPathComponent("archive-receipt.json"), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dir.appendingPathComponent("archive-receipt.json").path)
        if receipt["documents"] != nil {
            try exportVerifiedReceipt(dir, fallbackRoot: exportRoot)
        }
    }
}

final class NoGatewayRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
