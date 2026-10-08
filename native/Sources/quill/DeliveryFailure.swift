import Foundation

/// Persistable recovery instructions. Details never contain auth headers or raw responses.
struct DeliveryFailure: Error, Codable, Sendable, CustomStringConvertible {
    let code: String
    let detail: String
    let retryable: Bool
    let completionAttempted: Bool
    var description: String { detail }

    static let signInRequired = DeliveryFailure(code: "sign_in_required", detail: "Gateway sign-in expired or access was denied. Sign in to send waiting meetings.", retryable: false, completionAttempted: false)

    static func classify(_ error: Error) -> DeliveryFailure {
        if let failure = error as? DeliveryFailure { return failure }
        if error is GatewayArchive.ConnectionIssue {
            return DeliveryFailure(code: "plugin_unavailable", detail: "The Gateway is not accepting meetings. Local files are safe.", retryable: true, completionAttempted: false)
        }
        if error is URLError {
            return DeliveryFailure(code: "network_unavailable", detail: "The Gateway could not be reached. Local files are safe.", retryable: true, completionAttempted: false)
        }
        return DeliveryFailure(code: "local_save_failed", detail: "The meeting could not be saved. Review its details before retrying.", retryable: false, completionAttempted: false)
    }

    static func response(status: Int, data: Data) -> DeliveryFailure {
        if let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = value["code"] as? String, code.range(of: #"^[a-z][a-z0-9_]{0,79}$"#, options: .regularExpression) != nil,
           let detail = value["detail"] as? String, !detail.isEmpty, detail.count <= 512,
           !detail.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
           let retryable = value["retryable"] as? Bool,
           let attempted = value["completionAttempted"] as? Bool {
            return DeliveryFailure(code: code, detail: detail, retryable: retryable, completionAttempted: attempted)
        }
        if [301, 302, 303, 307, 308, 401, 403].contains(status) {
            return signInRequired
        }
        if status == 404 {
            return DeliveryFailure(code: "plugin_unavailable", detail: "The Gateway is not accepting meetings. Check the plugin connection.", retryable: true, completionAttempted: false)
        }
        return DeliveryFailure(code: status >= 500 ? "gateway_unavailable" : "plugin_update_needed",
                               detail: status >= 500 ? "The Gateway could not finish this save. Local files are safe." : "The Gateway could not accept this meeting. Check the plugin version and meeting details.",
                               retryable: status >= 500, completionAttempted: false)
    }
}
