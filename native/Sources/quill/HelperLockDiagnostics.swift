import Foundation
import Darwin
import ArgumentParser

/// Observations only. Never grants ownership, changes a lock or admits work.
/// Queries run in a child because closing a descriptor in the calling process
/// can release that process's POSIX record locks, even after a read-only query.
enum HelperLockDiagnostics {
    enum Role: String, Codable, Sendable { case instance, lifecycle, capture, archive }
    enum State: String, Codable, Sendable { case absent, unavailable, unsafe, changed, noBlockingLock, shared, exclusive }
    struct Request: Codable, Sendable {
        let role: Role
        let path: String
        var recordingRef: String? = nil
        var meetingIndex: Int? = nil
        var key: String { role.rawValue + ":" + (recordingRef ?? "") + ":" + (meetingIndex.map(String.init) ?? "") }
        var valid: Bool {
            guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4096 else { return false }
            if role == .archive {
                return recordingRef?.count == 24 && recordingRef?.allSatisfy { $0.isHexDigit } == true
                    && (meetingIndex == nil || (0..<25).contains(meetingIndex!))
            }
            return recordingRef == nil && meetingIndex == nil
        }
    }
    struct Observation: Codable, Sendable {
        let role: Role
        let recordingRef: String?
        let meetingIndex: Int?
        let state: State
        let ownerPID: Int32?
        let observedAt: Double
        var key: String { role.rawValue + ":" + (recordingRef ?? "") + ":" + (meetingIndex.map(String.init) ?? "") }
    }
    struct Input: Codable { let schemaVersion: Int; let requests: [Request] }
    struct Output: Codable { let schemaVersion: Int; let observations: [Observation] }
    static let maximumInput = 131_072

    static func capture(_ requests: [Request], executable: URL?, timeout: Double = 2) async -> [Observation] {
        func unavailable() -> [Observation] { requests.map { observation($0, .unavailable) } }
        guard requests.count <= 28, requests.allSatisfy(\.valid), Set(requests.map(\.key)).count == requests.count,
              let executable else { return unavailable() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ocmh-lock-snapshot-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            // Foundation normalizes /private/var back to /var. Use the physical
            // name for both the private environment and the child's cwd.
            guard let resolved = realpath(directory.path, nil) else { return unavailable() }
            let sandbox = URL(fileURLWithPath: String(cString: resolved))
            free(resolved)
            let input = try JSONEncoder().encode(Input(schemaVersion: 1, requests: requests))
            guard input.count <= maximumInput else { return unavailable() }
            let environment = ["PATH": "/usr/bin:/bin", "HOME": sandbox.path, "TMPDIR": sandbox.path,
                               "LANG": "C", "OPENCLAW_TEAMS_HOME": sandbox.appendingPathComponent("empty").path]
            let result = try await HarnessProcess.run(executable: executable, arguments: ["lock-snapshot-internal"],
                input: input, directory: sandbox, timeout: timeout, childEnvironment: environment,
                maximumOutputBytes: 32_768, maximumErrorBytes: 8192)
            guard result.status == 0 else { return unavailable() }
            let output = try decodeOutput(result.output)
            guard output.observations.map(\.key) == requests.map(\.key) else { return unavailable() }
            return output.observations
        } catch { return unavailable() }
    }

    private static func observation(_ request: Request, _ state: State, owner: Int32? = nil) -> Observation {
        Observation(role: request.role, recordingRef: request.recordingRef, meetingIndex: request.meetingIndex, state: state,
                    ownerPID: owner, observedAt: Date().timeIntervalSince1970)
    }

    fileprivate static func worker(_ data: Data) throws -> Data {
        guard data.count <= maximumInput,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["schemaVersion", "requests"],
              let rows = object["requests"] as? [[String: Any]], rows.count <= 28,
              rows.allSatisfy({ Set($0.keys).isSubset(of: ["role", "path", "recordingRef", "meetingIndex"]) }) else {
            throw ValidationError("Lock snapshot unavailable.")
        }
        let input = try JSONDecoder().decode(Input.self, from: data)
        guard input.schemaVersion == 1, input.requests.allSatisfy(\.valid),
              Set(input.requests.map(\.key)).count == input.requests.count else { throw ValidationError("Lock snapshot unavailable.") }
        return try JSONEncoder().encode(Output(schemaVersion: 1, observations: input.requests.map(inspect)))
    }

    private static func decodeOutput(_ data: Data) throws -> Output {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["schemaVersion", "observations"],
              let rows = object["observations"] as? [[String: Any]], rows.count <= 28,
              rows.allSatisfy({ Set($0.keys).isSubset(of: ["role", "recordingRef", "meetingIndex", "state", "ownerPID", "observedAt"]) }) else {
            throw ValidationError("Lock snapshot unavailable.")
        }
        let output = try JSONDecoder().decode(Output.self, from: data)
        guard output.schemaVersion == 1, output.observations.allSatisfy({ value in
            value.observedAt.isFinite && value.observedAt > 0
                && (value.ownerPID == nil || ((value.state == .shared || value.state == .exclusive) && value.ownerPID! > 0))
        }) else { throw ValidationError("Lock snapshot unavailable.") }
        return output
    }

    private static func inspect(_ request: Request) -> Observation {
        let parts = request.path.split(separator: "/").map(String.init)
        guard let leaf = parts.last, !parts.contains("."), !parts.contains("..") else { return observation(request, .unsafe) }
        var parent = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { return observation(request, .unavailable) }
        defer { close(parent) }
        func failure(_ error: Int32) -> Observation {
            observation(request, error == ENOENT ? .absent : [ELOOP, ENOTDIR].contains(error) ? .unsafe : .unavailable)
        }
        for part in parts.dropLast() {
            let next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard next >= 0 else { return failure(errno) }
            close(parent); parent = next
        }
        var before = stat()
        guard fstatat(parent, leaf, &before, AT_SYMLINK_NOFOLLOW) == 0 else { return failure(errno) }
        guard before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1 else { return observation(request, .unsafe) }
        let fd = openat(parent, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return failure(errno) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return observation(request, .unavailable) }
        guard info.st_dev == before.st_dev, info.st_ino == before.st_ino else { return observation(request, .changed) }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { return observation(request, .unsafe) }
        var query = Darwin.flock(l_start: 0, l_len: 0, l_pid: 0, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
        guard withUnsafeMutablePointer(to: &query, { fcntl(fd, F_GETLK, $0) }) == 0 else { return observation(request, .unavailable) }
        var current = stat()
        guard fstatat(parent, leaf, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_dev == info.st_dev, current.st_ino == info.st_ino,
              current.st_mode & S_IFMT == S_IFREG, current.st_nlink == 1 else { return observation(request, .changed) }
        let state: State
        switch Int32(query.l_type) {
        case F_UNLCK: state = .noBlockingLock
        case F_RDLCK: state = .shared
        case F_WRLCK: state = .exclusive
        default: return observation(request, .unavailable)
        }
        // Darwin returns -1 for flock/OFD locks. A PID file cannot replace that evidence.
        return observation(request, state, owner: state != .noBlockingLock && query.l_pid > 0 ? query.l_pid : nil)
    }
}

struct LockSnapshot: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "lock-snapshot-internal", shouldDisplay: false)
    func run() throws {
        let input = try FileHandle.standardInput.read(upToCount: HelperLockDiagnostics.maximumInput + 1) ?? Data()
        FileHandle.standardOutput.write(try HelperLockDiagnostics.worker(input))
    }
}
