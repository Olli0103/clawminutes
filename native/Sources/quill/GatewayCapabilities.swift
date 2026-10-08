import Foundation

/// One text protocol shared by connection checks and each delivery preflight.
/// A successful HTTP response alone does not establish archive compatibility.
struct GatewayCapabilities: Decodable, Sendable {
    struct Features: Decodable, Sendable {
        let textEnvelope: Int
        let structuredErrors: Int
        let idempotentCompletedSave: Bool
        let cappedNotesAttempts: Int
        let revisions: Int
        let notesRecovery: Int
        let receiptVerification: Int?
        let captureGapEvidence: Int?
        let maximumCaptureGaps: Int?
    }
    struct Archive: Decodable, Sendable {
        let adapterVersion: Int
        let sdkVersion: String
        let verification: String
    }
    let plugin: String
    let protocolVersion: Int
    let rawAudioAccepted: Bool
    let capabilities: Features
    let archive: Archive
    let gatewayMachine: String
    let notesModelConfigured: String?

    static let unsupported = DeliveryFailure(code: "plugin_update_needed",
        detail: "The helper and Gateway do not share a verified text/archive protocol. Check their plugin versions before retrying. Local files are preserved; no meeting was sent.",
        retryable: false, completionAttempted: false)

    static func verify(_ data: Data) throws -> Self {
        guard data.count <= 16_384, let value = try? JSONDecoder().decode(Self.self, from: data),
              value.plugin == "teams-transcribe", value.protocolVersion == 1, !value.rawAudioAccepted,
              value.capabilities.textEnvelope == 1, value.capabilities.structuredErrors == 1,
              value.capabilities.idempotentCompletedSave, value.capabilities.cappedNotesAttempts == 3,
              value.capabilities.revisions == 1, value.capabilities.notesRecovery == 1,
              value.archive.adapterVersion == 1, ["2026.9.7", "2026.9.8"].contains(value.archive.sdkVersion),
              value.archive.verification == "isolated-readback-v1",
              safeDisplay(value.gatewayMachine), value.notesModelConfigured == nil || safeDisplay(value.notesModelConfigured!) else {
            throw unsupported
        }
        return value
    }
    /// Older Gateways accept seven reasons and at most 32 ranges. Require the
    /// expanded contract only when this particular text package needs it.
    func verifyCaptureEvidence(in body: Data) throws {
        guard let value = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let transcript = value["transcript"] as? [String: Any] else { throw Self.unsupported }
        guard let raw = transcript["capture_gaps"] else { return }
        guard let gaps = raw as? [[String: Any]] else { throw Self.unsupported }
        let expanded = Set(["boundary_context_unverified", "capture_timing_uncertain", "rotation_pending"])
        let needsExpanded = gaps.count > 32 || gaps.contains { expanded.contains($0["reason"] as? String ?? "") }
        if needsExpanded {
            guard capabilities.captureGapEvidence == 2,
                  let maximum = capabilities.maximumCaptureGaps,
                  gaps.count <= min(4096, maximum) else { throw Self.unsupported }
        }
    }
    private static func safeDisplay(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 256 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    var description: String {
        "Gateway connected: \(gatewayMachine)\nArchive adapter verified: OpenClaw \(archive.sdkVersion)\nAI notes model configured: \(notesModelConfigured ?? "unavailable")"
    }
}
