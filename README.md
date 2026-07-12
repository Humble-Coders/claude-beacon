# Claude Beacon

A macOS menu bar utility that **flashes the instant any Claude Code session
needs your attention** — waiting to run a tool, asking you a question, or done
with its turn — whether it's running in a terminal or the Claude desktop app.
Click the icon and a **dropdown lists the sessions waiting on you** by name.

- **Event-driven, no polling for state.** Terminal detection rides on Claude
  Code hooks; desktop detection tails the desktop app's own log. Both are
  instant — no screen scraping, no OCR, no window polling.
- **Read-only. No system permissions.** The beacon only watches files it is
  already allowed to read. No Accessibility, no Automation, no window control.
- **Local only.** No network. Everything is local files + kqueue watches.

## Quick install (macOS)

```sh
git clone https://github.com/Humble-Coders/claude-beacon.git && cd claude-beacon && ./install.sh
```

That's it — it builds the app locally and wires up the Claude Code hooks. You
need a Mac with **Xcode Command Line Tools** (`xcode-select --install`) and
**Homebrew** (for `jq`); the installer checks for these and does the rest.

> Restart any already-open **terminal** Claude sessions (or run `/hooks`) so they
> pick up the hooks. The desktop app needs no restart.

```
Terminal Claude Code                     Claude desktop app
   │  hooks: SessionStart, Notification,    │  hooks: SessionStart, PreToolUse,
   │  UserPromptSubmit, PreToolUse, Stop    │  UserPromptSubmit, Stop, SessionEnd
   │                                        │  + permission/question prompts, which
   ▼                                        │  hooks CAN'T see, appear in main.log
beacon-hook (fast bash, async, exit 0)      ▼
   │  writes one JSON event file       ~/Library/Logs/Claude/main.log
   ▼                                        │  "Emitted tool permission request…"
~/.claude-beacon/events/  (queue)           │  "Received permission response…"
   │  DispatchSource (kqueue)                │  DispatchSource tail + backstop poll
   ▼                                        ▼
ClaudeBeacon.app  (Swift, menu-bar only / LSUIElement)
   ├─ SessionStore  reduce both sources → per-session state (+ state.json)
   ├─ EventWatcher  kqueue watch on the hook event queue
   ├─ LogWatcher    tail the desktop app log for permission/question prompts
   ├─ StatusItem    green glyph / red flash / amber + capped chime + dropdown
   ├─ Notifier      optional notifications
   └─ Eviction      PID liveness + TTL cleanup
```

## Install

```sh
./install.sh
```

The installer:
1. Checks `jq` (installs via Homebrew if missing) and Xcode Command Line Tools.
2. `swift build -c release`, assembles `~/Applications/ClaudeBeacon.app`, ad-hoc
   codesigns it.
3. Installs `beacon-hook` to `~/.claude-beacon/bin/`.
4. Backs up `~/.claude/settings.json` → `settings.json.beacon-bak`, then
   **idempotently merges** the beacon hooks (your existing hooks are preserved).
5. Launches the app.

No system permissions are required. Allow notifications when macOS asks
(optional). Menu → **Send Test Event** to see the flash, hear the chime, and
open the dropdown.

> **Already-running terminal sessions** won't emit hook events until they reload
> hooks. Run `/hooks` in each session (or restart it). New sessions pick them up
> automatically. **Desktop** permission/question detection needs no reload — it
> reads the app log directly.

## Uninstall

```sh
./uninstall.sh
```

Removes the app, the login item, `~/.claude-beacon/`, and **only** the beacon
entries from `settings.json` (your own hooks stay).

## Menu / behavior

The indicator is a traffic light, and it **shows the waiting session's name
inline** next to the icon so you can read it without opening the dropdown:

- **All clear** — a calm **green** dot, no name.
- **Needs you** (sticky) — a **red badge** that blinks between bold red and
  bright yellow (dark, readable count on the yellow), with the session name
  beside it. This is a permission or a question — it waits until you act.
- **Done** (transient) — a calm solid **blue** badge with a distinct one-shot
  "completion" ding. A finished turn is a *notification*, not a nag: it
  **self-clears after ~30 s** with no action needed (see below).
- **Idle-only** — a solid **amber** badge, no blink, no sound. Toggle off with
  *Alert on idle*.

The badge count (`!` for one, `2`, `3`, …) is how many are waiting; the inline
name is the most urgent one.

**Click the icon to open the dropdown.** It lists, most-urgent first, every
session — by its real name (desktop session title, or the project folder for
terminals) — with what it wants (🔴 permission / question, ✅ done, 🟠 idle), how
long it's waited, and where it runs. Clicking a *sticky* session **marks it
seen** (stops its flash); it clears for real when you actually act on it.

**Sticky alerts clear themselves** when you respond directly. For terminals,
Claude's next hook event (`UserPromptSubmit` / `PreToolUse`) marks it attended;
for the desktop app, the logged "permission response" clears that prompt. Either
way the flash stops within ~1–2 s with no click needed.

### "Done" is a self-clearing notification

A finished turn plays a **distinct completion ding** (different from the
attention chime) and shows a calm blue badge for ~30 s, then **removes itself** —
it never requires a user signal to go away. Send your next message sooner and it
clears immediately. This is the fix for "done alerts that never went away."

### The attention chime is capped at 3 per alert

When a session first needs you (sticky), the beacon plays a gentle chime up to
**3 times** (≈2 s apart), then goes quiet — **the icon keeps flashing** until you
deal with it. Each session gets its own budget of 3, reset once it's cleared, so
a second session can chime again (up to 3), but no single alert ever nags more
than three times. ("Done" never uses this budget — it's a single ding.)

## What raises an alert

| Surface | Waiting to run a tool | Asking a question | Turn finished (done) | Idle a while |
|---|---|---|---|---|
| Terminal | ✅ `Notification` hook | ✅ `Notification` hook | ✅ `Stop` hook | ✅ `Notification` (amber) |
| Desktop app | ✅ app log | ✅ app log | ✅ `Stop` hook | — |

### Desktop app: how detection works

The Claude **desktop app doesn't fire the `Notification` hook** for permission /
question prompts — it handles them internally. So the beacon reads the desktop
app's own log, `~/Library/Logs/Claude/main.log`, where every prompt appears the
instant it's raised:

- `Emitted tool permission request <id> for <Tool> in session local_<uuid>` →
  the session needs you (covers both tool permissions **and** `AskUserQuestion`).
- `Received permission response for <id>` → you answered; clear it.

The `local_<uuid>` is mapped to the CLI session UUID and human title via the
desktop session store, so log-derived and hook-derived state merge into one
session, and the dropdown shows the real session name.

This path is **fail-safe**: it only ever *adds* desktop alerts. If a future
desktop build renames those log lines, desktop permission/question detection
simply goes quiet — nothing crashes, and every other signal (terminal hooks,
desktop "done") keeps working. That log line is the app's internal format, not
an official API — the one part of this tool that could need a touch-up across
desktop updates.

Note: the "turn finished" ding fires on **every** finished desktop turn,
including the session you're actively watching — but because it's a self-clearing
notification (not a sticky flash), that's unobtrusive. Pause or toggle sound if
it's ever too chatty.

## Settings (menu-driven, UserDefaults-backed)

- **Alert on idle sessions** (default on) — amber for a bare `idle_prompt`.
- **Alert sound** (default on) — a gentle "Submarine" chime, capped at 3 per
  alert. Toggling it on plays a preview.
- **System notifications** (default on) — a banner naming the session that needs
  you; click it to dismiss that session's flash.
- **Launch at login** — via `SMAppService`.
- **Pause for 1 hour** — silence everything temporarily.

## Reliability

- **No lost events** — the app replays the hook spool directory on launch, so
  events written while it was dead are processed on next start.
- **Log tail survives rotation** — the desktop log watcher reopens on
  rotation/truncation and has a 2 s backstop poll so no append is ever missed;
  reads are offset-guarded so nothing is processed twice.
- **No double alerts** — desktop prompts are de-duplicated by request id (the app
  logs each line twice), so a prompt chimes once, not twice.
- **No stuck light** — a desktop prompt clears on its logged **response** *or* its
  **`aborted`** line (interrupted / cancelled / superseded prompts end with the
  latter). As a self-heal for any missed line (log rotation, restart, crash), a
  finished turn (`Stop`) and app startup both drop any still-open request — safe
  because a genuinely pending permission blocks the turn. `SessionEnd` +
  a 30 s PID-liveness sweep (`kill(pid, 0)`) + a 12 h TTL are the final backstops.
- **Right chime for the right event** — because a stale open request can no longer
  linger, a finished turn always rings as the calm "done" ding, never the
  attention chime.
- **Never blocks Claude Code** — the hook is async, sub-50 ms, and always
  exits 0; a hook crash can't break a session.

## Debugging

- `~/.claude-beacon/beacon.log` — timestamped lines from both the hook and the
  app. Menu → **Open Log**.
- `~/.claude-beacon/bin/beacon-hook dump-env` — run inside any terminal (or the
  desktop app) to see captured env, process ancestry, and host classification.
- `~/.claude-beacon/state.json` — the current reduced session state.

## Layout

```
claude-beacon/
  install.sh  uninstall.sh  README.md
  hooks/beacon-hook
  app/
    Package.swift  Info.plist.template
    Sources/ClaudeBeacon/
      AppMain.swift  StatusItemController.swift  SessionStore.swift
      EventWatcher.swift  LogWatcher.swift  Notifier.swift  Eviction.swift
      AlertSound.swift  Settings.swift  Log.swift
```
