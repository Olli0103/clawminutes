import Foundation
@preconcurrency import UserNotifications

@MainActor
final class NativeNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NativeNotifications()
    enum Action: String { case openNotes = "open_notes", keepRecording = "keep_recording", openSound = "open_sound" }
    enum Category: String { case notesReady = "notes_ready", callEnd = "call_end", audioWarning = "audio_warning" }
    var onAction: ((Action, [String: String]) -> Void)?

    enum NotificationError: Error, CustomStringConvertible {
        case appRequired, denied, deliveryUnconfirmed
        var description: String {
            switch self {
            case .appRequired: return "Run the installed ocmh.app to use native notifications."
            case .denied: return "Enable ocmh in System Settings > Notifications."
            case .deliveryUnconfirmed: return "Notification Center delivery could not be confirmed."
            }
        }
    }

    private func center() throws -> UNUserNotificationCenter {
        guard Bundle.main.bundleIdentifier == "ai.openclaw.teams-transcribe",
              Bundle.main.bundleURL.pathExtension == "app" else { throw NotificationError.appRequired }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Category.notesReady.rawValue, actions: [UNNotificationAction(identifier: Action.openNotes.rawValue, title: "Open notes", options: [.foreground])], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.callEnd.rawValue, actions: [UNNotificationAction(identifier: Action.keepRecording.rawValue, title: "Keep recording", options: [])], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.audioWarning.rawValue, actions: [UNNotificationAction(identifier: Action.openSound.rawValue, title: "Open Sound settings", options: [.foreground])], intentIdentifiers: [])
        ])
        return center
    }

    func authorize() async throws {
        let center = try center()
        var settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try await center.requestAuthorization(options: [.alert])
            settings = await center.notificationSettings()
        }
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            throw NotificationError.denied
        }
    }

    func status() async throws -> [String: Any] {
        let settings = await (try center()).notificationSettings()
        let authorization: String
        switch settings.authorizationStatus {
        case .notDetermined: authorization = "not_determined"
        case .denied: authorization = "denied"
        case .authorized: authorization = "authorized"
        case .provisional: authorization = "provisional"
        @unknown default: authorization = "unknown"
        }
        return ["authorization": authorization,
                "alerts_enabled": settings.alertSetting == .enabled,
                "notification_center_enabled": settings.notificationCenterSetting == .enabled,
                "bundle_id": Bundle.main.bundleIdentifier ?? ""]
    }

    static func content(title: String, body: String, category: Category? = nil, context: [String: String] = [:]) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        let prefix = "ocmh: "
        content.title = title.hasPrefix(prefix) ? String(title.dropFirst(prefix.count)) : title
        content.body = body
        content.categoryIdentifier = category?.rawValue ?? ""
        content.userInfo = context
        return content
    }

    func send(title: String, body: String, category: Category? = nil, context: [String: String] = [:]) async throws -> String {
        try await authorize()
        let center = try center()
        let identifier = UUID().uuidString
        try await center.add(UNNotificationRequest(identifier: identifier, content: Self.content(title: title, body: body, category: category, context: context), trigger: nil))
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(300))
            let delivered = await center.deliveredNotifications()
            if delivered.contains(where: { $0.request.identifier == identifier }) { return identifier }
        }
        throw NotificationError.deliveryUnconfirmed
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let identifier = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        let context = response.notification.request.content.userInfo as? [String: String] ?? [:]
        let action = Action(rawValue: identifier)
            ?? (identifier == UNNotificationDefaultActionIdentifier && category == Category.notesReady.rawValue ? .openNotes : nil)
        Task { @MainActor [weak self] in
            if let action { self?.onAction?(action, context) }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }
}

func notifyUser(title: String, body: String, category: NativeNotifications.Category? = nil, context: [String: String] = [:]) {
    Task { @MainActor in
        do {
            let id = try await NativeNotifications.shared.send(title: title, body: body, category: category, context: context)
            FileHandle.standardError.write(Data("ocmh notification delivered: \(id)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("ocmh notification failed: \(error)\n".utf8))
        }
    }
}
