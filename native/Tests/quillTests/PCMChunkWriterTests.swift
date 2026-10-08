import AVFoundation
import Foundation
import XCTest
@testable import quill

final class PCMChunkWriterTests: XCTestCase, @unchecked Sendable {
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
    private func root() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pcm-chunks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func buffer(_ value: Float, frames: UInt32 = 240) -> AVAudioPCMBuffer {
        let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        result.frameLength = frames
        for index in 0..<Int(frames) { result.floatChannelData![0][index] = value }
        return result
    }
    private func samples(_ file: URL) throws -> [Float] {
        let audio = try AVAudioFile(forReading: file)
        guard audio.length > 0 else { return [] }
        let data = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4096)!
        var result: [Float] = []
        // AVAudioFile may return fewer frames than requested before EOF.
        while audio.framePosition < audio.length {
            try audio.read(into: data)
            guard data.frameLength > 0 else { throw CocoaError(.fileReadCorruptFile) }
            result.append(contentsOf: UnsafeBufferPointer(start: data.floatChannelData![0], count: Int(data.frameLength)))
        }
        return result
    }
    private func assertSamples(_ actual: [Float], equalTo expected: [Float], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        let mismatch = zip(actual, expected).enumerated().first { _, pair in
            !pair.0.isFinite || abs(pair.0 - pair.1) > 1 / 32768
        }
        XCTAssertNil(mismatch, "Sample changed beyond one PCM16 step at \(mismatch?.offset ?? -1)", file: file, line: line)
    }
    func testCaptureStoresCompactPCMWithoutChangingChannelsRateOrFrameCount() throws {
        for (channels, interleaved): (UInt32, Bool) in [(1, false), (2, false), (2, true)] {
            let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
            let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: channels, interleaved: interleaved)!
            let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 48000)!
            input.frameLength = input.frameCapacity
            for channel in 0..<Int(channels) {
                for frame in 0..<Int(input.frameLength) {
                    let value = Float(sin(Double(frame) * 0.057 + Double(channel))) * 0.75
                    if interleaved { input.floatChannelData![0][frame * Int(channels) + channel] = value }
                    else { input.floatChannelData![channel][frame] = value }
                }
            }
            let writer = PCMChunkWriter(), url = dir.appendingPathComponent("capture.caf")
            try writer.start(writingTo: url, format: interleaved ? nil : sourceFormat)
            try writer.write(input)
            let second = dir.appendingPathComponent("capture-2.caf")
            let next = try writer.prepare(next: second)
            let closed = try writer.commit(next)
            XCTAssertEqual(closed.frames, 48000); XCTAssertEqual(closed.duration, 1)
            try writer.write(input); writer.stop()
            for url in [url, second] {
                let recorded = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
                let header = recorded.fileFormat.streamDescription.pointee
                XCTAssertEqual(header.mBitsPerChannel, 16)
                XCTAssertEqual(header.mBytesPerFrame, channels * 2)
                XCTAssertEqual(recorded.length, 48000); XCTAssertEqual(recorded.processingFormat.sampleRate, 48000)
                XCTAssertEqual(recorded.processingFormat.channelCount, channels)
                XCTAssertEqual(writer.progress.snapshot.frames, 48000); XCTAssertEqual(writer.progress.snapshot.duration, 1)
                let bytes = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber).intValue
                let payload = 48000 * Int(channels) * 2
                print("Synthetic capture: \(channels) channel(s), interleaved=\(interleaved), \(bytes) bytes including header; \(payload) PCM bytes expected")
                XCTAssertGreaterThanOrEqual(bytes, payload); XCTAssertLessThanOrEqual(bytes, payload + 8192)
                let output = AVAudioPCMBuffer(pcmFormat: recorded.processingFormat, frameCapacity: 4096)!
                var offset = 0
                while recorded.framePosition < recorded.length {
                    try recorded.read(into: output)
                    XCTAssertGreaterThan(output.frameLength, 0)
                    guard output.frameLength > 0 else { break }
                    for channel in 0..<Int(channels) {
                        for frame in 0..<Int(output.frameLength) {
                            let expected = interleaved ? input.floatChannelData![0][(offset + frame) * Int(channels) + channel]
                                : input.floatChannelData![channel][offset + frame]
                            XCTAssertEqual(output.floatChannelData![channel][frame], expected, accuracy: 1 / 32768)
                        }
                    }
                    offset += Int(output.frameLength)
                }
                XCTAssertEqual(offset, 48000)
            }
        }
    }
    func testCompactPCMQuantizesNormalizedSamplesAndClipsBeyondFullScale() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let values: [Float] = [-1.5, -1, -0.75, -1 / 65536, 0, 1 / 65536, 0.75, 0.999999, 1, 1.5]
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(values.count))!
        input.frameLength = input.frameCapacity
        for (index, value) in values.enumerated() { input.floatChannelData![0][index] = value }
        let writer = PCMChunkWriter(), file = dir.appendingPathComponent("mic.caf")
        try writer.start(writingTo: file, format: format); try writer.write(input); writer.stop()
        let decoded = try samples(file)
        XCTAssertEqual(decoded.count, values.count)
        XCTAssertEqual(decoded.first, -1); XCTAssertEqual(decoded.last, 1 - 1 / 32768)
        XCTAssertTrue(decoded.allSatisfy { $0.isFinite && $0 >= -1 && $0 < 1 })
        for index in 1..<(values.count - 1) {
            XCTAssertEqual(decoded[index], values[index], accuracy: 1 / 32768)
        }
    }
    func testCompactHandoffsAndHistoricalFloatAudioRemainReadableWithoutRewritingSources() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        func constant(_ value: Float) -> AVAudioPCMBuffer {
            let data = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 16000)!
            data.frameLength = data.frameCapacity
            data.floatChannelData![0].initialize(repeating: value, count: 16000)
            return data
        }
        let old = dir.appendingPathComponent("historical.caf")
        let historical = try AVAudioFile(forWriting: old, settings: sourceFormat.settings)
        try historical.write(from: constant(0.25)); historical.close()
        let original = try Data(contentsOf: old)
        let first = dir.appendingPathComponent("mic.caf"), second = dir.appendingPathComponent("mic-2.caf")
        let writer = PCMChunkWriter()
        try writer.start(writingTo: first, format: sourceFormat)
        try writer.write(constant(0.25))
        let prepared = try writer.prepare(next: second)
        let closed = try writer.commit(prepared)
        XCTAssertEqual(closed.frames, 16000); XCTAssertEqual(closed.duration, 1)
        try writer.write(constant(-0.5)); writer.stop()
        for file in [first, second] {
            let audio = try AVAudioFile(forReading: file), diskFormat = audio.fileFormat
            XCTAssertEqual(diskFormat.streamDescription.pointee.mBitsPerChannel, 16)
            XCTAssertEqual(try AudioRetention.duration(file), 1, accuracy: 0.000001)
        }
        let firstBytes = try Data(contentsOf: first), secondBytes = try Data(contentsOf: second)
        for left in [old, first] {
            let context = try BoundaryRecognition.makeClip(left: left, right: second)
            XCTAssertEqual(context.samples.count, 32000)
            XCTAssertEqual(context.leftDuration, 1); XCTAssertEqual(context.rightDuration, 1)
            XCTAssertTrue(context.samples.prefix(16000).allSatisfy { $0 == 0.25 })
            XCTAssertTrue(context.samples.suffix(16000).allSatisfy { $0 == -0.5 })
        }
        XCTAssertEqual(try Data(contentsOf: old), original)
        XCTAssertEqual(try Data(contentsOf: first), firstBytes)
        XCTAssertEqual(try Data(contentsOf: second), secondBytes)
    }
    func testPreparedFileReceivesNoFramesUntilCommitAndAllBuffersSurvive() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let writer = PCMChunkWriter(), first = dir.appendingPathComponent("mic.caf"), second = dir.appendingPathComponent("mic-2.caf")
        try writer.start(writingTo: first, format: format)
        let epoch = writer.progress.currentEpoch
        try writer.write(buffer(0.1), at: Date(timeIntervalSince1970: 1000), epoch: epoch)
        let next = try writer.prepare(next: second)
        try writer.write(buffer(0.2), at: Date(timeIntervalSince1970: 1000.01), epoch: epoch)
        XCTAssertEqual(try samples(second).count, 0)
        let closed = try writer.commit(next)
        XCTAssertEqual(closed.frames, 480); XCTAssertEqual(closed.duration, 0.02, accuracy: 0.00001)
        XCTAssertEqual(writer.progress.currentEpoch, epoch)
        XCTAssertEqual(writer.progress.snapshot.frames, 0)
        assertSamples(try samples(first), equalTo: Array(repeating: Float(0.1), count: 240) + Array(repeating: Float(0.2), count: 240))
        try writer.write(buffer(0.3), at: Date(timeIntervalSince1970: 1000.02), epoch: epoch)
        writer.stop()
        assertSamples(try samples(second), equalTo: Array(repeating: Float(0.3), count: 240))
        XCTAssertEqual(writer.progress.snapshot.frames, 240)
        XCTAssertThrowsError(try writer.commit(next))
    }
    func testPreparationFailureDoesNotOverwriteFilesOrStopCurrentWriter() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let writer = PCMChunkWriter(), first = dir.appendingPathComponent("mic.caf"), existing = dir.appendingPathComponent("mic-2.caf")
        let original = Data("Existing capture".utf8)
        try original.write(to: existing)
        try writer.start(writingTo: first, format: format)
        try writer.write(buffer(0.1))
        XCTAssertThrowsError(try writer.prepare(next: existing))
        try writer.write(buffer(0.2)); writer.stop()
        XCTAssertEqual(try Data(contentsOf: existing), original)
        XCTAssertEqual(try samples(first).count, 480)
    }
    func testLinkedDestinationAndReplacedPreparedFileCannotCaptureAudio() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let writer = PCMChunkWriter(), first = dir.appendingPathComponent("mic.caf"), target = dir.appendingPathComponent("outside")
        let second = dir.appendingPathComponent("mic-2.caf")
        try Data("Outside".utf8).write(to: target)
        try writer.start(writingTo: first, format: format); try writer.write(buffer(0.1))
        try FileManager.default.createSymbolicLink(at: second, withDestinationURL: target)
        XCTAssertThrowsError(try writer.prepare(next: second))
        try FileManager.default.removeItem(at: second)
        let next = try writer.prepare(next: second)
        try Data("Replacement".utf8).write(to: second, options: .atomic)
        XCTAssertThrowsError(try writer.commit(next))
        try writer.write(buffer(0.2)); writer.stop()
        XCTAssertEqual(try samples(first).count, 480)
        XCTAssertEqual(try Data(contentsOf: target), Data("Outside".utf8))
    }
    func testPreparedTokensAreBoundToWriterGenerationAndDeviceEventsSurvive() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let first = PCMChunkWriter(), second = PCMChunkWriter()
        try first.start(writingTo: dir.appendingPathComponent("mic.caf"), format: format)
        try second.start(writingTo: dir.appendingPathComponent("system.caf"), format: format)
        try first.write(buffer(0.1)); try second.write(buffer(0.2))
        let next = try first.prepare(next: dir.appendingPathComponent("mic-2.caf"))
        XCTAssertThrowsError(try second.commit(next))
        let epoch = first.progress.currentEpoch
        first.progress.deviceChanged(epoch: epoch)
        XCTAssertThrowsError(try first.commit(next))
        XCTAssertTrue(first.progress.snapshot.configurationChanged)
        first.stop(); second.stop()
        try first.start(writingTo: dir.appendingPathComponent("mic-3.caf"), format: format)
        try first.write(buffer(0.3))
        XCTAssertThrowsError(try first.commit(next), "A stopped/replaced engine invalidates its prepared files")
        try first.write(buffer(0.9), epoch: epoch)
        XCTAssertEqual(first.progress.snapshot.frames, 240, "Retired engine buffers must not enter the new file")
        first.stop()
    }
    func testChunkResetCannotEraseConcurrentFailureOrDeviceEvent() {
        let progress = CaptureProgress(), epoch = progress.currentEpoch
        progress.wrote(frames: 240, sampleRate: 24000)
        progress.failed("write_failed"); progress.deviceChanged(epoch: epoch)
        progress.nextChunk()
        XCTAssertEqual(progress.currentEpoch, epoch)
        XCTAssertEqual(progress.snapshot.failure, "write_failed")
        XCTAssertTrue(progress.snapshot.configurationChanged)
        XCTAssertEqual(progress.snapshot.frames, 0)
    }
    func testManifestHandoffKeepsExactClockAndDoesNotSpendRecoveryBudget() throws {
        var capture = CaptureRecovery(origin: 1000)
        capture.begin(source: "mic", file: "mic.caf", at: Date(timeIntervalSince1970: 1000))
        let planned = CaptureProgress.Snapshot(firstWrite: Date(timeIntervalSince1970: 1000),
            lastWrite: Date(timeIntervalSince1970: 1300), frames: 7_200_000, duration: 300)
        let name = capture.nextFilename(source: "mic")
        try capture.planChunk(source: "mic", file: name, progress: planned)
        XCTAssertEqual(capture.segments.last?.rotation_pending, true)
        XCTAssertEqual(capture.gaps.last?.reason, "rotation_pending")
        var closed = planned; closed.duration = 300.01; closed.frames += 240
        closed.lastWrite = Date(timeIntervalSince1970: 1300.01)
        XCTAssertEqual(try capture.commitChunk(source: "mic", file: name, closed: closed), "mic.caf")
        XCTAssertTrue(capture.gaps.isEmpty)
        XCTAssertEqual(capture.segments.first?.closed, true)
        XCTAssertEqual(capture.segments.last?.offset_ms, 300010)
        let fresh = CaptureProgress.Snapshot(firstWrite: Date(timeIntervalSince1970: 1300.02),
            lastWrite: Date(timeIntervalSince1970: 1301), frames: 24000, duration: 1)
        capture.observe(source: "mic", progress: fresh)
        XCTAssertEqual(capture.segments.last?.offset_ms, 300010, "Wall-clock callback jitter cannot move a continuous boundary")
        XCTAssertFalse(capture.recoveryLimited(source: "mic", at: Date(timeIntervalSince1970: 1301)))
        var failed = fresh; failed.failure = "write_failed"
        XCTAssertEqual(capture.rotate(source: "mic", progress: failed, at: Date(timeIntervalSince1970: 1301)), "mic-3.caf")
        XCTAssertEqual(Set(capture.segments.map(\.file)).count, capture.segments.count)
    }
    func testRotationGapRemovalDoesNotMoveAnUnresolvedOtherSourceRecovery() throws {
        var capture = CaptureRecovery(origin: 1000)
        capture.begin(source: "system", file: "system.caf", at: Date(timeIntervalSince1970: 1000))
        capture.begin(source: "mic", file: "mic.caf", at: Date(timeIntervalSince1970: 1000))
        let good = CaptureProgress.Snapshot(firstWrite: Date(timeIntervalSince1970: 1000),
            lastWrite: Date(timeIntervalSince1970: 1300), frames: 7_200_000, duration: 300)
        try capture.planChunk(source: "system", file: "system-2.caf", progress: good)
        let failed = CaptureProgress.Snapshot(failure: "write_failed")
        XCTAssertNotNil(capture.rotate(source: "mic", progress: failed, at: Date(timeIntervalSince1970: 1300)))
        capture.begin(source: "mic", file: "mic-2.caf", at: Date(timeIntervalSince1970: 1300))
        _ = try capture.commitChunk(source: "system", file: "system-2.caf", closed: good)
        capture.observe(source: "mic", progress: .init(firstWrite: Date(timeIntervalSince1970: 1302), frames: 240, duration: 0.01))
        XCTAssertEqual(capture.gaps.count, 1)
        XCTAssertEqual(capture.gaps.first?.source, "mic")
        XCTAssertEqual(capture.gaps.first?.end_ms, 302000)
    }
    func testCumulativeClockShortfallAtRolloverBecomesExplicitUncertainty() throws {
        var capture = CaptureRecovery(origin: 1000)
        capture.begin(source: "mic", file: "mic.caf", at: Date(timeIntervalSince1970: 1000))
        let progress = CaptureProgress.Snapshot(firstWrite: Date(timeIntervalSince1970: 1000),
            lastWrite: Date(timeIntervalSince1970: 1303), frames: 7_200_000, duration: 300)
        try capture.planChunk(source: "mic", file: "mic-2.caf", progress: progress)
        _ = try capture.commitChunk(source: "mic", file: "mic-2.caf", closed: progress)
        XCTAssertEqual(capture.gaps.first?.reason, "frame_coverage_shortfall")
        XCTAssertEqual(capture.segments.first?.timing_uncertain, true)
        capture.observe(source: "mic", progress: .init(firstWrite: Date(timeIntervalSince1970: 1304), frames: 240, duration: 0.01))
        XCTAssertEqual(capture.segments.last?.offset_ms, 304000)
    }
}

extension PCMChunkWriterTests {
    func testProductionHandoffPersistsBeforeSwitchAndUsesTheActualClosedFrameCount() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let writer = PCMChunkWriter()
        try writer.start(writingTo: dir.appendingPathComponent("mic.caf"), format: format)
        try writer.write(buffer(0.1), at: Date(timeIntervalSince1970: 1000))
        var capture = CaptureRecovery(origin: 1000)
        capture.begin(source: "mic", file: "mic.caf", at: Date(timeIntervalSince1970: 1000))
        var persisted: CaptureRecovery?
        let result = CaptureChunkHandoff.perform(source: "mic", capture: capture, progress: writer.progress.snapshot,
            prepare: { file in try writer.prepare(next: dir.appendingPathComponent(file)) },
            persist: { proposed in
                persisted = proposed
                // Audio continues in the old file while the manifest is saved.
                try writer.write(self.buffer(0.2), at: Date(timeIntervalSince1970: 1000.01))
                XCTAssertEqual(try self.samples(dir.appendingPathComponent("mic-2.caf")).count, 0)
            }, commit: { next in
                XCTAssertEqual(persisted?.segments.last?.rotation_pending, true)
                return try writer.commit(next)
            })
        XCTAssertFalse(result.failed); XCTAssertEqual(result.closedFile, "mic.caf")
        XCTAssertEqual(result.capture.segments.first?.frames_written, 480)
        XCTAssertEqual(result.capture.segments.last?.offset_ms, 20)
        XCTAssertTrue(result.capture.gaps.isEmpty)
        try writer.write(buffer(0.3)); writer.stop()
        XCTAssertEqual(try samples(dir.appendingPathComponent("mic.caf")).count, 480)
        XCTAssertEqual(try samples(dir.appendingPathComponent("mic-2.caf")).count, 240)
    }
    func testFailedManifestWriteCannotSwitchWriterOrLoseAudio() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let writer = PCMChunkWriter()
        try writer.start(writingTo: dir.appendingPathComponent("mic.caf"), format: format)
        try writer.write(buffer(0.1))
        var capture = CaptureRecovery(origin: 1000)
        capture.begin(source: "mic", file: "mic.caf", at: Date(timeIntervalSince1970: 1000))
        var switched = false
        let result = CaptureChunkHandoff.perform(source: "mic", capture: capture, progress: writer.progress.snapshot,
            prepare: { file in try writer.prepare(next: dir.appendingPathComponent(file)) },
            persist: { _ in throw POSIXError(.ENOSPC) }, commit: { next in switched = true; return try writer.commit(next) })
        XCTAssertTrue(result.failed); XCTAssertNil(result.closedFile); XCTAssertFalse(switched)
        XCTAssertEqual(result.capture.gaps.first?.reason, "rotation_pending")
        try writer.write(buffer(0.2)); writer.stop()
        XCTAssertEqual(try samples(dir.appendingPathComponent("mic.caf")).count, 480)
        XCTAssertEqual(try samples(dir.appendingPathComponent("mic-2.caf")).count, 0)
    }
    func testPendingManifestAfterSimulatedCrashSuppressesTimingClaims() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let writer = PCMChunkWriter()
        try writer.start(writingTo: dir.appendingPathComponent("mic.caf"), format: format)
        try writer.write(buffer(0.1), at: Date(timeIntervalSince1970: 1000))
        var capture = CaptureRecovery(origin: 1000)
        capture.begin(source: "mic", file: "mic.caf", at: Date(timeIntervalSince1970: 1000))
        let result = CaptureChunkHandoff.perform(source: "mic", capture: capture, progress: writer.progress.snapshot,
            prepare: { file in try writer.prepare(next: dir.appendingPathComponent(file)) }, persist: { proposed in
                let segments = try JSONSerialization.jsonObject(with: JSONEncoder().encode(proposed.segments))
                let gaps = try JSONSerialization.jsonObject(with: JSONEncoder().encode(proposed.gaps))
                try JSONSerialization.data(withJSONObject: ["files": ["mic": "mic.caf"], "capture_segments": segments,
                    "capture_gaps": gaps]).write(to: dir.appendingPathComponent("meta.json"))
            }, commit: { _ in throw CancellationError() })
        writer.stop()
        XCTAssertTrue(result.failed)
        let parsed = try SessionMeta.read(from: dir)
        XCTAssertEqual(parsed.tracks.count, 2)
        XCTAssertFalse(parsed.tracks[0].timingUncertain)
        XCTAssertTrue(parsed.tracks[1].timingUncertain)
        XCTAssertEqual(parsed.captureGaps.first?.reason, "rotation_pending")
    }
}

private final class ChunkWriteErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var errors = 0
    func failed() { lock.withLock { errors += 1 } }
    var count: Int { lock.withLock { errors } }
}
extension PCMChunkWriterTests {
    func testConcurrentBufferWritesAcrossHandoffsHaveNoMissingOrDuplicatedFrames() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let writer = PCMChunkWriter(), errors = ChunkWriteErrors(), group = DispatchGroup()
        var files = [dir.appendingPathComponent("mic.caf")]
        try writer.start(writingTo: files[0], format: format)
        try writer.write(buffer(-1, frames: 8))
        let epoch = writer.progress.currentEpoch
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            for number in 0..<4000 {
                do { try writer.write(self.buffer(Float(number) / 8192, frames: 8), epoch: epoch) }
                catch { errors.failed() }
            }
        }
        for number in 2...10 {
            let next = dir.appendingPathComponent("mic-\(number).caf")
            if writer.progress.snapshot.frames == 0 { break }
            let prepared = try writer.prepare(next: next)
            _ = try writer.commit(prepared)
            files.append(next)
            if group.wait(timeout: .now()) == .success { break }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        writer.stop()
        XCTAssertEqual(errors.count, 0)
        let joined = try files.flatMap { try samples($0) }
        let expected = Array(repeating: Float(-1), count: 8) + (0..<4000).flatMap { Array(repeating: Float($0) / 8192, count: 8) }
        let mismatch = zip(joined, expected).enumerated().first { $0.element.0 != $0.element.1 }?.offset
        XCTAssertTrue(joined == expected, "Expected \(expected.count) samples; read \(joined.count). First changed sample: \(mismatch.map(String.init) ?? "none; tail length differs").")
    }
    func testLongManifestsRemainReadableAndHealthyRotationStopsBeforeRecoveryHeadroom() throws {
        var capture = CaptureRecovery(origin: 1000)
        capture.begin(source: "mic", file: "mic.caf", at: Date(timeIntervalSince1970: 1000))
        var start = 1000.0
        for _ in 1..<CaptureManifest.healthyRotationLimit {
            let progress = CaptureProgress.Snapshot(firstWrite: Date(timeIntervalSince1970: start),
                lastWrite: Date(timeIntervalSince1970: start + 300), frames: 7_200_000, duration: 300)
            let next = capture.nextFilename(source: "mic")
            try capture.planChunk(source: "mic", file: next, progress: progress)
            _ = try capture.commitChunk(source: "mic", file: next, closed: progress)
            start += 300
        }
        let progress = CaptureProgress.Snapshot(frames: 7_200_000, duration: 300)
        XCTAssertThrowsError(try capture.planChunk(source: "mic", file: capture.nextFilename(source: "mic"), progress: progress))
        XCTAssertFalse(capture.recoveryLimited(source: "mic", at: Date(timeIntervalSince1970: start)))
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let segments = try JSONSerialization.jsonObject(with: JSONEncoder().encode(capture.segments))
        try JSONSerialization.data(withJSONObject: ["files": ["mic": "mic.caf"], "capture_segments": segments])
            .write(to: dir.appendingPathComponent("meta.json"))
        XCTAssertEqual(try SessionMeta.read(from: dir).tracks.count, CaptureManifest.healthyRotationLimit)
    }
    func testStoppedLongFileExposesAllSuccessfulPCMFramesImmediately() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let writer = PCMChunkWriter(), file = dir.appendingPathComponent("mic.caf")
        try writer.start(writingTo: file, format: format)
        for number in 0..<4000 { try writer.write(buffer(Float(number) / 8192, frames: 8)) }
        XCTAssertEqual(writer.progress.snapshot.frames, 32000)
        writer.stop()
        XCTAssertEqual(try samples(file).count, 32000)
    }

}
