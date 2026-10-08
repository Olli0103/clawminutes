import Foundation

// Pure inherited parsers retained for fixtures. The enabled Teams adapter does
// not use these to admit apps, URLs or other meeting providers.
extension MeetingEvidence {
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

}
