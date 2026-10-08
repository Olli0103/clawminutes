import Foundation
import XCTest
@testable import quill

private actor ChunkEngine: TranscriptionEngine {
    nonisolated let name: String
    nonisolated let model: String
    private(set) var calls: [String] = []
    private(set) var prepares = 0
    var fail = false
    var paused = false
    private var gate: CheckedContinuation<Void, Never>?
    init(name: String = "parakeet", model: String = "fixture", fail: Bool = false, paused: Bool = false) {
        self.name = name; self.model = model; self.fail = fail; self.paused = paused
    }
    func prepare() async throws { prepares += 1 }
    func release() async {}
    func resume() { paused = false; gate?.resume(); gate = nil }
    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        calls.append(audio.deletingLastPathComponent().lastPathComponent + "/" + audio.lastPathComponent)
        if paused { await withCheckedContinuation { gate = $0 } }
        if fail { throw TranscriptionFailure("Fixture inference failure") }
        return [.init(start: 0.2, end: 0.8, text: audio.lastPathComponent,
                      words: [.init(start: 0.2, end: 0.8, text: audio.lastPathComponent)])]
    }
}

final class ClosedChunkRecognitionTests: XCTestCase, @unchecked Sendable {
    private func fixture(root: URL? = nil, name: String = "meeting", closed: Bool? = true, backend: String = "parakeet") throws -> URL {
        let parent = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("chunk-test-" + UUID().uuidString)
        let dir = parent.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var mic: [String: Any] = ["source": "mic", "file": "mic.caf", "offset_ms": 100, "started_at": 1000.1,
                                  "ended_at": 1001.1, "frames_written": 48000, "duration_seconds": 1]
        if let closed { mic["closed"] = closed }
        let metadata: [String: Any] = ["started": "2026-10-08T08:00:00Z", "recording_id": name, "status": "recording",
            "audio_started_at": 1000.0, "backend": backend, "files": ["mic": "mic.caf", "system": "system.caf"],
            "local_speaker_name": "Fixture Owner", "capture_segments": [mic,
                ["source": "system", "file": "system.caf", "offset_ms": 200, "started_at": 1000.2,
                 "frames_written": 48000, "duration_seconds": 1]]]
        try JSONSerialization.data(withJSONObject: metadata).write(to: dir.appendingPathComponent("meta.json"))
        for name in ["mic.caf", "system.caf"] { try Data("Synthetic audio bytes: \(name)".utf8).write(to: dir.appendingPathComponent(name)) }
        return dir
    }
    private func finish(_ dir: URL) throws {
        var meta = try ArchiveBacklog.object(dir.appendingPathComponent("meta.json"))
        meta["status"] = "stopped"; meta["ended"] = "2026-10-08T08:01:00Z"
        try JSONSerialization.data(withJSONObject: meta).write(to: dir.appendingPathComponent("meta.json"))
    }
    private func transcriber(_ dir: URL, engine: ChunkEngine, seconds: Double = 1) -> RecordingTranscriber {
        RecordingTranscriber(activityLockPath: dir.deletingLastPathComponent().appendingPathComponent("lifecycle.lock"),
                             audioDuration: { _ in seconds }, makeEngine: { _, _ in engine })
    }
    private func waitForCalls(_ count: Int, engine: ChunkEngine) async throws {
        for _ in 0..<200 {
            if await engine.calls.count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Synthetic engine did not receive expected work")
    }

    func testClosedCheckpointIsLocalAndFinalReusesWordsWithNamesAndOffsets() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let engine = ChunkEngine()
        // Use one engine instance through both passes.
        let recorder = transcriber(dir, engine: engine)
        try await recorder.transcribeClosedChunk(dir, file: "mic.caf")
        let state = try MeetingPipelineState.load(dir)
        XCTAssertEqual(state.stage, .capturing)
        XCTAssertEqual(state.recognitionChunks?["mic.caf"]?.count, 1)
        XCTAssertNotNil(state.recognitionChunks?["mic.caf"]?.checkpointSHA256)
        XCTAssertEqual(state.transcription.count, 0); XCTAssertEqual(state.delivery.count, 0)
        for name in ["transcript.json", "transcript.md", "notes.md", "archive-receipt.json", "audio-retention-receipt.json"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.caf").path))
        // New process/actor, same durable state and cache, without extra STT for mic.
        await recorder.release()
        let finalEngine = ChunkEngine()
        try finish(dir)
        try await transcriber(dir, engine: finalEngine).transcribe(dir, detectSpeakers: false)
        let calls = await finalEngine.calls
        XCTAssertEqual(calls, ["meeting/system.caf"])
        let transcript = try JSONDecoder().decode(Transcript.self, from: ArchiveBacklog.read(dir.appendingPathComponent("transcript.json")))
        XCTAssertEqual(transcript.segments.map(\.start_ms), [300, 400])
        XCTAssertEqual(transcript.segments.first?.speaker_name, "Fixture Owner")
        XCTAssertNil(transcript.segments.last?.speaker_name)
        XCTAssertEqual(transcript.engine, "parakeet"); XCTAssertEqual(transcript.model, "fixture")
        let checkpoint = try JSONDecoder().decode(ClosedChunkRecognition.Checkpoint.self,
            from: ArchiveBacklog.read(ClosedChunkRecognition.path(dir, file: "mic.caf")))
        XCTAssertEqual(checkpoint.segments.first?.words.first?.text, "mic.caf")
    }
    func testEndedButUnacknowledgedAndOpenTracksCannotPrepareOrInfer() async throws {
        for flag in [Bool?.none, .some(false)] {
            let dir = try fixture(closed: flag); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
            let engine = ChunkEngine()
                do { try await transcriber(dir, engine: engine).transcribeClosedChunk(dir, file: "mic.caf"); XCTFail("Not closed") } catch {}
            do { try await transcriber(dir, engine: engine).transcribeClosedChunk(dir, file: "system.caf"); XCTFail("Still open") } catch {}
            let prepares = await engine.prepares; XCTAssertEqual(prepares, 0)
            XCTAssertNil(try MeetingPipelineState.load(dir).recognitionChunks)
        }
    }
    func testCloudSelectionAndSavedReceiptCannotStartIncrementalRecognition() async throws {
        for backend in ["elevenlabs", "parakeet"] {
            let dir = try fixture(backend: backend); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
            if backend == "parakeet" { try Data("Saved receipt".utf8).write(to: dir.appendingPathComponent("archive-receipt.json")) }
            let engine = ChunkEngine()
            do { try await transcriber(dir, engine: engine).transcribeClosedChunk(dir, file: "mic.caf"); XCTFail("Must reject") } catch {}
            let calls = await engine.calls, prepares = await engine.prepares
            XCTAssertTrue(calls.isEmpty); XCTAssertEqual(prepares, 0)
        }
    }
    func testFailedSpeculativeAttemptIsDurableButDoesNotConsumeFinalRetryBudget() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let failure = ChunkEngine(fail: true)
        do { try await transcriber(dir, engine: failure).transcribeClosedChunk(dir, file: "mic.caf"); XCTFail("Fixture fails") } catch {}
        let replacement = ChunkEngine()
        try await transcriber(dir, engine: replacement).transcribeClosedChunk(dir, file: "mic.caf")
        let prepares = await replacement.prepares
        XCTAssertEqual(prepares, 0, "Relaunch must not repeat speculative inference")
        let state = try MeetingPipelineState.load(dir)
        XCTAssertEqual(state.recognitionChunks?["mic.caf"]?.count, 1)
        XCTAssertNil(state.recognitionChunks?["mic.caf"]?.checkpointSHA256)
        XCTAssertEqual(state.transcription.count, 0)
        XCTAssertNil(state.transcription.lastError)
        try finish(dir)
        try await transcriber(dir, engine: replacement).transcribe(dir, detectSpeakers: false)
        let calls = await replacement.calls; XCTAssertEqual(calls.count, 2)
    }
    func testCorruptedCheckpointOrChangedAudioFallsBackToFinalRecognition() async throws {
        for damageAudio in [false, true] {
            let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
            try await transcriber(dir, engine: ChunkEngine()).transcribeClosedChunk(dir, file: "mic.caf")
            let file = damageAudio ? dir.appendingPathComponent("mic.caf") : ClosedChunkRecognition.path(dir, file: "mic.caf")
            try Data("Changed fixture".utf8).write(to: file)
            try finish(dir)
            let engine = ChunkEngine()
            try await transcriber(dir, engine: engine).transcribe(dir, detectSpeakers: false)
            let calls = await engine.calls; XCTAssertEqual(calls.count, 2)
        }
    }
    func testDifferentModelDoesNotReuseEarlierRecognition() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        try await transcriber(dir, engine: ChunkEngine()).transcribeClosedChunk(dir, file: "mic.caf")
        try finish(dir)
        let engine = ChunkEngine(model: "different-model")
        try await transcriber(dir, engine: engine).transcribe(dir, detectSpeakers: false)
        let calls = await engine.calls; XCTAssertEqual(calls.count, 2)
    }
    func testFileMutationWhileInferenceRunsCannotPublishCheckpoint() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let engine = ChunkEngine(paused: true)
        let worker = transcriber(dir, engine: engine)
        let pending = Task { try await worker.transcribeClosedChunk(dir, file: "mic.caf") }
        try await waitForCalls(1, engine: engine)
        try Data("Replaced audio".utf8).write(to: dir.appendingPathComponent("mic.caf"), options: .atomic)
        await engine.resume()
        do { try await pending.value; XCTFail("Changed source") } catch {}
        XCTAssertNil(try MeetingPipelineState.load(dir).recognitionChunks?["mic.caf"]?.checkpointSHA256)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ClosedChunkRecognition.path(dir, file: "mic.caf").path))
    }
    func testCancellationCannotPublishOrDeleteAudio() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let engine = ChunkEngine(paused: true)
        let recorder = transcriber(dir, engine: engine)
        let pending = Task { try await recorder.transcribeClosedChunk(dir, file: "mic.caf") }
        try await waitForCalls(1, engine: engine)
        pending.cancel(); await engine.resume()
        do { try await pending.value; XCTFail("Cancelled") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(try MeetingPipelineState.load(dir).recognitionChunks?["mic.caf"]?.checkpointSHA256)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.caf").path))
    }
    func testLinkedAudioAndOrphanCacheNeverBecomeTrusted() async throws {
        for linkAudio in [true, false] {
            let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
            if linkAudio {
                try FileManager.default.removeItem(at: dir.appendingPathComponent("mic.caf"))
                try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("mic.caf"), withDestinationURL: dir.appendingPathComponent("system.caf"))
            } else {
                try Data("Orphan".utf8).write(to: ClosedChunkRecognition.path(dir, file: "mic.caf"))
            }
            let engine = ChunkEngine()
            do { try await transcriber(dir, engine: engine).transcribeClosedChunk(dir, file: "mic.caf") }
            catch { XCTAssertTrue(linkAudio) }
            let prepares = await engine.prepares; XCTAssertEqual(prepares, 0)
            XCTAssertNil(try MeetingPipelineState.load(dir).recognitionChunks)
        }
    }
    func testInvalidTimingAndOversizedDurationCannotPublishCheckpoint() async throws {
        XCTAssertFalse(ClosedChunkRecognition.valid([.init(start: .nan, end: 1, text: "Bad")], seconds: 1))
        XCTAssertFalse(ClosedChunkRecognition.valid([.init(start: 0, end: 3, text: "Bad")], seconds: 1))
        XCTAssertFalse(ClosedChunkRecognition.valid([.init(start: 0, end: 1, text: "Bad", words: [.init(start: -1, end: 0, text: "Bad")])], seconds: 1))
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let engine = ChunkEngine()
        do { try await transcriber(dir, engine: engine, seconds: 601).transcribeClosedChunk(dir, file: "mic.caf"); XCTFail("Unbounded work") } catch {}
        let prepares = await engine.prepares; XCTAssertEqual(prepares, 0)
    }
    func testCoordinatorUsesOneEngineAndPrioritizesFinishedMeeting() async throws {
        let first = try fixture(name: "first"), root = first.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let second = try fixture(root: root, name: "second"), final = try fixture(root: root, name: "final")
        try finish(final)
        let engine = ChunkEngine(paused: true)
        let coordinator = TranscriptionCoordinator(activityLockPath: root.appendingPathComponent("lease"),
            localModelAvailable: { true }, detectSpeakers: { false }, audioDuration: { _ in 1 },
            saveArchive: { _ in throw URLError(.notConnectedToInternet) }, makeEngine: { _, _ in engine })
        await coordinator.enqueueClosedChunk(first, file: "mic.caf")
        try await waitForCalls(1, engine: engine)
        for _ in 0..<5 { await coordinator.enqueueClosedChunk(first, file: "mic.caf") }
        await coordinator.enqueueClosedChunk(second, file: "mic.caf")
        let done = expectation(description: "Queue drained")
        done.assertForOverFulfill = false
        await coordinator.setStatusHandler { if case .archivePending = $0 { done.fulfill() } }
        await coordinator.enqueue(final, transcriptionEnabled: true)
        await engine.resume()
        await fulfillment(of: [done], timeout: 10)
        try await waitForCalls(4, engine: engine)
        let calls = await engine.calls
        XCTAssertEqual(calls, ["first/mic.caf", "final/mic.caf", "final/system.caf", "second/mic.caf"])
        XCTAssertEqual(try MeetingPipelineState.load(first).transcription.count, 0)
    }
    func testQueueBackpressureKeepsAllFinalAudioAndSkipsOnlySpeculativeWork() async throws {
        let first = try fixture(name: "first"), root = first.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = ChunkEngine(paused: true)
        let coordinator = TranscriptionCoordinator(activityLockPath: root.appendingPathComponent("lease"),
            localModelAvailable: { true }, detectSpeakers: { false }, audioDuration: { _ in 1 },
            saveArchive: { _ in throw URLError(.notConnectedToInternet) }, makeEngine: { _, _ in engine })
        await coordinator.enqueueClosedChunk(first, file: "mic.caf")
        try await waitForCalls(1, engine: engine)
        var pending: [URL] = []
        for number in 1...17 {
            let dir = try fixture(root: root, name: "waiting-\(number)")
            pending.append(dir)
            await coordinator.enqueueClosedChunk(dir, file: "mic.caf")
        }
        let dropped = try XCTUnwrap(pending.last)
        try finish(dropped)
        let done = expectation(description: "Bounded queue drained")
        done.assertForOverFulfill = false
        await coordinator.setStatusHandler { if case .archivePending = $0 { done.fulfill() } }
        await coordinator.enqueue(dropped, transcriptionEnabled: true)
        await engine.resume()
        await fulfillment(of: [done], timeout: 10)
        let calls = await engine.calls
        XCTAssertEqual(calls.count, 19)
        XCTAssertEqual(Array(calls.prefix(3)), ["first/mic.caf", "waiting-17/mic.caf", "waiting-17/system.caf"])
        XCTAssertNil(try MeetingPipelineState.load(dropped).recognitionChunks)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dropped.appendingPathComponent("transcript.json").path))
        for directory in pending {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("mic.caf").path))
        }
    }
    func testCaptureClosureAcknowledgementIsSeparateFromRecoveryRequest() {
        var capture = CaptureRecovery(origin: 1000)
        capture.begin(source: "mic", file: "mic.caf", at: Date(timeIntervalSince1970: 1000))
        let progress = CaptureProgress.Snapshot(firstWrite: Date(timeIntervalSince1970: 1000),
            lastWrite: Date(timeIntervalSince1970: 1001), frames: 48000, duration: 1, failure: "write_failed")
        XCTAssertEqual(capture.rotate(source: "mic", progress: progress, at: Date(timeIntervalSince1970: 1002)), "mic-2.caf")
        XCTAssertNil(capture.segments.first?.closed)
        XCTAssertEqual(capture.sealClosedSegments(source: "mic"), ["mic.caf"])
        XCTAssertEqual(capture.segments.first?.closed, true)
        XCTAssertTrue(capture.sealClosedSegments(source: "mic").isEmpty)
        capture.begin(source: "mic", file: "mic-2.caf", at: Date(timeIntervalSince1970: 1002))
        XCTAssertTrue(capture.sealClosedSegments(source: "mic").isEmpty)
        XCTAssertNil(capture.segments.last?.closed)
    }

    func testFinalRecognitionRejectsAudioChangedDuringInference() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        try finish(dir)
        let engine = ChunkEngine(paused: true)
        let recorder = transcriber(dir, engine: engine)
        let pending = Task { try await recorder.transcribe(dir, detectSpeakers: false) }
        try await waitForCalls(1, engine: engine)
        try Data("Changed final source".utf8).write(to: dir.appendingPathComponent("mic.caf"), options: .atomic)
        await engine.resume()
        do { try await pending.value; XCTFail("Changed final source must stay pending") }
        catch { XCTAssertEqual((error as? DeliveryFailure)?.code, "pipeline_state_conflict") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.md").path))
    }

    func testChunkOnlyDrainCannotRetryNearbyGatewayBacklog() async throws {
        let active = try fixture(name: "active"), root = active.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let pending = try fixture(root: root, name: "pending")
        try finish(pending)
        try Transcript(engine: "parakeet", model: "fixture", created_at: "2026-10-08T08:00:00Z",
            segments: [.init(speaker: "me", start_ms: 100, end_ms: 200, text: "Fixture")]).write(to: pending)
        let engine = ChunkEngine()
        let delivered = expectation(description: "Background chunks must not deliver text")
        delivered.isInverted = true
        let done = expectation(description: "Background recognition drained")
        let coordinator = TranscriptionCoordinator(activityLockPath: root.appendingPathComponent("lease"),
            localModelAvailable: { true }, detectSpeakers: { false }, audioDuration: { _ in 1 },
            saveArchive: { _ in delivered.fulfill() }, makeEngine: { _, _ in engine })
        await coordinator.setStatusHandler { if case .idle = $0 { done.fulfill() } }
        await coordinator.enqueueClosedChunk(active, file: "mic.caf")
        await fulfillment(of: [done], timeout: 5)
        await fulfillment(of: [delivered], timeout: 0.1)
        XCTAssertEqual(try MeetingPipelineState.load(active).delivery.count, 0)
        XCTAssertEqual(try MeetingPipelineState.load(pending).delivery.count, 0)
    }

}
