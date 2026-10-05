import Foundation

/// One meeting recording: a timestamped folder holding two independent tracks
/// plus a meta.json written on clean stop. Independent track clocks preserve
/// source and timing evidence; audio alone does not establish participant names.
final class RecordingSession {
    private(set) var dir: URL
    private let recordingID: String
    let startedAt = Date()
    var audioStartedAt: Date { startedAt }

    private let mic = MicRecorder()
    private let system = SystemAudioRecorder()
    private lazy var capture = CaptureRecovery(origin: startedAt.timeIntervalSince1970)
    private var healthTask: Task<Void, Never>?
    private var closing = false
    private var hasStarted = false
    private var requestedEnd: Date?
    private(set) var captureWarning: String?
    private let localSpeakerName = Config.localSpeakerName()
    private let sharedMicrophone = Config.sharedMicrophone()
    private let selectedBackend = Config.transcriptionEngine()
    private let notesMode = Config.notesMode()
    private let noteTemplate = MeetingNotesSettings.selected
    private var meetingContext: MeetingContext?
    func updateMeetingContext(_ context: MeetingContext) {
        guard context.last_observed_at >= startedAt.timeIntervalSince1970 - 15,
              context.ended_observed_at.map({ $0 >= startedAt.timeIntervalSince1970 }) ?? true else { return }
        guard meetingContext == nil || meetingContext?.meeting_id == context.meeting_id else { return }
        meetingContext = context
    }
    private func addMeetingMetadata(_ meta: inout [String: Any]) {
        meta["note_template"] = noteTemplate.json
        meta["recording_id"] = recordingID
        if let meetingContext { meta["meeting_context"] = meetingContext.json }
        // Keep all segment clocks in the same fixed session timebase.
        meta["audio_started_at"] = startedAt.timeIntervalSince1970
        meta["start_offset_ms"] = Dictionary(uniqueKeysWithValues: ["mic", "system"].map { source in
            (source, capture.segments.first(where: { $0.source == source })?.offset_ms ?? 0)
        })
        meta["capture_segments"] = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(capture.segments))) ?? []
        meta["capture_gaps"] = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(capture.gaps))) ?? []
    }
    private let fixture = ProcessInfo.processInfo.environment["OPENCLAW_TEAMS_CAPTURE_FIXTURE"] == "1"
    private var seenCaptions: Set<String> = []
    private var roster: ParticipantRoster?
    private var lastRosterObservation = -Double.infinity
    private var lastRosterWrite = -Double.infinity

    func recordSpeakers(_ observation: SpeakerObservation) {
        guard observation.observed_at >= startedAt.timeIntervalSince1970 else { return }
        if let meetingContext, observation.meeting_id != meetingContext.meeting_id { return }
        if observation.source == "meeting_roster" {
            guard observation.observed_at > lastRosterObservation else { return }
            lastRosterObservation = observation.observed_at
        }
        if let text = observation.text {
            let key = observation.meeting_id + "\n" + observation.names.joined(separator: "\n") + "\n" + text
            guard seenCaptions.insert(key).inserted else { return }
        }
        let url = dir.appendingPathComponent("speaker-observations.jsonl")
        do {
            let data = try JSONEncoder().encode(observation) + Data("\n".utf8)
            if !FileManager.default.fileExists(atPath: url.path) {
                try data.write(to: url, options: .atomic)
            } else {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            }
            if observation.participants != nil || !observation.names.isEmpty {
                roster?.observe(observation, localName: localSpeakerName)
                if let roster, observation.observed_at - lastRosterWrite >= 2 {
                    try JSONEncoder().encode(roster).write(to: dir.appendingPathComponent("participants.json"), options: .atomic)
                    lastRosterWrite = observation.observed_at
                }
            }
        } catch {
            FileHandle.standardError.write(Data("speaker observation write failed: \(error)\n".utf8))
        }
    }

    private static let folderFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Create the session folder under `root` (yyyy.MM.dd-HHmm, suffixed on
    /// collision) without starting capture yet.
    init(root: URL, context: MeetingContext? = nil) throws {
        meetingContext = context?.isCurrent(at: startedAt.timeIntervalSince1970) == true ? context : nil
        let cleanSubject = meetingContext.flatMap { TeamsMeetingTitle.clean($0.title) }.map(MeetingDocuments.component) ?? "Meeting"
        let subject = cleanSubject.isEmpty ? "Meeting" : cleanSubject
        let base = Self.folderFormat.string(from: startedAt) + "_" + subject
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base)-\(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        dir = candidate
        recordingID = candidate.lastPathComponent
        capture.begin(source: "mic", file: "mic.caf", at: startedAt)
        capture.begin(source: "system", file: "system.caf", at: startedAt)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        var initial: [String: Any] = ["started": ISO8601DateFormatter().string(from: startedAt), "audio_started_at": startedAt.timeIntervalSince1970, "backend": selectedBackend, "notes_mode": notesMode, "status": "recording", "files": ["mic": "mic.caf", "system": "system.caf"], "start_offset_ms": ["mic": 0, "system": 0]]
        addMeetingMetadata(&initial)
        try JSONSerialization.data(withJSONObject: initial).write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
        roster = ParticipantRoster(audio_started_at: startedAt.timeIntervalSince1970)
        if let roster { try JSONEncoder().encode(roster).write(to: dir.appendingPathComponent("participants.json"), options: .atomic) }
    }

    /// Start both tracks. If the mic fails after the system tap started, the
    /// tap is torn down so we never run half a session silently.
    @MainActor func start() async throws {
        do {
            try await RecordingPermissions.authorizeMicrophone()
            try await system.start(writingTo: dir.appendingPathComponent("system.caf"))
            do {
                try mic.start(writingTo: dir.appendingPathComponent("mic.caf"))
                // Engine.start() can succeed without input callbacks. Do not show
                // Recording until actual microphone frames have reached disk.
                for attempt in 0..<2 {
                    let deadline = Date().addingTimeInterval(3)
                    while !mic.hasAudioFrames && Date() < deadline {
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    if mic.hasAudioFrames { break }
                    mic.stop()
                    if attempt == 0 { try mic.start(writingTo: dir.appendingPathComponent("mic.caf")) }
                }
                guard mic.hasAudioFrames else {
                    throw TranscriptionFailure("The microphone produced no audio. Check the input device in macOS Sound settings, then try Start again. The attempted capture is preserved.")
                }
                hasStarted = true
                checkpoint()
            }
            catch { mic.stop(); await system.stopAsync(); throw error }
        } catch {
            let url = dir.appendingPathComponent("meta.json")
            if let data = try? Data(contentsOf: url), var meta = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                meta["status"] = "start_failed"
                meta["start_failure_reason"] = String(describing: error)
                if fixture { meta["fixture"] = true }
                if let updated = try? JSONSerialization.data(withJSONObject: meta) { try? updated.write(to: url, options: .atomic) }
            }
            throw error
        }
    }

    static func isUnstartedAttempt(_ dir: URL) -> Bool {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
              let meta = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              meta["status"] as? String == "start_failed" else { return false }
        return !["mic.caf", "system.caf"].contains { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    @MainActor func checkpoint() {
        capture.observe(source: "mic", progress: mic.progress.snapshot)
        capture.observe(source: "system", progress: system.progress.snapshot)
        writeCheckpoint()
        guard hasStarted, !closing, healthTask == nil else { return }
        healthTask = Task { [weak self] in
            guard let self else { return }
            defer { healthTask = nil }
            await checkCaptureHealth()
        }
    }

    private func writeCheckpoint() {
        let micStart = mic.firstBufferAt ?? startedAt
        let systemStart = system.firstBufferAt ?? startedAt
        let earliest = min(micStart, systemStart)
        var meta: [String: Any] = ["started": ISO8601DateFormatter().string(from: startedAt), "audio_started_at": earliest.timeIntervalSince1970, "backend": selectedBackend, "notes_mode": notesMode, "status": "recording", "checkpoint_at": Date().timeIntervalSince1970, "files": ["mic": "mic.caf", "system": "system.caf"], "start_offset_ms": ["mic": Int(micStart.timeIntervalSince(startedAt)*1000), "system": Int(systemStart.timeIntervalSince(startedAt)*1000)], "shared_microphone": sharedMicrophone]
        addMeetingMetadata(&meta)
        if fixture { meta["fixture"] = true; meta["capture_scope"] = "global_system_fixture" }
        if let data = try? JSONSerialization.data(withJSONObject: meta) { try? data.write(to: dir.appendingPathComponent("meta.json"), options: .atomic) }
    }

    @MainActor private func checkCaptureHealth() async {
        for source in ["mic", "system"] {
            guard !closing, !Task.isCancelled else { return }
            let progress = source == "mic" ? mic.progress.snapshot : system.progress.snapshot
            guard capture.problem(source: source, progress: progress, at: Date()) != nil else { continue }
            captureWarning = "\(source == "mic" ? "Microphone" : "Teams audio") interrupted. Captured audio is preserved; checking recovery."
            guard let filename = capture.rotate(source: source, progress: progress, at: Date()) else {
                captureWarning = "\(source == "mic" ? "Microphone" : "Teams audio") is incomplete. Audio is kept for review."
                continue
            }
            // Persist the old segment before awaiting any capture operation.
            writeCheckpoint()
            if source == "mic" { mic.stop() } else { await system.stopAsync() }
            guard !closing, !Task.isCancelled else { return }
            capture.begin(source: source, file: filename, at: Date())
            writeCheckpoint()
            do {
                if source == "mic" { try mic.start(writingTo: dir.appendingPathComponent(filename)) }
                else { try await system.start(writingTo: dir.appendingPathComponent(filename)) }
                captureWarning = "Audio capture restarted. A gap is marked in the transcript; audio is kept for review."
            } catch {
                if source == "mic" { mic.progress.failed("restart_failed") }
                else { system.progress.failed("restart_failed") }
                captureWarning = "Audio recovery failed. Captured audio is kept; check the input device and permissions."
            }
        }
        writeCheckpoint()
    }

    @MainActor func stopAsync() async {
        closing = true
        requestedEnd = Date()
        healthTask?.cancel()
        await healthTask?.value
        mic.stop()
        await system.stopAsync()
        stop()
    }

    /// Stop both tracks and write meta.json.
    func stop() {
        closing = true
        healthTask?.cancel()
        mic.stop()
        system.stop()

        let ended = requestedEnd ?? Date()
        capture.finish(source: "mic", progress: mic.progress.snapshot, at: ended)
        capture.finish(source: "system", progress: system.progress.snapshot, at: ended)
        let iso = ISO8601DateFormatter()

        // The tracks don't start on the same buffer; record how far each
        // lags the earliest so transcript timestamps share one clock.
        let micStart = mic.firstBufferAt ?? startedAt
        let systemStart = system.firstBufferAt ?? startedAt
        let earliest = min(micStart, systemStart)
        roster?.audio_started_at = startedAt.timeIntervalSince1970
        if let roster, let data = try? JSONEncoder().encode(roster) {
            try? data.write(to: dir.appendingPathComponent("participants.json"), options: .atomic)
        }

        var meta: [String: Any] = [
            "started": iso.string(from: startedAt),
            "backend": selectedBackend, "notes_mode": notesMode,
            "status": "stopped",
            "ended": iso.string(from: ended),
            "duration_seconds": Int(ended.timeIntervalSince(audioStartedAt)),
            "audio_started_at": earliest.timeIntervalSince1970,
            "shared_microphone": sharedMicrophone,
            "files": ["mic": "mic.caf", "system": "system.caf"],
            "start_offset_ms": [
                "mic": Int(micStart.timeIntervalSince(startedAt) * 1000),
                "system": Int(systemStart.timeIntervalSince(startedAt) * 1000),
            ],
        ]
        addMeetingMetadata(&meta)
        if fixture { meta["fixture"] = true; meta["capture_scope"] = "global_system_fixture" }
        if let localSpeakerName, !sharedMicrophone { meta["local_speaker_name"] = localSpeakerName }
        if let data = try? JSONSerialization.data(
            withJSONObject: meta,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
        }
        do { dir = try RecordingFolders.renameFinished(dir) }
        catch { FileHandle.standardError.write(Data("Could not add meeting title to recording folder: \(error)\n".utf8)) }
    }
}
