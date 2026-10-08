import Foundation

/// Text delivery and verified local export. This stage never starts capture or
/// speech recognition and cannot bypass a permanent error or the AI budget.
actor MeetingDeliveryStage {
    enum Result: Sendable { case skipped, saved, failed(DeliveryFailure) }
    private var busy = false
    private let activityLockPath: URL
    private let saveArchive: @Sendable (URL) async throws -> Void
    private let onSaved: @Sendable (RecentMeeting) -> Void
    init(activityLockPath: URL, saveArchive: @escaping @Sendable (URL) async throws -> Void,
         onSaved: @escaping @Sendable (RecentMeeting) -> Void = { meeting in
             notifyUser(title: "Notes ready", body: meeting.title, category: .notesReady, context: ["meetingID": meeting.id])
         }) {
        self.activityLockPath = activityLockPath; self.saveArchive = saveArchive; self.onSaved = onSaved
    }
    func deliver(_ dir: URL, now: TimeInterval) async -> Result {
        guard !busy, ArchiveBacklog.isFinished(dir) else { return .skipped }
        busy = true; defer { busy = false }
        do {
            let lease = try HelperWorkLease.acquire(at: activityLockPath)
            defer { withExtendedLifetime(lease) {} }
            let item = ArchiveBacklog.inspect(dir)
            guard item.pending else { return .skipped }
            try ArchiveBacklog.reserve(item, now: now)
            var state = try MeetingPipelineState.load(dir, inspected: item, now: now)
            state.stage = .delivering; state.updatedAt = now; try state.write(dir)
            try await saveArchive(dir)
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("archive-retry.json"))
            MeetingLog.append(dir, "Gateway Meetings archive saved and read back")
            let saved = ArchiveBacklog.inspect(dir)
            if saved.state == .saved || (saved.state == .needsReview && saved.reason.hasPrefix("Notes and transcript saved")) {
                let meeting = RecentMeeting.make(saved)
                onSaved(meeting)
            }
            MeetingRetention.apply(dir)
            return .saved
        } catch {
            do { try ArchiveBacklog.recordFailure(error, directory: dir) }
            catch { MeetingLog.append(dir, "Could not persist the save failure. Local files preserved.") }
            let failure = DeliveryFailure.classify(error)
            MeetingLog.append(dir, "archive failed [\(failure.code)]: \(failure.detail); recording and transcript preserved. \(failure.retryable ? "Automatic retry scheduled." : "Review required before another attempt.")")
            return .failed(failure)
        }
    }
}

/// Retention remains independent and verifies source artifacts on every removal.
enum MeetingRetention {
    static func apply(_ dir: URL) {
        guard (try? ArchiveBacklog.object(dir.appendingPathComponent("meta.json"))["text_only_revision"] as? Bool) != true,
              Config.mayAutomaticallyDeleteAudio(dir), !AudioRetention.explicitlyRemoved(dir) else { return }
        do {
            let count = try AudioRetention.deleteAfterVerification(dir)
            if count > 0 { MeetingLog.append(dir, "Audio retention: verified text and notes; removed \(count) audio track(s)") }
        } catch { MeetingLog.append(dir, "Audio retention: \(error)") }
    }
}

enum MeetingLog {
    static func append(_ dir: URL, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = dir.appendingPathComponent("transcribe.log")
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else { try? Data(line.utf8).write(to: url) }
    }
}
