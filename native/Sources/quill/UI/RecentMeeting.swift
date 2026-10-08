import Foundation

/// Value snapshot for the menu and detail window. Opening documents uses only
/// verified export bindings; private audio folders are a separate action.
struct RecentMeeting: Identifiable, Sendable {
    let directory: URL
    let title: String
    let started: Date?
    let stage: MeetingPipelineState.Stage
    let issue: DeliveryFailure?
    let detail: String
    let notes: URL?
    let transcript: URL?
    var id: String { directory.path }
    var ready: Bool { notes != nil }
    var needsAttention: Bool { stage == .needsAttention || stage == .waitingForModel }
    var statusTitle: String {
        switch stage {
        case .capturing: return "Recording"
        case .recorded, .interrupted: return "Waiting to transcribe"
        case .waitingForModel: return "Local model needed"
        case .transcribing: return "Transcribing"
        case .transcribed: return "Waiting to send"
        case .delivering: return "Sending"
        case .delivered: return "Saving notes"
        case .exported, .audioRemoved: return "Notes ready"
        case .needsAttention: return "Needs attention"
        }
    }
    var symbol: String {
        if needsAttention { return "exclamationmark.circle" }
        return ready ? "checkmark.circle" : (stage == .capturing ? "record.circle" : "clock")
    }
    static func make(_ item: ArchiveBacklog.Item, active: Bool = false) -> Self {
        let meta = try? ArchiveBacklog.object(item.directory.appendingPathComponent("meta.json"))
        let context = meta?["meeting_context"] as? [String: Any]
        let title = (context?["title"] as? String).flatMap(TeamsMeetingTitle.clean) ?? "Meeting"
        let started = (meta?["started"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        var state = try? MeetingPipelineState.load(item.directory, inspected: item)
        if !active { state?.reconcile(item, now: Date().timeIntervalSince1970) }
        let issue = state?.transcription.lastError ?? item.retry?.lastError
        var notes: URL?
        if item.state == .saved || (item.state == .needsReview && item.reason.hasPrefix("Notes and transcript saved")) {
            if let data = try? ArchiveBacklog.read(item.directory.appendingPathComponent("notes-export-path.txt")),
               let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                notes = URL(fileURLWithPath: path).appendingPathComponent("notes.md")
            }
        }
        let transcript = item.directory.appendingPathComponent("transcript.md")
        return Self(directory: item.directory, title: title, started: started,
            stage: state?.stage ?? .needsAttention, issue: issue,
            detail: issue?.detail ?? item.reason, notes: notes,
            transcript: readableDocument(transcript) ? transcript : nil)
    }
    static func readableDocument(_ file: URL) -> Bool {
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return false }
        return FileManager.default.isReadableFile(atPath: file.path)
    }
}
