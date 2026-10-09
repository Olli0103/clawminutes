import Foundation

/// All live audio writers share the installer lease and one exclusive capture
/// lock. A setup check can never open a second tap beside a meeting recording.
final class CaptureOwnership {
    private let work: HelperWorkLease
    private let capture: AppRunLock
    private init(work: HelperWorkLease, capture: AppRunLock) { self.work = work; self.capture = capture }
    static func acquire(activityLockPath: URL = HelperWorkLease.path) throws -> CaptureOwnership {
        let work = try HelperWorkLease.acquire(at: activityLockPath)
        guard let capture = try AppRunLock.acquire(at: activityLockPath.deletingLastPathComponent().appendingPathComponent("capture.lock")) else {
            throw TranscriptionFailure("Another recording or audio check is active. Finish it before starting another capture.")
        }
        return Self(work: work, capture: capture)
    }
}
