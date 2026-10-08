import Foundation

/// Post-recording pipeline: a serial queue of session folders to transcribe.
/// mic.caf → "me", system.caf → "them"; each track's segments are shifted by
/// its start offset, merged by timestamp, and written as transcript.json
/// (canonical) plus transcript.md (readable). The filesystem is the queue —
/// Recovery scans use persisted attempt budgets at launch and while running.
/// Recognition, delivery and retention have separate implementations. A failure
/// stays attached to its meeting and never blocks later jobs.
actor TranscriptionCoordinator {
    enum Status: Sendable {
        case idle
        case transcribing(session: String, queued: Int)
        case postprocessing(session: String, queued: Int)
        case failed(session: String)
        case archivePending(session: String)
        case needsReview(session: String, reason: String)
    }

    private var queue: [URL] = []
    private var draining = false
    private var activeTranscription: URL?
    private var activeRoot: URL?
    private let clock: @Sendable () -> Double
    private let localModelAvailable: @Sendable () -> Bool
    private let transcriber: RecordingTranscriber
    private var lastIssue: Status?
    private var statusHandler: (@Sendable (Status) -> Void)?
    private let activityLockPath: URL
    private let delivery: MeetingDeliveryStage
    private var checkingBacklog = false
    private var backlogIndex = ArchiveBacklogIndex()
    private var meetingsHandler: (@Sendable ([RecentMeeting]) -> Void)?
    func setMeetingsHandler(_ handler: @escaping @Sendable ([RecentMeeting]) -> Void) { meetingsHandler = handler }
    private var backlogHandler: (@Sendable (Int) -> Void)?

    struct BacklogReport: Codable, Sendable {
        var attempted = 0
        var pending = 0
        var transcriptionPending = 0
        var needsReview = 0
        var busy = false
    }

    func setBacklogHandler(_ handler: @escaping @Sendable (Int) -> Void) { backlogHandler = handler }

    /// Reconcile text delivery while the app stays running. Never starts capture or inference.
    func retryArchiveBacklog(root: URL, force: Bool = false, capabilities: GatewayCapabilities? = nil,
                             now: TimeInterval = Date().timeIntervalSince1970) async throws -> BacklogReport {
        guard !checkingBacklog else { return BacklogReport(busy: true) }
        checkingBacklog = true
        defer { checkingBacklog = false }
        var report = BacklogReport()
        if force {
            for item in try backlogIndex.scan(root: root) { try ArchiveBacklog.rearmConnection(item, now: now, capabilities: capabilities) }
        }
        let items = try backlogIndex.scan(root: root)
        for item in items where item.pending && report.attempted < 5 {
            if !force, let retry = item.retry, retry.nextAttemptAt > now { continue }
            if await runHook(for: item.directory, now: now) { report.attempted += 1 }
        }
        let remaining = try backlogIndex.scan(root: root)
        let lease = try HelperWorkLease.acquire(at: activityLockPath)
        defer { withExtendedLifetime(lease) {} }
        for item in remaining where item.state != .recording && item.state != .fixture && activeTranscription != item.directory {
            do {
                var state = try MeetingPipelineState.load(item.directory, inspected: item, now: now)
                state.reconcile(item, now: now); try state.write(item.directory)
            } catch { FileHandle.standardError.write(Data("Meeting recovery state could not be reconciled. Files preserved.\n".utf8)) }
        }
        report.pending = remaining.filter(\.pending).count
        report.transcriptionPending = remaining.filter { $0.state == .transcriptionPending }.count
        report.needsReview = remaining.filter { $0.state == .needsReview }.count
        backlogHandler?(report.pending)
        meetingsHandler?(remaining.reversed().filter { $0.state != .fixture }.map { RecentMeeting.make($0) })
        if let review = remaining.first(where: { $0.state == .needsReview }) {
            lastIssue = .needsReview(session: review.directory.lastPathComponent, reason: review.reason)
        } else if let speech = remaining.first(where: { $0.state == .transcriptionPending && $0.reason != "Waiting to transcribe" }) {
            lastIssue = .needsReview(session: speech.directory.lastPathComponent, reason: speech.reason)
        } else if let pending = remaining.first(where: \.pending) {
            lastIssue = .archivePending(session: pending.directory.lastPathComponent)
        } else {
            switch lastIssue { case .archivePending, .needsReview: lastIssue = nil; default: break }
        }
        if !draining { publish(lastIssue ?? .idle) }
        return report
    }

    /// Retries finished local recordings without a relaunch. No capture starts,
    /// and missing-model/credential causes wait for their explicit remedy.
    @discardableResult func retryPendingTranscriptions(root: URL, modelInstalled: Bool = false, credentialsInstalled: Bool = false) throws -> Int {
        guard Config.transcriptionEnabled() else { return 0 }
        let lease = try HelperWorkLease.acquire(at: activityLockPath)
        defer { withExtendedLifetime(lease) {} }
        activeRoot = root
        var added = 0
        for item in try backlogIndex.scan(root: root) where item.state == .transcriptionPending || item.state == .needsReview {
            let dir = item.directory
            guard activeTranscription != dir, !queue.contains(dir), ArchiveBacklog.isFinished(dir),
                  !FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.json").path),
                  !RecordingSession.isUnstartedAttempt(dir),
                  !AudioRetention.explicitlyRemoved(dir) else { continue }
            let initial: MeetingPipelineState
            do { initial = try MeetingPipelineState.load(dir, inspected: item, now: clock()) }
            catch {
                lastIssue = .needsReview(session: dir.lastPathComponent, reason: MeetingPipelineState.invalidState.detail)
                continue
            }
            var state = initial
            if modelInstalled || localModelAvailable() { state.localModelInstalled(at: clock()) }
            if credentialsInstalled { state.speechCredentialsInstalled(at: clock()) }
            try state.write(dir)
            guard state.mayTranscribe(at: clock()) else { continue }
            queue.append(dir); added += 1
            if added >= 5 { break }
        }
        drainIfIdle()
        return added
    }

    init(activityLockPath: URL = HelperWorkLease.path,
         clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 },
         localModelAvailable: @escaping @Sendable () -> Bool = { ParakeetEngine.modelsAvailable },
         audioDuration: @escaping @Sendable (URL) throws -> Double = AudioRetention.duration,
         saveArchive: @escaping @Sendable (URL) async throws -> Void = { try await GatewayArchive.save($0) },
         makeEngine: @escaping @Sendable (TranscriptionEngineKind, Bool) -> any TranscriptionEngine = { kind, offline in
        switch kind {
        case .parakeet: return ParakeetEngine()
        case .elevenLabs: return ElevenLabsEngine(offline: offline)
        }
    }) {
        self.clock = clock
        self.localModelAvailable = localModelAvailable
        self.activityLockPath = activityLockPath
        self.transcriber = RecordingTranscriber(activityLockPath: activityLockPath, audioDuration: audioDuration, makeEngine: makeEngine)
        self.delivery = MeetingDeliveryStage(activityLockPath: activityLockPath, saveArchive: saveArchive)
    }

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        statusHandler = handler
    }

    /// Queue a finished session. Existing transcripts can still be delivered
    /// when transcription is disabled.
    func enqueue(_ sessionDir: URL, transcriptionEnabled: Bool = Config.transcriptionEnabled()) async {
        guard transcriptionEnabled else {
            await runHook(for: sessionDir)
            return
        }
        guard !queue.contains(sessionDir), activeTranscription != sessionDir else { return }
        activeRoot = sessionDir.deletingLastPathComponent()
        queue.append(sessionDir)
        drainIfIdle()
    }

    /// Scan the recordings root for sessions that finished (meta.json exists)
    /// but were never transcribed. Folder names sort chronologically, so
    /// oldest-first is a name sort.
    @discardableResult func resumePending(root: URL, startupOwner: AppRunLock? = nil) async -> Bool {
        var workLease: HelperWorkLease?
        // The installer can still hold its lease when launchctl starts this
        // process. Wait briefly so startup recovery is not silently skipped.
        for _ in 0..<20 {
            if let acquired = try? HelperWorkLease.acquire(at: activityLockPath) { workLease = acquired; break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let workLease else {
            publish(.failed(session: "Pending meeting recovery"))
            FileHandle.standardError.write(Data("Could not resume pending meetings while helper lifecycle work is active. Files remain pending for the next launch.\n".utf8))
            return false
        }
        defer { withExtendedLifetime(workLease) {} }
        if let startupOwner {
            do { _ = try InterruptedRecordingRecovery.recover(root: root, owner: startupOwner, activityLockPath: activityLockPath) }
            catch {
                publish(.failed(session: "Interrupted meeting recovery"))
                FileHandle.standardError.write(Data("Interrupted meeting recovery failed. Files preserved; new capture remains paused.\n".utf8))
                return false
            }
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return true }

        activeRoot = root
        let fm = FileManager.default
        let pending = entries
            .filter {
                fm.fileExists(atPath: $0.appendingPathComponent("meta.json").path)
                    && ArchiveBacklog.isFinished($0)
                    && !fm.fileExists(atPath: $0.appendingPathComponent("transcript.json").path)
                    && !RecordingSession.isUnstartedAttempt($0)
                    && !AudioRetention.explicitlyRemoved($0)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for dir in pending where Config.transcriptionEnabled() && !queue.contains(dir) && activeTranscription != dir {
            do {
                var state = try MeetingPipelineState.load(dir, now: clock())
                if localModelAvailable() { state.localModelInstalled(at: clock()) }
                try state.write(dir)
                if state.mayTranscribe(at: clock()) { queue.append(dir) }
            } catch { lastIssue = .needsReview(session: dir.lastPathComponent, reason: MeetingPipelineState.invalidState.detail) }
        }
        do { _ = try await retryArchiveBacklog(root: root) }
        catch { FileHandle.standardError.write(Data("Could not check pending meeting saves. Recording files preserved.\n".utf8)) }
        if Config.deleteAudioAfterVerification() {
            for dir in entries where fm.fileExists(atPath: dir.appendingPathComponent("archive-receipt.json").path) && !AudioRetention.explicitlyRemoved(dir) {
                MeetingRetention.apply(dir)
            }
        }
        if !pending.isEmpty {
            FileHandle.standardError.write(Data(
                "resuming \(pending.count) untranscribed session(s)\n".utf8
            ))
        }
        drainIfIdle()
        return true
    }

    // MARK: -

    private func drainIfIdle() {
        guard !draining, !queue.isEmpty else { return }
        draining = true
        Task { await drain() }
    }

    private func drain() async {
        let workLease: HelperWorkLease
        do { workLease = try HelperWorkLease.acquire(at: activityLockPath) }
        catch {
            draining = false
            publish(.failed(session: queue.first?.lastPathComponent ?? "Pending meeting"))
            return // Files remain pending for the next launch; never start inference during replacement.
        }
        defer { withExtendedLifetime(workLease) {} }
        while !queue.isEmpty {
            let dir = queue.removeFirst()
            activeTranscription = dir
            var state: MeetingPipelineState?
            do {
                var current = try MeetingPipelineState.load(dir, now: clock())
                guard current.mayTranscribe(at: clock()) else {
                    lastIssue = .needsReview(session: dir.lastPathComponent, reason: current.transcription.lastError?.detail ?? "Speech recognition stopped after three attempts. Audio is retained.")
                    activeTranscription = nil
                    continue
                }
                try current.reserveTranscription(at: clock())
                try current.write(dir)
                state = current
                publish(.transcribing(session: dir.lastPathComponent, queued: queue.count))
                try await transcribe(dir)
                state?.stage = .transcribed; state?.transcription.lastError = nil; state?.updatedAt = clock()
                try state?.write(dir)
                let cleanupOptions = PostProcessingOptions(json: ["mode": "off"])
                if cleanupOptions.mode != .off { publish(.postprocessing(session: dir.lastPathComponent, queued: queue.count)) }
                let cleanup = await TranscriptPostProcessor.process(dir, options: cleanupOptions)
                log(dir, "postprocess: \(cleanup.status)")
                await runHook(for: dir)
                let item = backlogIndex.item(dir)
                var latest = try MeetingPipelineState.load(dir)
                latest.reconcile(item, now: clock()); try latest.write(dir)
                switch lastIssue {
                case .failed(let name), .needsReview(let name, _): if name == dir.lastPathComponent && item.state == .saved { lastIssue = nil }
                default: break
                }
            } catch {
                log(dir, "transcription failed: \(error)")
                if FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.json").path) {
                    lastIssue = .needsReview(session: dir.lastPathComponent, reason: "The transcript is ready, but meeting progress could not be saved. Local files are preserved.")
                } else if var state {
                    state.transcriptionFailed(error, at: clock())
                    try? state.write(dir)
                    lastIssue = .needsReview(session: dir.lastPathComponent,
                        reason: state.transcription.lastError?.detail ?? "Speech recognition did not finish. Audio is retained.")
                } else {
                    lastIssue = .needsReview(session: dir.lastPathComponent, reason: MeetingPipelineState.invalidState.detail)
                }
            }
            activeTranscription = nil
        }
        await transcriber.release()
        if let root = activeRoot { try? await retryArchiveBacklog(root: root) }
        publish(lastIssue ?? .idle)
        draining = false
        // An enqueue that landed between the loop exiting and the release
        // finishing would otherwise sit until the next enqueue.
        drainIfIdle()
    }

    func transcribe(_ dir: URL, detectSpeakers: Bool = Config.speakerDetection(), remoteSpeakerCount: Int? = nil,
                    engineOverride: TranscriptionEngineKind? = nil, offline: Bool = false, learnVoiceMemory: Bool = true, allowAudioLinks: Bool = false) async throws {
        try await transcriber.transcribe(dir, detectSpeakers: detectSpeakers, remoteSpeakerCount: remoteSpeakerCount,
                                         engineOverride: engineOverride, offline: offline, learnVoiceMemory: learnVoiceMemory, allowAudioLinks: allowAudioLinks)
    }

    /// Delivery owns its lease, retry reservation, receipt verification and retention.
    @discardableResult private func runHook(for dir: URL, now: TimeInterval = Date().timeIntervalSince1970) async -> Bool {
        switch await delivery.deliver(dir, now: now) {
        case .skipped: return false
        case .saved:
            if case .archivePending(let pending) = lastIssue, pending == dir.lastPathComponent { lastIssue = nil }
        case .failed(let failure):
            lastIssue = failure.retryable ? .archivePending(session: dir.lastPathComponent)
                : .needsReview(session: dir.lastPathComponent, reason: failure.detail)
        }
        if !draining { publish(lastIssue ?? .idle) }
        return true
    }

    private func log(_ dir: URL, _ message: String) { MeetingLog.append(dir, message) }

    private func publish(_ status: Status) {
        if let root = activeRoot, let items = try? backlogIndex.scan(root: root) {
            meetingsHandler?(items.reversed().filter { $0.state != .fixture }.map { RecentMeeting.make($0, active: $0.directory == activeTranscription) })
        }
        statusHandler?(status)
    }
}
