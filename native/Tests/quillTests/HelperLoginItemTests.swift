import Foundation
import XCTest
@testable import quill

final class HelperLoginItemTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let agent: URL
        var parked: URL { root.appendingPathComponent(HelperLoginItem.disabledName) }
        var item: HelperLoginItem { HelperLoginItem(root: root, agent: agent) }
        var plist: [String: Any] {
            ["Label": HelperLoginItem.label, "ProgramArguments": [root.appendingPathComponent("ocmh.app/Contents/MacOS/ocmh").path, "run", "--out", root.appendingPathComponent("recordings").path],
             "EnvironmentVariables": ["OPENCLAW_TEAMS_HOME": root.path], "RunAtLoad": true,
             "KeepAlive": ["SuccessfulExit": false], "ThrottleInterval": 10,
             "StandardOutPath": root.appendingPathComponent("stdout.log").path,
             "StandardErrorPath": root.appendingPathComponent("stderr.log").path]
        }
        func write(_ plist: [String: Any]? = nil) throws {
            try PropertyListSerialization.data(fromPropertyList: plist ?? self.plist, format: .xml, options: 0).write(to: agent)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: agent.path)
        }
    }
    private func fixture() throws -> Fixture {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("clawminutes-login-" + UUID().uuidString)
        let root = base.appendingPathComponent("state"), agents = base.appendingPathComponent("home/Library/LaunchAgents")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: base) }
        return Fixture(root: root, agent: agents.appendingPathComponent(HelperLoginItem.label + ".plist"))
    }

    func testPreferenceMovesExactOwnedAgentAndPreservesCrashSupervision() throws {
        let f = try fixture(); try f.write()
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: f.agent.path)
        let before = try Data(contentsOf: f.agent)
        let inode = try FileManager.default.attributesOfItem(atPath: f.agent.path)[.systemFileNumber] as? NSNumber
        let status = f.item.status()
        XCTAssertEqual(status.enabled, true)
        let off = try f.item.setEnabled(false, expected: status)
        XCTAssertEqual(off.enabled, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.agent.path))
        XCTAssertEqual(try Data(contentsOf: f.parked), before)
        let attributes = try FileManager.default.attributesOfItem(atPath: f.parked.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, 0o640)
        XCTAssertEqual(attributes[.systemFileNumber] as? NSNumber, inode)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: f.parked), format: nil) as? [String: Any])
        XCTAssertEqual(plist["KeepAlive"] as? [String: Bool], ["SuccessfulExit": false])
        XCTAssertEqual(try f.item.setEnabled(true, expected: off).enabled, true)
        XCTAssertEqual(try Data(contentsOf: f.agent), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.parked.path))
    }

    func testChangingFutureLoginDoesNotTouchActiveRecordingOrConfiguration() throws {
        let f = try fixture(); try f.write()
        let config = f.root.appendingPathComponent("config.json")
        try Data("{fixture-config".utf8).write(to: config)
        let session = try RecordingSession(root: f.root.appendingPathComponent("recordings"), activityLockPath: f.root.appendingPathComponent("lifecycle.lock"))
        let metadata = session.dir.appendingPathComponent("meta.json")
        let before = try Data(contentsOf: metadata)
        XCTAssertEqual(try f.item.setEnabled(false, expected: f.item.status()).enabled, false)
        XCTAssertEqual(try Data(contentsOf: metadata), before)
        XCTAssertEqual(try Data(contentsOf: config), Data("{fixture-config".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.dir.appendingPathComponent("mic.caf").path))
        withExtendedLifetime(session) {}
    }

    func testStaleAndReplacedAgentSnapshotsCannotMoveCurrentFile() throws {
        let f = try fixture(); try f.write()
        let old = f.item.status(), bytes = try Data(contentsOf: f.agent)
        try bytes.write(to: f.agent, options: .atomic)
        XCTAssertThrowsError(try f.item.setEnabled(false, expected: old))
        XCTAssertEqual(try Data(contentsOf: f.agent), bytes)
        let current = f.item.status()
        let disabled = try f.item.setEnabled(false, expected: current)
        XCTAssertThrowsError(try f.item.setEnabled(true, expected: current))
        XCTAssertEqual(f.item.status(), disabled)
    }

    func testMissingMalformedAndConflictingAgentsNeverGetRecreatedOrOverwritten() throws {
        let f = try fixture()
        XCTAssertNil(f.item.status().enabled)
        XCTAssertThrowsError(try f.item.setEnabled(true, expected: f.item.status()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.agent.path))
        try Data("{broken".utf8).write(to: f.agent)
        XCTAssertNil(f.item.status().enabled)
        XCTAssertThrowsError(try f.item.setEnabled(false, expected: f.item.status()))
        XCTAssertEqual(try Data(contentsOf: f.agent), Data("{broken".utf8))
        try f.write(); let original = try Data(contentsOf: f.agent)
        try original.write(to: f.parked)
        XCTAssertNil(f.item.status().enabled)
        XCTAssertThrowsError(try f.item.setEnabled(false, expected: f.item.status()))
        XCTAssertEqual(try Data(contentsOf: f.agent), original)
        XCTAssertEqual(try Data(contentsOf: f.parked), original)
    }

    func testUnownedRootsExecutablesAndAdditionalLaunchTriggersAreRefused() throws {
        let f = try fixture()
        for (key, value) in [
            ("Label", "another-app" as Any), ("ProgramArguments", ["/bin/sh", "run"]),
            ("EnvironmentVariables", ["OPENCLAW_TEAMS_HOME": "/different-root"]),
            ("RunAtLoad", false), ("KeepAlive", true), ("RunAtLoad", 1),
            ("KeepAlive", ["SuccessfulExit": 0]), ("StartInterval", 10), ("Program", "/bin/sh")
        ] {
            var plist = f.plist; plist[key] = value; try f.write(plist)
            let before = try Data(contentsOf: f.agent)
            XCTAssertNil(f.item.status().enabled, key)
            XCTAssertThrowsError(try f.item.setEnabled(false, expected: f.item.status()), key)
            XCTAssertEqual(try Data(contentsOf: f.agent), before)
        }
    }

    func testLinkedAndOversizedAgentsArePreserved() throws {
        let f = try fixture(); try f.write()
        let before = try Data(contentsOf: f.agent), target = f.root.appendingPathComponent("target")
        try FileManager.default.moveItem(at: f.agent, to: target)
        try FileManager.default.createSymbolicLink(at: f.agent, withDestinationURL: target)
        XCTAssertNil(f.item.status().enabled)
        XCTAssertThrowsError(try f.item.setEnabled(false, expected: f.item.status()))
        XCTAssertEqual(try Data(contentsOf: target), before)
        try FileManager.default.removeItem(at: f.agent)
        try FileManager.default.createSymbolicLink(at: f.agent, withDestinationURL: f.root.appendingPathComponent("absent"))
        XCTAssertNil(f.item.status().enabled)
        try FileManager.default.removeItem(at: f.agent)
        try Data(repeating: 65, count: 65_537).write(to: f.agent)
        XCTAssertNil(f.item.status().enabled)
        XCTAssertThrowsError(try f.item.setEnabled(false, expected: f.item.status()))
        XCTAssertEqual(try Data(contentsOf: f.agent).count, 65_537)
    }

    func testInstallerLockAndPendingMarkerBlockPreferenceMutation() throws {
        let f = try fixture(); try f.write()
        let before = try Data(contentsOf: f.agent), status = f.item.status()
        let fd = open(f.root.appendingPathComponent("lifecycle.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try f.item.setEnabled(false, expected: status))
        flock(fd, LOCK_UN); close(fd)
        try Data("{}".utf8).write(to: f.root.appendingPathComponent("installation-pending.json"))
        XCTAssertThrowsError(try f.item.setEnabled(false, expected: status))
        XCTAssertEqual(try Data(contentsOf: f.agent), before)
    }

    func testSwiftPreferenceSurvivesRealPythonInstallerUpdateAndCanBeEnabledAgain() throws {
        let f = try fixture(); try f.write()
        let off = try f.item.setEnabled(false, expected: f.item.status())
        let base = f.root.deletingLastPathComponent(), distribution = base.appendingPathComponent("distribution")
        let source = distribution.appendingPathComponent("helper/ocmh.app/Contents")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try Data("fixture binary".utf8).write(to: source.appendingPathComponent("MacOS/ocmh"))
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": HelperLoginItem.label, "CFBundleShortVersionString": "0.2.16", "OCMHUsesLifecycleLock": true], format: .xml, options: 0).write(to: source.appendingPathComponent("Info.plist"))
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repository.deleteLastPathComponent() }
        let program = """
        import importlib.util, os, pathlib, subprocess, sys
        spec = importlib.util.spec_from_file_location('installer', sys.argv[1])
        helper = importlib.util.module_from_spec(spec); spec.loader.exec_module(helper)
        root, home, distribution = map(pathlib.Path, sys.argv[2:5])
        os.environ['OPENCLAW_TEAMS_HOME'] = str(root)
        pathlib.Path.home = classmethod(lambda cls: home)
        helper.__file__ = str(distribution/'scripts/helper.py')
        def command(*args, **kwargs):
            return subprocess.CompletedProcess(args, 1 if args[:2] == ('/bin/launchctl', 'print') else 0, b'', b'')
        helper.command = command
        def reject_signal(*args): raise AssertionError('Unexpected process signal')
        helper.os.kill = reject_signal
        sys.argv = ['helper.py', 'update', '--no-launch']
        helper.main()
        """
        let process = Process(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", program, repository.appendingPathComponent("scripts/helper.py").path, f.root.path, base.appendingPathComponent("home").path, distribution.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = errors
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.agent.path))
        XCTAssertEqual(f.item.status().enabled, false)
        XCTAssertThrowsError(try f.item.setEnabled(true, expected: off), "The update must invalidate the pre-update snapshot")
        XCTAssertEqual(try f.item.setEnabled(true, expected: f.item.status()).enabled, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.parked.path))
    }
}
