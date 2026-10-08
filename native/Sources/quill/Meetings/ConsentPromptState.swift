import Foundation
import CryptoKit

/// Consent belongs to an ongoing call, not one of its full-size or compact windows.
/// Live replacement windows share handled consent until a corroborated end.
/// Across launches, only an evidenced process incarnation, title and previously
/// observed WindowServer ID can suppress the prompt. Legacy PID-only state is ignored.
struct ConsentPromptState {
    private(set) var prompted: Set<String>
    private var observedIDs: Set<String> = []
    private var endedSince: [String: TimeInterval] = [:]
    private var owners: [String: String] = [:]
    private var records: [String: SavedCall] = [:]
    private var activeOwners: Set<String> = []

    private struct SavedCall: Codable {
        let processID: Int32
        let processStartedAt: Double
        let titleFingerprint: String
        var windowIDs: Set<UInt32>
        var owner: String { "process:\(processID):\(processStartedAt):\(titleFingerprint)" }
        var valid: Bool {
            processID > 0 && processStartedAt.isFinite && processStartedAt > 0
                && titleFingerprint.count == 64 && titleFingerprint.allSatisfy { $0.isHexDigit }
                && !windowIDs.isEmpty && windowIDs.count <= 128 && !windowIDs.contains(0)
        }
    }
    private struct Saved: Codable { let schemaVersion: Int; let calls: [SavedCall] }

    init(saved: Data?) {
        prompted = []
        guard let saved, saved.count <= 65_536,
              let value = try? JSONDecoder().decode(Saved.self, from: saved),
              value.schemaVersion == 2, value.calls.count <= 128,
              value.calls.allSatisfy({ $0.valid }) else { return }
        for call in value.calls { records[call.owner] = call }
    }
    func savedData() throws -> Data {
        try JSONEncoder().encode(Saved(schemaVersion: 2, calls: records.values.sorted { $0.owner < $1.owner }))
    }
    private func owner(_ id: String) -> String { owners[id] ?? Self.owner(id) }

    init(prompted: Set<String> = []) { self.prompted = prompted }

    mutating func observe(_ meeting: DetectedMeeting) -> Bool {
        observedIDs.insert(meeting.id)
        let identity = meeting.consentIdentity
        let owner = identity?.owner ?? Self.owner(meeting.id)
        let savedMatch = identity.map { identity in
            identity.persistable && records[owner]?.windowIDs.contains(identity.windowID ?? 0) == true
        } ?? false
        let alreadyPrompted = activeOwners.contains(owner) || savedMatch
            || prompted.contains { self.owner($0) == owner }
        owners[meeting.id] = owner
        activeOwners.insert(owner)
        if let identity, identity.persistable, let windowID = identity.windowID,
           let fingerprint = identity.titleFingerprint {
            var record = records[owner] ?? SavedCall(processID: identity.processID,
                processStartedAt: identity.processStartedAt, titleFingerprint: fingerprint, windowIDs: [])
            record.windowIDs.insert(windowID)
            // Bound persistent history even if Teams never gives an end signal.
            if record.windowIDs.count <= 128 { records[owner] = record }
            if records.count > 128 { records = [owner: record] }
        }
        prompted.insert(meeting.id)
        endedSince.removeValue(forKey: owner)
        return !alreadyPrompted
    }

    mutating func update(_ observations: [String: MeetingObservation], now: TimeInterval,
                         promptInProgress: Bool = false) {
        let owners = Set(prompted.map { owner($0) })
        for (id, observation) in observations where owners.contains(owner(id)) {
            // Do not accumulate retired windows between calls. A scanner can
            // report the previous call's end long after its consent was cleared.
            if prompted.contains(id) { observedIDs.insert(id) }
            if case .present = observation { observedIDs.insert(id) }
        }
        for owner in owners {
            let members = observedIDs.filter { self.owner($0) == owner }
            // Missing and unknown observations cannot establish a call end.
            guard !promptInProgress, !members.isEmpty,
                  members.allSatisfy({ observations[$0] == .ended }) else {
                endedSince.removeValue(forKey: owner)
                continue
            }
            if endedSince[owner] == nil { endedSince[owner] = now }
            if now - (endedSince[owner] ?? now) >= 30 {
                prompted = prompted.filter { self.owner($0) != owner }
                observedIDs.subtract(members)
                endedSince.removeValue(forKey: owner)
                records.removeValue(forKey: owner)
                activeOwners.remove(owner)
                for member in members { self.owners.removeValue(forKey: member) }
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

/// WindowServer identity survives helper relaunch; the Teams launch date rejects
/// PID reuse. A title hash prevents a reused call window adopting old consent.
/// Missing identity is session-local and never saved as a PID-only suppression.
struct MeetingConsentIdentity: Equatable, Sendable {
    let processID: Int32
    let processStartedAt: Double
    let windowID: UInt32?
    let titleFingerprint: String?
    init(processID: Int32, processStartedAt: Double, windowID: UInt32?, title: String?) {
        self.processID = processID; self.processStartedAt = processStartedAt; self.windowID = windowID
        let normalized = title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        titleFingerprint = normalized.flatMap { $0.isEmpty ? nil : SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
    }
    var owner: String { "process:\(processID):\(processStartedAt):\(titleFingerprint ?? "unavailable")" }
    var persistable: Bool {
        processID > 0 && processStartedAt.isFinite && processStartedAt > 0 && windowID != nil && windowID != 0 && titleFingerprint != nil
    }
}
