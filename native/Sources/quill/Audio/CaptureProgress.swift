import Foundation

/// Counts only buffers successfully written to disk. Digital silence still counts.
/// An audio callback without a successful write must never look like capture progress.
final class CaptureProgress: @unchecked Sendable {
    struct Snapshot: Sendable {
        var firstWrite: Date?
        var lastWrite: Date?
        var frames: Int64 = 0
        var duration: Double = 0
        var failure: String?
    }
    private let lock = NSLock()
    private var value = Snapshot()
    var snapshot: Snapshot { lock.withLock { value } }
    func reset() { lock.withLock { value = Snapshot() } }
    func wrote(frames: Int64, sampleRate: Double, at date: Date = Date()) {
        guard frames > 0, sampleRate > 0 else { return }
        lock.withLock {
            if value.firstWrite == nil { value.firstWrite = date }
            value.lastWrite = date
            value.frames += frames
            value.duration += Double(frames) / sampleRate
        }
    }
    func failed(_ reason: String) { lock.withLock { value.failure = reason } }
}

struct CaptureSegment: Codable, Sendable {
    let source: String
    let file: String
    var started_at: Double
    var ended_at: Double?
    var frames_written: Int64 = 0
    var duration_seconds: Double = 0
    var offset_ms: Int = 0
}

struct CaptureGap: Codable, Sendable {
    let source: String
    let start_ms: Int
    var end_ms: Int
    let reason: String
}

/// Used by the live session's one-second checkpoint. Restart attempts rotate
/// files; they never reopen or overwrite a previous capture segment.
struct CaptureRecovery {
    private(set) var segments: [CaptureSegment] = []
    private(set) var gaps: [CaptureGap] = []
    private var active: [String: Int] = [:]
    private var attempts: [String: Int] = [:]
    private var nextAttempt: [String: Double] = [:]
    private var pendingGap: [String: Int] = [:]
    let origin: Double

    init(origin: Double) { self.origin = origin }
    mutating func begin(source: String, file: String, at date: Date) {
        active[source] = segments.count
        segments.append(CaptureSegment(source: source, file: file, started_at: date.timeIntervalSince1970,
                                       offset_ms: max(0, Int((date.timeIntervalSince1970 - origin) * 1000))))
    }
    mutating func observe(source: String, progress: CaptureProgress.Snapshot) {
        guard let index = active[source] else { return }
        if let first = progress.firstWrite {
            segments[index].started_at = first.timeIntervalSince1970
            segments[index].offset_ms = max(0, Int((first.timeIntervalSince1970 - origin) * 1000))
            if let gap = pendingGap.removeValue(forKey: source) {
                gaps[gap].end_ms = max(gaps[gap].start_ms, segments[index].offset_ms)
            }
        }
        segments[index].frames_written = progress.frames
        segments[index].duration_seconds = progress.duration
    }
    func problem(source: String, progress: CaptureProgress.Snapshot, at date: Date) -> String? {
        guard let index = active[source] else { return nil }
        if progress.failure != nil { return "capture_failed" }
        let time = date.timeIntervalSince1970
        let last = progress.lastWrite?.timeIntervalSince1970 ?? segments[index].started_at
        if time - last >= 10 { return "buffers_stalled" }
        if let first = progress.firstWrite, time - first.timeIntervalSince1970 - progress.duration >= 10 {
            return "frame_coverage_shortfall"
        }
        return nil
    }
    /// Called before stopping an affected stream. The unaffected stream keeps running.
    mutating func rotate(source: String, progress: CaptureProgress.Snapshot, at date: Date) -> String? {
        observe(source: source, progress: progress)
        guard let reason = problem(source: source, progress: progress, at: date),
              (attempts[source] ?? 0) < 3, date.timeIntervalSince1970 >= (nextAttempt[source] ?? 0),
              let index = active[source] else { return nil }
        let boundary = date.timeIntervalSince1970
        segments[index].ended_at = boundary
        if pendingGap[source] == nil {
            // A cumulative shortfall doesn't locate the lost frames. Mark the
            // entire affected segment as uncertain rather than invent a precise gap.
            let missing = segments[index].started_at + (reason == "frame_coverage_shortfall" ? 0 : progress.duration)
            pendingGap[source] = gaps.count
            gaps.append(CaptureGap(source: source, start_ms: max(0, Int((missing - origin) * 1000)),
                                   end_ms: max(0, Int((boundary - origin) * 1000)), reason: reason))
        }
        let count = (attempts[source] ?? 0) + 1
        attempts[source] = count
        nextAttempt[source] = boundary + 15
        active.removeValue(forKey: source)
        return "\(source)-\(count + 1).caf"
    }
    mutating func finish(source: String, progress: CaptureProgress.Snapshot, at date: Date) {
        observe(source: source, progress: progress)
        if let index = active.removeValue(forKey: source) {
            segments[index].ended_at = date.timeIntervalSince1970
            let missing = segments[index].started_at + progress.duration
            if pendingGap[source] == nil, date.timeIntervalSince1970 - missing >= 2 {
                gaps.append(CaptureGap(source: source, start_ms: max(0, Int((missing - origin) * 1000)),
                                       end_ms: max(0, Int((date.timeIntervalSince1970 - origin) * 1000)), reason: "incomplete_at_stop"))
            }
        }
        if let gap = pendingGap.removeValue(forKey: source) {
            gaps[gap].end_ms = max(gaps[gap].end_ms, Int((date.timeIntervalSince1970 - origin) * 1000))
        }
    }
}
