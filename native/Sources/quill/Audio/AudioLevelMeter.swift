import AVFoundation
import Accelerate
import Foundation

/// Optional display telemetry. Disabled when the popover is closed, never part
/// of recording health, source coverage, retention or recovery decisions.
final class AudioLevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var rms: Float = 0
    private var sampledAt = Date.distantPast
    func setEnabled(_ value: Bool) { lock.withLock { enabled = value; if !value { rms = 0 } } }
    var value: Float { lock.withLock { Date().timeIntervalSince(sampledAt) < 0.5 ? rms : 0 } }
    func observe(_ buffer: AVAudioPCMBuffer) {
        guard lock.withLock({ enabled }), buffer.frameLength > 0,
              let data = buffer.floatChannelData else { return }
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        var power: Float = 0
        if buffer.format.isInterleaved {
            vDSP_rmsqv(data[0], 1, &power, vDSP_Length(frames * channels))
        } else {
            for channel in 0..<channels {
                var channelRMS: Float = 0
                vDSP_rmsqv(data[channel], 1, &channelRMS, vDSP_Length(frames))
                power += channelRMS * channelRMS
            }
            power = sqrt(power / Float(max(1, channels)))
        }
        lock.withLock {
            guard enabled else { return }
            // Raw linear RMS is exposed; the UI can choose its own visual scale.
            rms = power.isFinite ? min(1, max(0, power)) : 0
            sampledAt = Date()
        }
    }
}
