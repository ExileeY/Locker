import Foundation
import UserNotifications

/// Posts "Claude needs your input" notifications. Behind a protocol so `AppModel` can be given a stub.
@MainActor
protocol Notifying: AnyObject {
    /// Called when the user clicks a notification.
    var onOpenWorkspace: ((UUID) -> Void)? { get set }
    func requestAuthorization()
    func notifyNeedsInput(workspaceID: UUID, name: String)
    func clear(workspaceID: UUID)
}

@MainActor
final class NotificationService: NSObject, Notifying, UNUserNotificationCenterDelegate {
    var onOpenWorkspace: ((UUID) -> Void)?
    private var center: UNUserNotificationCenter { .current() }

    override init() {
        super.init()
        // Unit tests and tools run without an app bundle, where UNUserNotificationCenter would trap.
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        center.delegate = self
    }

    private var available: Bool { center.delegate === self }

    func requestAuthorization() {
        guard available else { return }
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifyNeedsInput(workspaceID: UUID, name: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = "Locker · \(name)"
        content.body = "Claude needs your input"
        content.sound = .default
        content.userInfo = ["workspaceID": workspaceID.uuidString]
        // One identifier per workspace: a new request replaces a stale banner.
        center.add(UNNotificationRequest(identifier: workspaceID.uuidString, content: content, trigger: nil))
    }

    func clear(workspaceID: UUID) {
        guard available else { return }
        center.removeDeliveredNotifications(withIdentifiers: [workspaceID.uuidString])
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let raw = response.notification.request.content.userInfo["workspaceID"] as? String
        Task { @MainActor in
            if let raw, let id = UUID(uuidString: raw) { self.onOpenWorkspace?(id) }
            completionHandler()
        }
    }

    /// Show the banner even while Locker is frontmost (the user may be on a different workspace).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
