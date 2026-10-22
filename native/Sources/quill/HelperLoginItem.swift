import CoreFoundation
import Foundation

/// The file location is the preference. Keep the installer-owned job intact so
/// an already loaded job and the installer's manual run retain crash supervision.
/// This module never launches, unloads, signals or executes another process.
struct HelperLoginItem: Sendable {
    static let label = "ai.openclaw.teams-transcribe"
    static let disabledName = "launch-at-login-disabled.plist"
    struct Status: Equatable, Sendable {
        let enabled: Bool?
        let detail: String
        fileprivate let fingerprint: String?
        static let unavailable = Self(enabled: nil, detail: "Install or update the bundled helper to choose launch at login.", fingerprint: nil)
        static let preview = Self(enabled: true, detail: "Changes apply at your next login. This session keeps running.", fingerprint: nil)
    }
    let root: URL
    let agent: URL
    init(root: URL = Config.path.deletingLastPathComponent(),
         agent: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(Self.label).plist")) {
        self.root = root; self.agent = agent
    }
    private var disabled: URL { root.appendingPathComponent(Self.disabledName) }
    private struct Snapshot {
        let source: URL
        let enabled: Bool
        let fingerprint: String
    }
    private static let invalid = TranscriptionFailure("The login setting could not be verified. Existing files were left untouched. Update the bundled helper or review its installation.")

    func status() -> Status {
        do {
            guard let snapshot = try read() else { return .unavailable }
            return Status(enabled: snapshot.enabled, detail: Status.preview.detail, fingerprint: snapshot.fingerprint)
        } catch {
            return Status(enabled: nil, detail: Self.invalid.description, fingerprint: nil)
        }
    }

    @discardableResult func setEnabled(_ enabled: Bool, expected: Status) throws -> Status {
        let lease = try HelperWorkLease.acquire(at: root.appendingPathComponent("lifecycle.lock"))
        defer { withExtendedLifetime(lease) {} }
        guard let lock = try AppRunLock.acquire(at: root.appendingPathComponent("login-setting.lock")) else {
            throw TranscriptionFailure("The login setting is already changing. Check again before retrying.")
        }
        defer { withExtendedLifetime(lock) {} }
        guard let snapshot = try read(), expected.fingerprint == snapshot.fingerprint, expected.enabled == snapshot.enabled else {
            throw TranscriptionFailure("The login setting changed. Check again before retrying. Existing files were left untouched.")
        }
        if enabled == snapshot.enabled { return status() }
        let destination = enabled ? agent : disabled
        try verifyDirectory(destination.deletingLastPathComponent())
        // RENAME_EXCL refuses an intervening destination, including a dangling
        // link. Cross-volume moves fail rather than becoming a copy/delete pair.
        guard renamex_np(snapshot.source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw TranscriptionFailure("Could not change launch at login. Existing files were preserved. Check the installation before retrying.")
        }
        let result = status()
        guard result.enabled == enabled else {
            throw TranscriptionFailure("The login setting needs review after the move. This session was not restarted.")
        }
        return result
    }

    private func verifyDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else { throw Self.invalid }
    }
    private func read() throws -> Snapshot? {
        let normal = try readFile(agent), parked = try readFile(disabled)
        guard normal == nil || parked == nil else { throw Self.invalid }
        guard let value = normal ?? parked else { return nil }
        let source = normal == nil ? disabled : agent
        try verifyDirectory(source.deletingLastPathComponent())
        guard let plist = try PropertyListSerialization.propertyList(from: value.data, format: nil) as? [String: Any] else { throw Self.invalid }
        let keys: Set<String> = ["Label", "ProgramArguments", "EnvironmentVariables", "RunAtLoad", "KeepAlive", "ThrottleInterval", "StandardOutPath", "StandardErrorPath"]
        guard Set(plist.keys).isSubset(of: keys), plist["Label"] as? String == Self.label,
              let args = plist["ProgramArguments"] as? [String],
              args.first == root.appendingPathComponent("ocmh.app/Contents/MacOS/ocmh").path,
              (args.count == 2 || (args.count == 4 && args[2] == "--out" && !args[3].isEmpty)), args[1] == "run",
              let environment = plist["EnvironmentVariables"] as? [String: String], environment["OPENCLAW_TEAMS_HOME"] == root.path,
              Self.boolean(plist["RunAtLoad"]) == true,
              let keepAlive = plist["KeepAlive"] as? [String: Any], Set(keepAlive.keys) == ["SuccessfulExit"],
              Self.boolean(keepAlive["SuccessfulExit"]) == false else { throw Self.invalid }
        let identity = "\(value.device):\(value.inode):\(value.mode):\(source.path)\n"
        let fingerprint = AudioRetention.digest(Data(identity.utf8) + value.data)
        return Snapshot(source: source, enabled: normal != nil, fingerprint: fingerprint)
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    private struct FileBytes {
        let data: Data
        let device: Int32
        let inode: UInt64
        let mode: UInt16
    }
    private func readFile(_ url: URL) throws -> FileBytes? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw Self.invalid
        }
        let stream = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? stream.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_uid == geteuid(), (1...65_536).contains(info.st_size) else { throw Self.invalid }
        var data = Data()
        while data.count <= 65_536 {
            guard let part = try stream.read(upToCount: 65_537 - data.count), !part.isEmpty else { break }
            data.append(part)
        }
        guard data.count == info.st_size, data.count <= 65_536 else { throw Self.invalid }
        return FileBytes(data: data, device: info.st_dev, inode: info.st_ino, mode: info.st_mode)
    }
}
