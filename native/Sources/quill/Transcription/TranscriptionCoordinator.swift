import Foundation

/// Post-recording pipeline: a serial queue of session folders to transcribe.
/// mic.caf → "me", system.caf → "them"; each track's segments are shifted by
/// its start offset, merged by timestamp, and written as transcript.json
/// (canonical) plus transcript.md (readable). The filesystem is the queue —
/// `resumePending()` rescans at launch, so a crash or quit mid-transcription
/// just retries on next run. Failures append to the session's transcribe.log
/// and never block later jobs.
actor TranscriptionCoordinator {
    enum Status: Sendable {
        case idle
        case transcribing(session: String, queued: Int)
        case postprocessing(session: String, queued: Int)
        case failed(session: String)
        case archivePending(session: String)
    }

    private var queue: [URL] = []
    private var draining = false
    private var engine: TranscriptionEngine?
    private var engineOffline = false
    private let makeEngine: @Sendable (TranscriptionEngineKind, Bool) -> any TranscriptionEngine
    private var lastIssue: Status?
    private var statusHandler: (@Sendable (Status) -> Void)?
    private let activityLockPath: URL
    private let saveArchive: @Sendable (URL) async throws -> Void

    init(activityLockPath: URL = HelperWorkLease.path,
         saveArchive: @escaping @Sendable (URL) async throws -> Void = { try await GatewayArchive.save($0) },
         makeEngine: @escaping @Sendable (TranscriptionEngineKind, Bool) -> any TranscriptionEngine = { kind, offline in
        switch kind {
        case .parakeet: return ParakeetEngine()
        case .elevenLabs: return ElevenLabsEngine(offline: offline)
        }
    }) {
        self.activityLockPath = activityLockPath
        self.saveArchive = saveArchive
        self.makeEngine = makeEngine
    }

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        statusHandler = handler
    }

    /// Queue a finished session. With transcription disabled in config, the
    /// on_stop hook still fires — it just gets an untranscribed folder.
    func enqueue(_ sessionDir: URL, transcriptionEnabled: Bool = Config.transcriptionEnabled()) async {
        guard transcriptionEnabled else {
            await runHook(for: sessionDir)
            return
        }
        queue.append(sessionDir)
        drainIfIdle()
    }

    /// Scan the recordings root for sessions that finished (meta.json exists)
    /// but were never transcribed. Folder names sort chronologically, so
    /// oldest-first is a name sort.
    func resumePending(root: URL) async {
        guard Config.transcriptionEnabled() else { return }
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
            return
        }
        defer { withExtendedLifetime(workLease) {} }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }

        let fm = FileManager.default
        let pending = entries
            .filter {
                fm.fileExists(atPath: $0.appendingPathComponent("meta.json").path)
                    && !fm.fileExists(atPath: $0.appendingPathComponent("transcript.json").path)
                    && !RecordingSession.isUnstartedAttempt($0)
                    && !AudioRetention.explicitlyRemoved($0)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for dir in pending where !queue.contains(dir) {
            queue.append(dir)
        }
        for dir in entries where fm.fileExists(atPath: dir.appendingPathComponent("transcript.json").path) && (!fm.fileExists(atPath: dir.appendingPathComponent("archive-receipt.json").path) || Self.needsNotesExport(dir)) { await runHook(for: dir) }
        if Config.deleteAudioAfterVerification() {
            for dir in entries where fm.fileExists(atPath: dir.appendingPathComponent("archive-receipt.json").path) && !AudioRetention.explicitlyRemoved(dir) {
                applyRetention(dir)
            }
        }
        if !pending.isEmpty {
            FileHandle.standardError.write(Data(
                "resuming \(pending.count) untranscribed session(s)\n".utf8
            ))
        }
        drainIfIdle()
    }

    // MARK: -

    private func drainIfIdle() {
        guard !draining, !queue.isEmpty else { return }
        draining = true
        lastIssue = nil
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
            publish(.transcribing(session: dir.lastPathComponent, queued: queue.count))
            do {
                try await transcribe(dir)
                let cleanupOptions = PostProcessingOptions(json: ["mode": "off"])
                if cleanupOptions.mode != .off { publish(.postprocessing(session: dir.lastPathComponent, queued: queue.count)) }
                let cleanup = await TranscriptPostProcessor.process(dir, options: cleanupOptions)
                log(dir, "postprocess: \(cleanup.status)")
                notifyUser(title: "ocmh: transcript ready", body: dir.lastPathComponent)
                await runHook(for: dir)
            } catch {
                log(dir, "transcription failed: \(error)")
                lastIssue = .failed(session: dir.lastPathComponent)
                notifyUser(
                    title: "ocmh: transcription failed",
                    body: "\(dir.lastPathComponent) — see transcribe.log"
                )
            }
        }
        await engine?.release()
        engine = nil
        publish(lastIssue ?? .idle)
        draining = false
        // An enqueue that landed between the loop exiting and the release
        // finishing would otherwise sit until the next enqueue.
        drainIfIdle()
    }

    func transcribe(_ dir: URL, detectSpeakers: Bool = Config.speakerDetection(), remoteSpeakerCount: Int? = nil,
                    engineOverride: TranscriptionEngineKind? = nil, offline: Bool = false, learnVoiceMemory: Bool = true) async throws {
        let workLease = try HelperWorkLease.acquire(at: activityLockPath)
        defer { withExtendedLifetime(workLease) {} }
        let meta = try SessionMeta.read(from: dir)
        // Snapshot the selection for both tracks. Menu changes affect the next job.
        let rawMeta = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("meta.json"))) as? [String: Any]
        let selected = engineOverride ?? (rawMeta?["backend"] as? String).flatMap(TranscriptionEngineKind.init(rawValue:))
        let engine = try await preparedEngine(kind: selected, offline: offline || selected == .parakeet)
        let observationURL = dir.appendingPathComponent("speaker-observations.jsonl")
        let observations = ((try? String(contentsOf: observationURL, encoding: .utf8)) ?? "")
            .split(separator: "\n").compactMap { try? JSONDecoder().decode(SpeakerObservation.self, from: Data($0.utf8)) }
        var roster = meta.participantRoster ?? ParticipantRoster(audio_started_at: meta.audioStartedAt ?? 0)
        if let started = meta.audioStartedAt { roster.audio_started_at = started }
        if let name = meta.localSpeakerName, !meta.sharedMicrophone {
            roster.observe(SpeakerObservation(observed_at: roster.audio_started_at, meeting_id: "local", names: [name],
                                              source: "local_microphone", is_local: true), localName: name)
        }
        for observation in observations { roster.observe(observation, localName: meta.localSpeakerName) }

        var merged: [Transcript.Segment] = []
        var analysis = SpeakerAnalysis(turns: [], names: [:])
        var speakerStatus: [String: String] = [:]
        var successfulTracks = 0
        for track in meta.tracks {
            let audio = dir.appendingPathComponent(track.file)
            guard FileManager.default.fileExists(atPath: audio.path) else {
                throw TranscriptionFailure("Missing expected track \(track.file). Recording preserved; recovery needs review.")
            }
            log(dir, "transcribing \(track.file) (\(engine.name))")
            // One bad track (empty, truncated) shouldn't cost us the other's
            // transcript — log it and keep going.
            let segments: [TranscriptSegment]
            do {
                segments = try await engine.transcribe(audio)
                successfulTracks += 1
            } catch {
                // Cloud failures must not publish a partial meeting as complete.
                // Successful tracks have their own cache for the next attempt.
                throw error
            }
            let offset = TimeInterval(track.offsetMs) / 1000
            if detectSpeakers && (track.speaker == "them" || meta.sharedMicrophone) && !segments.isEmpty {
                do {
                    log(dir, "separating speakers in \(track.file)")
                    var trackAnalysis = try await SpeakerDiarizer.analyze(audio, source: track.source,
                                                                         speakerCount: track.source == "system" ? remoteSpeakerCount : nil,
                                                                         captureVoiceSamples: track.source == "system" && Config.voiceMemoryEnabled())
                    if meta.tracks.filter({ $0.source == track.source }).count > 1 {
                        trackAnalysis.scopeClusters(to: track.file.replacingOccurrences(of: ".caf", with: ""))
                    }
                    if let started = meta.audioStartedAt, track.source == "system" {
                        trackAnalysis.named_spans = SpeakerAttribution.nameSpans(turns: trackAnalysis.turns, observations: observations,
                                                               audioStartedAt: started + offset, segments: segments)
                        trackAnalysis.voice_identities = SpeakerAttribution.voiceNames(turns: trackAnalysis.turns, spans: trackAnalysis.named_spans)
                        for span in trackAnalysis.named_spans {
                            trackAnalysis.names[SpeakerAttribution.namedSpeakerID(span.identity, source: track.source)] = span.identity
                        }
                    }
                    if track.source == "system", Config.voiceMemoryEnabled() {
                        do {
                            let recordingKey = try ElevenLabsEngine.fingerprint(audio)
                            try VoiceMemoryStore.shared.apply(to: &trackAnalysis, recording: recordingKey, roster: roster, learn: learnVoiceMemory)
                        } catch { log(dir, "speaker fingerprint memory unavailable: \(error); using current meeting evidence") }
                    }
                    if let samples = trackAnalysis.voice_samples {
                        analysis.voice_samples = (analysis.voice_samples ?? []) + samples.map {
                            VoiceSample(speaker_id: $0.speaker_id, start: $0.start + offset, end: $0.end + offset, embedding: $0.embedding)
                        }
                    }
                    merged += SpeakerAttribution.align(segments, turns: trackAnalysis.turns, source: track.source,
                                                       offset: offset, namedSpans: trackAnalysis.named_spans,
                                                       voiceIdentities: trackAnalysis.voice_identities)
                    analysis.turns += trackAnalysis.turns.map { SpeakerTurn(speaker_id: $0.speaker_id, start: $0.start + offset, end: $0.end + offset) }
                    analysis.names.merge(trackAnalysis.names) { _, new in new }
                    if let identities = trackAnalysis.voice_identities {
                        analysis.voice_identities = (analysis.voice_identities ?? [:]).merging(identities) { _, new in new }
                    }
                    analysis.named_spans += trackAnalysis.named_spans.map { NamedSpeakerSpan(start: $0.start + offset, end: $0.end + offset, identity: $0.identity) }
                    speakerStatus[track.source] = trackAnalysis.turns.isEmpty ? "no_speech_detected" : "complete"
                    continue
                } catch {
                    speakerStatus[track.source] = "failed"
                    log(dir, "speaker detection failed for \(track.file): \(error); preserving unlabelled transcript")
                }
            }
            let localName = track.source == "mic" && !meta.sharedMicrophone ? meta.localSpeakerName : nil
            merged += segments.map {
                Transcript.Segment(
                    speaker: track.speaker,
                    start_ms: Int(($0.start + offset) * 1000),
                    end_ms: Int(($0.end + offset) * 1000),
                    text: $0.text,
                    source: track.source,
                    speaker_name: localName,
                    attribution: localName == nil ? "audio_source" : "local_microphone"
                )
            }
        }
        guard successfulTracks > 0 else {
            throw TranscriptionFailure("No audio track could be transcribed. See transcribe.log; the session remains pending.")
        }
        merged.sort { $0.start_ms < $1.start_ms }
        // Roster membership alone cannot establish who spoke.

        let transcript = Transcript(
            engine: engine.name,
            model: engine.model,
            created_at: ISO8601DateFormatter().string(from: Date()),
            segments: merged,
            schema_version: 2,
            execution_machine: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            execution_location: engine.name == "parakeet" ? "recording_mac" : "elevenlabs_cloud_direct_from_recording_mac",
            speaker_detection: speakerStatus,
            participant_roster: roster
        )
        var output = transcript
        output.capture_gaps = meta.captureGaps.isEmpty ? nil : meta.captureGaps
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(analysis).write(to: dir.appendingPathComponent("speaker-analysis.json"), options: .atomic)
        try output.write(to: dir)
        log(dir, "done — \(merged.count) segments")
    }

    private func preparedEngine(kind override: TranscriptionEngineKind?, offline: Bool) async throws -> TranscriptionEngine {
        guard let kind = override ?? TranscriptionEngineKind(rawValue: Config.transcriptionEngine()) else {
            throw TranscriptionFailure("Unknown transcription engine: \(Config.transcriptionEngine()). Choose an engine from the ocmh menu.")
        }
        if let engine, engine.name == kind.rawValue, engineOffline == offline { return engine }
        await engine?.release()
        engine = nil
        let next = makeEngine(kind, offline)
        do { try await next.prepare() }
        catch { await next.release(); throw error }
        engine = next
        engineOffline = offline
        return next
    }

    /// Fires the configured on_stop shell command with the session directory
    /// as its sole argument, after the transcript exists (or immediately after
    /// recording when transcription is disabled).
    private static func needsNotesExport(_ dir: URL) -> Bool {
        guard !FileManager.default.fileExists(atPath: dir.appendingPathComponent("notes-export-path.txt").path),
              let data = try? Data(contentsOf: dir.appendingPathComponent("archive-receipt.json")),
              let receipt = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return receipt["documents"] != nil
    }
    private func runHook(for dir: URL) async {
        do {
            try await saveArchive(dir)
            log(dir, "Gateway Meetings archive saved and read back")
            applyRetention(dir)
            if case .archivePending(let pending) = lastIssue, pending == dir.lastPathComponent { lastIssue = nil }
            if !draining { publish(lastIssue ?? .idle) }
        } catch {
            lastIssue = .archivePending(session: dir.lastPathComponent)
            if !draining { publish(.archivePending(session: dir.lastPathComponent)) }
            log(dir, "archive failed: \(error); recording and transcript preserved. Reconnect Gateway and retry archive.")
        }
    }

    private func applyRetention(_ dir: URL) {
        guard Config.deleteAudioAfterVerification(), !AudioRetention.explicitlyRemoved(dir) else { return }
        do {
            let count = try AudioRetention.deleteAfterVerification(dir)
            if count > 0 { log(dir, "Audio retention: verified text and notes; removed \(count) audio track(s)") }
        } catch { log(dir, "Audio retention: \(error)") }
    }

    private func log(_ dir: URL, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = dir.appendingPathComponent("transcribe.log")
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private func publish(_ status: Status) {
        statusHandler?(status)
    }
}

/// The slice of meta.json the coordinator needs: which files exist, who they
/// represent, and how far each track started after the earliest one.
struct SessionMeta {
    struct Track {
        let file: String
        let speaker: String
        let offsetMs: Int
        var source: String { speaker == "me" ? "mic" : "system" }
    }

    let tracks: [Track]
    let audioStartedAt: Double?
    let localSpeakerName: String?
    let sharedMicrophone: Bool
    var participantRoster: ParticipantRoster? = nil
    var captureGaps: [CaptureGap] = []

    enum MetaError: Error, CustomStringConvertible {
        case unreadable(URL)

        var description: String {
            switch self {
            case .unreadable(let url): return "can't parse \(url.path)"
            }
        }
    }

    static func read(from dir: URL) throws -> SessionMeta {
        let url = dir.appendingPathComponent("meta.json")
        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let files = json["files"] as? [String: String]
        else { throw MetaError.unreadable(url) }

        // Sessions recorded before offsets were captured default to 0 —
        // tracks start within tens of milliseconds of each other anyway.
        let offsets = json["start_offset_ms"] as? [String: Int] ?? [:]
        var tracks: [Track] = []
        if let segments = json["capture_segments"] as? [[String: Any]] {
            guard !segments.isEmpty, segments.count <= 16 else { throw MetaError.unreadable(url) }
            var names = Set<String>()
            for segment in segments {
                guard let source = segment["source"] as? String, ["mic", "system"].contains(source),
                      let file = segment["file"] as? String, validTrackFile(file), names.insert(file).inserted,
                      let offset = segment["offset_ms"] as? Int, offset >= 0 else { throw MetaError.unreadable(url) }
                // A cleanly stopped segment with no written frames contains no speech.
                // Interrupted sessions still inspect their PCM files rather than trust a stale checkpoint.
                if json["status"] as? String == "stopped", segment["frames_written"] as? Int == 0 { continue }
                tracks.append(Track(file: file, speaker: source == "mic" ? "me" : "them", offsetMs: offset))
            }
        } else {
            for source in ["mic", "system"] {
                if let file = files[source] {
                    guard validTrackFile(file) else { throw MetaError.unreadable(url) }
                    tracks.append(Track(file: file, speaker: source == "mic" ? "me" : "them", offsetMs: offsets[source] ?? 0))
                }
            }
        }
        let roster = (try? Data(contentsOf: dir.appendingPathComponent("participants.json")))
            .flatMap { try? JSONDecoder().decode(ParticipantRoster.self, from: $0) }
        let gaps = try json["capture_gaps"].map { try JSONDecoder().decode([CaptureGap].self, from: JSONSerialization.data(withJSONObject: $0)) } ?? []
        guard gaps.allSatisfy({ ["mic", "system"].contains($0.source) && $0.start_ms >= 0 && $0.end_ms >= $0.start_ms }) else { throw MetaError.unreadable(url) }
        return SessionMeta(tracks: tracks, audioStartedAt: json["audio_started_at"] as? Double,
                           localSpeakerName: SpeakerAttribution.cleanName(json["local_speaker_name"] as? String),
                           sharedMicrophone: json["shared_microphone"] as? Bool ?? false, participantRoster: roster, captureGaps: gaps)
    }
    static func validTrackFile(_ file: String) -> Bool {
        file.range(of: #"^(mic|system)(-[0-9]+)?\.caf$"#, options: .regularExpression) != nil
    }
}

/// Canonical transcript. Property names are the JSON schema — this struct
/// exists to be serialized.
struct Transcript: Codable, Sendable {
    struct Segment: Codable, Sendable {
        var speaker: String
        let start_ms: Int
        let end_ms: Int
        var text: String
        var source: String? = nil
        var speaker_name: String? = nil
        var attribution: String? = nil

        var displayName: String {
            if let speaker_name { return speaker_name }
            if speaker.hasSuffix("_unknown") { return "Unknown speaker" }
            if let number = speaker.split(separator: "_").last, Int(number) != nil {
                return "Unknown speaker"
            }
            return "Unknown speaker"
        }
    }

    let engine: String
    let model: String
    let created_at: String
    var segments: [Segment]
    var schema_version: Int? = nil
    var execution_machine: String? = nil
    var execution_location: String? = nil
    var speaker_detection: [String: String]? = nil
    var participant_roster: ParticipantRoster? = nil
    var capture_gaps: [CaptureGap]? = nil

    /// Write transcript.json and render transcript.md. Both writes are atomic
    /// (temp file + rename), so a partially written transcript never exists on
    /// disk — resumePending treats presence of transcript.json as "done".
    func write(to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try Data(rendered(title: dir.lastPathComponent).utf8)
            .write(to: dir.appendingPathComponent("transcript.md"), options: .atomic)
        try encoder.encode(self)
            .write(to: dir.appendingPathComponent("transcript.json"), options: .atomic)
    }

    private func rendered(title: String) -> String {
        var lines = ["# \(title)", "", "engine: \(engine) (\(model))", ""]
        if let gaps = capture_gaps, !gaps.isEmpty {
            lines += ["## Capture gaps", "", "Audio is incomplete in these intervals. Missing speech cannot be recovered from the transcript.", ""]
            for gap in gaps {
                lines.append("- \(gap.source): \(Self.clock(gap.start_ms)) to \(Self.clock(gap.end_ms)) · \(gap.reason)")
            }
            lines.append("")
        }
        if let roster = participant_roster, !roster.participants.isEmpty {
            lines += ["## Participants", ""]
            for participant in roster.participants.sorted(by: { $0.name < $1.name }) {
                let name = participant.name.replacingOccurrences(of: "*", with: "\\*")
                    .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
                lines.append("- \(name)\(participant.is_local ? " (you)" : "")")
            }
            lines += ["", "## Transcript", ""]
        }
        for seg in segments {
            let name = seg.displayName.replacingOccurrences(of: "*", with: "\\*")
                .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            lines.append("**[\(Self.clock(seg.start_ms))] \(name):** \(seg.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func clock(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
