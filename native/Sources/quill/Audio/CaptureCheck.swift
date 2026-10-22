import AVFoundation
import CoreGraphics
import Foundation

struct CaptureCheckTrack: Sendable, Equatable {
    enum State: String, Sendable { case sound, silent, incomplete, unavailable }
    let source: String
    let state: State
    let seconds: Double
    var title: String { source == "mic" ? "Microphone" : "Teams audio" }
    var detail: String {
        switch state {
        case .sound: return "Sound received"
        case .silent: return "No sound detected. Speak or play a sound in Teams, then check again."
        case .incomplete: return "Only part of the check was captured. Check the device and try again."
        case .unavailable: return "No readable audio received. Check permissions and the device."
        }
    }
    static func inspect(_ file: URL, source: String) -> Self {
        do {
            let signature = try AudioRetention.FileIdentity.read(file)
            guard signature.bytes > 0, signature.bytes <= 20_000_000 else { throw MeetingPipelineState.invalidState }
            let audio = try AVAudioFile(forReading: file, commonFormat: .pcmFormatFloat32, interleaved: false)
            let format = audio.processingFormat
            guard format.sampleRate.isFinite, (8000...192000).contains(format.sampleRate), (1...8).contains(format.channelCount),
                  audio.length > 0, Double(audio.length) / format.sampleRate <= 20 else { throw MeetingPipelineState.invalidState }
            let duration = Double(audio.length) / format.sampleRate
            var peak: Float = 0
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { throw MeetingPipelineState.invalidState }
            while audio.framePosition < audio.length {
                try audio.read(into: buffer, frameCount: 4096)
                guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { throw MeetingPipelineState.invalidState }
                for channel in 0..<Int(format.channelCount) {
                    for index in 0..<Int(buffer.frameLength) {
                        let sample = channels[channel][index]
                        guard sample.isFinite else { throw MeetingPipelineState.invalidState }
                        peak = max(peak, abs(sample))
                    }
                }
            }
            guard try AudioRetention.FileIdentity.read(file) == signature else { throw MeetingPipelineState.conflictingState }
            return Self(source: source, state: duration < 8 ? .incomplete : (peak >= 0.001 ? .sound : .silent), seconds: duration)
        } catch { return Self(source: source, state: .unavailable, seconds: 0) }
    }
}

@MainActor protocol CaptureCheckDevice {
    func start(in directory: URL) async throws
    func stop() async
}

@MainActor final class NativeCaptureCheckDevice: CaptureCheckDevice {
    private let mic = MicRecorder()
    private let system = SystemAudioRecorder()
    func start(in directory: URL) async throws {
        // This diagnostic never uses the global-system fixture fallback.
        try await system.start(writingTo: directory.appendingPathComponent("system.caf"), allowFixture: false)
        try Task.checkCancellation()
        try mic.start(writingTo: directory.appendingPathComponent("mic.caf"))
        try Task.checkCancellation()
    }
    func stop() async { mic.stop(); await system.stopAsync() }
}

/// Explicitly started, ten-second diagnostic. Its directory has no meeting
/// metadata and no route into speech recognition, the backlog or the Gateway.
@MainActor final class CaptureCheckRunner {
    enum Phase: Equatable { case starting, recording(Int), stopping }
    struct Report: Sendable {
        let tracks: [CaptureCheckTrack]
        let cancelled: Bool
        let startFailed: Bool
        let audioRemoved: Bool
        let directory: URL
        var passed: Bool { !cancelled && !startFailed && audioRemoved && tracks.count == 2 && tracks.allSatisfy { $0.state == .sound } }
    }
    private let root: URL
    private let activityLockPath: URL
    private let permissions: () -> Bool
    private let makeDevice: () -> any CaptureCheckDevice
    private let wait: @Sendable () async throws -> Void
    private var busy = false
    init(root: URL = Config.path.deletingLastPathComponent().appendingPathComponent("capture-checks"),
         activityLockPath: URL = HelperWorkLease.path,
         permissions: @escaping () -> Bool = { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized && CGPreflightScreenCaptureAccess() },
         makeDevice: @escaping () -> any CaptureCheckDevice = { NativeCaptureCheckDevice() },
         wait: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }) {
        self.root = root; self.activityLockPath = activityLockPath; self.permissions = permissions
        self.makeDevice = makeDevice; self.wait = wait
    }
    func run(progress: (Phase) -> Void = { _ in }) async throws -> Report {
        guard !busy else { throw TranscriptionFailure("An audio check is already running.") }
        guard permissions() else { throw TranscriptionFailure("Allow microphone and Teams audio access before starting the check.") }
        try Task.checkCancellation()
        let ownership = try CaptureOwnership.acquire(activityLockPath: activityLockPath)
        defer { withExtendedLifetime(ownership) {} }
        busy = true; defer { busy = false }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootIdentity = try Self.identity(root)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let identity = try Self.identity(directory)
        let device = makeDevice()
        var failed = false, cancelled = false
        progress(.starting)
        do {
            try await device.start(in: directory)
            for remaining in stride(from: 10, through: 1, by: -1) {
                try Task.checkCancellation(); progress(.recording(remaining)); try await wait()
            }
        } catch { cancelled = Task.isCancelled || error is CancellationError; failed = !cancelled }
        progress(.stopping)
        await device.stop()
        let tracks = cancelled || failed ? [] : ["mic", "system"].map {
            CaptureCheckTrack.inspect(directory.appendingPathComponent($0 + ".caf"), source: $0)
        }
        let removed = Self.removeOwnedAudio(directory, identity: identity, root: root, rootIdentity: rootIdentity)
        return Report(tracks: tracks, cancelled: cancelled, startFailed: failed, audioRemoved: removed, directory: directory)
    }
    private static func identity(_ directory: URL) throws -> String {
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw MeetingPipelineState.invalidState }
        return "\(info.st_dev):\(info.st_ino)"
    }
    private static func removeOwnedAudio(_ directory: URL, identity: String, root: URL, rootIdentity: String) -> Bool {
        do {
            guard try Self.identity(root) == rootIdentity, try Self.identity(directory) == identity else { return false }
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            guard files.allSatisfy({ ["mic.caf", "system.caf"].contains($0.lastPathComponent) }) else { return false }
            for file in files {
                _ = try AudioRetention.FileIdentity.read(file)
                guard try Self.identity(directory) == identity else { return false }
                try FileManager.default.removeItem(at: file)
            }
            guard try Self.identity(directory) == identity else { return false }
            try FileManager.default.removeItem(at: directory)
            return true
        } catch { return false }
    }
}
