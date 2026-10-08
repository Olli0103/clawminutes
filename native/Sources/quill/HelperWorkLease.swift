import Foundation

/// Capture and processing share this lease. The installer requires exclusive
/// ownership before it can signal, replace or remove the helper. Keep the inode
/// in place: an OS-released lock, rather than a stale file, determines activity.
final class HelperWorkLease: @unchecked Sendable {
    static var path: URL { Config.path.deletingLastPathComponent().appendingPathComponent("lifecycle.lock") }
    private let descriptor: Int32
    private init(_ descriptor: Int32) { self.descriptor = descriptor }

    static func acquire(at path: URL = path) throws -> HelperWorkLease {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(path.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var lockInfo = stat()
        guard fstat(descriptor, &lockInfo) == 0, lockInfo.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            throw TranscriptionFailure("Could not verify the helper lifecycle lock. Your recording files are preserved.")
        }
        guard flock(descriptor, LOCK_SH | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK {
                throw TranscriptionFailure("ocmh is being updated or removed. Try again after it finishes. Your recording files are preserved.")
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        // The marker survives a terminated installer after its OS lock releases.
        // Any marker, including a broken link or malformed file, blocks work.
        let pending = path.deletingLastPathComponent().appendingPathComponent("installation-pending.json")
        var markerInfo = stat()
        let markerResult = lstat(pending.path, &markerInfo)
        let markerError = errno
        guard markerResult != 0, markerError == ENOENT else {
            flock(descriptor, LOCK_UN); close(descriptor)
            throw TranscriptionFailure("An interrupted ClawMinutes update needs review before recording or processing can continue. Your recording files are preserved.")
        }
        return HelperWorkLease(descriptor)
    }

    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
