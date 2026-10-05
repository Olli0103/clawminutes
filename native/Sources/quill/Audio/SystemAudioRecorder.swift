@preconcurrency import ScreenCaptureKit
import AVFoundation
import CoreMedia
import Foundation

/// Audio-only ScreenCaptureKit output, filtered to the Teams application.
/// No screen output or recording output is registered; no pixels are saved.
/// The Core Audio tap implementation is retained for provenance, but is not
/// used because callback creation hangs on the tested macOS 27.2 machine.
final class SystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private var file: AVAudioFile?
    private var destination: URL?
    private let queue = DispatchQueue(label: "ai.openclaw.teams-transcribe.teams-audio")
    let progress = CaptureProgress()
    var firstBufferAt: Date? { progress.snapshot.firstWrite }
    private(set) var isRecording = false

    func start(writingTo url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw TranscriptionFailure("No display available for Teams audio capture. Recording remains off.") }
        let fixture = ProcessInfo.processInfo.environment["OPENCLAW_TEAMS_CAPTURE_FIXTURE"] == "1"
        let filter: SCContentFilter
        if fixture {
            let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        } else {
            let teams = content.applications.filter { $0.bundleIdentifier == "com.microsoft.teams" || $0.bundleIdentifier.hasPrefix("com.microsoft.teams2") || $0.bundleIdentifier.hasPrefix("com.microsoft.teams.") }
            guard !teams.isEmpty else { throw TranscriptionFailure("Open Teams and join the call, then try Start again. Recording remains off.") }
            filter = SCContentFilter(display: display, including: teams, exceptingWindows: [])
        }
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.captureMicrophone = false
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
        config.queueDepth = 3
        destination = url
        progress.reset()
        let capture = SCStream(filter: filter, configuration: config, delegate: self)
        try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        stream = capture
        do { try await capture.startCapture(); isRecording = true }
        catch { stream = nil; destination = nil; throw error }
    }

    func stopAsync() async {
        if let stream { try? await stream.stopCapture() }
        finish()
    }
    /// Last-resort termination: written PCM survives without an AAC packet table.
    func stop() {
        stream?.stopCapture(completionHandler: { _ in })
        finish()
    }
    private func finish() {
        queue.sync { file = nil; destination = nil }
        stream = nil
        isRecording = false
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard self.stream === stream else { return }
        progress.failed("stream_stopped")
        FileHandle.standardError.write(Data("Teams audio capture stopped: \(error.localizedDescription)\n".utf8))
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard self.stream === stream, outputType == .audio, CMSampleBufferDataIsReady(sampleBuffer), let destination,
              let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let buffers = AudioBufferList.allocate(maximumBuffers: 2)
        defer { buffers.unsafeMutablePointer.deallocate() }
        var retained: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: nil,
            bufferListOut: buffers.unsafeMutablePointer, bufferListSize: MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size,
            blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment), blockBufferOut: &retained)
        guard status == noErr, let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: buffers.unsafePointer, deallocator: nil), pcm.frameLength > 0 else { return }
        do {
            if file == nil {
                file = try AVAudioFile(forWriting: destination, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVSampleRateKey: format.sampleRate,
                    AVNumberOfChannelsKey: format.channelCount], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            }
            try file?.write(from: pcm)
            progress.wrote(frames: Int64(pcm.frameLength), sampleRate: format.sampleRate)
            withExtendedLifetime(retained) {}
        } catch {
            progress.failed("write_failed")
            FileHandle.standardError.write(Data("Teams audio write failed: \(error.localizedDescription)\n".utf8))
        }
    }
}
