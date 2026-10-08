import XCTest
import Darwin
@testable import quill

final class HelperLockDiagnosticsTests: XCTestCase, @unchecked Sendable {
    private var worker: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/debug/ocmh")
    }
    private func fixtureRoot() throws -> URL {
        let resolved = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(resolved) }
        let root = URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
    private func script(_ root: URL, _ body: String) throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString + ".sh")
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    func testActualReportObservesHeldLocksWithoutInventingOwnersOrChangingThem() async throws {
        let resolved = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(resolved) }
        let root = URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent(UUID().uuidString)
        let recordings = root.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: settings)
        let instancePath = root.appendingPathComponent("run.lock")
        let instance = try XCTUnwrap(AppRunLock.acquire(at: instancePath))
        let lease = try HelperWorkLease.acquire(at: root.appendingPathComponent("lifecycle.lock"))
        let meeting = recordings.appendingPathComponent("PRIVATE-MEETING")
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: false)
        try Data(#"{"started":"2026-10-08T10:00:00Z","ended":"2026-10-08T11:00:00Z","status":"stopped","recording_id":"PRIVATE-ID"}"#.utf8)
            .write(to: meeting.appendingPathComponent("meta.json"))
        let archive = try XCTUnwrap(AppRunLock.acquire(at: meeting.appendingPathComponent("archive.lock")))
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        let report = try await HelperDiagnostics.observedReport(root: recordings, settings: settings,
            permissions: .init(accessibility: false, microphone: false, systemAudio: false),
            localModelAvailable: false, instanceLock: instancePath, workerExecutable: worker)
        let data = try HelperDiagnostics.data(report)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let observations = try XCTUnwrap(object["lockObservations"] as? [[String: Any]])
        func row(_ role: String) throws -> [String: Any] {
            try XCTUnwrap(observations.first { $0["role"] as? String == role })
        }
        XCTAssertEqual(try row("instance")["state"] as? String, "exclusive")
        XCTAssertEqual(try row("lifecycle")["state"] as? String, "shared")
        XCTAssertEqual(try row("capture")["state"] as? String, "absent")
        XCTAssertEqual(try row("archive")["state"] as? String, "exclusive")
        XCTAssertEqual(try row("archive")["recordingRef"] as? String, report.meetings.first?.recordingRef)
        XCTAssertNil(try row("instance")["ownerPID"])
        XCTAssertNil(try row("lifecycle")["ownerPID"])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(root.path))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("PRIVATE"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), before)
        XCTAssertNil(try AppRunLock.acquire(at: instancePath))
        let exclusive = open(root.appendingPathComponent("lifecycle.lock").path, O_RDONLY | O_CLOEXEC)
        defer { close(exclusive) }
        XCTAssertEqual(flock(exclusive, LOCK_EX | LOCK_NB), -1)
        XCTAssertEqual(errno, EWOULDBLOCK)
        withExtendedLifetime((instance, lease, archive)) {}
    }

    func testChildObservationPreservesParentsPOSIXRecordLockAndReportsKernelPID() async throws {
        let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("record.lock")
        let fd = open(path.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0); defer { close(fd) }
        var lock = Darwin.flock(l_start: 0, l_len: 0, l_pid: 0, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
        XCTAssertEqual(withUnsafeMutablePointer(to: &lock, { fcntl(fd, F_SETLK, $0) }), 0)
        let request = HelperLockDiagnostics.Request(role: .instance, path: path.path)
        for _ in 0..<2 {
            let observed = await HelperLockDiagnostics.capture([request], executable: worker)
            XCTAssertEqual(observed.first?.state, .exclusive)
            XCTAssertEqual(observed.first?.ownerPID, getpid())
        }
        // The second independent child would observe no lock if the first
        // query had closed a matching descriptor in this parent process.
    }

    func testExistingUnlockedArchiveKeepsItsReferenceAndMissingFilesStayAbsent() async throws {
        let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("archive.lock")
        let original = Data("PRIVATE-LOCK-CONTENT".utf8); try original.write(to: path)
        let before = try FileManager.default.attributesOfItem(atPath: path.path)
        let reference = String(repeating: "a", count: 24)
        let result = await HelperLockDiagnostics.capture([
            .init(role: .archive, path: path.path, recordingRef: reference),
            .init(role: .capture, path: root.appendingPathComponent("missing.lock").path)
        ], executable: worker)
        XCTAssertEqual(result.map(\.state), [.noBlockingLock, .absent])
        XCTAssertEqual(result.first?.recordingRef, reference)
        XCTAssertNil(result.first?.ownerPID)
        XCTAssertEqual(try Data(contentsOf: path), original)
        let after = try FileManager.default.attributesOfItem(atPath: path.path)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("missing.lock").path))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("PRIVATE"))
    }

    func testLinkedAncestorsLeavesSpecialFilesAndHardLinksAreNotInspected() async throws {
        let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target"); try Data("PRIVATE".utf8).write(to: target)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let linkedParent = root.appendingPathComponent("parent")
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: root)
        let fifo = root.appendingPathComponent("fifo"); XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let hard = root.appendingPathComponent("hard"); try FileManager.default.linkItem(at: target, to: hard)
        let paths = [link, linkedParent.appendingPathComponent("target"), fifo, hard, root]
        let requests = paths.enumerated().map { index, path in
            HelperLockDiagnostics.Request(role: .archive, path: path.path, recordingRef: String(format: "%024x", index))
        }
        let result = await HelperLockDiagnostics.capture(requests, executable: worker)
        XCTAssertEqual(result.map(\.state), Array(repeating: .unsafe, count: paths.count))
        XCTAssertEqual(try Data(contentsOf: target), Data("PRIVATE".utf8))
    }

    func testWorkerInputRejectsUnboundedDuplicateAndUnrecognizedRequests() async throws {
        let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let valid: [String: Any] = ["schemaVersion": 1, "requests": [["role": "capture", "path": "/missing.lock"]]]
        let bad: [[String: Any]] = [
            ["schemaVersion": 2, "requests": []],
            ["schemaVersion": 1, "requests": [], "private": "PRIVATE"],
            ["schemaVersion": 1, "requests": [["role": "capture", "path": "/missing.lock", "token": "PRIVATE"]]],
            ["schemaVersion": 1, "requests": Array(repeating: ["role": "capture", "path": "/missing.lock"], count: 2)],
            ["schemaVersion": 1, "requests": [["role": "archive", "path": "/missing.lock", "recordingRef": "PRIVATE"]]],
            ["schemaVersion": 1, "requests": [["role": "capture", "path": "relative"]]],
            ["schemaVersion": 1, "requests": [["role": "capture", "path": "/bad\0path"]]]
        ]
        var inputs = try bad.map { try JSONSerialization.data(withJSONObject: $0) }
        var oversized = try JSONSerialization.data(withJSONObject: valid)
        oversized.append(Data(repeating: 32, count: HelperLockDiagnostics.maximumInput))
        inputs.append(oversized)
        for input in inputs {
            let result = try await HarnessProcess.run(executable: worker, arguments: ["lock-snapshot-internal"],
                input: input, directory: root, timeout: 2, childEnvironment: ["PATH": "/usr/bin:/bin", "HOME": root.path],
                maximumOutputBytes: 32_768, maximumErrorBytes: 8192)
            XCTAssertNotEqual(result.status, 0)
            XCTAssertTrue(result.output.isEmpty)
        }
    }

    func testWorkerEnvironmentIsPrivateAndUntrustedRepliesCannotLeakFieldsOrOwners() async throws {
        let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let request = HelperLockDiagnostics.Request(role: .instance, path: root.appendingPathComponent("none").path)
        let good = #"{"schemaVersion":1,"observations":[{"role":"instance","state":"noBlockingLock","observedAt":1}]}"#
        let environmentProbe = try script(root, """
        [ "$HOME" = "$PWD" ] || exit 11
        [ "$TMPDIR" = "$PWD" ] || exit 12
        [ "$OPENCLAW_TEAMS_HOME" = "$PWD/empty" ] || exit 13
        [ "$PATH" = "/usr/bin:/bin" ] || exit 14
        [ -z "${HTTPS_PROXY+x}${HTTP_PROXY+x}${NODE_OPTIONS+x}${CODEX_HOME+x}${ANTHROPIC_API_KEY+x}${OPENAI_API_KEY+x}" ] || exit 15
        printf '%s' '\(good)'
        """)
        let result = await HelperLockDiagnostics.capture([request], executable: environmentProbe)
        XCTAssertEqual(result.first?.state, .noBlockingLock)
        let replies = [
            good.replacingOccurrences(of: "\"observedAt\":1", with: "\"observedAt\":1,\"path\":\"PRIVATE\""),
            good.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2"),
            good.replacingOccurrences(of: "\"role\":\"instance\"", with: "\"role\":\"capture\""),
            good.replacingOccurrences(of: "\"observedAt\":1", with: "\"observedAt\":1,\"ownerPID\":123")
        ]
        for reply in replies {
            let executable = try script(root, "printf '%s' '\(reply)'")
            let values = await HelperLockDiagnostics.capture([request], executable: executable)
            XCTAssertEqual(values.first?.state, .unavailable)
            XCTAssertNil(values.first?.ownerPID)
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(values), as: UTF8.self).contains("PRIVATE"))
        }
    }

    func testUnavailableAndTimedOutWorkersCannotBlockDiagnostics() async throws {
        let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let request = HelperLockDiagnostics.Request(role: .capture, path: root.appendingPathComponent("none").path)
        let missing = await HelperLockDiagnostics.capture([request], executable: nil)
        XCTAssertEqual(missing.first?.state, .unavailable)
        let sleeper = try script(root, "exec /bin/sleep 30")
        let started = ProcessInfo.processInfo.systemUptime
        let timeout = await HelperLockDiagnostics.capture([request], executable: sleeper, timeout: 0.1)
        XCTAssertEqual(timeout.first?.state, .unavailable)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [sleeper.lastPathComponent])
    }

    func testFastChildExitCannotBypassOutputOrErrorLimits() async throws {
        let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        for redirect in ["", " >&2"] {
            do {
                _ = try await HarnessProcess.run(executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "/usr/bin/head -c 2048 /dev/zero" + redirect], directory: root, timeout: 2,
                    childEnvironment: ["PATH": "/usr/bin:/bin"], maximumOutputBytes: 1024, maximumErrorBytes: 1024)
                XCTFail("The child exceeded its output budget")
            } catch HarnessProcess.Failure.outputTooLarge {}
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testCopiedMeetingIdentityDoesNotHideOtherLockObservations() async throws {
        let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let recordings = root.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: false)
        for name in ["original", "corrected-copy"] {
            let directory = recordings.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try Data(#"{"started":"2026-10-08T10:00:00Z","ended":"2026-10-08T11:00:00Z","status":"stopped","recording_id":"same-id"}"#.utf8)
                .write(to: directory.appendingPathComponent("meta.json"))
            try Data().write(to: directory.appendingPathComponent("archive.lock"))
        }
        let held = try XCTUnwrap(AppRunLock.acquire(at: recordings.appendingPathComponent("original/archive.lock")))
        let report = try await HelperDiagnostics.observedReport(root: recordings, settings: root.appendingPathComponent("config.json"),
            permissions: .init(accessibility: false, microphone: false, systemAudio: false), localModelAvailable: false,
            instanceLock: nil, workerExecutable: worker)
        XCTAssertEqual(report.meetings.count, 2)
        XCTAssertEqual(report.meetings[0].recordingRef, report.meetings[1].recordingRef)
        let samples = report.lockObservations.filter { $0.role == .archive }
        XCTAssertEqual(Set(samples.map(\.state)), [.exclusive, .noBlockingLock])
        XCTAssertEqual(report.lockObservations.first { $0.role == .capture }?.state, .absent)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: HelperDiagnostics.data(report)) as? [String: Any])
        let rows = try XCTUnwrap(json["lockObservations"] as? [[String: Any]])
        XCTAssertEqual(Set(rows.compactMap { $0["meetingIndex"] as? Int }), [0, 1])
        withExtendedLifetime(held) {}
    }
}
