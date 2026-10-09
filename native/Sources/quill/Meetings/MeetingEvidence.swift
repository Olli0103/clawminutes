import Foundation

/// A complete per-process window inventory can confirm an old consent's end.
/// Missing windows or controls alone cannot do so.
struct ConsentEndWindow: Sendable {
    let identity: MeetingConsentIdentity?
    let complete: Bool
    let minimized: Bool?
    let inCall: Bool
    let endScreen: Bool
}

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
    static func confirmedConsentEnds(_ windows: [ConsentEndWindow]) -> [MeetingConsentIdentity] {
        guard !windows.isEmpty,
              windows.allSatisfy({ $0.complete && $0.minimized == false && !$0.inCall }) else { return [] }
        return windows.compactMap { window in
            guard window.endScreen, let identity = window.identity, identity.persistable else { return nil }
            return identity
        }
    }
    static func missingWindow(meeting: DetectedMeeting, replacementCall: Bool, destroyed: Bool,
                              knownWindowID: UInt32?, currentWindowIDs: Set<UInt32>?) -> MeetingObservation {
        if replacementCall { return .present(meeting) }
        guard destroyed, let knownWindowID, let currentWindowIDs,
              !currentWindowIDs.contains(knownWindowID) else { return .unknown }
        return .ended
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
        let hasShortGermanMute = normalized.contains { $0 == "stummschalten" || $0.hasPrefix("stummschalten (") || $0.hasPrefix("stummschalten(") }
        return hasLeave && (hasAudio || hasShortGermanMute)
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
