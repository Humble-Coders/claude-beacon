import AppKit
import UserNotifications

@main
struct ClaudeBeaconApp {
    // NSApplication.delegate is weak, so hold the delegate strongly here.
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // LSUIElement / menu bar only
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, StatusActionsDelegate {
    private let store = SessionStore()
    private lazy var watcher = EventWatcher(store: store)     // terminal + desktop hooks
    private lazy var logWatcher = LogWatcher(store: store)    // desktop permission/question prompts
    private lazy var controller = StatusItemController(store: store)
    private lazy var notifier = Notifier(store: store)
    private lazy var eviction = Eviction(store: store)

    func applicationDidFinishLaunching(_ notification: Notification) {
        BeaconPaths.ensure()
        Log.write("ClaudeBeacon launching (pid \(ProcessInfo.processInfo.processIdentifier))")

        controller.actions = self

        // Store changes drive the icon; new red alerts drive chime + notification.
        store.onChange = { [weak self] in self?.controller.refresh() }
        store.onNewAlert = { [weak self] session in
            self?.controller.newAlert(session)
            self?.notifier.handleNewAlert(session)
        }

        notifier.start()
        watcher.start()          // replays event spool, then arms the kqueue watch
        logWatcher.start()       // tails the desktop app log
        eviction.start()
        controller.refresh()

        Log.write("ClaudeBeacon ready; tracking \(store.sessions.count) session(s)")
    }

    // MARK: - StatusActionsDelegate

    /// Write a fake pending event so the user can see the flash + chime.
    func sendTestEvent() {
        BeaconPaths.ensure()
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        let event: [String: Any] = [
            "v": 1,
            "type": "pending",
            "ts": ts,
            "session_id": "beacon-test-event",
            "cwd": FileManager.default.homeDirectoryForCurrentUser.path,
            "project": "TEST",
            "notification_type": "permission_prompt",
            "message": "This is a Claude Beacon test event.",
            "host": [
                "host_type": "claude_desktop",
                "tty": NSNull(),
                "claude_pid": ProcessInfo.processInfo.processIdentifier,
                "term_program": NSNull(),
                "term_program_version": NSNull(),
                "iterm_session_uuid": NSNull(),
                "term_session_id": NSNull(),
                "tmux_pane": NSNull(),
                "wezterm_pane": NSNull(),
                "kitty_window_id": NSNull(),
            ],
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: event)
            let tmp = BeaconPaths.events.appendingPathComponent(".tmp-test-\(ts).json")
            let final = BeaconPaths.events.appendingPathComponent("\(ts)-test.json")
            try data.write(to: tmp)
            try FileManager.default.moveItem(at: tmp, to: final)
            Log.write("test event written")
        } catch {
            Log.write("test event write failed: \(error)")
        }
    }

    func openLog() {
        NSWorkspace.shared.open(BeaconPaths.log)
    }

    func quit() {
        watcher.stop()
        logWatcher.stop()
        eviction.stop()
        NSApp.terminate(nil)
    }
}
