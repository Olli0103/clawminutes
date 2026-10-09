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
        var configurationChanged = false
        func recentlyWriting(at date: Date) -> Bool {
            frames > 0 && failure == nil && !configurationChanged
                && lastWrite.map { date.timeIntervalSince($0) >= 0 && date.timeIntervalSince($0) < 3 } == true
        }
    }
    private let lock = NSLock()
    private var value = Snapshot()
    private var epoch: UInt64 = 0
    var currentEpoch: UInt64 { lock.withLock { epoch } }
    var snapshot: Snapshot { lock.withLock { value } }
    func reset() { lock.withLock { epoch &+= 1; value = Snapshot() } }
    /// File rollover keeps the engine epoch and any concurrent device event.
    func nextChunk() {
        lock.withLock {
            value = Snapshot(failure: value.failure, configurationChanged: value.configurationChanged)
        }
    }
    func wrote(frames: Int64, sampleRate: Double, at date: Date = Date()) {
        guard frames > 0, sampleRate > 0 else { return }
        lock.withLock {
            if value.firstWrite == nil { value.firstWrite = date }
            value.lastWrite = date
            value.frames += frames
            value.duration += Double(frames) / sampleRate
        }
    }
    func deviceChanged(epoch expected: UInt64? = nil) {
        lock.withLock {
            guard expected == nil || expected == epoch else { return }
            value.configurationChanged = true
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
    /// Set only after the recorder closes the file, never when recovery is merely requested.
    var closed: Bool? = nil
    var rotation_pending: Bool? = nil
    var continuous_clock: Bool? = nil
    var timing_uncertain: Bool? = nil
}

enum CaptureManifest {
    static let maximumSegments = 1024
    static let healthyRotationLimit = maximumSegments - 16
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
    private var fileNumbers: [String: Int] = [:]
    private var attemptTimes: [String: [Double]] = [:]
    private var nextAttempt: [String: Double] = [:]
    private var pendingGap: [String: Int] = [:]
    private var chunkGaps: [String: Int] = [:]
    let origin: Double

    init(origin: Double) { self.origin = origin }
    mutating func begin(source: String, file: String, at date: Date) {
        fileNumbers[source] = max(fileNumbers[source] ?? 1, Int(file.dropFirst(source.count + 1).dropLast(4)) ?? 1)
        active[source] = segments.count
        segments.append(CaptureSegment(source: source, file: file, started_at: date.timeIntervalSince1970,
                                       offset_ms: max(0, Int((date.timeIntervalSince1970 - origin) * 1000))))
    }
    mutating func observe(source: String, progress: CaptureProgress.Snapshot) {
        guard let index = active[source] else { return }
        if let first = progress.firstWrite, segments[index].continuous_clock != true {
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
        if progress.configurationChanged { return "device_changed" }
        if progress.failure != nil { return "capture_failed" }
        let time = date.timeIntervalSince1970
        let last = progress.lastWrite?.timeIntervalSince1970 ?? segments[index].started_at
        if time - last >= 10 { return "buffers_stalled" }
        if let first = progress.firstWrite, time - first.timeIntervalSince1970 - progress.duration >= 10 {
            return "frame_coverage_shortfall"
        }
        return nil
    }
    func recoveryLimited(source: String, at date: Date) -> Bool {
        (attemptTimes[source] ?? []).filter { date.timeIntervalSince1970 - $0 < 600 }.count >= 3
    }
    /// Called before stopping an affected stream. The unaffected stream keeps running.
    mutating func rotate(source: String, progress: CaptureProgress.Snapshot, at date: Date) -> String? {
        observe(source: source, progress: progress)
        guard let reason = problem(source: source, progress: progress, at: date),
              !recoveryLimited(source: source, at: date), date.timeIntervalSince1970 >= (nextAttempt[source] ?? 0),
              segments.count < CaptureManifest.maximumSegments,
              let index = active[source] else { return nil }
        let boundary = date.timeIntervalSince1970
        segments[index].ended_at = boundary
        if reason == "frame_coverage_shortfall" { segments[index].timing_uncertain = true }
        if pendingGap[source] == nil {
            // A cumulative shortfall doesn't locate the lost frames. Mark the
            // entire affected segment as uncertain rather than invent a precise gap.
            let missing = segments[index].started_at + (reason == "frame_coverage_shortfall" ? 0 : progress.duration)
            pendingGap[source] = gaps.count
            gaps.append(CaptureGap(source: source, start_ms: max(0, Int((missing - origin) * 1000)),
                                   end_ms: max(0, Int((boundary - origin) * 1000)), reason: reason))
        }
        attemptTimes[source] = (attemptTimes[source] ?? []).filter { boundary - $0 < 600 } + [boundary]
        nextAttempt[source] = boundary + 15
        active.removeValue(forKey: source)
        return nextFilename(source: source)
    }
    mutating func nextFilename(source: String) -> String {
        let next = (fileNumbers[source] ?? 1) + 1
        fileNumbers[source] = next
        return "\(source)-\(next).caf"
    }
    /// Persist this provisional manifest before the writer can switch. Its
    /// uncertain boundary survives a crash until the exact handoff is committed.
    mutating func planChunk(source: String, file: String, progress: CaptureProgress.Snapshot) throws {
        guard let index = active[source], segments.count < CaptureManifest.healthyRotationLimit,
              !segments.contains(where: { $0.file == file }), progress.frames > 0 else { throw MeetingPipelineState.conflictingState }
        observe(source: source, progress: progress)
        let boundary = segments[index].started_at + progress.duration
        let offset = max(0, Int(((boundary - origin) * 1000).rounded()))
        segments.append(CaptureSegment(source: source, file: file, started_at: boundary, offset_ms: offset,
                                       rotation_pending: true, continuous_clock: true))
        chunkGaps[file] = gaps.count
        gaps.append(CaptureGap(source: source, start_ms: offset, end_ms: offset, reason: "rotation_pending"))
    }
    mutating func commitChunk(source: String, file: String, closed: CaptureProgress.Snapshot) throws -> String {
        guard let old = active[source], let next = segments.firstIndex(where: { $0.source == source && $0.file == file && $0.rotation_pending == true }) else {
            throw MeetingPipelineState.conflictingState
        }
        observe(source: source, progress: closed)
        let boundary = segments[old].started_at + closed.duration
        segments[old].ended_at = boundary; segments[old].closed = true
        segments[next].started_at = boundary
        segments[next].offset_ms = max(0, Int(((boundary - origin) * 1000).rounded()))
        segments[next].rotation_pending = nil
        active[source] = next
        if let gap = chunkGaps.removeValue(forKey: file) {
            gaps.remove(at: gap)
            for key in Array(pendingGap.keys) where pendingGap[key]! > gap { pendingGap[key]! -= 1 }
            for key in Array(chunkGaps.keys) where chunkGaps[key]! > gap { chunkGaps[key]! -= 1 }
        }
        if let last = closed.lastWrite, abs(last.timeIntervalSince1970 - boundary) >= 2 {
            segments[old].timing_uncertain = true
            gaps.append(CaptureGap(source: source, start_ms: segments[old].offset_ms,
                end_ms: segments[next].offset_ms, reason: "frame_coverage_shortfall"))
            segments[next].continuous_clock = nil // Re-anchor the next file to its observed first buffer.
        }
        return segments[old].file
    }
    /// No handoff occurred, so the declared empty file has no speech. Keep it
    /// declared with an explicit marker rather than hiding an uncertain artifact.
    mutating func failedChunk(source: String, file: String) {
        if let index = segments.firstIndex(where: { $0.file == file && $0.rotation_pending == true }) {
            segments[index].ended_at = segments[index].started_at
            segments[index].closed = true
        }
    }
    mutating func sealClosedSegments(source: String) -> [String] {
        var files: [String] = []
        for index in segments.indices where segments[index].source == source
            && segments[index].ended_at != nil && segments[index].closed != true {
            segments[index].closed = true
            if segments[index].frames_written > 0 { files.append(segments[index].file) }
        }
        return files
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
