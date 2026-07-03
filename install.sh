#!/usr/bin/env bash
# Claude Beacon installer.
#   - builds and installs ClaudeBeacon.app (menu bar utility)
#   - installs the beacon-hook script
#   - merges the beacon hooks into ~/.claude/settings.json (idempotent, additive)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BEACON_HOME="$HOME/.claude-beacon"
BIN_DIR="$BEACON_HOME/bin"
EVENTS_DIR="$BEACON_HOME/events"
APP_DIR="$HOME/Applications/ClaudeBeacon.app"
SETTINGS="$HOME/.claude/settings.json"
HOOK_CMD_PREFIX='$HOME/.claude-beacon/bin/beacon-hook'

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m warn:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Dependencies
# ---------------------------------------------------------------------------
say "Checking dependencies"
if ! command -v jq >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    say "Installing jq via Homebrew"
    brew install jq
  else
    die "jq is required and Homebrew is not installed. Install jq (https://jqlang.github.io/jq/) and re-run."
  fi
fi
command -v swift >/dev/null 2>&1 || die "swift not found."
xcode-select -p >/dev/null 2>&1 || die "Xcode Command Line Tools not found. Run: xcode-select --install"

# ---------------------------------------------------------------------------
# 2. Build + assemble the app bundle
# ---------------------------------------------------------------------------
say "Building ClaudeBeacon.app (release)"
( cd "$REPO_DIR/app" && swift build -c release )
BIN_PATH="$REPO_DIR/app/.build/release/ClaudeBeacon"
[ -x "$BIN_PATH" ] || die "build did not produce $BIN_PATH"

say "Assembling app bundle at $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/ClaudeBeacon"
cp "$REPO_DIR/app/Info.plist.template" "$APP_DIR/Contents/Info.plist"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

say "Ad-hoc codesigning"
codesign --force --deep --sign - "$APP_DIR" || warn "codesign failed; notifications/TCC may misbehave"

# ---------------------------------------------------------------------------
# 3. Install the hook script
# ---------------------------------------------------------------------------
say "Installing beacon-hook -> $BIN_DIR"
mkdir -p "$BIN_DIR" "$EVENTS_DIR"
cp "$REPO_DIR/hooks/beacon-hook" "$BIN_DIR/beacon-hook"
chmod +x "$BIN_DIR/beacon-hook"

# ---------------------------------------------------------------------------
# 4. Merge hooks into settings.json (idempotent, preserves existing hooks)
# ---------------------------------------------------------------------------
say "Merging hooks into $SETTINGS"
mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

# Back up first.
cp "$SETTINGS" "$SETTINGS.beacon-bak"
say "Backed up settings to $SETTINGS.beacon-bak"

# Beacon hook additions. Uses $HOME (shell-expanded by Claude Code at run time).
read -r -d '' BEACON_ADD <<JSON || true
{
  "SessionStart":     [{ "hooks": [{ "type": "command", "command": "${HOOK_CMD_PREFIX} register", "async": true, "timeout": 5 }] }],
  "Notification":     [{ "matcher": "permission_prompt|idle_prompt|elicitation_dialog",
                         "hooks": [{ "type": "command", "command": "${HOOK_CMD_PREFIX} pending", "async": true, "timeout": 5 }] }],
  "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "${HOOK_CMD_PREFIX} attended", "async": true, "timeout": 5 }] }],
  "PreToolUse":       [{ "hooks": [{ "type": "command", "command": "${HOOK_CMD_PREFIX} attended", "async": true, "timeout": 5 }] }],
  "Stop":             [{ "hooks": [{ "type": "command", "command": "${HOOK_CMD_PREFIX} stopped", "async": true, "timeout": 5 }] }],
  "SessionEnd":       [{ "hooks": [{ "type": "command", "command": "${HOOK_CMD_PREFIX} ended", "async": true, "timeout": 5 }] }]
}
JSON

# For each event: strip any existing beacon groups (idempotency), then append
# the fresh beacon group. Never touches non-beacon hook entries.
TMP="$(mktemp)"
jq --argjson add "$BEACON_ADD" '
  .hooks = (.hooks // {})
  | reduce ($add | to_entries[]) as $e (.;
      .hooks[$e.key] = (
        ((.hooks[$e.key] // [])
          | map(select(any(.hooks[]?; (.command // "") | test("beacon-hook")) | not)))
        + $e.value
      )
    )
' "$SETTINGS" > "$TMP" || die "jq merge failed; settings.json left unchanged"

# Validate before replacing.
jq empty "$TMP" >/dev/null 2>&1 || die "merged settings.json is invalid JSON; aborting"
mv "$TMP" "$SETTINGS"
say "Hooks merged."

# ---------------------------------------------------------------------------
# 5. Launch
# ---------------------------------------------------------------------------
say "Launching ClaudeBeacon.app"
open "$APP_DIR" || warn "could not open app; launch it manually from ~/Applications"

# ---------------------------------------------------------------------------
# 6. Post-install checklist
# ---------------------------------------------------------------------------
cat <<'EOF'

────────────────────────────────────────────────────────────
 Claude Beacon installed.

 No system permissions required — the beacon only watches files it is
 already allowed to read. When macOS asks, allow notifications (optional).

 Try it:
   1. Click the beacon icon → "Send Test Event" to see the flash,
      hear the chime, and open the dropdown of sessions needing you.
   2. Toggle "Launch at login" from the menu if you want it always on.

 IMPORTANT: already-running Claude Code sessions won't emit events
 until they reload hooks. In each running session run /hooks (reload)
 or restart it. New sessions pick up the hooks automatically. Desktop
 permission/question prompts are detected with no hook reload needed.

 Logs: ~/.claude-beacon/beacon.log  (menu → "Open Log")
────────────────────────────────────────────────────────────
EOF
