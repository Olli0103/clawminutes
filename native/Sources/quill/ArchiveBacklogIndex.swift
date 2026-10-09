import Foundation

/// Cache expensive verification while every input's filesystem identity stays
/// unchanged. Receipts and hashes remain authoritative; cache entries never
/// authorize deletion. ctime catches edits that restore the old mtime and size.
struct ArchiveBacklogIndex {
    private struct Cached { let stamp: String; let item: ArchiveBacklog.Item }
    private var entries: [String: Cached] = [:]
    private let inspect: (URL, URL) -> ArchiveBacklog.Item
    init(inspect: @escaping (URL, URL) -> ArchiveBacklog.Item = { ArchiveBacklog.inspect($0, notesRoot: $1) }) {
        self.inspect = inspect
    }
    private func stamp(_ file: URL) -> String {
        var info = stat()
        guard lstat(file.path, &info) == 0 else { return "missing" }
        return "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec):\(info.st_mode)"
    }
    private func directoryIdentity(_ file: URL) -> String {
        var info = stat()
        guard lstat(file.path, &info) == 0 else { return "missing" }
        return "\(info.st_dev):\(info.st_ino):\(info.st_mode)"
    }
    mutating func item(_ directory: URL, notesRoot: URL = MeetingNotesSettings.folder) -> ArchiveBacklog.Item {
        var ancestors: [URL] = []
        var files = ["meta.json", "transcript.json", "participants.json", "archive-receipt.json", "archive-retry.json",
                     "notes-export-path.txt", "notes-export-location.json", "state.json", "notes-recovery.json"].map { directory.appendingPathComponent($0) }
        if let data = try? ArchiveBacklog.read(directory.appendingPathComponent("notes-export-path.txt")), data.count <= 4096,
           let text = String(data: data, encoding: .utf8), text.hasPrefix("/") {
            let destination = URL(fileURLWithPath: text.trimmingCharacters(in: .whitespacesAndNewlines))
            files += [destination] + ["notes.md", "transcript.md", "metadata.json"].map { destination.appendingPathComponent($0) }
            // Include each ancestor: changing a directory into a link must
            // invalidate the cached path verification even if target files match.
            var parent = destination.deletingLastPathComponent()
            while parent.path != "/" { ancestors.append(parent); parent.deleteLastPathComponent() }
        }
        let signature = ([notesRoot.path, directoryIdentity(directory)] + files.map(stamp) + ancestors.map(directoryIdentity)).joined(separator: "\n")
        if let cached = entries[directory.path], cached.stamp == signature { return cached.item }
        let result = inspect(directory, notesRoot)
        entries[directory.path] = Cached(stamp: signature, item: result)
        return result
    }
    mutating func scan(root: URL, notesRoot: URL = MeetingNotesSettings.folder) throws -> [ArchiveBacklog.Item] {
        let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("meta.json").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let current = Set(directories.map(\.path))
        entries = entries.filter { current.contains($0.key) }
        return directories.map { item($0, notesRoot: notesRoot) }
    }
}
