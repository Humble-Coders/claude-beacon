import AppKit

/// Actions the status menu delegates back to the app.
protocol StatusActionsDelegate: AnyObject {
    func sendTestEvent()
    func openLog()
    func quit()
}

/// Owns the NSStatusItem: renders idle / red-flash / amber states, plays the
/// capped alert chime, and shows a dropdown listing the sessions that need you.
/// No window switching — clicking a session just marks it seen (stops its flash).
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let store: SessionStore
    weak var actions: StatusActionsDelegate?

    private var flashTimer: Timer?
    private var flashOn = true
    private var flashStart: Date?

    // Chime budget: each fresh alert grants up to `chimesPerAlert` chimes, spaced
    // `chimeInterval` apart, then silence — the icon keeps flashing regardless.
    private var chimeTimer: Timer?
    private var chimesOwed = 0
    private let chimesPerAlert = 3
    private let chimeInterval: TimeInterval = 2.0
    private let chimesCeiling = 30          // safety cap against pile-ups

    private enum Mode: Equatable { case idle, amber, red, done }
    private var currentMode: Mode = .idle

    // A finer sweep than Eviction, to self-clear "done" notifications on time.
    private var houseTimer: Timer?

    private lazy var idleImage: NSImage = Self.circleImage(color: .systemGreen, alpha: 1.0)
    private lazy var pausedImage: NSImage = Self.makePausedImage()

    // Alert frames, rebuilt whenever the displayed count changes.
    private var badgeText = ""
    private var redFrame = NSImage()
    private var redAltFrame = NSImage()
    private var amberFrame = NSImage()
    private var doneFrame = NSImage()

    /// Longest session name shown inline in the menu bar before truncation.
    private let maxTitleChars = 22

    init(store: SessionStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureButton()
        startHousekeeping()
        refresh()
    }

    private func startHousekeeping() {
        let t = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.store.expireDone()   // fires onChange → refresh when it clears one
            self.refresh()            // keep time-based state + "ago" labels fresh
        }
        RunLoop.main.add(t, forMode: .common)
        houseTimer = t
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = idleImage
        button.imagePosition = .imageLeft
        button.target = self
        button.action = #selector(statusClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    // MARK: - Refresh (called by store.onChange and eviction)

    func refresh() {
        guard let button = statusItem.button else { return }

        if Settings.shared.isPaused {
            stopFlash()
            stopChimes()
            currentMode = .idle
            button.image = pausedImage
            button.title = ""
            button.toolTip = "Claude Beacon — paused"
            return
        }

        // Three classes, in priority order. Sticky attention (needs action) wins,
        // then the transient "done" ding, then a bare idle prompt.
        let attn = store.alerting.filter { $0.isAttentionPending }
        let done = store.pending.filter { $0.isDonePending }
        let idle = Settings.shared.alertOnIdle ? store.alerting.filter { $0.isIdlePending } : []

        let headline: Session?
        let count: Int
        let mode: Mode
        if !attn.isEmpty {
            headline = attn.first; count = attn.count; mode = .red
        } else if !done.isEmpty {
            headline = done.first; count = done.count; mode = .done
            stopChimes()
        } else if !idle.isEmpty {
            headline = idle.first; count = idle.count; mode = .amber
            stopChimes()
        } else {
            headline = nil; count = 0; mode = .idle
            stopChimes()
        }

        // Rebuild badge frames if the number changed. Yellow uses dark text —
        // white-on-yellow is unreadable in the menu bar.
        let text = count > 1 ? "\(count)" : "!"
        if text != badgeText {
            badgeText = text
            redFrame    = Self.alertBadge(color: .systemRed,    text: text, textColor: .white)
            redAltFrame = Self.alertBadge(color: .systemYellow, text: text, textColor: .black)
            amberFrame  = Self.alertBadge(color: .systemOrange, text: text, textColor: .white)
            doneFrame   = Self.alertBadge(color: .systemBlue,   text: text, textColor: .white)
            if currentMode == .red { button.image = flashOn ? redFrame : redAltFrame }
        }

        setMode(mode)

        // Show the waiting session's name inline so you can read it without
        // opening the dropdown. Count lives in the badge.
        if let h = headline {
            button.title = " " + truncate(h.displayName, to: maxTitleChars)
        } else {
            button.title = ""
        }

        let waiting = attn.count + done.count + idle.count
        button.toolTip = waiting == 0
            ? "Claude Beacon — all clear"
            : "Claude Beacon — \(waiting) session\(waiting == 1 ? "" : "s") waiting"
    }

    /// Called (via the store) each time a session *newly* needs attention.
    /// Sticky attention gets the capped 3× chime budget; a finished turn gets a
    /// single distinct "done" ding.
    func newAlert(_ s: Session) {
        if s.isAttentionPending {
            grantChimes()
        } else if s.isDonePending {
            AlertSound.playDone()
        }
    }

    private func setMode(_ mode: Mode) {
        guard let button = statusItem.button else { return }
        if mode == currentMode {
            // Static modes: keep the current (possibly recounted) frame.
            switch mode {
            case .amber: button.image = amberFrame
            case .done:  button.image = doneFrame
            default:     break
            }
            return
        }
        currentMode = mode
        switch mode {
        case .idle:
            stopFlash()
            button.image = idleImage
        case .amber:
            stopFlash()
            button.image = amberFrame
        case .done:
            stopFlash()
            button.image = doneFrame
        case .red:
            startFlash()
        }
    }

    private func truncate(_ s: String, to n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }

    // MARK: - Chime (capped, per-alert budget)

    private func grantChimes() {
        guard Settings.shared.alertSound, !Settings.shared.isPaused else { return }
        chimesOwed = min(chimesOwed + chimesPerAlert, chimesCeiling)
        if chimeTimer == nil {
            // Play the first one immediately, then schedule the remainder.
            playChimeIfOwed()
            let t = Timer(timeInterval: chimeInterval, repeats: true) { [weak self] _ in
                self?.playChimeIfOwed()
            }
            RunLoop.main.add(t, forMode: .common)
            chimeTimer = t
        }
    }

    private func playChimeIfOwed() {
        guard Settings.shared.alertSound, !Settings.shared.isPaused else { stopChimes(); return }
        guard chimesOwed > 0 else { stopChimes(); return }
        chimesOwed -= 1
        AlertSound.playOnce()
        if chimesOwed <= 0 { stopChimes() }
    }

    private func stopChimes() {
        chimeTimer?.invalidate()
        chimeTimer = nil
        chimesOwed = 0
    }

    // MARK: - Flashing

    private func startFlash() {
        stopFlash()
        flashStart = Date()
        flashOn = true
        statusItem.button?.image = redFrame
        let t = Timer(timeInterval: 0.45, repeats: true) { [weak self] _ in
            self?.flashTick()
        }
        RunLoop.main.add(t, forMode: .common)
        flashTimer = t
    }

    private func flashTick() {
        guard let button = statusItem.button else { return }
        // After flashDurationSeconds, stop strobing and hold solid red so it
        // stays obvious without strobing forever.
        if let start = flashStart,
           Date().timeIntervalSince(start) > Settings.shared.flashDurationSeconds {
            flashTimer?.invalidate()
            flashTimer = nil
            button.image = redFrame
            return
        }
        flashOn.toggle()
        button.image = flashOn ? redFrame : redAltFrame
    }

    private func stopFlash() {
        flashTimer?.invalidate()
        flashTimer = nil
        flashStart = nil
        flashOn = true
    }

    // MARK: - Click handling

    @objc private func statusClicked() {
        // Any click opens the dropdown. No window switching.
        showMenu(buildMenu())
    }

    private func showMenu(_ menu: NSMenu) {
        guard let button = statusItem.button else { return }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.height + 4),
                   in: button)
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // 1. Sessions that need you, most urgent first: attention, then done,
        //    then idle; oldest first within a class.
        func rank(_ s: Session) -> Int {
            if s.isAttentionPending { return 0 }
            if s.isDonePending { return 1 }
            return 2
        }
        let waiting = store.pending.sorted { lhs, rhs in
            if rank(lhs) != rank(rhs) { return rank(lhs) < rank(rhs) }
            return (lhs.pendingSince ?? .distantFuture) < (rhs.pendingSince ?? .distantFuture)
        }
        if waiting.isEmpty {
            menu.addItem(disabledHeader("No sessions need you"))
        } else {
            menu.addItem(disabledHeader("Needs your attention"))
            for s in waiting {
                let item = NSMenuItem(title: attentionLabel(s),
                                      action: #selector(acknowledgeSession(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = s.sessionID
                // A dot shows urgency; acknowledged items are dimmed via a checkmark.
                item.state = (s.acknowledgedAt != nil) ? .on : .off
                menu.addItem(item)
            }
        }

        // 2. Other recent sessions (context only).
        let waitingIDs = Set(waiting.map { $0.sessionID })
        let others = store.all.filter { !waitingIDs.contains($0.sessionID) }.prefix(6)
        if !others.isEmpty {
            menu.addItem(.separator())
            menu.addItem(disabledHeader("Recent"))
            for s in others {
                let item = NSMenuItem(title: "○ \(s.displayName) · \(s.hostLabel)",
                                      action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        appendCommonItems(to: menu)
        return menu
    }

    /// Preferences / pause / test / log / quit.
    private func appendCommonItems(to menu: NSMenu) {
        addCheckItem(menu, "Alert on idle sessions", checked: Settings.shared.alertOnIdle, action: #selector(toggleAlertOnIdle))
        addCheckItem(menu, "Alert sound", checked: Settings.shared.alertSound, action: #selector(toggleAlertSound))
        addCheckItem(menu, "System notifications", checked: Settings.shared.systemNotifications, action: #selector(toggleNotifications))
        addCheckItem(menu, "Launch at login", checked: Settings.shared.launchAtLogin, action: #selector(toggleLaunchAtLogin))
        menu.addItem(.separator())

        if Settings.shared.isPaused {
            let until = Settings.shared.pausedUntil ?? Date()
            let item = NSMenuItem(title: "Resume (paused until \(timeString(until)))", action: #selector(resumeBeacon), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        } else {
            let item = NSMenuItem(title: "Pause for 1 hour", action: #selector(pauseBeacon), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        addItem(menu, "Send Test Event", #selector(doSendTestEvent))
        addItem(menu, "Open Log", #selector(doOpenLog))
        menu.addItem(.separator())
        addItem(menu, "Quit Claude Beacon", #selector(doQuit))
    }

    // MARK: Menu action targets

    /// Clicking a waiting session just marks it seen — stops its flash without
    /// removing it (it clears for real when you actually act on it).
    @objc private func acknowledgeSession(_ sender: NSMenuItem) {
        guard let sid = sender.representedObject as? String else { return }
        store.acknowledge(sid)
    }
    @objc private func toggleAlertOnIdle() { Settings.shared.alertOnIdle.toggle(); refresh() }
    @objc private func toggleAlertSound() {
        Settings.shared.alertSound.toggle()
        if Settings.shared.alertSound { AlertSound.preview() } else { stopChimes() }
    }
    @objc private func toggleNotifications() { Settings.shared.systemNotifications.toggle() }
    @objc private func toggleLaunchAtLogin() { Settings.shared.launchAtLogin.toggle() }
    @objc private func pauseBeacon() { Settings.shared.pause(for: 3600); refresh() }
    @objc private func resumeBeacon() { Settings.shared.resume(); refresh() }
    @objc private func doSendTestEvent() { actions?.sendTestEvent() }
    @objc private func doOpenLog() { actions?.openLog() }
    @objc private func doQuit() { actions?.quit() }

    // MARK: Menu helpers

    private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private func addCheckItem(_ menu: NSMenu, _ title: String, checked: Bool, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = checked ? .on : .off
        menu.addItem(item)
    }

    private func disabledHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func attentionLabel(_ s: Session) -> String {
        let dot: String
        if s.isAttentionPending { dot = "🔴 " }
        else if s.isDonePending { dot = "✅ " }
        else { dot = "🟠 " }
        return "\(dot)\(s.displayName) · \(s.typeLabel) · \(ago(s.pendingSince)) · \(s.hostLabel)"
    }

    private func ago(_ date: Date?) -> String {
        guard let date = date else { return "—" }
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter(); f.timeStyle = .short; return f.string(from: date)
    }

    // MARK: - Image drawing

    /// A drawn notification-style badge: a filled rounded pill in `color` with
    /// white bold `text` ("!" for a single alert, or the count).
    static func alertBadge(color: NSColor, text: String, textColor: NSColor = .white) -> NSImage {
        let h: CGFloat = 16
        let font = NSFont.systemFont(ofSize: 11, weight: .heavy)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let str = NSAttributedString(string: text, attributes: attrs)
        let textSize = str.size()
        let w = max(h, textSize.width + 9)

        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        let rect = NSRect(x: 0.5, y: 1, width: w - 1, height: h - 2)
        let radius = (h - 2) / 2
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        let origin = NSPoint(x: (w - textSize.width) / 2, y: (h - textSize.height) / 2)
        str.draw(at: origin)
        img.unlockFocus()
        img.isTemplate = false
        return img
    }

    private static func makePausedImage() -> NSImage {
        if let img = NSImage(systemSymbolName: "pause.circle", accessibilityDescription: "Claude Beacon paused") {
            img.isTemplate = true
            return img
        }
        return circleImage(color: .systemGreen, alpha: 1.0)
    }

    /// A filled circle glyph rendered at menu-bar size.
    static func circleImage(color: NSColor, alpha: CGFloat) -> NSImage {
        let d: CGFloat = 12
        let size = NSSize(width: d + 2, height: d + 2)
        let img = NSImage(size: size)
        img.lockFocus()
        let rect = NSRect(x: 1, y: 1, width: d, height: d)
        color.withAlphaComponent(alpha).setFill()
        NSBezierPath(ovalIn: rect).fill()
        img.unlockFocus()
        img.isTemplate = false
        return img
    }
}
