import Foundation

enum MeetingRevisions {
    struct Descriptor: Codable, Equatable, Sendable {
        let number: Int
        let baseRecordingId: String
        let parentSessionId: String
        let reason: String
        var recordingId: String { Self.recordingId(base: baseRecordingId, number: number) }
        static func recordingId(base: String, number: Int) -> String {
            "cmrev-" + AudioRetention.digest(Data(base.utf8)).prefix(24) + "-\(number)"
        }
        static func archiveIdentity(started: String, recordingId: String) -> String {
            "teams-" + AudioRetention.digest(Data((started + "\n" + recordingId).utf8)).prefix(24)
        }
        func validate(started: String, recordingId: String) throws {
            let previous = number == 2 ? baseRecordingId : Self.recordingId(base: baseRecordingId, number: number - 1)
            guard (2...1000).contains(number), baseRecordingId.range(of: #"^[-A-Za-z0-9_.]{1,128}$"#, options: .regularExpression) != nil,
                  ["speaker_correction", "template_change", "retranscription"].contains(reason),
                  recordingId == self.recordingId,
                  parentSessionId == Self.archiveIdentity(started: started, recordingId: previous) else { throw invalid }
        }
        var json: [String: Any] { ["number": number, "baseRecordingId": baseRecordingId, "parentSessionId": parentSessionId, "reason": reason] }
    }
    enum Change: Sendable {
        case speaker(indices: Set<Int>, name: String)
        case template(NoteTemplate)
        case retranscribed(Transcript)
        var reason: String {
            switch self { case .speaker: return "speaker_correction"; case .template: return "template_change"; case .retranscribed: return "retranscription" }
        }
    }
    static var invalid: DeliveryFailure {
        DeliveryFailure(code: "revision_conflict", detail: "This meeting's version could not be verified. Existing files are preserved.", retryable: false, completionAttempted: false)
    }
    static func descriptor(meta: [String: Any], directory: URL) throws -> Descriptor? {
        guard let object = meta["revision"] else { return nil }
        guard let fields = object as? [String: Any], Set(fields.keys) == ["number", "baseRecordingId", "parentSessionId", "reason"] else { throw invalid }
        let value = try JSONDecoder().decode(Descriptor.self, from: JSONSerialization.data(withJSONObject: object))
        guard let started = meta["started"] as? String else { throw invalid }
        try value.validate(started: started, recordingId: meta["recording_id"] as? String ?? directory.lastPathComponent)
        return value
    }
    /// Produces a complete text-only version beside its source. All work is
    /// staged privately and published by one directory rename. No source artifact changes.
    static func create(from source: URL, change: Change, activityLockPath: URL = HelperWorkLease.path) throws -> URL {
        let lease = try HelperWorkLease.acquire(at: activityLockPath)
        defer { withExtendedLifetime(lease) {} }
        guard try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
              try source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
              ArchiveBacklog.isFinished(source) else { throw invalid }
        guard let archiveLock = try AppRunLock.acquire(at: source.appendingPathComponent("archive.lock")) else {
            throw TranscriptionFailure("This meeting is being saved. Wait for it to finish before changing it.")
        }
        defer { withExtendedLifetime(archiveLock) {} }
        let metadataData = try ArchiveBacklog.read(source.appendingPathComponent("meta.json"))
        guard var meta = try JSONSerialization.jsonObject(with: metadataData) as? [String: Any],
              let started = meta["started"] as? String else { throw invalid }
        let original = try ArchiveBacklog.read(source.appendingPathComponent("transcript.json"))
        let receipt = try ArchiveBacklog.object(source.appendingPathComponent("archive-receipt.json"))
        guard ArchiveBacklog.receiptMatches(receipt, transcriptData: original, meta: meta, directory: source),
              receipt["documents"] is [String: Any], let parent = receipt["sessionId"] as? String else {
            throw TranscriptionFailure("Save and verify this meeting before creating a new version.")
        }
        let current = try descriptor(meta: meta, directory: source)
        let base = current?.baseRecordingId ?? (meta["recording_id"] as? String ?? source.lastPathComponent)
        let number = (current?.number ?? 1) + 1
        let version = Descriptor(number: number, baseRecordingId: base, parentSessionId: parent, reason: change.reason)
        try version.validate(started: started, recordingId: version.recordingId)
        let root = source.deletingLastPathComponent()
        let key = AudioRetention.digest(Data((started + "\n" + base).utf8)).prefix(24)
        guard let versionLock = try AppRunLock.acquire(at: root.appendingPathComponent(".revisions-\(key).lock")) else {
            throw TranscriptionFailure("Another version is being prepared. Try again after it finishes.")
        }
        defer { withExtendedLifetime(versionLock) {} }
        for candidate in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            guard (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  let other = try? ArchiveBacklog.object(candidate.appendingPathComponent("meta.json")),
                  other["started"] as? String == started,
                  let next = try? descriptor(meta: other, directory: candidate), next.baseRecordingId == base else { continue }
            guard next.number < number else { throw TranscriptionFailure("A newer version already exists. Open the latest version before making another change.") }
        }
        var transcript = try JSONDecoder().decode(Transcript.self, from: original)
        switch change {
        case .speaker(let indices, let name):
            guard let cleaned = SpeakerAttribution.cleanName(name), !indices.isEmpty,
                  indices.allSatisfy({ transcript.segments.indices.contains($0) }) else {
                throw TranscriptionFailure("Select the exact turns you can identify and enter a valid name.")
            }
            for index in indices { transcript.segments[index].speaker_name = cleaned; transcript.segments[index].attribution = "manual" }
        case .template(let template):
            try template.validate(); meta["notes_mode"] = "ai"; meta["note_template"] = template.json
        case .retranscribed(let replacement):
            guard !replacement.segments.isEmpty else { throw TranscriptionFailure("The new transcript is empty. Existing files are preserved.") }
            transcript = replacement
        }
        meta["recording_id"] = version.recordingId; meta["revision"] = version.json
        meta["text_only_revision"] = true
        meta["files"] = [String: String](); meta.removeValue(forKey: "capture_segments")
        let context = meta["meeting_context"] as? [String: Any]
        let title = MeetingDocuments.component(context?["title"] as? String ?? "Meeting")
        let fm = FileManager.default
        let stagingRoot = root.appendingPathComponent(".revision-staging", isDirectory: true)
        try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try stagingRoot.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw invalid }
        let staging = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]).write(to: staging.appendingPathComponent("meta.json"), options: .atomic)
        try transcript.write(to: staging, title: (title.isEmpty ? "Meeting" : title) + " · v\(number)")
        if let data = try? ArchiveBacklog.read(source.appendingPathComponent("participants.json")) { try data.write(to: staging.appendingPathComponent("participants.json"), options: .atomic) }
        var state = try MeetingPipelineState.load(staging)
        state.revision = number; state.stage = .transcribed; try state.write(staging)
        for file in try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) { try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        guard try ArchiveBacklog.read(source.appendingPathComponent("transcript.json")) == original,
              try ArchiveBacklog.read(source.appendingPathComponent("meta.json")) == metadataData else { throw invalid }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy.MM.dd-HHmm"
        guard let date = ISO8601DateFormatter().date(from: started) else { throw invalid }
        let name = formatter.string(from: date) + "_" + (title.isEmpty ? "Meeting" : title) + "_v\(number)"
        var target = root.appendingPathComponent(name), suffix = 2
        while fm.fileExists(atPath: target.path) { target = root.appendingPathComponent(name + "-\(suffix)"); suffix += 1 }
        try fm.moveItem(at: staging, to: target)
        return target
    }
}
