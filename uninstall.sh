#!/usr/bin/env bash
# uninstall.sh — remove the session-journal skill + hooks from a target project.
#
# Removes the skill dir + the three hook scripts and strips their registrations
# from <target>/.claude/settings.json. Does NOT delete docs/session-journal/
# (your working state) or the .gitignore line — remove those by hand if you want.
#
# Usage: ./uninstall.sh [TARGET_DIR]   # default: current directory
set -euo pipefail

TARGET="$(cd "${1:-$PWD}" && pwd)"
ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }

printf '\nRemoving session-journal from %s\n\n' "$TARGET"
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required"; exit 1; }

rm -rf "$TARGET/.claude/skills/session-journal"
rm -f  "$TARGET/.claude/hooks/session-journal-inject.sh" \
       "$TARGET/.claude/hooks/session-journal-cleanup.sh" \
       "$TARGET/.claude/hooks/session-journal-nudge.sh"
ok "removed skill + hook scripts"

SETTINGS="$TARGET/.claude/settings.json"
if [ -f "$SETTINGS" ]; then
  jq '
    def strip($ev):
      if .hooks[$ev] == null then .
      else .hooks[$ev] = ([ .hooks[$ev][]
             | select([ .hooks[]?.command // empty ] | any(test("session-journal-")) | not) ])
      end;
    if .hooks == null then .
    else strip("SessionStart") | strip("SessionEnd") | strip("PostToolUse")
       # drop now-empty event arrays
       | .hooks |= with_entries(select(.value | length > 0))
    end
  ' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  ok "stripped hook registrations from settings.json"
fi

printf '\nDone. Your docs/session-journal/ contents were left in place.\n\n'
