import Foundation

enum RecordingStorage {
    static let minimumFreeBytes: Int64 = 1_000_000_000
    enum Issue: Error, CustomStringConvertible {
        case lowSpace, unavailable
        var description: String {
            switch self {
            case .lowSpace: return "Free at least 1 GB on the recording disk before starting. Long meetings need more space."
            case .unavailable: return "The recording disk's free space could not be checked. Check that the folder is available."
            }
        }
    }
    static func available(at root: URL) throws -> Int64 {
        var existing = root
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" { existing.deleteLastPathComponent() }
        let values = try FileManager.default.attributesOfFileSystem(forPath: existing.path)
        guard let value = values[.systemFreeSize] as? NSNumber else { throw Issue.unavailable }
        return value.int64Value
    }
    static func checkStart(freeBytes: Int64) throws {
        guard freeBytes >= minimumFreeBytes else { throw Issue.lowSpace }
    }
    static func summary(root: URL) throws -> String {
        let free = try available(at: root)
        var bytes: Int64 = 0
        if let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles]) {
            for case let file as URL in files where ["caf", "wav", "m4a", "aac", "flac"].contains(file.pathExtension.lowercased()) {
                let properties = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                if properties.isRegularFile == true, properties.isSymbolicLink != true { bytes += Int64(properties.fileSize ?? 0) }
            }
        }
        return "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) of recording audio · \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free"
    }
}
