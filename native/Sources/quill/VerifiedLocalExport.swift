import Foundation

/// Retries only the documents already proven by a complete saved receipt.
/// No transport, capability handshake, provider or credential dependency.
enum VerifiedLocalExport {
    static func failure(attempts: Int) -> DeliveryFailure {
        DeliveryFailure(code: attempts >= 3 ? "local_export_retry_limit" : "local_export_failed",
            detail: attempts >= 3
                ? "Notes are saved to your Gateway. Saving them on this Mac stopped after three attempts. Check the notes folder, then retry saving notes."
                : "Notes are saved to your Gateway but could not be saved on this Mac. Check the notes folder. Local saving will retry up to three times.",
            retryable: attempts < 3, completionAttempted: false)
    }
    /// Returns false when an automatic attempt is not due. Explicit retries
    /// preserve all counters and never authorize another model completion.
    static func perform(_ dir: URL, activityLockPath: URL = HelperWorkLease.path,
                        now: Double = Date().timeIntervalSince1970, explicit: Bool = false) throws -> Bool {
        let lease = try HelperWorkLease.acquire(at: activityLockPath)
        defer { withExtendedLifetime(lease) {} }
        guard let lock = try AppRunLock.acquire(at: dir.appendingPathComponent("archive.lock")) else { throw MeetingPipelineState.conflictingState }
        defer { withExtendedLifetime(lock) {} }
        let item = ArchiveBacklog.inspect(dir)
        if item.verifiedText == .exported { return true }
        guard item.verifiedText == .archive else { throw MeetingPipelineState.invalidState }
        var state = try MeetingPipelineState.load(dir)
        var attempt = state.localExport ?? .init()
        guard attempt.count < 1000 else { throw failure(attempts: attempt.count) }
        guard explicit || attempt.mayAttempt(at: now) else { return false }
        attempt.count += 1; attempt.nextAttemptAt = now + ArchiveBacklog.Retry.delay(attempt: attempt.count)
        attempt.lastError = nil; attempt.lastErrorAt = nil
        state.localExport = attempt; state.reconcile(item, now: now); state.updatedAt = now
        try state.write(dir)
        do {
            try GatewayArchive.exportVerifiedReceipt(dir)
            let saved = ArchiveBacklog.inspect(dir)
            guard saved.verifiedText == .exported else { throw MeetingPipelineState.invalidState }
            state = try MeetingPipelineState.load(dir)
            state.reconcile(saved, now: now); try state.write(dir)
            return true
        } catch {
            // A progress-write conflict cannot invalidate already saved files.
            if ArchiveBacklog.inspect(dir).verifiedText == .exported { throw error }
            throw try persistFailure(dir, now: now, reserve: false)
        }
    }
    /// Called after a remote callback saved a verified receipt but failed its
    /// first disk export. The remote reservation is retained as history.
    static func recordFailedAttempt(_ dir: URL, activityLockPath: URL, now: Double) throws -> DeliveryFailure {
        let lease = try HelperWorkLease.acquire(at: activityLockPath)
        defer { withExtendedLifetime(lease) {} }
        guard let lock = try AppRunLock.acquire(at: dir.appendingPathComponent("archive.lock")) else { throw MeetingPipelineState.conflictingState }
        defer { withExtendedLifetime(lock) {} }
        guard ArchiveBacklog.inspect(dir).verifiedText == .archive else { throw MeetingPipelineState.conflictingState }
        return try persistFailure(dir, now: now, reserve: true)
    }
    private static func persistFailure(_ dir: URL, now: Double, reserve: Bool) throws -> DeliveryFailure {
        var state = try MeetingPipelineState.load(dir)
        var attempt = state.localExport ?? .init()
        if reserve {
            guard attempt.count < 1000 else { throw MeetingPipelineState.invalidState }
            attempt.count += 1; attempt.nextAttemptAt = now + ArchiveBacklog.Retry.delay(attempt: attempt.count)
        }
        let issue = failure(attempts: attempt.count)
        attempt.lastError = issue; attempt.lastErrorAt = now; state.localExport = attempt
        state.reconcile(ArchiveBacklog.inspect(dir), now: now)
        state.stage = issue.retryable ? .delivered : .needsAttention; state.updatedAt = now
        try state.write(dir)
        MeetingLog.append(dir, "Local export failed [\(issue.code)]. Gateway receipt and paid attempt history preserved.")
        return issue
    }
}
