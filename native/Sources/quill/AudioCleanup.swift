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
    static func execute(_ plan: AudioRetention.Plan, activityLockPath: URL = HelperWorkLease.path,
        measure: (URL) throws -> Double = AudioRetention.duration) throws -> Int {
        let work = try HelperWorkLease.acquire(at: activityLockPath)
        defer { withExtendedLifetime(work) {} }
        return try AudioRetention.deleteAfterVerification(URL(fileURLWithPath: plan.directory), measure: measure, expected: plan, policy: .explicitExisting)
    }
}
