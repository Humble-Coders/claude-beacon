#!/usr/bin/env bash
# Claude Beacon uninstaller. Removes the app, the login item, ~/.claude-beacon,
# and only the beacon hook entries from settings.json (leaving your own hooks).
set -euo pipefail

BEACON_HOME="$HOME/.claude-beacon"
APP_DIR="$HOME/Applications/ClaudeBeacon.app"
SETTINGS="$HOME/.claude/settings.json"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m warn:\033[0m %s\n' "$*"; }

say "Quitting ClaudeBeacon (if running)"
osascript -e 'tell application "System Events" to if exists (process "ClaudeBeacon") then tell application "ClaudeBeacon" to quit' 2>/dev/null || true
pkill -x ClaudeBeacon 2>/dev/null || true

say "Removing login item"
# Best effort: unregister via the app if still present, else ignore.
osascript -e 'tell application "System Events" to delete login item "ClaudeBeacon"' 2>/dev/null || true

say "Removing app bundle"
rm -rf "$APP_DIR"

# Strip only beacon hook entries from settings.json.
if [ -f "$SETTINGS" ] && command -v jq >/dev/null 2>&1; then
  say "Removing beacon hooks from $SETTINGS"
  cp "$SETTINGS" "$SETTINGS.beacon-uninstall-bak"
  TMP="$(mktemp)"
  jq '
    if (.hooks | type) == "object" then
      .hooks |= (
        with_entries(
          .value |= map(select(any(.hooks[]?; (.command // "") | test("beacon-hook")) | not))
        )
        # drop event keys left with an empty array
        | with_entries(select(.value | length > 0))
      )
      # drop .hooks entirely if now empty
      | (if (.hooks | length) == 0 then del(.hooks) else . end)
    else . end
  ' "$SETTINGS" > "$TMP" && jq empty "$TMP" >/dev/null 2>&1 && mv "$TMP" "$SETTINGS" \
    || warn "could not clean settings.json (backup at $SETTINGS.beacon-uninstall-bak)"
else
  warn "settings.json or jq missing; skipping hook cleanup"
fi

say "Removing $BEACON_HOME"
rm -rf "$BEACON_HOME"

say "Claude Beacon uninstalled."
