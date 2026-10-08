import Foundation

enum MenuBarStyle: String, CaseIterable {
    case iconOnly = "icon_only"
    case descriptive
}

enum HelperActivity: Equatable {
    case ready, recording(String), audioCheck(String), transcribing, preparing, failed, archivePending

    var title: String {
        switch self {
        case .ready: return "Ready"
        case .recording(let elapsed): return "Recording · \(elapsed)"
        case .audioCheck(let status): return "Audio check · \(status)"
        case .transcribing: return "Transcribing"
        case .preparing: return "Setting up"
        case .failed: return "Needs attention"
        case .archivePending: return "Waiting to send"
        }
    }
    var isWorking: Bool {
        switch self { case .recording, .audioCheck, .transcribing, .preparing: return true; default: return false }
    }
}

enum MenuPresentation {
    static func restoredCaptureWarning(recording: Bool, current: String?, metadata: Data?, transcript: Data? = nil) -> String? {
        // A pending older meeting must not replace the live capture's warning.
        guard !recording else { return current }
        struct Evidence: Decodable { let capture_gaps: [CaptureGap]? }
        let captured = metadata.flatMap { try? JSONDecoder().decode(Evidence.self, from: $0) }
        let recognized = transcript.flatMap { try? JSONDecoder().decode(Evidence.self, from: $0) }
        guard captured != nil || recognized != nil else { return current }
        let gaps = (captured?.capture_gaps ?? []) + (recognized?.capture_gaps ?? [])
        guard !gaps.isEmpty else { return nil }
        if gaps.allSatisfy({ $0.reason == "boundary_context_unverified" }) {
            return "Words at audio file boundaries need review. Original recognition and audio are retained."
        }
        if gaps.contains(where: { $0.reason == "frame_coverage_shortfall" || $0.reason == "incomplete_at_stop" }) {
            return "Audio timing needs review. The transcript marks timing uncertainty after a capture frame shortfall. Audio is retained."
        }
        return "Audio capture was interrupted. Review the marked gaps in the transcript. Audio is retained."
    }
    static func activity(recording: Bool, elapsed: String, status: TranscriptionCoordinator.Status, preparing: Bool = false) -> HelperActivity {
        if recording { return .recording(elapsed) }
        if preparing { return .preparing }
        switch status {
        case .idle: return .ready
        case .recognizingChunk, .transcribing, .postprocessing: return .transcribing
        case .failed, .needsReview: return .failed
        case .archivePending: return .archivePending
        }
    }
    static func pipelineDetail(_ status: TranscriptionCoordinator.Status) -> String? {
        switch status {
        case .idle: return nil
        case .recognizingChunk(let name, _): return "Recognizing closed audio for \(name) on this Mac. The final transcript is still pending."
        case .transcribing(let name, let queued): return "Transcribing \(name)" + (queued > 0 ? " · \(queued) waiting" : "")
        case .postprocessing(let name, _): return "Finishing \(name)"
        case .needsReview(let name, let reason): return "\(name): \(reason)"
        case .failed(let name): return "Transcription did not finish for \(name). Audio is retained. Open the meeting below for recovery options."
        case .archivePending(let name): return "Transcript ready on this Mac. Saving \(name) to the Gateway is pending. Open the meeting below for its status and recovery options. Audio is retained."
        }
    }
    static func meetingTitle(promptsEnabled: Bool, accessibilityGranted: Bool, detection: String) -> String {
        if !promptsEnabled { return "Meeting prompts off" }
        if !accessibilityGranted { return "Manual recording available" }
        if detection == "Teams meeting detected" || detection.hasPrefix("Watching Teams") || detection.hasPrefix("Watching Microsoft Teams") { return "Teams call detected" }
        if detection.hasPrefix("Meeting ended") { return detection }
        if detection.contains("unavailable") || detection == "Checking Teams…" { return "Checking Teams status" }
        return "Waiting for a Teams call"
    }
    static func callSummary(_ meetingTitle: String) -> String {
        switch meetingTitle {
        case "Teams call detected": return "Teams call"
        case "Meeting prompts off": return "Detection off"
        case "Manual recording available": return "Manual only"
        case "Checking Teams status": return "Checking call"
        default: return meetingTitle.hasPrefix("Meeting ended") ? "Call ended" : "No call"
        }
    }
    static func title(style: MenuBarStyle, activity: HelperActivity, backend: String, meeting: String? = nil) -> String {
        guard style != .iconOnly else { return "" }
        return " " + ([meeting, activity.title, backend].compactMap { $0 }).joined(separator: " · ")
    }
}
