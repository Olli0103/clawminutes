import Foundation

/// A detection event can request consent, but cannot start capture.
struct ConsentPromptState {
    private(set) var prompted: Set<String>
    init(prompted: Set<String> = []) { self.prompted = prompted }
    mutating func observe(_ meeting: DetectedMeeting) -> Bool { prompted.insert(meeting.id).inserted }
    mutating func ended(_ id: String) { prompted.remove(id) }
}
