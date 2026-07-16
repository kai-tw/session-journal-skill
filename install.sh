#!/usr/bin/env bash
# install.sh — drop the session-journal skill + its hooks into a target project.
#
# Copies the skill and the three hook scripts into <target>/.claude/, then
# NON-DESTRUCTIVELY merges the three hook registrations into
# <target>/.claude/settings.json (SessionStart / SessionEnd / PostToolUse) and
# adds docs/session-journal/ to <target>/.gitignore. Idempotent: re-running skips
# anything already installed.
#
# Usage:
#   ./install.sh [TARGET_DIR]      # default: current directory
#
# Requirements: bash, jq, git (target should be a git repo — the journal anchors
# its storage to the git root).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$(cd "${1:-$PWD}" && pwd)"

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }

printf '\nInstalling session-journal → %s\n\n' "$TARGET"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required (brew install jq / apt install jq)"; exit 1; }
[ -f "$SCRIPT_DIR/.claude/skills/session-journal/SKILL.md" ] || { echo "ERROR: run this from the cloned repo (payload .claude/ not found next to install.sh)"; exit 1; }
git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1 || warn "target is not a git repo — the journal anchors to the git root, so initialise one (git init) before real use."

# 1) copy skill + hooks -------------------------------------------------------
mkdir -p "$TARGET/.claude/skills" "$TARGET/.claude/hooks"
cp -R "$SCRIPT_DIR/.claude/skills/session-journal" "$TARGET/.claude/skills/"
cp "$SCRIPT_DIR/.claude/hooks/session-journal-inject.sh"  "$TARGET/.claude/hooks/"
cp "$SCRIPT_DIR/.claude/hooks/session-journal-cleanup.sh" "$TARGET/.claude/hooks/"
cp "$SCRIPT_DIR/.claude/hooks/session-journal-nudge.sh"   "$TARGET/.claude/hooks/"
chmod +x "$TARGET/.claude/skills/session-journal/scripts/journal.sh" "$TARGET/.claude/hooks/session-journal-"*.sh
ok "copied skill → .claude/skills/session-journal/"
ok "copied hooks → .claude/hooks/session-journal-{inject,cleanup,nudge}.sh"

# 2) merge hook registrations into settings.json (non-destructive) ------------
SETTINGS="$TARGET/.claude/settings.json"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
jq empty "$SETTINGS" 2>/dev/null || { echo "ERROR: $SETTINGS is not valid JSON — fix it, then re-run."; exit 1; }

INJ='"$CLAUDE_PROJECT_DIR/.claude/hooks/session-journal-inject.sh"'
CLN='"$CLAUDE_PROJECT_DIR/.claude/hooks/session-journal-cleanup.sh"'
NDG='"$CLAUDE_PROJECT_DIR/.claude/hooks/session-journal-nudge.sh"'

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
  • Restart your agent session (or start a new one) so the SessionStart hook fires
    and the skill is picked up.
  • The journal lives in docs/session-journal/ (gitignored). Inspect it with:
      .claude/skills/session-journal/scripts/journal.sh list
  • Read the skill: .claude/skills/session-journal/SKILL.md

EOF
