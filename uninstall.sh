#!/usr/bin/env bash
# uninstall.sh — remove the session-journal skill from a project and strip its
# hook registrations from settings.json. Does NOT delete docs/session-journal/
# (your working state) or the .gitignore line — remove those by hand if you want.
#
# If the skill was added as a git SUBMODULE, this only strips settings and tells
# you to run `git submodule deinit` yourself (removing a submodule's files by
# hand corrupts .git/modules state).
#
# Usage: ./uninstall.sh [TARGET_DIR]   # default: current directory
set -euo pipefail

TARGET="$(cd "${1:-$PWD}" && pwd)"
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }

printf '\nRemoving session-journal from %s\n\n' "$TARGET"
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required"; exit 1; }

SKILLDIR="$TARGET/.claude/skills/session-journal"
if [ -e "$SKILLDIR/.git" ]; then
  warn "skill is a git submodule — leaving files in place. Remove it with:"
  warn "    git submodule deinit -f .claude/skills/session-journal && git rm -f .claude/skills/session-journal"
elif [ -d "$SKILLDIR" ]; then
  rm -rf "$SKILLDIR"
  ok "removed .claude/skills/session-journal/"
fi

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
       | .hooks |= with_entries(select(.value | length > 0))
    end
  ' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  ok "stripped hook registrations from settings.json"
fi

printf '\nDone. Your docs/session-journal/ contents were left in place.\n\n'
