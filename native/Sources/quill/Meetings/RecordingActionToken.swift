import Foundation

/// A notification from another recording or process launch cannot control the
/// current recording, even if an in-memory generation counter happens to match.
struct RecordingActionToken {
    private(set) var value: String?
    mutating func begin() { value = UUID().uuidString }
    mutating func finish() { value = nil }
    func accepts(_ candidate: String?) -> Bool { value != nil && value == candidate }
}
