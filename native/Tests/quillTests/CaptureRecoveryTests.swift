import XCTest
@testable import quill

final class CaptureRecoveryTests: XCTestCase {
    private func time(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }
    func testWrittenSilentFramesStayHealthyButStoppedCallbacksRotateWithoutOverwriting() {
        let progress = CaptureProgress()
        progress.wrote(frames: 480000, sampleRate: 48000, at: time(1000))
        progress.wrote(frames: 480000, sampleRate: 48000, at: time(1010))
        var capture = CaptureRecovery(origin: 1000)
        capture.begin(source: "mic", file: "mic.caf", at: time(1000))
        capture.begin(source: "system", file: "system.caf", at: time(1000))
        XCTAssertNil(capture.problem(source: "mic", progress: progress.snapshot, at: time(1015)))
        XCTAssertEqual(capture.rotate(source: "mic", progress: progress.snapshot, at: time(1021)), "mic-2.caf")
        capture.begin(source: "mic", file: "mic-2.caf", at: time(1021))
        progress.reset()
        progress.wrote(frames: 48000, sampleRate: 48000, at: time(1022))
        capture.observe(source: "mic", progress: progress.snapshot)
        XCTAssertEqual(capture.segments.map(\.file), ["mic.caf", "system.caf", "mic-2.caf"])
        XCTAssertEqual(capture.segments[0].duration_seconds, 20)
        XCTAssertEqual(capture.segments[2].offset_ms, 22000)
        XCTAssertEqual(capture.gaps.first?.start_ms, 20000)
        XCTAssertEqual(capture.gaps.first?.end_ms, 22000)
        XCTAssertNil(capture.segments[1].ended_at, "The system stream must stay open when the microphone rotates")
    }
    func testWriteFailureAndFrameShortfallAreSeparateFromCallbackSilence() {
        let progress = CaptureProgress()
        var capture = CaptureRecovery(origin: 1000)
        capture.begin(source: "system", file: "system.caf", at: time(1000))
        progress.wrote(frames: 48000, sampleRate: 48000, at: time(1000))
        progress.wrote(frames: 48000, sampleRate: 48000, at: time(1015))
        XCTAssertEqual(capture.problem(source: "system", progress: progress.snapshot, at: time(1016)), "frame_coverage_shortfall")
        progress.failed("write_failed")
        XCTAssertEqual(capture.problem(source: "system", progress: progress.snapshot, at: time(1016)), "capture_failed")
        XCTAssertEqual(progress.snapshot.frames, 96000, "A failed write is not captured audio")
    }
    func testRecoveryHasBackoffAndAFiniteAttemptLimit() {
        var capture = CaptureRecovery(origin: 1000)
        let failed = CaptureProgress.Snapshot(failure: "stream_stopped")
        capture.begin(source: "system", file: "system.caf", at: time(1000))
        for number in 1...3 {
            let now = time(1000 + Double(number * 15))
            XCTAssertEqual(capture.rotate(source: "system", progress: failed, at: now), "system-\(number + 1).caf")
            capture.begin(source: "system", file: "system-\(number + 1).caf", at: now)
            XCTAssertNil(capture.rotate(source: "system", progress: failed, at: now.addingTimeInterval(1)))
        }
        XCTAssertNil(capture.rotate(source: "system", progress: failed, at: time(1100)))
        capture.finish(source: "system", progress: failed, at: time(1100))
        XCTAssertEqual(capture.gaps.count, 1)
        XCTAssertEqual(capture.gaps[0].end_ms, 100000)
    }
    func testHealthRequiresRecentSuccessfulWritesAndDoesNotTreatSilenceAsFailure() {
        let progress = CaptureProgress()
        XCTAssertFalse(progress.snapshot.recentlyWriting(at: time(1000)))
        progress.wrote(frames: 48000, sampleRate: 48000, at: time(1000))
        XCTAssertTrue(progress.snapshot.recentlyWriting(at: time(1001)))
        XCTAssertFalse(progress.snapshot.recentlyWriting(at: time(1004)))
        progress.failed("write_failed")
        XCTAssertFalse(progress.snapshot.recentlyWriting(at: time(1001)))
    }
    func testRetiredEngineEventsCannotMarkTheNewSegmentAsChanged() {
        let progress = CaptureProgress()
        let retired = progress.currentEpoch
        progress.reset()
        progress.deviceChanged(epoch: retired)
        XCTAssertFalse(progress.snapshot.configurationChanged)
        progress.deviceChanged(epoch: progress.currentEpoch)
        XCTAssertTrue(progress.snapshot.configurationChanged)
    }
    func testDeviceChangeRotatesBeforeStallAndBudgetRenewsWithoutReusingFiles() {
        let progress = CaptureProgress()
        var capture = CaptureRecovery(origin: 1000)
        capture.begin(source: "mic", file: "mic.caf", at: time(1000))
        progress.wrote(frames: 48000, sampleRate: 48000, at: time(1000))
        progress.deviceChanged()
        XCTAssertEqual(capture.problem(source: "mic", progress: progress.snapshot, at: time(1001)), "device_changed")
        for index in 1...3 {
            let now = time(1001 + Double((index - 1) * 20))
            let filename = capture.rotate(source: "mic", progress: progress.snapshot, at: now)
            XCTAssertEqual(filename, "mic-\(index + 1).caf")
            capture.begin(source: "mic", file: filename!, at: now)
        }
        XCTAssertTrue(capture.recoveryLimited(source: "mic", at: time(1100)))
        XCTAssertNil(capture.rotate(source: "mic", progress: progress.snapshot, at: time(1100)))
        XCTAssertFalse(capture.recoveryLimited(source: "mic", at: time(1700)))
        XCTAssertEqual(capture.rotate(source: "mic", progress: progress.snapshot, at: time(1700)), "mic-5.caf")
        XCTAssertEqual(Set(capture.segments.map(\.file)).count, capture.segments.count)
        XCTAssertEqual(capture.gaps.first?.reason, "device_changed")
    }
    func testIndependentDiarizationNumbersCannotMergePeopleAcrossSegments() {
        var first = SpeakerAnalysis(turns: [SpeakerTurn(speaker_id: "system_1", start: 0, end: 1)], names: [:])
        var second = first
        first.scopeClusters(to: "system")
        second.scopeClusters(to: "system-2")
        XCTAssertNotEqual(first.turns[0].speaker_id, second.turns[0].speaker_id)
    }
}
