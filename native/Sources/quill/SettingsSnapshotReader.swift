import Foundation

/// Polling reads retain only small helper preferences, never templates or unknown
/// keys. Writes and consequential routing/retention decisions must use fresh().
/// Fingerprints detect ordinary edits; this is not a transactional file lock.
final class SettingsSnapshotReader: @unchecked Sendable {
    static let helperKeys: Set<String> = [
        "notes_mode", "menu_bar_style", "post_processing", "speaker_voice_memory",
        "speaker_detection", "zoom_visual_speaker_detection", "zoom_local_speaker_name",
        "shared_microphone", "local_speaker_name", "meeting_detection", "recordings_dir",
        "on_stop", "mic_voice_processing"
    ]
    private struct Entry { let stamp: String; let value: [String: Any]? }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private let keys: Set<String>
    private let maxBytes: Int
    private let readBytes: @Sendable (URL) throws -> Data
    private let warning: @Sendable () -> Void
    init(keys: Set<String> = SettingsSnapshotReader.helperKeys, maxBytes: Int = 256 * 1024,
         readBytes: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) },
         warning: @escaping @Sendable () -> Void = {
             FileHandle.standardError.write(Data("Could not read ClawMinutes settings. Existing files were left untouched.\n".utf8))
         }) {
        self.keys = keys; self.maxBytes = max(0, maxBytes)
        self.readBytes = readBytes; self.warning = warning
    }
    private func stamp(_ path: URL) -> String? {
        // Include both link and target identity; never cache special-file reads.
        var link = stat(), target = stat()
        guard lstat(path.path, &link) == 0, stat(path.path, &target) == 0,
              target.st_mode & S_IFMT == S_IFREG else { return nil }
        return [link, target].map {
            "\($0.st_dev):\($0.st_ino):\($0.st_size):\($0.st_mtimespec.tv_sec):\($0.st_mtimespec.tv_nsec):\($0.st_ctimespec.tv_sec):\($0.st_ctimespec.tv_nsec):\($0.st_mode)"
        }.joined(separator: ":")
    }
    private func forget(_ path: String) {
        entries.removeValue(forKey: path); order.removeAll { $0 == path }
    }
    private func remember(_ value: [String: Any]?, at path: String, stamp: String) {
        forget(path)
        if order.count == 4 { entries.removeValue(forKey: order.removeFirst()) }
        entries[path] = Entry(stamp: stamp, value: value); order.append(path)
    }
    func read(at path: URL) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        guard let before = stamp(path) else { forget(path.path); return nil }
        if let entry = entries[path.path], entry.stamp == before { return entry.value }
        forget(path.path)
        guard let data = try? readBytes(path) else { warning(); return nil }
        guard stamp(path) == before else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            remember(nil, at: path.path, stamp: before); warning(); return nil
        }
        let projected = json.filter { keys.contains($0.key) }
        // Large valid profiles still work. Bound retained bytes rather than
        // imposing a new size limit on the source or dropping unknown keys.
        if let encoded = try? JSONSerialization.data(withJSONObject: projected), encoded.count <= maxBytes {
            remember(projected, at: path.path, stamp: before)
        }
        return projected
    }
    /// Full source read, preserving existing malformed-file and writer behavior.
    /// No cached snapshot can authorize audio deletion or overwrite unknown keys.
    func fresh(at path: URL) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        forget(path.path)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard let data = try? readBytes(path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            warning(); return nil
        }
        return json
    }
}
