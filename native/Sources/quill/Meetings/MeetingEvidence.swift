import Foundation

/// Once a visible meeting has ended, keeping its tab open must not restart
/// recording when that tab moves into the background.
struct MeetingEndState {
    private var ended: Set<String> = []

    mutating func isEnded(_ id: String, endScreen: Bool, inCall: Bool) -> Bool {
        if inCall { ended.remove(id) }
        else if endScreen { ended.insert(id) }
        return ended.contains(id)
    }

    mutating func forget(_ id: String) { ended.remove(id) }

    /// Positive end evidence stays latched through partial AX reads. Only new call controls clear it.
    mutating func observation(for meeting: DetectedMeeting, inCall: Bool, endScreen: Bool) -> MeetingObservation {
        if isEnded(meeting.id, endScreen: endScreen, inCall: inCall) { return .ended }
        return inCall ? .present(meeting) : .unknown
    }
}

enum MeetingEvidence {
    static func nativeService(bundleID: String) -> String? {
        switch bundleID.lowercased() {
        case "us.zoom.xos": return "Zoom"
        case "com.microsoft.teams2", "com.microsoft.teams": return "Microsoft Teams"
        case "com.tinyspeck.slackmacgap": return "Slack"
        default: return nil
        }
    }

    static func isZoomConferenceWindow(title: String, videoLabels: [String]) -> Bool {
        title == "Zoom Meeting" && videoLabels.contains {
            $0.range(of: #", (?:Computer|Phone) audio (?:unmuted|muted)(?:,|$)"#, options: .regularExpression) != nil
        }
    }

    static func meetCode(in text: String) -> String? {
        let lower = text.lowercased()
        guard lower.contains("meet") else { return nil }
        guard let range = lower.range(of: "(?<![a-z])[a-z]{3}-[a-z]{4}-[a-z]{3}(?![a-z])", options: .regularExpression) else { return nil }
        return String(lower[range])
    }

    static func service(url: String) -> String? {
        guard let parsed = URL(string: url), let host = parsed.host?.lowercased() else { return nil }
        if host == "meet.google.com", parsed.path.range(of: "^/[a-z]{3}-[a-z]{4}-[a-z]{3}/?$", options: .regularExpression) != nil { return "Google Meet" }
        if host == "teams.microsoft.com" || host == "teams.live.com" || host == "teams.cloud.microsoft" { return "Microsoft Teams" }
        if host == "zoom.us" || host.hasSuffix(".zoom.us") { return "Zoom" }
        if ["https", "http"].contains(parsed.scheme?.lowercased() ?? ""),
           host.hasSuffix(".slack.com"),
           parsed.path.range(of: "^/(client|huddle|messages|archives)(/|$)", options: .regularExpression) != nil { return "Slack" }
        return nil
    }

    static func isLeaveControl(_ text: String) -> Bool {
        let text = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "auflegen" || text.hasPrefix("auflegen (") || text.hasPrefix("auflegen(") { return true }
        return ["leave call", "leave meeting", "end meeting", "hang up", "end call", "besprechung verlassen", "besprechung beenden", "anruf beenden"]
            .contains { text == $0 || text.hasPrefix($0 + " ") || text.hasPrefix($0 + "(") }
    }

    static func hasCallControls(_ buttons: [String]) -> Bool {
        if buttons.contains(where: isLeaveControl) { return true }
        let normalized = buttons.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        let hasLeave = normalized.contains { text in ["leave", "end", "verlassen", "beenden"].contains { text == $0 || text.hasPrefix($0 + " (") || text.hasPrefix($0 + "(") } }
        let hasAudio = normalized.contains { $0.hasPrefix("mute") || $0.hasPrefix("unmute") || $0.hasPrefix("turn off microphone") || $0.hasPrefix("turn on microphone") || $0.hasPrefix("mikrofon stummschalten") || $0.hasPrefix("stummschaltung aufheben") }
        return hasLeave && hasAudio
    }

    static func isEndMessage(_ text: String) -> Bool {
        let text = text.lowercased().replacingOccurrences(of: "’", with: "'").trimmingCharacters(in: .whitespacesAndNewlines)
        return ["you left the meeting", "you've left the meeting", "you have left the meeting",
                "the meeting has ended", "this meeting has ended", "your call has ended",
                "you left the call", "you've left the call", "the host has ended this meeting",
                "you've left this meeting", "you have left this meeting", "you left this meeting",
                "you've left this call", "this call has ended", "call ended",
                "sie haben die besprechung verlassen", "du hast die besprechung verlassen",
                "sie haben den anruf verlassen", "du hast den anruf verlassen",
                "die besprechung wurde beendet", "die besprechung ist beendet", "der anruf wurde beendet", "anruf beendet"]
            .contains { phrase in text == phrase || [".", "!", "\n"].contains(where: { text.hasPrefix(phrase + $0) }) }
    }
}
