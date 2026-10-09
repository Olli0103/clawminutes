import AVFoundation
import Foundation
import FluidAudio

/// Re-decodes a bounded, continuous PCM seam. Timed anchors or complete short
/// files authorize replacing earlier speech. It never changes a cache.
enum BoundaryRecognition {
    static let contextSeconds = 6.0
    struct Pair {
        let left: [TranscriptSegment]
        let right: [TranscriptSegment]
    }
    /// Owned model-ready samples. No audio excerpt is written to disk.
    struct Clip: Sendable {
        let samples: [Float]
        let leftStart: Double
        let leftSeconds: Double
        let rightSeconds: Double
        let rightDuration: Double
        let leftDuration: Double
    }
    static let sampleRate = 16000.0
    static let maximumSamples = Int(contextSeconds * 2 * sampleRate)

    static func makeClip(left: URL, right: URL) throws -> Clip {
        try Task.checkCancellation()
        let firstIdentity = try AudioRetention.FileIdentity.read(left), secondIdentity = try AudioRetention.FileIdentity.read(right)
        // Request owned planar floats even for integer/interleaved source CAFs.
        let first = try AVAudioFile(forReading: left, commonFormat: .pcmFormatFloat32, interleaved: false)
        let second = try AVAudioFile(forReading: right, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = first.processingFormat
        guard first.length > 0, second.length > 0, format == second.processingFormat,
              (8000...192000).contains(format.sampleRate), (1...2).contains(format.channelCount) else {
            throw MeetingPipelineState.invalidState
        }
        let firstFrames = min(first.length, Int64(contextSeconds * format.sampleRate))
        let secondFrames = min(second.length, Int64(contextSeconds * format.sampleRate))
        // At most 12 seconds, 192 kHz and two Float32 channels: 18,432,000
        // source bytes. Resampling produces at most 192,000 owned floats.
        guard let joined = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(firstFrames + secondFrames)) else {
            throw MeetingPipelineState.invalidState
        }
        first.framePosition = first.length - firstFrames
        try copy(first, frames: firstFrames, into: joined, offset: 0)
        second.framePosition = 0
        try copy(second, frames: secondFrames, into: joined, offset: Int(firstFrames))
        joined.frameLength = joined.frameCapacity
        try Task.checkCancellation()
        let samples = try AudioConverter().resampleBuffer(joined)
        let duration = Double(firstFrames + secondFrames) / format.sampleRate
        guard !samples.isEmpty, samples.count <= maximumSamples,
              abs(Double(samples.count) / sampleRate - duration) <= 0.002,
              samples.allSatisfy(\.isFinite) else { throw MeetingPipelineState.invalidState }
        try Task.checkCancellation()
        guard try AudioRetention.FileIdentity.read(left) == firstIdentity,
              try AudioRetention.FileIdentity.read(right) == secondIdentity else { throw MeetingPipelineState.conflictingState }
        return Clip(samples: samples, leftStart: Double(first.length - firstFrames) / format.sampleRate,
            leftSeconds: Double(firstFrames) / format.sampleRate, rightSeconds: Double(secondFrames) / format.sampleRate,
            rightDuration: Double(second.length) / format.sampleRate, leftDuration: Double(first.length) / format.sampleRate)
    }
    private static func copy(_ input: AVAudioFile, frames: Int64, into output: AVAudioPCMBuffer, offset: Int) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 4096),
              let destination = output.floatChannelData else { throw MeetingPipelineState.invalidState }
        var remaining = frames, position = offset
        while remaining > 0 {
            try Task.checkCancellation()
            try input.read(into: buffer, frameCount: UInt32(min(remaining, Int64(buffer.frameCapacity))))
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { throw MeetingPipelineState.invalidState }
            let count = Int(buffer.frameLength)
            for channel in 0..<Int(output.format.channelCount) {
                let source = UnsafeBufferPointer(start: channels[channel], count: count)
                guard source.allSatisfy(\.isFinite) else { throw MeetingPipelineState.invalidState }
                destination[channel].advanced(by: position).update(from: channels[channel], count: count)
            }
            remaining -= Int64(count); position += count
        }
    }

    static func reconcile(left: [TranscriptSegment], right: [TranscriptSegment],
                          context: [TranscriptSegment], leftStart: Double, leftDuration: Double,
                          rightSeconds: Double, rightDuration: Double) -> Pair? {
        let seconds = leftDuration - leftStart + rightSeconds
        guard leftStart >= 0, leftDuration.isFinite, rightDuration.isFinite, rightDuration > 0,
              seconds.isFinite, seconds > 0, seconds <= contextSeconds * 2 + 0.01,
              ClosedChunkRecognition.valid(context, seconds: seconds),
              let before = words(left), let after = words(right), let decoded = words(context) else { return nil }
        let bridge = decoded.map { TranscriptWord(start: $0.start + leftStart, end: $0.end + leftStart, text: $0.text) }
        let shiftedAfter = after.map { TranscriptWord(start: $0.start + leftDuration, end: $0.end + leftDuration, text: $0.text) }
        // Both recognitions report silence throughout the context window.
        if bridge.isEmpty, before.allSatisfy({ $0.end <= leftStart }), after.allSatisfy({ $0.start >= rightSeconds }) {
            return Pair(left: left, right: right)
        }
        let leftAnchor = anchor(original: before, bridge: bridge, lower: leftStart + 0.25, upper: leftDuration - 1, latest: false)
        let rightAnchor = anchor(original: shiftedAfter, bridge: bridge, lower: leftDuration + 1, upper: leftDuration + rightSeconds - 0.25, latest: true)
        // Whole short files supply their natural beginning/end instead of a
        // textual anchor outside the clip. Long files require both anchors.
        guard leftAnchor != nil || leftStart == 0,
              rightAnchor != nil || rightSeconds == rightDuration else { return nil }
        let keepLeft = leftAnchor.map { $0.original + 2 } ?? 0
        let keepRight = rightAnchor?.original ?? after.count
        let begin = leftAnchor.map { $0.bridge + 2 } ?? 0
        let end = rightAnchor?.bridge ?? bridge.count
        guard begin <= end else { return nil }
        let replacement = Array(bridge[begin..<end])
        let removed = before.count - keepLeft + keepRight
        guard !replacement.isEmpty || removed == 0 else { return nil }
        let keptBefore = Array(before.prefix(keepLeft)), keptAfter = Array(shiftedAfter.dropFirst(keepRight))
        let all = keptBefore + replacement + keptAfter
        // Anchor drift cannot create crossed, duplicated timestamp intervals.
        guard ordered(all), all.allSatisfy({ $0.end <= leftDuration + rightDuration + 1 }) else { return nil }
        // A word spanning the seam belongs to the left file once, with its
        // complete text and time. Source-local time never becomes negative.
        return Pair(left: segments(all.filter { $0.start < leftDuration }),
            right: segments(all.filter { $0.start >= leftDuration }.map {
                TranscriptWord(start: $0.start - leftDuration, end: $0.end - leftDuration, text: $0.text)
            }))
    }
    private static func words(_ spans: [TranscriptSegment]) -> [TranscriptWord]? {
        guard spans.allSatisfy({ span in
            let text = span.text.split(whereSeparator: \.isWhitespace).map(String.init)
            let timed = span.words.flatMap { $0.text.split(whereSeparator: \.isWhitespace).map(String.init) }
            return text == timed
        }) else { return nil }
        let result = spans.flatMap(\.words)
        return ordered(result) ? result : nil
    }
    private static func ordered(_ words: [TranscriptWord]) -> Bool {
        words.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start }) &&
            zip(words, words.dropFirst()).allSatisfy({ $0.start <= $1.start && $0.end <= $1.end })
    }
    private static func key(_ word: TranscriptWord) -> String { String(word.text.lowercased().filter { $0.isLetter || $0.isNumber }) }
    private static func anchor(original: [TranscriptWord], bridge: [TranscriptWord], lower: Double, upper: Double,
                               latest: Bool) -> (original: Int, bridge: Int)? {
        guard original.count >= 2, bridge.count >= 2, lower <= upper else { return nil }
        let range = lower...upper
        let candidates = Array(0..<(original.count - 1))
        for index in latest ? candidates.reversed() : candidates {
            let a = original[index], b = original[index + 1]
            guard range.contains(a.start), range.contains(b.end), !key(a).isEmpty, !key(b).isEmpty else { continue }
            let matches = (0..<(bridge.count - 1)).filter {
                key(bridge[$0]) == key(a) && key(bridge[$0 + 1]) == key(b) &&
                    abs(bridge[$0].start - a.start) <= 0.75 && abs(bridge[$0 + 1].end - b.end) <= 0.75
            }
            if matches.count == 1 { return (index, matches[0]) }
        }
        return nil
    }
    private static func segments(_ words: [TranscriptWord]) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = [], pending: [TranscriptWord] = []
        func flush() {
            guard let first = pending.first, let last = pending.last else { return }
            result.append(TranscriptSegment(start: first.start, end: last.end, text: pending.map(\.text).joined(separator: " "), words: pending))
            pending.removeAll(keepingCapacity: true)
        }
        for word in words {
            if let last = pending.last, word.start - last.end > 1 { flush() }
            pending.append(word)
            if pending.count >= 60 || word.text.hasSuffix(".") || word.text.hasSuffix("?") || word.text.hasSuffix("!") { flush() }
        }
        flush()
        return result
    }
}
