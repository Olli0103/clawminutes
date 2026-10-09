import Foundation

/// Historical cleanup never changes the future-only preference.
enum AudioCleanup {
    struct Row: Identifiable, Sendable {
        let meeting: RecentMeeting
        let plan: AudioRetention.Plan?
        let issue: String?
        var alreadyRemoved = false
        var id: String { meeting.id }
    }
    static func review(_ meetings: [RecentMeeting], measure: (URL) throws -> Double = AudioRetention.duration) throws -> [Row] {
        try meetings.map { meeting in
            try Task.checkCancellation()
            do {
                let plan = try AudioRetention.review(meeting.directory, measure: measure)
                return Row(meeting: meeting, plan: plan, issue: plan == nil ? "Audio already removed." : nil, alreadyRemoved: plan == nil)
            } catch is CancellationError { throw CancellationError() }
            catch { return Row(meeting: meeting, plan: nil, issue: detail(error)) }
        }
    }
    static func detail(_ error: Error) -> String {
        if let known = error as? TranscriptionFailure { return known.description }
        return "Audio could not be fully verified or removed. Check this meeting's files before reviewing again."
    }
    static func defaultSelection(_ rows: [Row]) -> Set<String> {
        Set(rows.filter { !$0.alreadyRemoved && !($0.plan?.remaining.isEmpty ?? true) }.map(\.id))
    }
    static func explanation(_ row: Row) -> String {
        if row.meeting.stage == .capturing { return "This meeting is still recording. Finish it before deleting its audio." }
        if row.meeting.canVerifyLegacyReceipt { return "Confirm the saved notes first. Open this meeting and choose Find my notes." }
        let issue = (row.issue ?? "").lowercased()
        if issue.contains("gaps") || issue.contains("coverage") || issue.contains("boundaries") {
            return "The recording may be incomplete. Its audio is kept so you can review the transcript."
        }
        if issue.contains("no teams speech") { return "No Teams speech was found in the transcript. Review the recording before removing its audio." }
        return "Saved notes and a complete transcript could not be verified. Recover this meeting before deleting its audio."
    }
    static func execute(_ plan: AudioRetention.Plan, activityLockPath: URL = HelperWorkLease.path,
        measure: (URL) throws -> Double = AudioRetention.duration) throws -> Int {
        let work = try HelperWorkLease.acquire(at: activityLockPath)
        defer { withExtendedLifetime(work) {} }
        return try AudioRetention.deleteAfterVerification(URL(fileURLWithPath: plan.directory), measure: measure, expected: plan, policy: .explicitExisting)
    }
}
