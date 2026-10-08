import AVFoundation
import Foundation

/// Records the default input device to a file via AVAudioEngine, writing linear PCM
/// mono. Buffers stream straight to disk — nothing is held in memory, so
/// session length is unbounded.
///
/// With voice processing on (the default), Apple's echo canceller subtracts
/// speaker playback from the mic so the system track doesn't bleed into the
/// mic track. VoiceProcessingIO is a duplex unit, not an input effect: it
/// needs a rendered output path and one explicit mono client format on both
/// sides, or it silently delivers zeroed buffers (rca-001). A first-second
/// liveness check catches routes where even the correct graph stays silent
/// and restarts capture raw.
final class MicRecorder: @unchecked Sendable {
    enum RecorderError: Error, CustomStringConvertible {
        case engineStartFailed(Error)
        case fileCreationFailed(Error)
        case formatUnsupported(AVAudioFormat)

        var description: String {
            switch self {
            case .engineStartFailed(let e): return "mic engine start failed: \(e)"
            case .fileCreationFailed(let e): return "mic file creation failed: \(e)"
            case .formatUnsupported(let f): return "can't downmix mic format \(f)"
            }
        }
    }

    private var engine = AVAudioEngine()
    private var configurationObserver: NSObjectProtocol?
    private var preferRaw = false
    private var generation = 0
    private var file: AVAudioFile?
    private var url: URL?
    private(set) var isRecording = false
    /// Wall-clock time of the first captured buffer — the track's true start,
    /// used to offset-align the two tracks' transcript timestamps.
    let progress = CaptureProgress()
    var firstBufferAt: Date? { progress.snapshot.firstWrite }
    var hasAudioFrames: Bool { progress.snapshot.frames > 0 }

    // Liveness check state (voice-processing path only). Written from the tap
    // callback, read on main when deciding to fall back.
    private var livenessFrames = 0
    private var livenessPeak: Float = 0
    private var livenessSettled = false

    /// Start capturing the mic, writing linear PCM into `url` (use a .caf extension
    /// — PCM CAF needs no packet-table finalization, so a crash loses nothing written).
    func start(writingTo url: URL) throws {
        guard !isRecording else { return }
        generation += 1
        progress.reset()
        self.url = url
        try attach(voiceProcessing: !preferRaw && Config.micVoiceProcessing())
        isRecording = true
    }

    /// Stop capturing and finalize the file. Idempotent.
    func stop() {
        guard isRecording else { return }
        isRecording = false
        generation += 1
        removeConfigurationObserver()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        file = nil
    }

    // MARK: -

    /// Build the engine graph, create the PCM file, and start capture. Called
    /// once at start, and a second time (voiceProcessing: false) if the
    /// liveness check trips.
    private func attach(voiceProcessing: Bool) throws {
        engine = AVAudioEngine()
        let input = engine.inputNode

        var voice = voiceProcessing
        if voice {
            do {
                try input.setVoiceProcessingEnabled(true)
                // The live voice unit makes macOS treat the session like a
                // call and duck all other audio — meetings played through the
                // speakers would get quieter the moment recording starts.
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    .init(enableAdvancedDucking: false, duckingLevel: .min)
            } catch {
                FileHandle.standardError.write(Data(
                    "warning: mic voice processing unavailable (\(error)) — recording raw mic\n".utf8
                ))
                voice = false
            }
        }
        let inputFormat = input.outputFormat(forBus: 0)

        // One explicit mono client format. With voice processing this is the
        // Voice I/O boundary format on both sides of the duplex unit — never
        // accept the inherited multichannel route format (a 9-channel device
        // yielded digital silence). Raw capture downmixes to the same shape;
        // speech models want one channel anyway.
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RecorderError.formatUnsupported(inputFormat)
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVSampleRateKey: monoFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        do {
            file = try AVAudioFile(
                forWriting: url!,
                settings: settings,
                commonFormat: monoFormat.commonFormat,
                interleaved: monoFormat.isInterleaved
            )
        } catch {
            throw RecorderError.fileCreationFailed(error)
        }

        if voice {
            // Complete the duplex graph: VoiceProcessingIO must render to an
            // output device or the input side never produces audio. The mixer
            // has no sources — nothing is monitored or played — its connection
            // exists solely to give the unit a formatted output path.
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: monoFormat)
            livenessFrames = 0
            livenessPeak = 0
            livenessSettled = false
            installVoiceTap(on: input, format: monoFormat)
        } else {
            try installRawTap(on: input, inputFormat: inputFormat, monoFormat: monoFormat)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            file = nil
            throw RecorderError.engineStartFailed(error)
        }

        // A route change is observed immediately and picked up by the next
        // one-second health tick, instead of waiting for ten seconds of silence.
        removeConfigurationObserver()
        let epoch = progress.currentEpoch
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: nil) { [weak self] _ in self?.progress.deviceChanged(epoch: epoch) }
        let report = "mic: voiceProcessing=\(input.isVoiceProcessingEnabled) "
            + "input=\(input.outputFormat(forBus: 0)) tap=\(monoFormat)\n"
        FileHandle.standardError.write(Data(report.utf8))
    }

    /// Voice-processing path: the unit converts to the mono client format
    /// itself, so tapped buffers write straight to the file. Tracks signal
    /// peak over the first second — an unsupported route (device pair, macOS
    /// AUVPAggregate defects) delivers callbacks full of digital zeros, and
    /// the only recovery is restarting raw.
    private func installVoiceTap(on input: AVAudioInputNode, format: AVAudioFormat) {
        let checkFrames = Int(format.sampleRate)
        let generation = self.generation
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let file = self.file else { return }

            if !self.livenessSettled {
                let frames = Int(buffer.frameLength)
                if let data = buffer.floatChannelData?[0] {
                    for i in 0..<frames {
                        self.livenessPeak = max(self.livenessPeak, abs(data[i]))
                    }
                }
                self.livenessFrames += frames
                if self.livenessFrames >= checkFrames {
                    self.livenessSettled = true
                    if self.livenessPeak == 0 {
                        DispatchQueue.main.async {
                            guard self.generation == generation else { return }
                            self.fallBackToRaw()
                        }
                        return
                    }
                }
            }

            do {
                try file.write(from: buffer)
                self.progress.wrote(frames: Int64(buffer.frameLength), sampleRate: format.sampleRate)
            } catch {
                self.progress.failed("write_failed")
                FileHandle.standardError.write(Data("mic track write failed: \(error)\n".utf8))
            }
        }
    }

    /// Raw path: tap at the device's native format and downmix to mono. Same
    /// sample rate on both sides, so the one-shot convert applies.
    private func installRawTap(
        on input: AVAudioInputNode,
        inputFormat: AVAudioFormat,
        monoFormat: AVAudioFormat
    ) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: monoFormat) else {
            throw RecorderError.formatUnsupported(inputFormat)
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let file = self.file else { return }
            guard let mono = AVAudioPCMBuffer(
                pcmFormat: monoFormat,
                frameCapacity: buffer.frameCapacity
            ) else { return }
            do {
                try converter.convert(to: mono, from: buffer)
                try file.write(from: mono)
                self.progress.wrote(frames: Int64(mono.frameLength), sampleRate: monoFormat.sampleRate)
            } catch {
                self.progress.failed("write_failed")
                FileHandle.standardError.write(Data("mic track write failed: \(error)\n".utf8))
            }
        }
    }

    private func removeConfigurationObserver() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
    }
    deinit { removeConfigurationObserver() }

    /// Request a raw segment through the session's normal recovery path. Even
    /// the silent prefix is preserved; this recorder never deletes captured audio.
    private func fallBackToRaw() {
        guard isRecording else { return }
        preferRaw = true
        progress.failed("voice_processing_silent")
    }
}
