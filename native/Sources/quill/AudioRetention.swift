import Foundation
import AVFoundation
import CryptoKit

/// Deletes declared capture files only after durable text readback and complete coverage.
enum AudioRetention {
    static func explicitlyRemoved(_ dir: URL) -> Bool {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("audio-retention-receipt.json")),
              let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return value["policy"] as? String == "explicit_existing_audio_deletion"
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

    @discardableResult static func deleteAfterVerification(
        _ dir: URL, measure: (URL) throws -> Double = duration
    ) throws -> Int {
        let fm = FileManager.default
        guard try dir.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw TranscriptionFailure("Retention check rejects linked recording folders")
        }
        let metaFile = dir.appendingPathComponent("meta.json")
        let meta = try object(metaFile)
        let segments = meta["capture_segments"] as? [[String: Any]]
        let names: [String]
        if let segments {
            let files = segments.compactMap { $0["file"] as? String }
            guard !files.isEmpty, files.count == segments.count, files.count <= 16,
                  Set(files).count == files.count, files.allSatisfy(SessionMeta.validTrackFile) else {
                throw TranscriptionFailure("Invalid capture file manifest; audio kept")
            }
            names = files
        } else { names = ["mic.caf", "system.caf"] }
        let marker = dir.appendingPathComponent("audio-retention-receipt.json")
        if fm.fileExists(atPath: marker.path),
           let previous = try? object(marker), previous["policy"] as? String == "delete_after_verification",
           names.allSatisfy({ !fm.fileExists(atPath: dir.appendingPathComponent($0).path) }) { return 0 }

        guard meta["status"] as? String == "stopped",
              let started = meta["audio_started_at"] as? Double,
              let end = meta["ended"] as? String, let ended = ISO8601DateFormatter().date(from: end),
              ended.timeIntervalSince1970 > started else { throw TranscriptionFailure("Recording is active or incomplete; audio kept") }
        let elapsed = ended.timeIntervalSince1970 - started
        if let gaps = meta["capture_gaps"] as? [Any], !gaps.isEmpty {
            throw TranscriptionFailure("Capture gaps require review; audio kept")
        }
        if let context = meta["meeting_context"] as? [String: Any],
           let observedEnd = context["ended_observed_at"] as? Double, observedEnd < started {
            throw TranscriptionFailure("Stale meeting context; audio kept")
        }
        let transcriptData = try read(dir.appendingPathComponent("transcript.json"))
        let transcript = try JSONDecoder().decode(Transcript.self, from: transcriptData)
        guard transcript.capture_gaps?.isEmpty ?? true else {
            throw TranscriptionFailure("Transcript records capture gaps; audio kept")
        }
        guard !transcript.segments.isEmpty, transcript.segments.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              transcript.segments.allSatisfy({ $0.start_ms >= 0 && $0.end_ms >= $0.start_ms && Double($0.end_ms) <= (elapsed + 5) * 1000 }),
              !readable(try read(dir.appendingPathComponent("transcript.md"))).isEmpty else {
            throw TranscriptionFailure("Transcript verification failed; audio kept")
        }
        let receipt = try object(dir.appendingPathComponent("archive-receipt.json"))
        guard receipt["saved"] as? Bool == true, receipt["utteranceCount"] as? Int == transcript.segments.count,
              receipt["localTranscriptSHA256"] as? String == digest(transcriptData),
              let id = receipt["sessionId"] as? String,
              let docs = receipt["documents"] as? [String: Any],
              let notes = docs["notesMarkdown"] as? String, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let text = docs["transcriptMarkdown"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let metadata = docs["metadata"] as? [String: Any], metadata["sessionId"] as? String == id else {
            throw TranscriptionFailure("Matching Gateway readback missing; audio kept")
        }
        let destination = readable(try read(dir.appendingPathComponent("notes-export-path.txt")))
        guard destination.hasPrefix("/") else { throw TranscriptionFailure("Notes export is missing; audio kept") }
        let folder = URL(fileURLWithPath: destination)
        guard readable(try read(folder.appendingPathComponent("notes.md"))) == notes.trimmingCharacters(in: .whitespacesAndNewlines),
              readable(try read(folder.appendingPathComponent("transcript.md"))) == text.trimmingCharacters(in: .whitespacesAndNewlines),
              try object(folder.appendingPathComponent("metadata.json"))["sessionId"] as? String == id else {
            throw TranscriptionFailure("Notes export readback differs; audio kept")
        }
        let offsets = meta["start_offset_ms"] as? [String: Int] ?? [:]
        for name in names {
            let file = dir.appendingPathComponent(name)
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else { throw TranscriptionFailure("Audio track unavailable; audio kept") }
            let offset = segments?.first(where: { $0["file"] as? String == name })?["offset_ms"] as? Int
                ?? offsets[name == "mic.caf" ? "mic" : "system"] ?? 0
            let expected = elapsed - Double(offset) / 1000
            let actual = try measure(file)
            guard actual.isFinite, expected > 0, actual > 0,
                  abs(actual - expected) <= max(5, expected * 0.01) else {
                throw TranscriptionFailure("Incomplete audio coverage in \(name); audio kept")
            }
        }
        // Persist the validation result before unlinking so interrupted cleanup has an audit record.
        var audit: [String: Any] = ["policy": "delete_after_verification", "verifiedAt": ISO8601DateFormatter().string(from: Date()),
                                  "sessionId": id, "localTranscriptSHA256": digest(transcriptData), "files": names, "deleted": false]
        try JSONSerialization.data(withJSONObject: audit, options: [.prettyPrinted, .sortedKeys]).write(to: marker, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        for name in names {
            guard try object(metaFile)["status"] as? String == "stopped" else { throw TranscriptionFailure("Recording became active; cleanup stopped") }
            try fm.removeItem(at: dir.appendingPathComponent(name))
        }
        audit["deleted"] = true
        audit["deletedAt"] = ISO8601DateFormatter().string(from: Date())
        try JSONSerialization.data(withJSONObject: audit, options: [.prettyPrinted, .sortedKeys]).write(to: marker, options: .atomic)
        return names.count
    }

    private static func readable(_ data: Data) -> String {
        String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
