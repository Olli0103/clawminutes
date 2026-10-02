import Foundation

enum MenuBarStyle: String, CaseIterable {
    case iconOnly = "icon_only"
    case descriptive
}

enum HelperActivity: Equatable {
    case ready, recording(String), transcribing, preparing, failed

    var title: String {
        switch self {
        case .ready: return "Ready"
        case .recording(let elapsed): return "Recording · \(elapsed)"
        case .transcribing: return "Transcribing"
        case .preparing: return "Setting up"
        case .failed: return "Needs attention"
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
