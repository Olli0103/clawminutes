import AVFoundation
import Foundation

/// Serializes file writes and buffer-boundary handoff. Preparing the next file
/// and persisting its manifest happen outside the audio callback lock.
final class PCMChunkWriter: @unchecked Sendable {
    final class Prepared {
        fileprivate var file: AVAudioFile?
        fileprivate let generation: UInt64
        fileprivate let owner: UUID
        fileprivate let identity: AudioRetention.FileIdentity
        let url: URL
        fileprivate init(file: AVAudioFile, generation: UInt64, url: URL, owner: UUID, identity: AudioRetention.FileIdentity) {
            self.file = file; self.generation = generation; self.url = url; self.owner = owner; self.identity = identity
        }
    }
    let progress = CaptureProgress()
    private let lock = NSLock()
    private let owner = UUID()
    private var file: AVAudioFile?
    private var destination: URL?
    private var generation: UInt64 = 0

    func start(writingTo url: URL, format: AVAudioFormat? = nil) throws {
        try lock.withLock {
            generation &+= 1
            file?.close(); file = nil; destination = url; progress.reset()
            if let format { file = try Self.open(url, format: format) }
        }
    }
    func write(_ buffer: AVAudioPCMBuffer, at date: Date = Date(), epoch: UInt64? = nil) throws {
        try lock.withLock {
            guard let destination, epoch == nil || epoch == progress.currentEpoch else { return }
            if file == nil { file = try Self.open(destination, format: buffer.format) }
            try file?.write(from: buffer)
            progress.wrote(frames: Int64(buffer.frameLength), sampleRate: buffer.format.sampleRate, at: date)
        }
    }
    /// This file contains no captured frames until commit succeeds. Failure or
    /// a crash before declaration may leave an empty CAF for manual review.
    func prepare(next url: URL) throws -> Prepared {
        let (format, expected): (AVAudioFormat, UInt64) = try lock.withLock {
            guard let file, destination != nil, progress.snapshot.frames > 0 else { throw MeetingPipelineState.conflictingState }
            return (file.processingFormat, generation)
        }
        let fd = Darwin.open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var reserved = stat()
        guard fstat(fd, &reserved) == 0, reserved.st_mode & S_IFMT == S_IFREG else { throw MeetingPipelineState.conflictingState }
        let next = try Self.open(url, format: format)
        let identity = try AudioRetention.FileIdentity.read(url)
        guard identity.inode == UInt64(reserved.st_ino), identity.device == Int64(reserved.st_dev) else { throw MeetingPipelineState.conflictingState }
        return Prepared(file: next, generation: expected, url: url, owner: owner, identity: identity)
    }
    /// Caller must first persist a pending capture segment. No file creation
    /// or meeting-manifest write runs under this lock. Each buffer reaches one file.
    func commit(_ next: Prepared) throws -> CaptureProgress.Snapshot {
        try lock.withLock {
            let closed = progress.snapshot
            guard destination != nil, file != nil, next.generation == generation, next.owner == owner,
                  try AudioRetention.FileIdentity.read(next.url) == next.identity,
                  let prepared = next.file, closed.frames > 0,
                  closed.failure == nil, !closed.configurationChanged else { throw MeetingPipelineState.conflictingState }
            // Finalize the old CAF before publishing it for recognition.
            file?.close(); file = nil
            file = prepared; next.file = nil; destination = next.url
            progress.nextChunk()
            generation &+= 1
            return closed
        }
    }
    func stop() { lock.withLock { file?.close(); file = nil; destination = nil; generation &+= 1 } }
    private static func open(_ url: URL, format: AVAudioFormat) throws -> AVAudioFile {
        try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }
}
