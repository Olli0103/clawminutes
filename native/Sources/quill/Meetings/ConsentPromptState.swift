import Foundation

/// Consent belongs to an ongoing call, not one of its full-size or compact windows.
/// The native scanner IDs are process:window-serial. Keep a Teams process's
/// windows together until every observed window has continuously ended for 30s.
struct ConsentPromptState {
    private(set) var prompted: Set<String>
    private var observedIDs: Set<String> = []
    private var endedSince: [String: TimeInterval] = [:]

    init(prompted: Set<String> = []) { self.prompted = prompted }

    mutating func observe(_ meeting: DetectedMeeting) -> Bool {
        observedIDs.insert(meeting.id)
        let owner = Self.owner(meeting.id)
        let alreadyPrompted = prompted.contains { Self.owner($0) == owner }
        prompted.insert(meeting.id)
        endedSince.removeValue(forKey: owner)
        return !alreadyPrompted
    }

    mutating func update(_ observations: [String: MeetingObservation], now: TimeInterval,
                         promptInProgress: Bool = false) {
        let owners = Set(prompted.map(Self.owner))
        for (id, observation) in observations where owners.contains(Self.owner(id)) {
            // Do not accumulate retired windows between calls. A scanner can
            // report the previous call's end long after its consent was cleared.
            if prompted.contains(id) { observedIDs.insert(id) }
            if case .present = observation { observedIDs.insert(id) }
        }
        for owner in owners {
            let members = observedIDs.filter { Self.owner($0) == owner }
            // Missing and unknown observations cannot establish a call end.
            guard !promptInProgress, !members.isEmpty,
                  members.allSatisfy({ observations[$0] == .ended }) else {
                endedSince.removeValue(forKey: owner)
                continue
            }
            if endedSince[owner] == nil { endedSince[owner] = now }
            if now - (endedSince[owner] ?? now) >= 30 {
                prompted = prompted.filter { Self.owner($0) != owner }
                observedIDs.subtract(members)
                endedSince.removeValue(forKey: owner)
            }
        }
    }

    private static func owner(_ id: String) -> String {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, Int32(parts[0]) != nil, Int(parts[1]) != nil {
            return "process:\(parts[0])"
        }
        return "meeting:\(id)"
    }
}
