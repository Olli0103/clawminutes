import Foundation

/// The slice of meta.json the coordinator needs: which files exist, who they
/// represent, and how far each track started after the earliest one.
struct SessionMeta {
    struct Track {
        let file: String
        let speaker: String
        let offsetMs: Int
        var timingUncertain = false
        var continuousFromPrevious = false
        var source: String { speaker == "me" ? "mic" : "system" }
    }

    let tracks: [Track]
    let audioStartedAt: Double?
    let localSpeakerName: String?
    let sharedMicrophone: Bool
    var participantRoster: ParticipantRoster? = nil
    var captureGaps: [CaptureGap] = []
    var recordingDuration: Double? = nil

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
            guard !segments.isEmpty, segments.count <= CaptureManifest.maximumSegments else { throw MetaError.unreadable(url) }
            var names = Set<String>()
            for segment in segments {
                guard let source = segment["source"] as? String, ["mic", "system"].contains(source),
                      let file = segment["file"] as? String, validTrackFile(file), names.insert(file).inserted,
                      let offset = segment["offset_ms"] as? Int, offset >= 0 else { throw MetaError.unreadable(url) }
                // Inspect actual PCM, including zero-frame checkpoints. They may
                // be stale after a crash, and missing tracks must become explicit gaps.
                tracks.append(Track(file: file, speaker: source == "mic" ? "me" : "them", offsetMs: offset,
                    timingUncertain: segment["rotation_pending"] as? Bool == true || segment["timing_uncertain"] as? Bool == true,
                    continuousFromPrevious: segment["continuous_clock"] as? Bool == true))
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
                           sharedMicrophone: json["shared_microphone"] as? Bool ?? false, participantRoster: roster, captureGaps: gaps,
                           recordingDuration: (json["ended"] as? String).flatMap { ended in
                               guard let started = json["audio_started_at"] as? Double,
                                     let end = ISO8601DateFormatter().date(from: ended) else { return nil }
                               let duration = end.timeIntervalSince1970 - started
                               return duration.isFinite && duration >= 0 && duration <= 7 * 24 * 3600 ? duration : nil
                           })
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
            if let speaker_name {
                return attribution == "meeting_voice" ? "\(speaker_name) (voice match, uncertain)" : speaker_name
            }
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
    func write(to dir: URL, title: String? = nil) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try Data(rendered(title: title ?? dir.lastPathComponent).utf8)
            .write(to: dir.appendingPathComponent("transcript.md"), options: .atomic)
        try encoder.encode(self)
            .write(to: dir.appendingPathComponent("transcript.json"), options: .atomic)
    }

    private func rendered(title: String) -> String {
        var lines = ["# \(title)", "", "engine: \(engine) (\(model))", ""]
        if let gaps = capture_gaps, !gaps.isEmpty {
            for boundary in [false, true] {
                let group = gaps.filter { ($0.reason == "boundary_context_unverified") == boundary }
                guard !group.isEmpty else { continue }
                lines += [boundary ? "## Transcription boundary review" : "## Capture gaps", "",
                    boundary ? "Words at file boundaries in these ranges need review. Original recognition and audio are retained. This does not establish interrupted capture."
                        : "Audio is incomplete or its timing is uncertain in these intervals. Missing speech cannot be recovered from the transcript.", ""]
                for gap in group {
                    lines.append("- \(gap.source): \(Self.clock(gap.start_ms)) to \(Self.clock(gap.end_ms)) · \(gap.reason)")
                }
                lines.append("")
            }
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
