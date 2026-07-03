import Foundation
import ServiceManagement

/// UserDefaults-backed settings plus the transient "pause" state.
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private enum Key {
        static let alertOnIdle = "alertOnIdle"
        static let alertSound = "alertSound"
        static let systemNotifications = "systemNotifications"
        static let flashDurationSeconds = "flashDurationSeconds"
        static let pausedUntil = "pausedUntil"
    }

    init() {
        d.register(defaults: [
            Key.alertOnIdle: true,
            Key.alertSound: true,
            Key.systemNotifications: true,
            Key.flashDurationSeconds: 45.0,
        ])
    }

    var alertOnIdle: Bool {
        get { d.bool(forKey: Key.alertOnIdle) }
        set { d.set(newValue, forKey: Key.alertOnIdle) }
    }

    var alertSound: Bool {
        get { d.bool(forKey: Key.alertSound) }
        set { d.set(newValue, forKey: Key.alertSound) }
    }

    var systemNotifications: Bool {
        get { d.bool(forKey: Key.systemNotifications) }
        set { d.set(newValue, forKey: Key.systemNotifications) }
    }

    var flashDurationSeconds: Double {
        get { d.double(forKey: Key.flashDurationSeconds) }
        set { d.set(newValue, forKey: Key.flashDurationSeconds) }
    }

    // MARK: Pause

    var pausedUntil: Date? {
        get { d.object(forKey: Key.pausedUntil) as? Date }
        set { d.set(newValue, forKey: Key.pausedUntil) }
    }

    var isPaused: Bool {
        guard let until = pausedUntil else { return false }
        return until > Date()
    }

    func pause(for interval: TimeInterval) {
        pausedUntil = Date().addingTimeInterval(interval)
    }

    func resume() {
        pausedUntil = nil
    }

    // MARK: Launch at login (SMAppService)

    var launchAtLogin: Bool {
        get {
            if #available(macOS 13.0, *) {
                return SMAppService.mainApp.status == .enabled
            }
            return false
        }
        set {
            guard #available(macOS 13.0, *) else { return }
            do {
                if newValue {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else {
                    if SMAppService.mainApp.status == .enabled {
                        try SMAppService.mainApp.unregister()
                    }
                }
            } catch {
                Log.write("launchAtLogin toggle failed: \(error)")
            }
        }
    }
}
