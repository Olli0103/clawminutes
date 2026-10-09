import Foundation

/// Exact reviewed contents, including user edits and empty subdirectories.
/// Limits bound review work; unsupported folders require a manual copy.
struct NotesFolderSnapshot: Equatable, Sendable {
    struct File: Equatable, Sendable { let bytes: Int64; let sha256: String }
    let files: [String: File]
    let directories: Set<String>
    var bytes: Int64 { files.values.reduce(0) { $0 + $1.bytes } }
    static func capture(_ folder: URL) throws -> Self {
        let fm = FileManager.default
        var files: [String: File] = [:], directories = Set<String>(), visited = 0, totalBytes: Int64 = 0
        func walk(_ directory: URL, prefix: String) throws {
            try Task.checkCancellation()
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw NotesMigration.unavailable }
            for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]) {
                try Task.checkCancellation()
                visited += 1
                guard visited <= 1000 else { throw NotesMigration.tooLarge }
                let relative = prefix + file.lastPathComponent
                let properties = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
                guard properties.isSymbolicLink != true else { throw NotesMigration.unavailable }
                if properties.isDirectory == true {
                    directories.insert(relative); try walk(file, prefix: relative + "/")
                } else {
                    guard properties.isRegularFile == true, let size = properties.fileSize, size <= 16_000_000 else { throw NotesMigration.tooLarge }
                    let data = try ArchiveBacklog.read(file)
                    guard data.count == size else { throw NotesMigration.changed }
                    files[relative] = File(bytes: Int64(size), sha256: AudioRetention.digest(data))
                    totalBytes += Int64(size)
                    guard totalBytes <= 100_000_000 else { throw NotesMigration.tooLarge }
                }
            }
        }
        try walk(folder, prefix: "")
        return Self(files: files, directories: directories)
    }
}

enum NotesMigration {
    struct Plan: Sendable {
        let recording: URL
        let recordingIdentity: String
        let receiptSHA256: String
        let source: URL
        let destination: URL
        let root: URL
        let rootIdentity: String
        let snapshot: NotesFolderSnapshot
    }
    struct Row: Identifiable, Sendable {
        let meeting: RecentMeeting
        let plan: Plan?
        let issue: String?
        var id: String { meeting.id }
    }
    static let changed = TranscriptionFailure("These notes changed after review. Review the current files before copying. Originals are preserved.")
    static let unavailable = TranscriptionFailure("Linked, missing or unreadable notes require a manual check. Originals are preserved.")
    static let tooLarge = TranscriptionFailure("This folder exceeds 1,000 entries, 16 MB per file or 100 MB in total. Copy it manually. Originals are preserved.")
    static func destinationIdentity(_ root: URL) throws -> String {
        var info = stat()
        guard lstat(root.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw TranscriptionFailure("Choose an existing folder rather than a symbolic link.")
        }
        return "\(info.st_dev):\(info.st_ino):\(info.st_mode)"
    }
    static func prepare(_ recording: URL, to root: URL) throws -> Plan {
        let rootIdentity = try destinationIdentity(root)
        let paths = try MeetingDocuments.migrationPaths(recording: recording, to: root)
        guard paths.source.standardizedFileURL != paths.destination.standardizedFileURL else {
            throw TranscriptionFailure("These notes are already in the selected folder.")
        }
        return try Plan(recording: recording, recordingIdentity: MeetingPipelineState.identity(recording),
            receiptSHA256: AudioRetention.digest(ArchiveBacklog.read(recording.appendingPathComponent("archive-receipt.json"))),
            source: paths.source, destination: paths.destination, root: root, rootIdentity: rootIdentity, snapshot: NotesFolderSnapshot.capture(paths.source))
    }
    static func review(_ meetings: [RecentMeeting], to root: URL) throws -> [Row] {
        try meetings.map { meeting in
            try Task.checkCancellation()
            do { return Row(meeting: meeting, plan: try prepare(meeting.directory, to: root), issue: nil) }
            catch is CancellationError { throw CancellationError() }
            catch { return Row(meeting: meeting, plan: nil, issue: detail(error)) }
        }
    }
    static func detail(_ error: Error) -> String {
        if let known = error as? TranscriptionFailure { return known.description }
        return "Could not finish the copy or update its saved location. Originals are preserved. Check the destination before retrying."
    }
    static func execute(_ plan: Plan, activityLockPath: URL = HelperWorkLease.path) throws -> URL {
        let work = try HelperWorkLease.acquire(at: activityLockPath)
        defer { withExtendedLifetime(work) {} }
        guard let lock = try AppRunLock.acquire(at: plan.recording.appendingPathComponent("archive.lock")) else {
            throw TranscriptionFailure("This meeting is being saved. Wait for it to finish, then review again.")
        }
        defer { withExtendedLifetime(lock) {} }
        guard try destinationIdentity(plan.root) == plan.rootIdentity else { throw changed }
        let paths = try MeetingDocuments.migrationPaths(recording: plan.recording, to: plan.root)
        guard try MeetingPipelineState.identity(plan.recording) == plan.recordingIdentity,
              AudioRetention.digest(try ArchiveBacklog.read(plan.recording.appendingPathComponent("archive-receipt.json"))) == plan.receiptSHA256,
              paths.source.standardizedFileURL == plan.source.standardizedFileURL,
              paths.destination.standardizedFileURL == plan.destination.standardizedFileURL else { throw changed }
        return try MeetingDocuments.migrateExport(recording: plan.recording, to: plan.root, expectedSource: plan.snapshot, expectedRootIdentity: plan.rootIdentity)
    }
}
