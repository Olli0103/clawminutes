import Foundation

enum MenuBarStyle: String, CaseIterable {
    case iconOnly = "icon_only"
    case descriptive
}

enum HelperActivity: Equatable {
    case ready, recording(String), transcribing, preparing, failed, archivePending

    var title: String {
        switch self {
        case .ready: return "Ready"
        case .recording(let elapsed): return "Recording · \(elapsed)"
        case .transcribing: return "Transcribing"
        case .preparing: return "Setting up"
        case .failed: return "Needs attention"
        case .archivePending: return "Transcript ready"
        }
    }
    var isWorking: Bool {
        switch self { case .recording, .transcribing, .preparing: return true; default: return false }
    }
}

enum MenuPresentation {
    static func activity(recording: Bool, elapsed: String, status: TranscriptionCoordinator.Status, preparing: Bool = false) -> HelperActivity {
        if recording { return .recording(elapsed) }
        if preparing { return .preparing }
        switch status {
        case .idle: return .ready
        case .transcribing, .postprocessing: return .transcribing
        case .failed: return .failed
        case .archivePending: return .archivePending
        }
    }
    static func pipelineDetail(_ status: TranscriptionCoordinator.Status) -> String? {
        switch status {
        case .idle: return nil
        case .transcribing(let name, let queued): return "Transcribing \(name)" + (queued > 0 ? " · \(queued) waiting" : "")
        case .postprocessing(let name, _): return "Finishing \(name)"
        case .failed(let name): return "Transcription did not finish for \(name). Audio is retained. See transcribe.log for the failed step."
        case .archivePending(let name): return "Transcript ready on this Mac. Saving \(name) to the Gateway is pending. Check the Gateway connection and retry pending saves. Audio is retained."
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
