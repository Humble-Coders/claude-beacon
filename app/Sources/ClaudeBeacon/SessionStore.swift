import Foundation

// MARK: - Wire format (matches beacon-hook event files)

/// Host context captured by the hook.
struct HostContext: Codable, Equatable {
    var host_type: String
    var tty: String?
    var claude_pid: Int?
    var term_program: String?
    var term_program_version: String?
    var iterm_session_uuid: String?
    var term_session_id: String?
    var tmux_pane: String?
    var wezterm_pane: String?
    var kitty_window_id: String?

    static func desktop(pid: Int?) -> HostContext {
        HostContext(host_type: "claude_desktop", tty: nil, claude_pid: pid,
                    term_program: nil, term_program_version: nil,
                    iterm_session_uuid: nil, term_session_id: nil,
                    tmux_pane: nil, wezterm_pane: nil, kitty_window_id: nil)
    }
}

/// One event file written by the hook.
struct BeaconEvent: Codable {
    var v: Int
    var type: String            // register | pending | attended | ended
    var ts: Int64
    var session_id: String
    var cwd: String
    var project: String
    var notification_type: String?
    var message: String?
    var host: HostContext
}

// MARK: - Reduced session state

/// A tracked Claude Code session, reduced from two independent signal sources:
///
///  1. **Hooks** (terminal + desktop): register / attended / ended, plus a
///     `waiting` flag raised by a Notification hook (terminal permission/idle)
///     or a finished turn (`turn_complete`). Cleared by the next user activity.
///
///  2. **Desktop app log** (desktop only): permission/question prompts that the
///     desktop app handles internally and never surfaces to hooks. Each open
///     prompt is tracked by its request id in `openRequests` and cleared when
///     the matching response is logged.
///
/// A session needs attention when `isPending` — either it has ≥1 unanswered
/// desktop prompt, or the hook `waiting` flag is set. The two mechanisms are
/// deliberately independent so neither can clobber the other.
struct Session: Codable, Equatable {
    var sessionID: String            // CLI session UUID (unifies hook + log)
    var project: String              // folder basename (from hooks)
    var title: String?               // desktop session title (from the log store)
    var cwd: String
    var host: HostContext
    var claudePID: Int?
    var lastEventTS: Int64

    /// Desktop permission/question prompts awaiting a response: reqID → kind
    /// ("permission" | "question"). Non-empty ⇒ needs attention.
    var openRequests: [String: String] = [:]

    /// Hook-driven "waiting for you" flag (terminal permission/idle, or a
    /// finished turn on either surface). Cleared by the next user activity.
    var waiting: Bool = false
    var waitingReason: String?       // permission_prompt | idle_prompt | elicitation_dialog | turn_complete

    var message: String?
    var pendingSince: Date?

    /// For a finished turn (`turn_complete`): when the transient "done" state
    /// self-clears. Done is a notification, not a nag — it never requires a user
    /// signal to go away.
    var doneExpiresAt: Date?

    /// Set when the user has been shown this session (clicked it in the beacon
    /// dropdown). While non-nil the session no longer drives the flash, though
    /// it stays in the list until actually resolved. Reset on any fresh alert.
    var acknowledgedAt: Date?

    // MARK: Derived

    /// **Sticky** attention that waits for a user action: a desktop permission /
    /// question prompt, or a terminal permission / elicitation. Clears only when
    /// actually resolved.
    var isAttentionPending: Bool {
        if !openRequests.isEmpty { return true }
        guard waiting else { return false }
        return waitingReason == "permission_prompt" || waitingReason == "elicitation_dialog"
    }

    /// **Transient** "finished a turn" state — self-clears at `doneExpiresAt`.
    var isDonePending: Bool {
        guard waiting, waitingReason == "turn_complete" else { return false }
        if let e = doneExpiresAt { return Date() < e }
        return false
    }

    /// A low-urgency "you've been idle" prompt with nothing else outstanding.
    var isIdlePending: Bool {
        guard openRequests.isEmpty, waiting, waitingReason == "idle_prompt" else { return false }
        return true
    }

    /// True when the session is showing anything to the user right now.
    var isPending: Bool { isAttentionPending || isDonePending || isIdlePending }

    /// Short, human label describing why it's waiting.
    var typeLabel: String {
        if openRequests.values.contains("question") { return "question" }
        if !openRequests.isEmpty { return "permission" }
        switch waitingReason {
        case "permission_prompt": return "permission"
        case "elicitation_dialog": return "question"
        case "idle_prompt": return "idle"
        case "turn_complete": return "done"
        default: return waitingReason ?? "waiting"
        }
    }

    /// Best human name for menus: the desktop title when known, else the folder.
    var displayName: String {
        if let t = title, !t.isEmpty { return t }
        return project
    }

    var hostLabel: String {
        switch host.host_type {
        case "iterm2": return "iTerm2"
        case "apple_terminal": return "Terminal"
        case "vscode": return "VS Code"
        case "wezterm": return "WezTerm"
        case "kitty": return "kitty"
        case "claude_desktop": return "Claude"
        case let t where t.hasPrefix("tmux+"): return "tmux"
        default: return host.host_type
        }
    }
}

// MARK: - Store

/// Reduces all signal sources into per-session state and persists a snapshot.
/// All access is expected on the main queue (both watchers dispatch there).
final class SessionStore {
    /// How long a finished-turn ("done") notification lingers before it
    /// self-clears — it never needs a user action to go away.
    static let doneLinger: TimeInterval = 30

    private(set) var sessions: [String: Session] = [:]

    /// Called after any mutation so the UI can refresh.
    var onChange: (() -> Void)?

    /// Called whenever a session *newly* needs attention with a red alert — one
    /// call per distinct new prompt / finished turn. Drives chimes + notifications.
    var onNewAlert: ((Session) -> Void)?

    init() {
        load()
    }

    /// Sessions currently waiting, oldest first (includes acknowledged ones).
    var pending: [Session] {
        sessions.values
            .filter { $0.isPending }
            .sorted { ($0.pendingSince ?? .distantFuture) < ($1.pendingSince ?? .distantFuture) }
    }

    /// Sessions actively demanding attention: pending AND not yet acknowledged.
    var alerting: [Session] {
        pending.filter { $0.acknowledgedAt == nil }
    }

    var all: [Session] {
        sessions.values.sorted { $0.lastEventTS > $1.lastEventTS }
    }

    // MARK: Hook event reduction

    /// Apply a single hook event (register / pending / attended / ended).
    @discardableResult
    func apply(_ e: BeaconEvent) -> Bool {
        let now = Date(timeIntervalSince1970: Double(e.ts) / 1000.0)
        var newAlert = false

        switch e.type {
        case "register":
            var s = sessions[e.session_id] ?? Session(
                sessionID: e.session_id, project: e.project, title: nil, cwd: e.cwd,
                host: e.host, claudePID: e.host.claude_pid, lastEventTS: e.ts)
            s.project = e.project
            s.cwd = e.cwd
            s.host = e.host
            s.claudePID = e.host.claude_pid
            s.lastEventTS = e.ts
            sessions[e.session_id] = s

        case "pending":
            var s = sessions[e.session_id] ?? Session(
                sessionID: e.session_id, project: e.project, title: nil, cwd: e.cwd,
                host: e.host, claudePID: e.host.claude_pid, lastEventTS: e.ts)
            let wasAttn = s.isAttentionPending
            s.project = e.project
            s.cwd = e.cwd
            s.host = e.host
            s.claudePID = e.host.claude_pid
            let reasonChanged = s.waitingReason != e.notification_type || s.message != e.message
            s.waiting = true
            s.waitingReason = e.notification_type
            s.message = e.message
            s.pendingSince = s.pendingSince ?? now
            s.lastEventTS = e.ts
            if e.notification_type == "turn_complete" {
                // The turn is over, so any desktop permission still marked "open"
                // is stale — its response/abort log line was missed (rotation,
                // restart, crash). Clear it, so this rings as a calm "done" ding
                // instead of a stuck red attention alert. This is safe: a
                // genuinely pending permission blocks the turn, so Stop cannot
                // fire while one is truly open. (We deliberately do NOT clear on
                // `attended` — PreToolUse fires mid-prompt, before you answer.)
                s.openRequests.removeAll()
                // A finished turn is a transient, self-clearing notification.
                s.doneExpiresAt = now.addingTimeInterval(Self.doneLinger)
                newAlert = s.isDonePending   // false for stale replayed events
            } else if s.isAttentionPending && (!wasAttn || reasonChanged) {
                s.acknowledgedAt = nil
                newAlert = true
            }
            sessions[e.session_id] = s

        case "attended":
            // The user acted (submitted a prompt / a tool ran). Clears the hook
            // `waiting` flag (and any lingering done state) — never the desktop
            // `openRequests`, which clear solely via their own logged responses.
            if var s = sessions[e.session_id] {
                s.waiting = false
                s.waitingReason = nil
                s.doneExpiresAt = nil
                s.lastEventTS = e.ts
                normalize(&s)
                sessions[e.session_id] = s
            }

        case "ended":
            sessions.removeValue(forKey: e.session_id)

        default:
            Log.write("unknown event type: \(e.type)")
        }

        finish(newAlert: newAlert, session: sessions[e.session_id])
        return newAlert
    }

    // MARK: Desktop app log signals

    /// A desktop permission/question prompt was emitted. `kind` is
    /// "question" (AskUserQuestion) or "permission" (any other tool).
    @discardableResult
    func desktopRequest(cliSessionID sid: String, title: String?, cwd: String?,
                        pid: Int?, kind: String, reqID: String, message: String?) -> Bool {
        let now = Date()
        var s = sessions[sid] ?? Session(
            sessionID: sid, project: (title ?? "Claude"), title: title,
            cwd: cwd ?? "", host: .desktop(pid: pid),
            claudePID: pid, lastEventTS: Int64(now.timeIntervalSince1970 * 1000))
        if let title = title, !title.isEmpty { s.title = title }
        if let cwd = cwd, !cwd.isEmpty { s.cwd = cwd }
        if s.host.host_type != "claude_desktop" { s.host = .desktop(pid: pid ?? s.claudePID) }
        if let pid = pid { s.claudePID = pid }

        // The app logs each line twice; a repeat reqID is a no-op, so a prompt
        // alerts exactly once. Every genuinely new reqID is a fresh alert.
        let inserted = s.openRequests[reqID] == nil
        s.openRequests[reqID] = kind
        s.message = message
        s.pendingSince = s.pendingSince ?? now
        s.lastEventTS = Int64(now.timeIntervalSince1970 * 1000)
        if inserted { s.acknowledgedAt = nil }

        sessions[sid] = s
        finish(newAlert: inserted, session: s)
        return inserted
    }

    /// A desktop prompt was answered. Clears that one request; the session goes
    /// idle when nothing else is outstanding. Returns true if a request actually
    /// cleared (the app double-logs each response, so the second call is a no-op).
    @discardableResult
    func desktopResolve(reqID: String) -> Bool {
        guard let sid = sessions.first(where: { $0.value.openRequests[reqID] != nil })?.key else { return false }
        var s = sessions[sid]!
        s.openRequests.removeValue(forKey: reqID)
        s.lastEventTS = Int64(Date().timeIntervalSince1970 * 1000)
        normalize(&s)
        sessions[sid] = s
        finish(newAlert: false, session: s)
        return true
    }

    // MARK: User actions

    /// Mark a session acknowledged (user opened it from the dropdown). Stops the
    /// flash without removing it from the waiting list.
    func acknowledge(_ sessionID: String) {
        if var s = sessions[sessionID], s.isPending, s.acknowledgedAt == nil {
            s.acknowledgedAt = Date()
            sessions[sessionID] = s
            persist()
            onChange?()
        }
    }

    /// Clear any finished-turn state whose linger has elapsed. Returns true if
    /// anything changed (so the caller can refresh the icon).
    @discardableResult
    func expireDone() -> Bool {
        var changed = false
        for (id, var s) in sessions {
            if s.waiting, s.waitingReason == "turn_complete",
               let e = s.doneExpiresAt, Date() >= e {
                s.waiting = false
                s.waitingReason = nil
                s.doneExpiresAt = nil
                normalize(&s)
                sessions[id] = s
                changed = true
            }
        }
        if changed { persist(); onChange?() }
        return changed
    }

    /// Remove a session outright (used by eviction).
    func remove(_ sessionID: String) {
        if sessions.removeValue(forKey: sessionID) != nil {
            persist()
            onChange?()
        }
    }

    // MARK: Internals

    /// Clear derived alert bookkeeping once a session is no longer pending.
    private func normalize(_ s: inout Session) {
        if !s.isPending {
            s.pendingSince = nil
            s.acknowledgedAt = nil
            s.message = nil
        }
    }

    private func finish(newAlert: Bool, session: Session?) {
        persist()
        onChange?()
        if newAlert, let s = session, s.isAttentionPending || s.isDonePending {
            onNewAlert?(s)
        }
    }

    // MARK: Persistence

    private func persist() {
        let snapshot = Array(sessions.values)
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: BeaconPaths.state, options: .atomic)
        } catch {
            Log.write("persist failed: \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: BeaconPaths.state) else { return }
        do {
            let snapshot = try JSONDecoder().decode([Session].self, from: data)
            for var s in snapshot {
                // Desktop permission prompts don't survive a restart: any that
                // were "open" when we last ran have almost certainly been answered
                // during the downtime (and the desktop app still shows any that
                // haven't). Carrying them over is the main way a stuck red light
                // happens, so drop them on load.
                s.openRequests.removeAll()
                sessions[s.sessionID] = s
            }
            Log.write("loaded \(snapshot.count) session(s) from state.json")
        } catch {
            // Schema change or corruption — start fresh; sessions repopulate as
            // events flow in. Never fatal.
            Log.write("state.json load skipped (\(error)); starting fresh")
        }
    }
}
