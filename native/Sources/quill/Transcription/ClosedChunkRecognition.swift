import Foundation
import CryptoKit

/// Local recognition only. A checkpoint contains neither speaker claims nor a
/// final transcript, and cannot qualify a meeting for delivery or audio cleanup.
enum ClosedChunkRecognition {
    static let maximumSeconds = 600.0
    static let maximumAudioBytes: Int64 = 512_000_000
    static let maximumCheckpointBytes = 8_000_000
    struct Source: Sendable {
        let identity: String
        let revision: Int
        let file: String
        let offsetMs: Int
        let duration: Double
        let signature: AudioRetention.FileIdentity
        let sha256: String
    }
    struct Checkpoint: Codable, Sendable {
        let schemaVersion: Int
        let recordingIdentity: String
        let revision: Int
        let file: String
        let offsetMs: Int
        let audioSHA256: String
        let seconds: Double
        let engine: String
        let model: String
        let segments: [TranscriptSegment]
    }
    static func path(_ dir: URL, file: String) -> URL { dir.appendingPathComponent(".speech-\(file).json") }

    /// Includes the closed-file acknowledgement, written after the capture
    /// writer has stopped. An ended_at checkpoint alone is insufficient.
    static func source(_ dir: URL, file: String, measure: (URL) throws -> Double) throws -> Source {
        guard SessionMeta.validTrackFile(file) else { throw MeetingPipelineState.invalidState }
        let state = try MeetingPipelineState.load(dir)
        guard state.delivery.count == 0, state.notesRecovery == nil else { throw DraftSourceOwnership.revisionRequired }
        let receipt = dir.appendingPathComponent("archive-receipt.json")
        var receiptInfo = stat()
        guard lstat(receipt.path, &receiptInfo) != 0, errno == ENOENT else { throw DraftSourceOwnership.revisionRequired }
        let metadata = try ArchiveBacklog.object(dir.appendingPathComponent("meta.json"))
        guard metadata["backend"] as? String == TranscriptionEngineKind.parakeet.rawValue,
              let manifests = metadata["capture_segments"] as? [[String: Any]], manifests.count <= CaptureManifest.maximumSegments,
              manifests.filter({ $0["file"] as? String == file }).count == 1,
              let item = manifests.first(where: { $0["file"] as? String == file }),
              item["closed"] as? Bool == true,
              let source = item["source"] as? String, ["mic", "system"].contains(source), file.hasPrefix(source),
              let offset = item["offset_ms"] as? Int, (0...604_800_000).contains(offset),
              let start = item["started_at"] as? Double, start.isFinite,
              let end = item["ended_at"] as? Double, end.isFinite, end >= start,
              (item["frames_written"] as? Int ?? 0) > 0 else { throw MeetingPipelineState.invalidState }
        let audio = dir.appendingPathComponent(file)
        let signature = try AudioRetention.FileIdentity.read(audio)
        guard signature.bytes > 0, signature.bytes <= maximumAudioBytes else { throw MeetingPipelineState.invalidState }
        let duration = try measure(audio)
        guard duration.isFinite, duration > 0, duration <= maximumSeconds else { throw MeetingPipelineState.invalidState }
        let hash = try fingerprint(audio)
        guard try AudioRetention.FileIdentity.read(audio) == signature else { throw MeetingPipelineState.conflictingState }
        return Source(identity: state.recordingIdentity, revision: state.revision, file: file, offsetMs: offset,
                      duration: duration, signature: signature, sha256: hash)
    }
    static func validateUnchanged(_ source: Source, in dir: URL) throws {
        let state = try MeetingPipelineState.load(dir)
        guard state.recordingIdentity == source.identity, state.revision == source.revision,
              state.delivery.count == 0, state.notesRecovery == nil,
              try AudioRetention.FileIdentity.read(dir.appendingPathComponent(source.file)) == source.signature,
              try fingerprint(dir.appendingPathComponent(source.file)) == source.sha256 else {
            throw MeetingPipelineState.conflictingState
        }
        let metadata = try ArchiveBacklog.object(dir.appendingPathComponent("meta.json"))
        guard let manifests = metadata["capture_segments"] as? [[String: Any]],
              let item = manifests.first(where: { $0["file"] as? String == source.file }),
              item["closed"] as? Bool == true else { throw MeetingPipelineState.conflictingState }
        let meta = try SessionMeta.read(from: dir)
        guard meta.tracks.contains(where: { $0.file == source.file && $0.offsetMs == source.offsetMs }) else {
            throw MeetingPipelineState.conflictingState
        }
    }
    static func valid(_ segments: [TranscriptSegment], seconds: Double) -> Bool {
        guard segments.count <= 20_000 else { return false }
        var words = 0
        for span in segments {
            words += span.words.count
            guard span.start.isFinite, span.end.isFinite, span.start >= 0, span.end >= span.start,
                  span.end <= seconds + 1, span.text.utf8.count <= 100_000, words <= 200_000,
                  span.words.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= span.start
                      && $0.end >= $0.start && $0.end <= span.end + 0.01 && $0.text.utf8.count <= 10_000 }) else { return false }
        }
        return true
    }
    /// Reuse requires both the state reference and matching audio, selection,
    /// model and timings. An orphan or damaged cache simply falls back to STT.
    static func cached(_ dir: URL, file: String, offsetMs: Int, seconds: Double,
                       engine: String, model: String) -> [TranscriptSegment]? {
        guard engine == "parakeet", let state = try? MeetingPipelineState.load(dir),
              let expected = state.recognitionChunks?[file]?.checkpointSHA256,
              let data = try? ArchiveBacklog.read(path(dir, file: file)), data.count <= maximumCheckpointBytes,
              AudioRetention.digest(data) == expected,
              let checkpoint = try? JSONDecoder().decode(Checkpoint.self, from: data),
              checkpoint.schemaVersion == 1, checkpoint.recordingIdentity == state.recordingIdentity,
              checkpoint.revision == state.revision, checkpoint.file == file, checkpoint.offsetMs == offsetMs,
              checkpoint.engine == engine, checkpoint.model == model,
              checkpoint.seconds == seconds, valid(checkpoint.segments, seconds: seconds),
              (try? fingerprint(dir.appendingPathComponent(file))) == checkpoint.audioSHA256 else { return nil }
        return checkpoint.segments
    }
    static func publish(_ segments: [TranscriptSegment], source: Source, dir: URL, engine: String, model: String) throws {
        guard engine == "parakeet", valid(segments, seconds: source.duration) else { throw MeetingPipelineState.invalidState }
        try validateUnchanged(source, in: dir)
        let output = path(dir, file: source.file)
        var info = stat()
        guard lstat(output.path, &info) != 0, errno == ENOENT else { throw MeetingPipelineState.conflictingState }
        let checkpoint = Checkpoint(schemaVersion: 1, recordingIdentity: source.identity, revision: source.revision,
            file: source.file, offsetMs: source.offsetMs, audioSHA256: source.sha256, seconds: source.duration,
            engine: engine, model: model, segments: segments)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(checkpoint)
        guard data.count <= maximumCheckpointBytes else { throw MeetingPipelineState.invalidState }
        try data.write(to: output, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        // A crash before this state commit leaves an untrusted orphan. Never
        // adopt it or treat its existence as a successful transcription.
        var state = try MeetingPipelineState.load(dir)
        guard state.recognitionChunks?[source.file]?.count == 1 else { throw MeetingPipelineState.conflictingState }
        state.recognitionChunks?[source.file]?.checkpointSHA256 = AudioRetention.digest(data)
        try state.write(dir)
    }
    private static func fingerprint(_ file: URL) throws -> String {
        let fd = open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw MeetingPipelineState.invalidState }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= maximumAudioBytes else { throw MeetingPipelineState.invalidState }
        let before = try AudioRetention.FileIdentity.read(file)
        guard UInt64(info.st_ino) == before.inode, Int64(info.st_dev) == before.device else { throw MeetingPipelineState.conflictingState }
        var hash = SHA256(), count: Int64 = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            count += Int64(data.count)
            guard count <= maximumAudioBytes else { throw MeetingPipelineState.invalidState }
            hash.update(data: data)
        }
        guard count == before.bytes, try AudioRetention.FileIdentity.read(file) == before else { throw MeetingPipelineState.conflictingState }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
