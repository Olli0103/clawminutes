import Foundation

/// Only the process-lock owner may run this, before enabling any new capture.
/// The restart time is not evidence of when the call ended.
enum InterruptedRecordingRecovery {
    static func recover(root: URL, owner: AppRunLock, activityLockPath: URL = HelperWorkLease.path,
                        now: Date = Date(), measure: (URL) throws -> Double = AudioRetention.duration) throws -> [URL] {
        let lease = try HelperWorkLease.acquire(at: activityLockPath)
        defer { withExtendedLifetime((owner, lease)) {} }
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        var recovered: [URL] = []
        for dir in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            let values = try dir.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let file = dir.appendingPathComponent("meta.json")
            guard fm.fileExists(atPath: file.path) else { continue }
            let fileValues = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard fileValues.isRegularFile == true, fileValues.isSymbolicLink != true,
                  (fileValues.fileSize ?? Int.max) <= 1_000_000,
                  var meta = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else {
                throw TranscriptionFailure("Interrupted meeting metadata is unreadable. Files were preserved.")
            }
            guard meta["status"] as? String == "recording" else { continue }
            guard let started = meta["audio_started_at"] as? Double, started.isFinite,
                  started < owner.acquiredAt.timeIntervalSince1970, started <= now.timeIntervalSince1970 else { continue }
            let parsed = try SessionMeta.read(from: dir)
            var ends: [String: Double] = [:]
            let maximumDuration = min(7 * 24 * 3600.0, now.timeIntervalSince1970 - started)
            for track in parsed.tracks {
                let audio = dir.appendingPathComponent(track.file)
                let attributes = try? audio.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard attributes?.isRegularFile == true, attributes?.isSymbolicLink != true,
                      let seconds = try? measure(audio), seconds.isFinite, seconds >= 0 else { continue }
                let end = min(maximumDuration, Double(track.offsetMs) / 1000 + seconds)
                ends[track.source] = max(ends[track.source] ?? 0, end)
            }
            let checkpoint = meta["checkpoint_at"] as? Double ?? started
            let elapsedCheckpoint = checkpoint.isFinite ? min(maximumDuration, max(0, checkpoint - started)) : 0
            let coverageEnd = max(elapsedCheckpoint, ends.values.max() ?? 0)
            var gaps = parsed.captureGaps
            for source in Set(parsed.tracks.map(\.source)).sorted() {
                let tail = min(coverageEnd, ends[source] ?? 0)
                // A zero-length marker means the extent after this boundary is
                // unknown. Never manufacture hours of missing audio up to launch.
                gaps.append(CaptureGap(source: source, start_ms: Int(tail * 1000),
                                       end_ms: Int(coverageEnd * 1000), reason: "helper_interrupted"))
            }
            meta["status"] = "interrupted"
            meta["ended"] = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: started + coverageEnd))
            meta["capture_gaps"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(gaps))
            meta["recovery"] = ["reason": "helper_interrupted", "recovered_at": now.timeIntervalSince1970,
                                "last_checkpoint_at": checkpoint, "call_end_unknown": true,
                                "end_basis": "available_audio_and_last_checkpoint"] as [String: Any]
            try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            recovered.append(dir)
        }
        return recovered.sorted { $0.path < $1.path }
    }
}
