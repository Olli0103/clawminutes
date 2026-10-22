import Foundation

/// Serializes transcript writers with delivery, cleanup and installer ownership.
/// A delivered or attempted source can only be read for a separate preview.
final class DraftSourceOwnership {
    private let lease: HelperWorkLease
    private let archive: AppRunLock
    private let processing: AppRunLock
    private let directory: URL
    private let editing: Bool
    private let snapshot: [String: String]
    private static let files = ["meta.json", "transcript.json", "transcript.md", "participants.json",
                                "speaker-observations.jsonl", "speaker-analysis.json", "postprocess.json"]
    private init(directory: URL, editing: Bool, lease: HelperWorkLease, archive: AppRunLock,
                 processing: AppRunLock, snapshot: [String: String]) {
        self.directory = directory; self.editing = editing
        self.lease = lease; self.archive = archive; self.processing = processing; self.snapshot = snapshot
    }
    static let revisionRequired = DeliveryFailure(code: "revision_conflict",
        detail: "This meeting was saved or delivery was attempted. Use a new revision or a separate preview; the original transcript is preserved.",
        retryable: false, completionAttempted: false)
    static func acquire(_ dir: URL, editing: Bool = true, activityLockPath: URL = HelperWorkLease.path) throws -> DraftSourceOwnership {
        // Reject linked directories before creating lock files in them.
        _ = try MeetingPipelineState.identity(dir)
        let lease = try HelperWorkLease.acquire(at: activityLockPath)
        guard let archive = try AppRunLock.acquire(at: dir.appendingPathComponent("archive.lock")),
              let processing = try AppRunLock.acquire(at: dir.appendingPathComponent(".postprocess.lock")) else {
            throw MeetingPipelineState.conflictingState
        }
        try validate(dir, editing: editing)
        return try Self(directory: dir, editing: editing, lease: lease, archive: archive,
                        processing: processing, snapshot: fingerprints(dir))
    }
    private static func validate(_ dir: URL, editing: Bool) throws {
        guard ArchiveBacklog.isFinished(dir) else {
            throw TranscriptionFailure("Finish or recover the recording before changing its transcript. Active audio is preserved.")
        }
        if editing {
            let receipt = dir.appendingPathComponent("archive-receipt.json")
            guard !FileManager.default.fileExists(atPath: receipt.path),
                  (try? FileManager.default.destinationOfSymbolicLink(atPath: receipt.path)) == nil else { throw revisionRequired }
            let state = try MeetingPipelineState.load(dir)
            guard state.delivery.count == 0, state.notesRecovery == nil else { throw revisionRequired }
        }
    }
    private static func fingerprints(_ dir: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for name in files {
            let file = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path)
                || (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) != nil {
                result[name] = AudioRetention.digest(try ArchiveBacklog.read(file))
            }
        }
        return result
    }
    func validateUnchanged() throws {
        try Self.validate(directory, editing: editing)
        guard try Self.fingerprints(directory) == snapshot else { throw MeetingPipelineState.conflictingState }
    }
}
