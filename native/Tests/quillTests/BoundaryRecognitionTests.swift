import AVFoundation
import Foundation
import XCTest
@testable import quill

final class BoundaryRecognitionTests: XCTestCase, @unchecked Sendable {
    fileprivate static func spans(_ words: [(Double, Double, String)]) -> [TranscriptSegment] {
        guard let first = words.first, let last = words.last else { return [] }
        return [TranscriptSegment(start: first.0, end: last.1, text: words.map { $0.2 }.joined(separator: " "),
            words: words.map { TranscriptWord(start: $0.0, end: $0.1, text: $0.2) })]
    }
    fileprivate static var before: [TranscriptSegment] { spans([(1, 1.5, "Earlier."), (25, 25.4, "We"), (26, 26.4, "agreed"), (29.8, 30, "inter")]) }
    fileprivate static var after: [TranscriptSegment] { spans([(0, 0.2, "national"), (1.5, 1.9, "delivery"), (2.2, 2.5, "on"), (2.8, 3.2, "Friday."), (10, 10.5, "Unchanged.")]) }
    fileprivate static var context: [TranscriptSegment] { spans([(1, 1.4, "We"), (2, 2.4, "agreed"), (5.8, 6.2, "international"), (7.5, 7.9, "delivery"), (8.2, 8.5, "on"), (8.8, 9.2, "Friday.")]) }
    private var before: [TranscriptSegment] { Self.before }
    private var after: [TranscriptSegment] { Self.after }
    private var context: [TranscriptSegment] { Self.context }
    private func spans(_ words: [(Double, Double, String)]) -> [TranscriptSegment] { Self.spans(words) }
    private func reconcile(_ context: [TranscriptSegment]) -> BoundaryRecognition.Pair? {
        BoundaryRecognition.reconcile(left: before, right: after, context: context,
            leftStart: 24, leftDuration: 30, rightSeconds: 6, rightDuration: 30)
    }
    func testAnchoredContextRepairsSplitWordOnceAndPreservesUnchangedSpeechAndTime() throws {
        let result = try XCTUnwrap(reconcile(context))
        XCTAssertEqual((result.left + result.right).flatMap(\.words).map(\.text),
            ["Earlier.", "We", "agreed", "international", "delivery", "on", "Friday.", "Unchanged."])
        let crossing = try XCTUnwrap(result.left.flatMap(\.words).last)
        XCTAssertEqual(crossing.start, 29.8, accuracy: 0.001); XCTAssertEqual(crossing.end, 30.2, accuracy: 0.001)
        XCTAssertEqual(result.right.flatMap(\.words).first?.start ?? -1, 1.5, accuracy: 0.001)
        XCTAssertTrue(result.right.flatMap(\.words).allSatisfy { $0.start >= 0 })
    }
    func testMissingAnchorsTextWithoutTimingsAndUnrepresentedTextCannotReplaceSpeech() {
        XCTAssertNil(reconcile(spans([(1, 1.4, "Different"), (2, 2.4, "words"), (5.8, 6.2, "international")])))
        XCTAssertNil(reconcile([TranscriptSegment(start: 0, end: 12, text: "Unanchored text")]))
        var changed = context
        changed[0] = TranscriptSegment(start: changed[0].start, end: changed[0].end, text: "Extra speech " + changed[0].text, words: changed[0].words)
        XCTAssertNil(reconcile(changed)); XCTAssertNil(reconcile([]))
    }
    func testInvalidTimingAndAmbiguousRepeatedAnchorsCannotReplaceSpeech() {
        let invalid = spans([(1, 1.4, "We"), (2, 2.4, "agreed"), (6, 5, "backwards")])
        XCTAssertNil(reconcile(invalid))
        let ambiguous = spans([(0.8, 1, "We"), (1.1, 1.8, "agreed"), (1.2, 1.8, "We"), (2, 2.4, "agreed"),
            (5.8, 6.2, "international"), (8.2, 8.5, "on"), (8.8, 9.2, "Friday.")])
        XCTAssertNil(reconcile(ambiguous))
    }
    func testWholeShortFilesUseNaturalEndsAndSilenceDoesNotInventSpeech() throws {
        let result = try XCTUnwrap(BoundaryRecognition.reconcile(left: spans([(0.8, 1, "inter")]), right: spans([(0, 0.2, "national")]),
            context: spans([(0.8, 1.2, "international")]), leftStart: 0, leftDuration: 1, rightSeconds: 1, rightDuration: 1))
        XCTAssertEqual(result.left.flatMap(\.words).map(\.text), ["international"]); XCTAssertTrue(result.right.isEmpty)
        let silence = BoundaryRecognition.reconcile(left: [], right: [], context: [], leftStart: 24, leftDuration: 30, rightSeconds: 6, rightDuration: 30)
        XCTAssertNotNil(silence)
    }
    private func audio(_ file: URL, seconds: Double, value: Float, channels: UInt32 = 1) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: channels)!
        let data = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(seconds * 24000))!
        data.frameLength = data.frameCapacity
        for channel in 0..<Int(channels) { data.floatChannelData![channel].initialize(repeating: value, count: Int(data.frameLength)) }
        let file = try AVAudioFile(forWriting: file, settings: format.settings)
        try file.write(from: data); file.close()
    }
    func testPCMContextCopiesExactTailAndHeadWithoutChangingSourcesAndCleansUp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("mic.caf"), second = root.appendingPathComponent("mic-2.caf")
        try audio(first, seconds: 10, value: 0.1); try audio(second, seconds: 10, value: 0.2)
        let original = try AudioRetention.FileIdentity.read(first)
        let clip = try BoundaryRecognition.makeClip(left: first, right: second)
        defer { clip.remove() }
        XCTAssertEqual(clip.leftStart, 4); XCTAssertEqual(clip.leftDuration, 10); XCTAssertEqual(clip.rightDuration, 10)
        let file = try AVAudioFile(forReading: clip.file)
        XCTAssertEqual(file.length, 288000)
        let data = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
        var index = 0
        while file.framePosition < file.length {
            try file.read(into: data)
            XCTAssertGreaterThan(data.frameLength, 0)
            guard data.frameLength > 0 else { break }
            for position in 0..<Int(data.frameLength) {
                XCTAssertEqual(data.floatChannelData![0][position], index < 144000 ? Float(0.1) : Float(0.2))
                index += 1
            }
        }
        XCTAssertEqual(index, 288000)
        XCTAssertEqual(try AudioRetention.FileIdentity.read(first), original)
        clip.remove(); XCTAssertFalse(FileManager.default.fileExists(atPath: clip.file.path))
    }
    func testChangedFormatAndLinkedInputsAreRejectedAndUnexpectedTemporaryItemsAreKept() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("mic.caf"), second = root.appendingPathComponent("mic-2.caf")
        try audio(first, seconds: 1, value: 0.1); try audio(second, seconds: 1, value: 0.2, channels: 2)
        XCTAssertThrowsError(try BoundaryRecognition.makeClip(left: first, right: second))
        try FileManager.default.removeItem(at: second)
        try FileManager.default.createSymbolicLink(at: second, withDestinationURL: first)
        XCTAssertThrowsError(try BoundaryRecognition.makeClip(left: first, right: second))
        try FileManager.default.removeItem(at: second); try audio(second, seconds: 1, value: 0.2)
        let clip = try BoundaryRecognition.makeClip(left: first, right: second)
        defer { try? FileManager.default.removeItem(at: clip.file.deletingLastPathComponent()) }
        let unexpected = clip.file.deletingLastPathComponent().appendingPathComponent("unexpected.txt")
        try Data("preserved".utf8).write(to: unexpected)
        clip.remove()
        XCTAssertTrue(FileManager.default.fileExists(atPath: clip.file.path))
        XCTAssertEqual(try String(contentsOf: unexpected, encoding: .utf8), "preserved")
    }
    func testStereoContextPreservesBothChannelsAndPrivatePermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let files = [root.appendingPathComponent("system.caf"), root.appendingPathComponent("system-2.caf")]
        for (index, url) in files.enumerated() {
            let data = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
            data.frameLength = 48000
            for channel in 0..<2 { data.floatChannelData![channel].initialize(repeating: Float(index * 2 + channel), count: 48000) }
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: data); file.close()
        }
        let clip = try BoundaryRecognition.makeClip(left: files[0], right: files[1])
        defer { clip.remove() }
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: clip.file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: clip.file.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let reader = try AVAudioFile(forReading: clip.file)
        XCTAssertEqual(reader.processingFormat.channelCount, 2); XCTAssertEqual(reader.length, 96000)
        let data = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 4096)!
        var frame = 0
        while reader.framePosition < reader.length {
            try reader.read(into: data)
            guard data.frameLength > 0 else { XCTFail("Unexpected PCM EOF"); break }
            for position in 0..<Int(data.frameLength) {
                for channel in 0..<2 { XCTAssertEqual(data.floatChannelData![channel][position], Float((frame < 48000 ? 0 : 2) + channel)) }
                frame += 1
            }
        }
        XCTAssertEqual(frame, 96000)
    }
}

private actor BoundaryEngine: TranscriptionEngine {
    nonisolated let name: String
    nonisolated let model = "synthetic-context"
    private(set) var calls: [URL] = []
    let decodeContext: @Sendable (URL) async throws -> [TranscriptSegment]
    init(name: String = "parakeet", decodeContext: @escaping @Sendable (URL) async throws -> [TranscriptSegment] = { _ in BoundaryRecognitionTests.context }) {
        self.name = name; self.decodeContext = decodeContext
    }
    func prepare() async throws {}
    func release() async {}
    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        calls.append(audio)
        switch audio.lastPathComponent {
        case "mic.caf": return BoundaryRecognitionTests.before
        case "mic-2.caf": return BoundaryRecognitionTests.after
        case "context.caf": return try await decodeContext(audio)
        default: return BoundaryRecognitionTests.spans([(4, 4.5, "Remote speech.")])
        }
    }
}

extension BoundaryRecognitionTests {
    private func fixture(continuous: Bool = true, uncertain: Bool = false) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("boundary-pipeline-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let meta: [String: Any] = ["started": "2026-10-08T08:00:00Z", "recording_id": "stable", "status": "recording",
            "audio_started_at": 1000.0, "backend": "parakeet", "local_speaker_name": "Fixture Owner",
            "files": ["mic": "mic.caf", "system": "system.caf"],
            "capture_segments": [
                ["source": "mic", "file": "mic.caf", "offset_ms": 0, "started_at": 1000, "ended_at": 1030, "closed": true, "frames_written": 720000],
                ["source": "mic", "file": "mic-2.caf", "offset_ms": 30000, "started_at": 1030, "continuous_clock": continuous, "timing_uncertain": uncertain],
                ["source": "system", "file": "system.caf", "offset_ms": 0, "started_at": 1000]]]
        try JSONSerialization.data(withJSONObject: meta).write(to: root.appendingPathComponent("meta.json"))
        try audio(root.appendingPathComponent("mic.caf"), seconds: 30, value: 0.1)
        try audio(root.appendingPathComponent("mic-2.caf"), seconds: 30, value: 0.2)
        try audio(root.appendingPathComponent("system.caf"), seconds: 60, value: 0.3)
        return root
    }
    private func finish(_ dir: URL) throws {
        var meta = try ArchiveBacklog.object(dir.appendingPathComponent("meta.json"))
        meta["status"] = "stopped"; meta["ended"] = "2026-10-08T08:01:00Z"
        try JSONSerialization.data(withJSONObject: meta).write(to: dir.appendingPathComponent("meta.json"))
    }
    private func worker(_ dir: URL, engine: BoundaryEngine) -> RecordingTranscriber {
        RecordingTranscriber(activityLockPath: dir.appendingPathComponent("lifecycle.lock"), audioDuration: { url in
            let audio = try AVAudioFile(forReading: url)
            return Double(audio.length) / audio.processingFormat.sampleRate
        }, makeEngine: { _, _ in engine })
    }
    private func result(_ dir: URL) throws -> Transcript {
        try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: dir.appendingPathComponent("transcript.json")))
    }
    func testFinalPipelineReusesCheckpointThenReconcilesContextBeforeSpeakerAlignment() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let engine = BoundaryEngine(), transcriber = worker(dir, engine: BoundaryEngine())
        // Durable cache is produced by one worker, then used by another.
        try await transcriber.transcribeClosedChunk(dir, file: "mic.caf")
        let cache = try Data(contentsOf: ClosedChunkRecognition.path(dir, file: "mic.caf"))
        try finish(dir)
        try await worker(dir, engine: engine).transcribe(dir, detectSpeakers: false)
        let transcript = try result(dir)
        XCTAssertEqual(transcript.segments.filter { $0.source == "mic" }.map(\.text).joined(separator: " "),
            "Earlier. We agreed international delivery on Friday. Unchanged.")
        XCTAssertTrue(transcript.segments.filter { $0.source == "mic" }.allSatisfy { $0.speaker_name == "Fixture Owner" })
        XCTAssertTrue(transcript.segments.filter { $0.source == "system" }.allSatisfy { $0.speaker_name == nil })
        XCTAssertTrue(transcript.capture_gaps?.isEmpty ?? true)
        XCTAssertEqual(try Data(contentsOf: ClosedChunkRecognition.path(dir, file: "mic.caf")), cache)
        let calls = await engine.calls
        XCTAssertEqual(calls.map(\.lastPathComponent), ["mic-2.caf", "system.caf", "context.caf"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: calls.last!.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("archive-receipt.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.caf").path))
    }
    func testUnanchoredOrFailedContextPreservesOriginalSpeechAndMarksReview() async throws {
        for failing in [true, false] {
            let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
            try finish(dir)
            let engine = BoundaryEngine { _ in
                if failing { throw TranscriptionFailure("Synthetic decoder failure") }
                return [TranscriptSegment(start: 0, end: 12, text: "No word timings")]
            }
            try await worker(dir, engine: engine).transcribe(dir, detectSpeakers: false)
            let transcript = try result(dir)
            XCTAssertTrue(transcript.segments.filter { $0.source == "mic" }.map(\.text).joined(separator: " ").contains("inter national"))
            XCTAssertEqual(transcript.capture_gaps?.last?.reason, "boundary_context_unverified")
            let markdown = try String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)
            XCTAssertTrue(markdown.contains("## Transcription boundary review")); XCTAssertFalse(markdown.contains("## Capture gaps"))
            let lastCall = await engine.calls.last
            let context = try XCTUnwrap(lastCall)
            XCTAssertFalse(FileManager.default.fileExists(atPath: context.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic-2.caf").path))
        }
    }
    func testMultipleUnverifiedSeamsUseOneBoundedReviewRangePerSource() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        var meta = try ArchiveBacklog.object(dir.appendingPathComponent("meta.json"))
        var tracks = meta["capture_segments"] as! [[String: Any]]
        tracks.append(["source": "mic", "file": "mic-3.caf", "offset_ms": 60000, "started_at": 1060, "continuous_clock": true])
        meta["capture_segments"] = tracks
        try JSONSerialization.data(withJSONObject: meta).write(to: dir.appendingPathComponent("meta.json"))
        try audio(dir.appendingPathComponent("mic-3.caf"), seconds: 30, value: 0.4)
        try finish(dir)
        let engine = BoundaryEngine { _ in [] }
        try await worker(dir, engine: engine).transcribe(dir, detectSpeakers: false)
        let warnings = try XCTUnwrap(result(dir).capture_gaps)
        XCTAssertEqual(warnings.count, 1); XCTAssertEqual(warnings[0].start_ms, 29000); XCTAssertEqual(warnings[0].end_ms, 61000)
    }
    func testLegacyRecoveryAndUncertainTracksDoNotJoinAcrossUnprovedContinuity() async throws {
        for uncertain in [false, true] {
            let dir = try fixture(continuous: uncertain, uncertain: uncertain)
            defer { try? FileManager.default.removeItem(at: dir) }
            try finish(dir)
            let engine = BoundaryEngine()
            try await worker(dir, engine: engine).transcribe(dir, detectSpeakers: false)
            let calls = await engine.calls
            XCTAssertFalse(calls.contains { $0.lastPathComponent == "context.caf" })
            if uncertain { XCTAssertEqual(try result(dir).capture_gaps?.last?.reason, "capture_timing_uncertain") }
        }
    }
    func testCloudOverrideNeverReceivesAdditionalContextAudio() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        try finish(dir)
        let engine = BoundaryEngine(name: "elevenlabs")
        try await worker(dir, engine: engine).transcribe(dir, detectSpeakers: false, engineOverride: .elevenLabs)
        let calls = await engine.calls
        XCTAssertEqual(calls.count, 3); XCTAssertFalse(calls.contains { $0.lastPathComponent == "context.caf" })
        XCTAssertEqual(try result(dir).capture_gaps?.last?.reason, "boundary_context_unverified")
    }
    func testCancellationDuringContextCannotPublishAndRemovesOnlyTemporaryClip() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        try finish(dir)
        let engine = BoundaryEngine { _ in try await Task.sleep(for: .seconds(30)); return Self.context }
        let transcriber = worker(dir, engine: engine)
        let work = Task { try await transcriber.transcribe(dir, detectSpeakers: false) }
        for _ in 0..<200 {
            if await engine.calls.contains(where: { $0.lastPathComponent == "context.caf" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let lastCall = await engine.calls.last
        let context = try XCTUnwrap(lastCall)
        XCTAssertEqual(context.lastPathComponent, "context.caf")
        work.cancel()
        do { try await work.value; XCTFail("Cancelled context must not publish") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.caf").path))
    }
    func testAudioChangedDuringContextCannotPublishFinalSpeech() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        try finish(dir)
        let engine = BoundaryEngine { _ in
            try Data("Changed source".utf8).write(to: dir.appendingPathComponent("mic.caf"), options: .atomic)
            return Self.context
        }
        do { try await worker(dir, engine: engine).transcribe(dir, detectSpeakers: false); XCTFail("Changed source") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic-2.caf").path))
    }
}
