import AppKit
import UserNotifications

/// Optional macOS notifications. On a fresh red alert, posts a notification
/// naming the session that needs you. Clicking it just dismisses the beacon's
/// flash for that session (there is no window switching).
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let store: SessionStore
    private var lastNotified: [String: Date] = [:]
    private let throttle: TimeInterval = 3   // coalesce rapid bursts only

    init(store: SessionStore) {
        self.store = store
        super.init()
    }

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                Log.write("notification auth error: \(error)")
            } else {
                Log.write("notification auth granted=\(granted)")
            }
        }
    }

    /// Called (via the store) when a session newly needs attention with a red alert.
    func handleNewAlert(_ s: Session) {
        guard Settings.shared.systemNotifications else { return }
        guard !Settings.shared.isPaused else { return }
        guard s.isAttentionPending || s.isDonePending else { return }

        if let last = lastNotified[s.sessionID], Date().timeIntervalSince(last) < throttle {
            return
        }
        lastNotified[s.sessionID] = Date()

        let content = UNMutableNotificationContent()
        switch s.typeLabel {
        case "question":   content.title = "Claude has a question"
        case "permission": content.title = "Claude needs approval"
        case "done":       content.title = "Claude finished"
        default:           content.title = "Claude needs you"
        }
        content.body = "\(s.displayName): \(s.message ?? "Waiting for your response")"
        content.sound = .default
        content.userInfo = ["session_id": s.sessionID]

        let request = UNNotificationRequest(
            identifier: "beacon-\(s.sessionID)-\(Int(Date().timeIntervalSince1970))",
            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error { Log.write("notification post failed: \(error)") }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    // Show notifications even while the app is frontmost.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // Clicking the notification just marks the session seen (stops its flash).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        guard let sid = response.notification.request.content.userInfo["session_id"] as? String else { return }
        store.acknowledge(sid)
    }
}
