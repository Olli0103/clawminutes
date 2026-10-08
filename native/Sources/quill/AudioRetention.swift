import Foundation
import AVFoundation
import CryptoKit

/// Deletes declared capture files only after durable text readback and complete coverage.
enum AudioRetention {
    enum Policy: String, Codable, Sendable {
        case automatic = "delete_after_verification"
        case explicitExisting = "explicit_existing_audio_deletion"
    }
    struct FileIdentity: Codable, Equatable, Sendable {
        let device: Int64, inode: UInt64, bytes: Int64, modified: Int64, modifiedNS: Int64, changed: Int64, changedNS: Int64
        static func read(_ file: URL) throws -> Self {
            var info = stat()
            guard lstat(file.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                throw TranscriptionFailure("Audio track is missing or linked; audio kept")
            }
            return Self(device: Int64(info.st_dev), inode: UInt64(info.st_ino), bytes: info.st_size,
                modified: Int64(info.st_mtimespec.tv_sec), modifiedNS: Int64(info.st_mtimespec.tv_nsec),
                changed: Int64(info.st_ctimespec.tv_sec), changedNS: Int64(info.st_ctimespec.tv_nsec))
        }
    }
    struct Track: Codable, Equatable, Sendable {
        let name: String, identity: FileIdentity, seconds: Double
    }
    struct Plan: Codable, Equatable, Sendable {
        let directory: String, directoryIdentity: String, exportDirectory: String, exportIdentity: String, sessionID: String
        let evidence: [String: String]
        let tracks: [Track]
        let missing: [String]
        var remaining: [Track] { tracks.filter { !missing.contains($0.name) } }
        var bytes: Int64 { remaining.reduce(0) { $0 + $1.identity.bytes } }
    }
    struct Audit: Codable, Sendable {
        let schemaVersion: Int
        let policy: Policy
        let verifiedAt: String
        let plan: Plan
        var removed: [String]
        var deleted: Bool
        var deletedAt: String?
    }
    private static func directoryIdentity(_ directory: URL) throws -> String {
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw TranscriptionFailure("Retention check rejects missing or linked folders")
        }
        return "\(info.st_dev):\(info.st_ino)"
    }
    private static func absent(_ file: URL) -> Bool {
        var info = stat()
        return lstat(file.path, &info) != 0 && errno == ENOENT
    }
    static func explicitlyRemoved(_ dir: URL) -> Bool {
        guard let value = try? object(dir.appendingPathComponent("audio-retention-receipt.json")),
              value["deleted"] as? Bool == true,
              let policy = value["policy"] as? String, Policy(rawValue: policy) != nil else { return false }
        let names: [String]
        if let data = try? read(dir.appendingPathComponent("audio-retention-receipt.json")),
           let audit = try? JSONDecoder().decode(Audit.self, from: data), audit.schemaVersion == 2 {
            names = audit.plan.tracks.map(\.name)
        } else { names = value["files"] as? [String] ?? [] }
        return !names.isEmpty && names.allSatisfy(SessionMeta.validTrackFile)
            && names.allSatisfy { absent(dir.appendingPathComponent($0)) }
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func duration(_ file: URL) throws -> Double {
        let audio = try AVAudioFile(forReading: file)
        guard audio.processingFormat.sampleRate > 0 else { throw TranscriptionFailure("Invalid audio sample rate") }
        return Double(audio.length) / audio.processingFormat.sampleRate
    }

    private static func read(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true,
              (values.fileSize ?? Int.max) <= 16_000_000 else { throw TranscriptionFailure("Retention check requires a regular local file") }
        return try Data(contentsOf: url)
    }

    private static func object(_ file: URL) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: read(file)) as? [String: Any] else {
            throw TranscriptionFailure("Retention check could not read metadata")
        }
        return value
    }

    private static func endDate(_ value: String) -> Date? {
        let clock = ISO8601DateFormatter()
        if let date = clock.date(from: value) { return date }
        clock.formatOptions.insert(.withFractionalSeconds)
        return clock.date(from: value)
    }

    /// Read-only verification. Missing tracks are accepted only from a schema-2
    /// deletion audit whose original text proofs and surviving tracks still match.
    static func review(_ dir: URL, measure: (URL) throws -> Double = duration) throws -> Plan? {
        try Task.checkCancellation()
        let identity = try directoryIdentity(dir)
        var evidence: [String: String] = [:]
        func checkedRead(_ file: URL) throws -> Data {
            let data = try read(file)
            evidence[file.path] = digest(data)
            return data
        }
        func checkedObject(_ file: URL) throws -> [String: Any] {
            guard let value = try JSONSerialization.jsonObject(with: checkedRead(file)) as? [String: Any] else {
                throw TranscriptionFailure("Retention metadata is unreadable; audio kept")
            }
            return value
        }
        let metaFile = dir.appendingPathComponent("meta.json")
        let meta = try checkedObject(metaFile)
        let segments = meta["capture_segments"] as? [[String: Any]]
        let names: [String]
        if let segments {
            let files = segments.compactMap { $0["file"] as? String }
            guard !files.isEmpty, files.count == segments.count, files.count <= CaptureManifest.maximumSegments,
                  Set(files).count == files.count, files.allSatisfy(SessionMeta.validTrackFile) else {
                throw TranscriptionFailure("Invalid capture file manifest; audio kept")
            }
            names = files
        } else { names = ["mic.caf", "system.caf"] }
        let marker = dir.appendingPathComponent("audio-retention-receipt.json")
        let previous: Audit? = (try? read(marker)).flatMap { try? JSONDecoder().decode(Audit.self, from: $0) }
        if explicitlyRemoved(dir), names.allSatisfy({ absent(dir.appendingPathComponent($0)) }) { return nil }

        guard meta["status"] as? String == "stopped",
              let started = meta["audio_started_at"] as? Double,
              let end = meta["ended"] as? String, let ended = endDate(end),
              ended.timeIntervalSince1970 > started else { throw TranscriptionFailure("Recording is active or incomplete; audio kept") }
        let elapsed = ended.timeIntervalSince1970 - started
        if let gaps = meta["capture_gaps"] as? [Any], !gaps.isEmpty {
            throw TranscriptionFailure("Capture gaps require review; audio kept")
        }
        if let context = meta["meeting_context"] as? [String: Any],
           let observedEnd = context["ended_observed_at"] as? Double, observedEnd < started {
            throw TranscriptionFailure("Stale meeting context; audio kept")
        }
        let transcriptData = try checkedRead(dir.appendingPathComponent("transcript.json"))
        let transcript = try JSONDecoder().decode(Transcript.self, from: transcriptData)
        guard transcript.capture_gaps?.isEmpty ?? true else {
            throw TranscriptionFailure("Transcript records capture gaps; audio kept")
        }
        guard !transcript.segments.isEmpty, transcript.segments.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              transcript.segments.allSatisfy({ $0.start_ms >= 0 && $0.end_ms >= $0.start_ms && Double($0.end_ms) <= (elapsed + 5) * 1000 }),
              !readable(try checkedRead(dir.appendingPathComponent("transcript.md"))).isEmpty else {
            throw TranscriptionFailure("Transcript verification failed; audio kept")
        }
        if names.contains(where: { $0.hasPrefix("system") }),
           !transcript.segments.contains(where: { segment in
               (segment.source == "system" || segment.speaker == "them" || segment.speaker.hasPrefix("system_"))
                   && !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
           }) {
            throw TranscriptionFailure("No Teams speech was transcribed. This may be a silent call or missing remote audio; review before deleting audio.")
        }
        let receipt = try checkedObject(dir.appendingPathComponent("archive-receipt.json"))
        guard ArchiveBacklog.receiptMatches(receipt, transcriptData: transcriptData, meta: meta, directory: dir),
              let id = receipt["sessionId"] as? String,
              let docs = receipt["documents"] as? [String: Any],
              let notes = docs["notesMarkdown"] as? String, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let text = docs["transcriptMarkdown"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let metadata = docs["metadata"] as? [String: Any], metadata["sessionId"] as? String == id else {
            throw TranscriptionFailure("Matching Gateway readback missing; audio kept")
        }
        let destination = readable(try checkedRead(dir.appendingPathComponent("notes-export-path.txt")))
        guard destination.hasPrefix("/") else { throw TranscriptionFailure("Notes export is missing; audio kept") }
        let folder = URL(fileURLWithPath: destination)
        let binding = dir.appendingPathComponent("notes-export-location.json")
        if FileManager.default.fileExists(atPath: binding.path) {
            let location = try checkedObject(binding)
            guard location["destination"] as? String == folder.path, location["sessionId"] as? String == id else { throw changed }
        }
        guard readable(try checkedRead(folder.appendingPathComponent("notes.md"))) == notes.trimmingCharacters(in: .whitespacesAndNewlines),
              readable(try checkedRead(folder.appendingPathComponent("transcript.md"))) == text.trimmingCharacters(in: .whitespacesAndNewlines),
              try checkedObject(folder.appendingPathComponent("metadata.json"))["sessionId"] as? String == id else {
            throw TranscriptionFailure("Notes export readback differs; audio kept")
        }
        let exportIdentity = try directoryIdentity(folder)
        let missing = names.filter { absent(dir.appendingPathComponent($0)) }
        if !missing.isEmpty {
            guard let previous, previous.schemaVersion == 2, previous.plan.directory == dir.path,
                  previous.plan.directoryIdentity == identity, previous.plan.exportIdentity == exportIdentity,
                  previous.plan.sessionID == id, previous.plan.evidence == evidence,
                  previous.plan.tracks.map(\.name) == names else {
                throw TranscriptionFailure("An audio track is missing without matching cleanup evidence; remaining audio kept")
            }
        }
        let offsets = meta["start_offset_ms"] as? [String: Int] ?? [:]
        var expectedDurations: [String: Double] = [:]
        var internalParts = Set<String>()
        if let segments {
            var parts: [(file: String, source: String, offset: Int)] = []
            for segment in segments {
                guard let file = segment["file"] as? String,
                      let source = segment["source"] as? String, ["mic", "system"].contains(source), file.hasPrefix(source),
                      let offset = segment["offset_ms"] as? Int, (0...604_800_000).contains(offset),
                      segment["rotation_pending"] as? Bool != true, segment["timing_uncertain"] as? Bool != true else {
                    throw TranscriptionFailure("An audio handoff or capture manifest is unverified; audio kept")
                }
                parts.append((file, source, offset))
            }
            guard Set(parts.map(\.source)) == Set(["mic", "system"]) else {
                throw TranscriptionFailure("A capture source is missing; audio kept")
            }
            for source in ["mic", "system"] {
                let ordered = parts.filter { $0.source == source }.sorted { $0.offset < $1.offset }
                guard Double(ordered[0].offset) / 1000 <= 5 else {
                    throw TranscriptionFailure("Audio starts too late; audio kept")
                }
                for index in ordered.indices {
                    let start = Double(ordered[index].offset) / 1000
                    let end = index + 1 < ordered.count ? Double(ordered[index + 1].offset) / 1000 : elapsed
                    guard end > start else { throw TranscriptionFailure("Invalid capture coverage; audio kept") }
                    expectedDurations[ordered[index].file] = end - start
                    if index + 1 < ordered.count { internalParts.insert(ordered[index].file) }
                }
            }
        }
        var tracks: [Track] = []
        for name in names {
            try Task.checkCancellation()
            let file = dir.appendingPathComponent(name)
            if missing.contains(name), let prior = previous?.plan.tracks.first(where: { $0.name == name }) {
                tracks.append(prior); continue
            }
            let signature = try FileIdentity.read(file)
            let offset = segments?.first(where: { $0["file"] as? String == name })?["offset_ms"] as? Int
                ?? offsets[name == "mic.caf" ? "mic" : "system"] ?? 0
            let expected = expectedDurations[name] ?? (elapsed - Double(offset) / 1000)
            let actual = try measure(file)
            let tolerance = internalParts.contains(name) ? max(0.05, expected * 0.001) : max(5, expected * 0.01)
            guard offset >= 0, actual.isFinite, expected > 0, actual > 0,
                  abs(actual - expected) <= tolerance,
                  try FileIdentity.read(file) == signature else {
                throw TranscriptionFailure("Incomplete or changed audio coverage in \(name); audio kept")
            }
            let track = Track(name: name, identity: signature, seconds: actual)
            if !missing.isEmpty, previous?.plan.tracks.first(where: { $0.name == name }) != track {
                throw TranscriptionFailure("Audio changed after interrupted cleanup; remaining audio kept")
            }
            tracks.append(track)
        }
        guard try directoryIdentity(dir) == identity, try directoryIdentity(folder) == exportIdentity else { throw changed }
        try validateEvidence(evidence)
        return Plan(directory: dir.path, directoryIdentity: identity, exportDirectory: folder.path, exportIdentity: exportIdentity, sessionID: id,
            evidence: evidence, tracks: tracks, missing: missing)
    }

    static let changed = TranscriptionFailure("Meeting files changed after review. Review again before deleting audio.")
    private static func validateEvidence(_ evidence: [String: String]) throws {
        for (path, hash) in evidence {
            guard digest(try read(URL(fileURLWithPath: path))) == hash else { throw changed }
        }
    }
    private static func write(_ audit: Audit, to marker: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(audit).write(to: marker, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
    }
    @discardableResult static func deleteAfterVerification(
        _ dir: URL, measure: (URL) throws -> Double = duration, expected: Plan? = nil,
        policy: Policy = .automatic, remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) throws -> Int {
        _ = try directoryIdentity(dir)
        guard let lock = try AppRunLock.acquire(at: dir.appendingPathComponent("archive.lock")) else {
            throw TranscriptionFailure("This meeting is being processed. Wait, then review again.")
        }
        defer { withExtendedLifetime(lock) {} }
        guard let plan = try review(dir, measure: measure) else { return 0 }
        if let expected, expected != plan { throw changed }
        var audit = Audit(schemaVersion: 2, policy: policy, verifiedAt: ISO8601DateFormatter().string(from: Date()),
            plan: plan, removed: plan.missing, deleted: false)
        let marker = dir.appendingPathComponent("audio-retention-receipt.json")
        try write(audit, to: marker)
        var count = 0
        for track in plan.remaining {
            // Recheck the text, directory and exact file immediately before each unlink.
            try validateEvidence(plan.evidence)
            guard try directoryIdentity(dir) == plan.directoryIdentity,
                  try directoryIdentity(URL(fileURLWithPath: plan.exportDirectory)) == plan.exportIdentity,
                  try FileIdentity.read(dir.appendingPathComponent(track.name)) == track.identity else { throw changed }
            try remove(dir.appendingPathComponent(track.name))
            guard absent(dir.appendingPathComponent(track.name)) else { throw changed }
            count += 1; audit.removed.append(track.name)
            try write(audit, to: marker)
        }
        guard plan.tracks.allSatisfy({ absent(dir.appendingPathComponent($0.name)) }) else { throw changed }
        audit.deleted = true; audit.deletedAt = ISO8601DateFormatter().string(from: Date())
        try write(audit, to: marker)
        return count
    }

    private static func readable(_ data: Data) -> String {
        String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
