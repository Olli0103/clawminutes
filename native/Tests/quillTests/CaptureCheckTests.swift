import AVFoundation
import Foundation
import XCTest
@testable import quill

@MainActor final class CheckDevice: CaptureCheckDevice {
    var starts = 0, stops = 0
    let action: (URL) throws -> Void
    init(action: @escaping (URL) throws -> Void) { self.action = action }
    func start(in directory: URL) async throws { starts += 1; try action(directory) }
    func stop() async { stops += 1 }
}

final class CaptureCheckTests: XCTestCase {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private static func pcm(_ file: URL, seconds: Double = 10, level: Float = 0.2) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * 8000)))
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][index] = level }
        let audio = try AVAudioFile(forWriting: file, settings: format.settings)
        try audio.write(from: buffer)
    }
    @MainActor func testOpeningAndMissingPermissionsNeverCreateOrStartCapture() async throws {
        let root = try folder(), checks = root.appendingPathComponent("checks")
        var factories = 0
        let runner = CaptureCheckRunner(root: checks, activityLockPath: root.appendingPathComponent("lease"), permissions: { false },
            makeDevice: { factories += 1; return CheckDevice { _ in XCTFail("No capture without permissions") } }, wait: {})
        XCTAssertEqual(factories, 0); XCTAssertFalse(FileManager.default.fileExists(atPath: checks.path))
        do { _ = try await runner.run(); XCTFail("Missing permissions must block capture") } catch {}
        XCTAssertEqual(factories, 0); XCTAssertFalse(FileManager.default.fileExists(atPath: checks.path))
    }
    @MainActor func testTenSecondCheckInspectsBothTracksStopsThenDiscardsOnlyTestAudio() async throws {
        let root = try folder(), checks = root.appendingPathComponent("checks")
        let recordings = root.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: false)
        try Data("Existing user audio".utf8).write(to: recordings.appendingPathComponent("mic.caf"))
        var waited = 0, phases: [CaptureCheckRunner.Phase] = []
        let device = CheckDevice { directory in
            try Self.pcm(directory.appendingPathComponent("mic.caf")); try Self.pcm(directory.appendingPathComponent("system.caf"))
        }
        let runner = CaptureCheckRunner(root: checks, activityLockPath: root.appendingPathComponent("lease"), permissions: { true },
            makeDevice: { device }, wait: { await MainActor.run { waited += 1 } })
        let report = try await runner.run { phases.append($0) }
        XCTAssertTrue(report.passed); XCTAssertTrue(report.audioRemoved)
        XCTAssertEqual(waited, 10); XCTAssertEqual(device.starts, 1); XCTAssertEqual(device.stops, 1)
        XCTAssertEqual(phases.first, .starting); XCTAssertEqual(phases.last, .stopping)
        XCTAssertEqual(phases.filter { if case .recording = $0 { return true }; return false }.count, 10)
        XCTAssertEqual(report.tracks.map(\.state), [.sound, .sound])
        XCTAssertFalse(FileManager.default.fileExists(atPath: report.directory.path))
        XCTAssertEqual(try String(contentsOf: recordings.appendingPathComponent("mic.caf"), encoding: .utf8), "Existing user audio")
        XCTAssertEqual(try ArchiveBacklog.scan(root: checks).count, 0)
    }
    @MainActor func testSilenceShortAndMissingTrackCannotPass() async throws {
        let root = try folder()
        for kind in ["silent", "short", "missing"] {
            let device = CheckDevice { directory in
                try Self.pcm(directory.appendingPathComponent("mic.caf"))
                if kind != "missing" { try Self.pcm(directory.appendingPathComponent("system.caf"), seconds: kind == "short" ? 2 : 10, level: 0) }
            }
            let runner = CaptureCheckRunner(root: root.appendingPathComponent("checks"), activityLockPath: root.appendingPathComponent("lease"),
                permissions: { true }, makeDevice: { device }, wait: {})
            let report = try await runner.run()
            XCTAssertFalse(report.passed); XCTAssertTrue(report.audioRemoved)
            XCTAssertEqual(report.tracks.first?.state, .sound)
            XCTAssertEqual(report.tracks.last?.state, kind == "silent" ? .silent : kind == "short" ? .incomplete : .unavailable)
        }
    }
    @MainActor func testStartFailureAndCancellationStillStopAndDiscard() async throws {
        let root = try folder()
        for failing in [true, false] {
            let device = CheckDevice { directory in
                try Self.pcm(directory.appendingPathComponent("system.caf"))
                if failing { throw TranscriptionFailure("Synthetic partial startup") }
            }
            let runner = CaptureCheckRunner(root: root.appendingPathComponent("checks"), activityLockPath: root.appendingPathComponent("lease"),
                permissions: { true }, makeDevice: { device }, wait: { throw CancellationError() })
            let report = try await runner.run()
            XCTAssertFalse(report.passed); XCTAssertTrue(report.audioRemoved)
            XCTAssertEqual(report.startFailed, failing); XCTAssertEqual(report.cancelled, !failing)
            XCTAssertEqual(device.stops, 1)
        }
    }
    @MainActor func testMeetingAndInstallerOwnershipBlockCheckBeforeDeviceConstruction() async throws {
        let root = try folder(), path = root.appendingPathComponent("lease"), checks = root.appendingPathComponent("checks")
        let session = try RecordingSession(root: root.appendingPathComponent("recordings"), activityLockPath: path)
        let runner = CaptureCheckRunner(root: checks, activityLockPath: path, permissions: { true },
            makeDevice: { XCTFail("Active meeting must block check before opening devices"); return CheckDevice { _ in } }, wait: {})
        do { _ = try await runner.run(); XCTFail("Active meeting must retain ownership") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: checks.path))
        withExtendedLifetime(session) {}
    }
    @MainActor func testCheckBlocksMeetingAndInstallerAndReleasesAfterStop() async throws {
        let root = try folder(), path = root.appendingPathComponent("lease")
        let device = CheckDevice { directory in
            XCTAssertThrowsError(try RecordingSession(root: root.appendingPathComponent("recordings"), activityLockPath: path))
            XCTAssertNil(try AppRunLock.acquire(at: path))
            try Self.pcm(directory.appendingPathComponent("mic.caf")); try Self.pcm(directory.appendingPathComponent("system.caf"))
        }
        let runner = CaptureCheckRunner(root: root.appendingPathComponent("checks"), activityLockPath: path,
            permissions: { true }, makeDevice: { device }, wait: {})
        _ = try await runner.run()
        XCTAssertNotNil(try CaptureOwnership.acquire(activityLockPath: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("recordings").path))
    }
    @MainActor func testUnexpectedFilesAndLinkedAudioAreNotDeleted() async throws {
        let root = try folder(), outside = root.appendingPathComponent("outside.caf")
        try Data("Preserve outside".utf8).write(to: outside)
        for linked in [false, true] {
            let device = CheckDevice { directory in
                if linked { try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("mic.caf"), withDestinationURL: outside) }
                else { try Data("Unknown file".utf8).write(to: directory.appendingPathComponent("other.txt")) }
            }
            let runner = CaptureCheckRunner(root: root.appendingPathComponent("checks"), activityLockPath: root.appendingPathComponent("lease"),
                permissions: { true }, makeDevice: { device }, wait: {})
            let report = try await runner.run()
            XCTAssertFalse(report.audioRemoved); XCTAssertFalse(report.passed)
            XCTAssertTrue(FileManager.default.fileExists(atPath: report.directory.path))
            XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "Preserve outside")
        }
    }
    func testPCMProbeRejectsOversizedUnreadableAndLinkedInputs() throws {
        let root = try folder(), file = root.appendingPathComponent("audio.caf")
        try Self.pcm(file, seconds: 21)
        XCTAssertEqual(CaptureCheckTrack.inspect(file, source: "mic").state, .unavailable)
        try Data("Not PCM".utf8).write(to: file)
        XCTAssertEqual(CaptureCheckTrack.inspect(file, source: "mic").state, .unavailable)
        let link = root.appendingPathComponent("link.caf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertEqual(CaptureCheckTrack.inspect(link, source: "mic").state, .unavailable)
    }
    @MainActor func testTaskCancellationStopsDeviceAndRemovesPartialAudio() async throws {
        let root = try folder(), started = expectation(description: "Fake device started")
        let device = CheckDevice { directory in
            try Self.pcm(directory.appendingPathComponent("system.caf")); started.fulfill()
        }
        let runner = CaptureCheckRunner(root: root.appendingPathComponent("checks"), activityLockPath: root.appendingPathComponent("lease"),
            permissions: { true }, makeDevice: { device }, wait: { try await Task.sleep(for: .seconds(10)) })
        let task = Task { try await runner.run() }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        let result = try await task.value
        XCTAssertTrue(result.cancelled); XCTAssertTrue(result.audioRemoved); XCTAssertFalse(result.passed)
        XCTAssertEqual(device.stops, 1)
    }
    @MainActor func testReplacedCheckDirectoryCannotAuthorizeDeletion() async throws {
        let root = try folder()
        let device = CheckDevice { directory in
            try Self.pcm(directory.appendingPathComponent("mic.caf"))
            try FileManager.default.moveItem(at: directory, to: directory.appendingPathExtension("moved"))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try Self.pcm(directory.appendingPathComponent("mic.caf"))
        }
        let runner = CaptureCheckRunner(root: root.appendingPathComponent("checks"), activityLockPath: root.appendingPathComponent("lease"),
            permissions: { true }, makeDevice: { device }, wait: {})
        let report = try await runner.run()
        XCTAssertFalse(report.audioRemoved); XCTAssertFalse(report.passed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.directory.appendingPathComponent("mic.caf").path))
    }

}
