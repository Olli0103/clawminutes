import ArgumentParser
import AppKit
import FluidAudio
import Foundation

struct SetupLocal: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "setup-local", abstract: "Download Parakeet v3 models to this Mac. No audio is read or uploaded.")
    mutating func run() async throws {
        ModelHub.offlineMode = false
        _ = try await AsrModels.downloadAndLoad(version: .v3)
        print("Parakeet v3 installed on \(ProcessInfo.processInfo.hostName). Local only is ready.")
    }
}

struct GatewayStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "gateway-status", abstract: "Check the configured Gateway without capture or uploads.")
    mutating func run() async throws { print(try await GatewayArchive.status().description) }
}

struct ArchiveSession: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "archive-session", abstract: "Send a finished text transcript to the configured Gateway. Never sends audio.")
    @Option var directory: String
    mutating func run() async throws {
        try await archive()
        print("Gateway archive receipt and local meeting documents verified.")
    }
    func archive(activityLockPath: URL = HelperWorkLease.path, appLockPath: URL? = nil,
                 now: TimeInterval = Date().timeIntervalSince1970,
                 saveArchive: @escaping @Sendable (URL) async throws -> Void = { try await GatewayArchive.save($0) }) async throws {
        let acquired = try appLockPath.map { try AppRunLock.acquire(at: $0) } ?? AppRunLock.acquire()
        guard let owner = acquired else { throw ValidationError("The helper is running. Use this meeting's recovery actions in Settings.") }
        defer { withExtendedLifetime(owner) {} }
        let folder = URL(fileURLWithPath: directory)
        let item = ArchiveBacklog.inspect(folder)
        if item.verifiedText == .exported { return }
        guard item.pending else { throw ValidationError(item.reason) }
        guard item.nextAttemptAt <= now else {
            throw ValidationError("This meeting is waiting before its next save attempt. Retry later; existing attempt history is preserved.")
        }
        let delivery = MeetingDeliveryStage(activityLockPath: activityLockPath, saveArchive: saveArchive, onSaved: { _ in })
        switch await delivery.deliver(folder, now: now) {
        case .saved: return
        case .failed(let failure): throw failure
        case .skipped:
            let latest = ArchiveBacklog.inspect(folder)
            guard latest.verifiedText == .exported else { throw ValidationError(latest.reason) }
        }
    }
}

struct ArchiveBacklogCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "archive-backlog", abstract: "Check finished transcript delivery and local exports. Read-only unless --retry is supplied.")
    @Option var out: String?
    @Flag(help: "Retry pending text saves. Use Settings while the helper is running.") var retry = false
    mutating func run() async throws {
        let root = Config.resolveRoot(cliOverride: out)
        if retry {
            guard let lock = try AppRunLock.acquire() else { throw ValidationError("The helper is running. Use Retry pending saves in its Settings.") }
            defer { withExtendedLifetime(lock) {} }
            let coordinator = TranscriptionCoordinator()
            let capabilities = try? await GatewayArchive.status()
            let report = try await coordinator.retryArchiveBacklog(root: root, force: true, capabilities: capabilities)
            print(String(decoding: try JSONEncoder().encode(report), as: UTF8.self))
        } else {
            let rows = try ArchiveBacklog.scan(root: root)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(rows), as: UTF8.self))
        }
    }
}

struct VerifyAudioRetention: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "verify-audio-retention", abstract: "Review saved transcript, notes and audio coverage. Add --delete to remove verified tracks. Never starts capture or contacts the Gateway.")
    @Option var directory: String
    @Flag(help: "Permanently delete audio after fresh verification. The default is read-only.") var delete = false
    mutating func run() throws {
        let folder = URL(fileURLWithPath: directory)
        if !delete {
            if let plan = try AudioRetention.review(folder) {
                print("Verified \(plan.remaining.count) remaining track(s), \(plan.bytes) bytes. Audio unchanged. Add --delete to remove them.")
            } else { print("Audio already removed. No changes made.") }
            return
        }
        let work = try HelperWorkLease.acquire()
        defer { withExtendedLifetime(work) {} }
        let count = try AudioRetention.deleteAfterVerification(folder, policy: .explicitExisting)
        print("Verified transcript and notes; removed \(count) audio track(s).")
    }
}

struct NameRecordingFolder: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "name-recording-folder", abstract: "Add an evidenced meeting title to a finished recording folder, preserving its archive identity.")
    @Option var directory: String
    mutating func run() throws {
        let work = try HelperWorkLease.acquire()
        defer { withExtendedLifetime(work) {} }
        print(try RecordingFolders.renameFinished(URL(fileURLWithPath: directory)).path)
    }
}

struct NameNotesFolder: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "name-notes-folder", abstract: "Clean an existing generated notes folder name using its saved receipt. Never contacts the Gateway.")
    @Option var directory: String
    mutating func run() throws { print(try MeetingDocuments.renameExisting(recording: URL(fileURLWithPath: directory), root: MeetingNotesSettings.folder).path) }
}

struct CaptureFixture: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "capture-fixture", abstract: "Explicitly start a bounded synthetic capture test. Captures microphone and global system audio.")
    @Option var seconds: Int = 10
    @Option var out: String
    @MainActor mutating func run() async throws {
        guard seconds > 0 && seconds <= 120 else { throw ValidationError("Seconds must be 1 to 120") }
        guard let lock = try AppRunLock.acquire() else { throw ValidationError("Stop the helper before the capture diagnostic. Capture remains off.") }
        setenv("OPENCLAW_TEAMS_CAPTURE_FIXTURE", "1", 1)
        let session = try RecordingSession(root: URL(fileURLWithPath: out))
        try await session.start()
        let metaURL = session.dir.appendingPathComponent("meta.json")
        var initialMeta = try JSONSerialization.jsonObject(with: Data(contentsOf: metaURL)) as? [String: Any] ?? [:]
        initialMeta["fixture"] = true
        initialMeta["capture_scope"] = "global_system_fixture"
        try JSONSerialization.data(withJSONObject: initialMeta).write(to: metaURL, options: .atomic)
        FileHandle.standardOutput.write(Data("START \(session.dir.path)\n".utf8))
        for _ in 0..<seconds { try await Task.sleep(for: .seconds(1)); session.checkpoint() }
        await session.stopAsync()
        var meta = try JSONSerialization.jsonObject(with: Data(contentsOf: metaURL)) as? [String: Any] ?? [:]
        meta["fixture"] = true
        meta["capture_scope"] = "global_system_fixture"
        try JSONSerialization.data(withJSONObject: meta).write(to: metaURL, options: .atomic)
        print("STOP \(session.dir.path)")
        withExtendedLifetime(lock) {}
    }
}

struct RecoverSessions: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "recover-sessions", abstract: "Recover pending recordings under an exclusive helper lock. Fails if a helper is running.")
    @Option var out: String
    mutating func run() async throws {
        guard let lock = try AppRunLock.acquire() else { throw ValidationError("Stop the helper before recovery. A capture or helper is active.") }
        let root = URL(fileURLWithPath: out)
        let coordinator = TranscriptionCoordinator()
        _ = try InterruptedRecordingRecovery.recover(root: root, owner: lock)
        let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        for dir in entries {
            let metaURL = dir.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL), let meta = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if !FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.json").path) {
                guard let kind = TranscriptionEngineKind(rawValue: meta["backend"] as? String ?? "parakeet") else { throw ValidationError("Unknown backend. Recording preserved.") }
                do { try await coordinator.transcribe(dir, engineOverride: kind, offline: kind == .parakeet) }
                catch { print("Recovery failed for \(dir.lastPathComponent): \(error). Recording preserved.") }
            }
        }
        withExtendedLifetime(lock) {}
        print("Recovery scan complete on \(ProcessInfo.processInfo.hostName).")
    }
}


struct MigrateNotesFolder: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "migrate-notes-folder", abstract: "Explicitly copy a finished meeting's notes, including edits, into a new root. Keeps the original; never contacts the Gateway.")
    @Option var directory: String
    @Option var destination: String
    mutating func run() throws {
        let work = try HelperWorkLease.acquire()
        defer { withExtendedLifetime(work) {} }
        let recording = URL(fileURLWithPath: directory)
        guard let lock = try AppRunLock.acquire(at: recording.appendingPathComponent("archive.lock")) else {
            throw ValidationError("This meeting is being saved. Retry after it finishes.")
        }
        defer { withExtendedLifetime(lock) {} }
        print(try MeetingDocuments.migrateExport(recording: recording, to: URL(fileURLWithPath: destination, isDirectory: true)).path)
    }
}
