import Foundation

/// Owns recognition engines and track alignment. It cannot upload to the
/// Gateway, export notes or remove source audio.
actor RecordingTranscriber {
    private struct RecognizedTrack {
        let track: SessionMeta.Track
        let duration: Double
        var segments: [TranscriptSegment]
    }
    private var engine: TranscriptionEngine?
    private var engineOffline = false
    private var busy = false
    private let activityLockPath: URL
    private let audioDuration: @Sendable (URL) throws -> Double
    private let makeEngine: @Sendable (TranscriptionEngineKind, Bool) -> any TranscriptionEngine
    init(activityLockPath: URL, audioDuration: @escaping @Sendable (URL) throws -> Double,
         makeEngine: @escaping @Sendable (TranscriptionEngineKind, Bool) -> any TranscriptionEngine) {
        self.activityLockPath = activityLockPath; self.audioDuration = audioDuration; self.makeEngine = makeEngine
    }
    func release() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        await engine?.release(); engine = nil
    }

    /// Speculative local work over one acknowledged closed file. It never
    /// touches final transcript artifacts, delivery, notes or audio retention.
    func transcribeClosedChunk(_ dir: URL, file: String) async throws {
        guard !busy else { throw MeetingPipelineState.conflictingState }
        busy = true; defer { busy = false }
        _ = try MeetingPipelineState.identity(dir)
        let lease = try HelperWorkLease.acquire(at: activityLockPath)
        guard let lock = try AppRunLock.acquire(at: dir.appendingPathComponent("archive.lock")) else {
            throw MeetingPipelineState.conflictingState
        }
        defer { withExtendedLifetime((lease, lock)) {} }
        let metadata = try ArchiveBacklog.object(dir.appendingPathComponent("meta.json"))
        guard metadata["status"] as? String == "recording" else { return }
        var state = try MeetingPipelineState.load(dir)
        guard state.recognitionChunks?[file] == nil,
              (state.recognitionChunks?.count ?? 0) < 256 else { return }
        let source = try ClosedChunkRecognition.source(dir, file: file, measure: audioDuration)
        var info = stat()
        guard lstat(ClosedChunkRecognition.path(dir, file: file).path, &info) != 0, errno == ENOENT else { return }
        state.recognitionChunks = (state.recognitionChunks ?? [:]).merging([file: .init(count: 1)]) { old, _ in old }
        try state.write(dir) // Reserve before prepare/inference; relaunch cannot repeat it.
        let engine = try await preparedEngine(kind: .parakeet, offline: true)
        guard engine.name == "parakeet" else { throw MeetingPipelineState.invalidState }
        try Task.checkCancellation()
        let segments = try await engine.transcribe(dir.appendingPathComponent(file))
        try Task.checkCancellation()
        try ClosedChunkRecognition.publish(segments, source: source, dir: dir, engine: engine.name, model: engine.model)
        MeetingLog.append(dir, "Local recognition checkpoint saved for \(file). Final reconciliation is still required.")
    }

    func transcribe(_ dir: URL, detectSpeakers: Bool = Config.speakerDetection(), remoteSpeakerCount: Int? = nil,
                    engineOverride: TranscriptionEngineKind? = nil, offline: Bool = false, learnVoiceMemory: Bool = true, allowAudioLinks: Bool = false) async throws {
        guard !busy else { throw TranscriptionFailure("Speech recognition is already processing another meeting. Audio is retained.") }
        busy = true
        defer { busy = false }
        let ownership = try DraftSourceOwnership.acquire(dir, activityLockPath: activityLockPath)
        defer { withExtendedLifetime(ownership) {} }
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

        var captureGaps = meta.captureGaps
        var merged: [Transcript.Segment] = []
        var analysis = SpeakerAnalysis(turns: [], names: [:])
        var speakerStatus: [String: String] = [:]
        var successfulTracks = 0
        var sourceSignatures: [(URL, AudioRetention.FileIdentity)] = []
        var recognized: [RecognizedTrack] = []
        for track in meta.tracks {
            let audio = dir.appendingPathComponent(track.file)
            let attributes = try? audio.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            let linkAllowed = allowAudioLinks && attributes?.isSymbolicLink == true
            let duration = (attributes?.isRegularFile == true && attributes?.isSymbolicLink != true) || linkAllowed ? try? audioDuration(audio) : nil
            guard let duration, duration.isFinite, duration > 0 else {
                let offset = max(0, track.offsetMs)
                let end = max(offset, Int((meta.recordingDuration ?? Double(offset) / 1000) * 1000))
                captureGaps.append(CaptureGap(source: track.source, start_ms: offset, end_ms: end, reason: "track_unavailable"))
                MeetingLog.append(dir, "Track unavailable [\(track.source)]: \(track.file). Its speech is missing; remaining tracks will be recovered.")
                continue
            }
            if track.timingUncertain {
                captureGaps.append(CaptureGap(source: track.source, start_ms: track.offsetMs,
                    end_ms: track.offsetMs + Int(duration * 1000), reason: "capture_timing_uncertain"))
                speakerStatus[track.source] = "timing_uncertain"
            }
            if !linkAllowed { sourceSignatures.append((audio, try AudioRetention.FileIdentity.read(audio))) }
            MeetingLog.append(dir, "transcribing \(track.file) (\(engine.name))")
            // One bad track (empty, truncated) shouldn't cost us the other's
            // transcript — log it and keep going.
            let segments: [TranscriptSegment]
            do {
                if !allowAudioLinks, let cached = ClosedChunkRecognition.cached(dir, file: track.file, offsetMs: track.offsetMs,
                        seconds: duration, engine: engine.name, model: engine.model) {
                    segments = cached
                    MeetingLog.append(dir, "Using verified local recognition checkpoint for \(track.file)")
                } else {
                    segments = try await engine.transcribe(audio)
                }
                successfulTracks += 1
            } catch {
                // Cloud failures must not publish a partial meeting as complete.
                // Successful tracks have their own cache for the next attempt.
                throw error
            }
            recognized.append(RecognizedTrack(track: track, duration: duration, segments: segments))
        }
        try await reconcileBoundaries(&recognized, directory: dir, engine: engine, gaps: &captureGaps, allowAudioLinks: allowAudioLinks)
        for item in recognized {
            let track = item.track, segments = item.segments
            let audio = dir.appendingPathComponent(track.file)
            let offset = TimeInterval(track.offsetMs) / 1000
            if !track.timingUncertain && detectSpeakers && (track.speaker == "them" || meta.sharedMicrophone) && !segments.isEmpty {
                do {
                    MeetingLog.append(dir, "separating speakers in \(track.file)")
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
                        } catch { MeetingLog.append(dir, "speaker fingerprint memory unavailable: \(error); using current meeting evidence") }
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
                    MeetingLog.append(dir, "speaker detection failed for \(track.file): \(error); preserving unlabelled transcript")
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
        guard successfulTracks > 0, merged.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
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
        output.capture_gaps = captureGaps.isEmpty ? nil : captureGaps
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try ownership.validateUnchanged()
        for (audio, signature) in sourceSignatures {
            guard try AudioRetention.FileIdentity.read(audio) == signature else { throw MeetingPipelineState.conflictingState }
        }
        try encoder.encode(analysis).write(to: dir.appendingPathComponent("speaker-analysis.json"), options: .atomic)
        try output.write(to: dir)
        MeetingLog.append(dir, "done — \(merged.count) segments")
    }

    private func reconcileBoundaries(_ items: inout [RecognizedTrack], directory: URL, engine: any TranscriptionEngine,
                                     gaps: inout [CaptureGap], allowAudioLinks: Bool) async throws {
        for source in ["mic", "system"] {
            let indices = items.indices.filter { items[$0].track.source == source }
                .sorted { items[$0].track.offsetMs < items[$1].track.offsetMs }
            for (left, right) in zip(indices, indices.dropFirst()) {
                let first = items[left], second = items[right]
                guard second.track.continuousFromPrevious, !first.track.timingUncertain, !second.track.timingUncertain else { continue }
                let boundary = second.track.offsetMs
                do {
                    guard engine.name == "parakeet", !allowAudioLinks,
                          abs(Double(boundary - first.track.offsetMs) / 1000 - first.duration) <= 0.002 else {
                        throw MeetingPipelineState.invalidState
                    }
                    try Task.checkCancellation()
                    let clip = try BoundaryRecognition.makeClip(left: directory.appendingPathComponent(first.track.file),
                        right: directory.appendingPathComponent(second.track.file))
                    defer { clip.remove() }
                    guard abs(clip.leftDuration - first.duration) <= 0.002,
                          abs(clip.rightDuration - second.duration) <= 0.002 else { throw MeetingPipelineState.conflictingState }
                    let context = try await engine.transcribe(clip.file)
                    try Task.checkCancellation()
                    guard let pair = BoundaryRecognition.reconcile(left: first.segments, right: second.segments, context: context,
                        leftStart: clip.leftStart, leftDuration: clip.leftDuration, rightSeconds: clip.rightSeconds,
                        rightDuration: clip.rightDuration) else { throw MeetingPipelineState.invalidState }
                    items[left].segments = pair.left; items[right].segments = pair.right
                    MeetingLog.append(directory, "Local speech context reconciled at a continuous \(source) file boundary.")
                } catch {
                    try Task.checkCancellation()
                    let reason = "boundary_context_unverified"
                    if let index = gaps.firstIndex(where: { $0.source == source && $0.reason == reason }) {
                        let earlier = gaps[index]
                        gaps[index] = CaptureGap(source: source, start_ms: min(earlier.start_ms, max(0, boundary - 1000)),
                            end_ms: max(earlier.end_ms, boundary + 1000), reason: reason)
                    } else {
                        gaps.append(CaptureGap(source: source, start_ms: max(0, boundary - 1000), end_ms: boundary + 1000, reason: reason))
                    }
                    MeetingLog.append(directory, "Speech context at a \(source) file boundary, \(boundary) ms, needs review. Original edge text and audio are preserved.")
                }
            }
        }
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

}
