import Foundation

/// An explicit user rename changes presentation metadata only. It never renames
/// folders, edits transcript text, resets attempts or triggers another delivery.
enum MeetingTitleOverride {
    static func save(_ title: String, in directory: URL) throws {
        guard let title = TeamsMeetingTitle.clean(title), !title.isEmpty else {
            throw TranscriptionFailure("Enter a meeting title.")
        }
        guard let ownership = try AppRunLock.acquire(at: directory.appendingPathComponent("archive.lock")) else {
            throw MeetingPipelineState.conflictingState
        }
        defer { withExtendedLifetime(ownership) {} }
        let file = directory.appendingPathComponent("meta.json")
        var meta = try ArchiveBacklog.object(file)
        guard meta["status"] as? String != "recording" else { throw MeetingPipelineState.conflictingState }
        meta["meeting_title_override"] = title
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
    }
}
