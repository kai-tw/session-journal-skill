#!/usr/bin/env bash
# install.sh — install the session-journal skill (+ its bundled hooks) into a
# project, and wire the three hook registrations into its settings.json.
#
# The skill is self-contained: SKILL.md, scripts/journal.sh and hooks/ all live
# under one directory, so in the target everything lands at
#   <target>/.claude/skills/session-journal/
# and the hooks are referenced from there. This is the SAME layout you get by
# mounting this repo as a git submodule at that path (see README), so the two
# adoption methods are interchangeable.
#
# Usage:
#   ./install.sh [TARGET_DIR]                  # copy files + merge settings + gitignore
#   ./install.sh --settings-only [TARGET_DIR]  # only merge settings + gitignore
#                                              # (for submodule users — files are
#                                              #  already present via the submodule)
#   TARGET_DIR defaults to the current directory.
#
# Requirements: bash, jq, git (the journal anchors its storage to the git root).
set -euo pipefail

SETTINGS_ONLY=0
if [ "${1:-}" = "--settings-only" ]; then SETTINGS_ONLY=1; shift; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$(cd "${1:-$PWD}" && pwd)"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }

printf '\nInstalling session-journal → %s\n\n' "$TARGET"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required (brew install jq / apt install jq)"; exit 1; }
[ -f "$SCRIPT_DIR/SKILL.md" ] || { echo "ERROR: run this from the skill root (SKILL.md not found next to install.sh)"; exit 1; }
git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1 || warn "target is not a git repo — the journal anchors to the git root, so initialise one (git init) before real use."

SKILLDIR="$TARGET/.claude/skills/session-journal"

# 1) copy skill + bundled hooks (skipped in --settings-only) ------------------
if [ "$SETTINGS_ONLY" -eq 0 ]; then
  mkdir -p "$SKILLDIR/scripts" "$SKILLDIR/hooks"
  cp "$SCRIPT_DIR/SKILL.md"            "$SKILLDIR/SKILL.md"
  cp "$SCRIPT_DIR/scripts/journal.sh"  "$SKILLDIR/scripts/journal.sh"
  cp "$SCRIPT_DIR/hooks/"session-journal-*.sh "$SKILLDIR/hooks/"
  chmod +x "$SKILLDIR/scripts/journal.sh" "$SKILLDIR/hooks/"session-journal-*.sh
  ok "installed skill + hooks → .claude/skills/session-journal/"
else
  [ -f "$SKILLDIR/SKILL.md" ] || warn "no skill found at .claude/skills/session-journal/ — add the submodule there first, then re-run --settings-only."
  ok "--settings-only: skipped file copy"
fi

# 2) merge hook registrations into settings.json (non-destructive) ------------
SETTINGS="$TARGET/.claude/settings.json"
mkdir -p "$TARGET/.claude"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
jq empty "$SETTINGS" 2>/dev/null || { echo "ERROR: $SETTINGS is not valid JSON — fix it, then re-run."; exit 1; }

H='"$CLAUDE_PROJECT_DIR/.claude/skills/session-journal/hooks'
INJ="$H/session-journal-inject.sh\""
CLN="$H/session-journal-cleanup.sh\""
NDG="$H/session-journal-nudge.sh\""

merged="$(jq \
  --arg inj "$INJ" --arg cln "$CLN" --arg ndg "$NDG" '
  def has($ev; $needle): ([ .hooks[$ev][]?.hooks[]?.command // empty ] | any(test($needle)));
  def append($ev; $group): .hooks[$ev] = ((.hooks[$ev] // []) + [$group]);
  (.hooks //= {})
  | (if has("SessionStart"; "session-journal-inject\\.sh") then .
     else append("SessionStart"; {hooks:[{type:"command", command:$inj, statusMessage:"Loading session journal..."}]}) end)
  | (if has("SessionEnd"; "session-journal-cleanup\\.sh") then .
     else append("SessionEnd"; {hooks:[{type:"command", command:$cln}]}) end)
  | (if has("PostToolUse"; "session-journal-nudge\\.sh") then .
     else append("PostToolUse"; {matcher:"Bash|EnterWorktree|ExitWorktree", hooks:[{type:"command", command:$ndg}]}) end)
  ' "$SETTINGS")"
printf '%s\n' "$merged" > "$SETTINGS"
ok "merged SessionStart / SessionEnd / PostToolUse hooks into .claude/settings.json"

# 3) gitignore the local-only journal storage --------------------------------
GI="$TARGET/.gitignore"
if [ -f "$GI" ] && grep -qE '^/?docs/session-journal/?$' "$GI"; then
  ok ".gitignore already ignores docs/session-journal/"
else
  { [ -f "$GI" ] && [ -n "$(tail -c1 "$GI")" ] && echo; printf '\n# session-journal — local-only working state, never commit\ndocs/session-journal/\n'; } >> "$GI"
  ok "added docs/session-journal/ to .gitignore (keeps your task state out of version control)"
fi

cat <<EOF

Done. Next:
  • Restart your agent session (or start a new one) so the SessionStart hook fires.
  • The journal lives in docs/session-journal/ (gitignored). Inspect it with:
      .claude/skills/session-journal/scripts/journal.sh list
  • Read the skill: .claude/skills/session-journal/SKILL.md

EOF
