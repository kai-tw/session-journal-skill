#!/bin/bash
# SessionEnd hook -> trash this session's detail file when the session TRULY ends.
#
# Resume-safe: scripts/journal.sh `cleanup` only deletes on terminal reasons
# (clear / logout) and ignores resume / prompt_input_exit /
# bypass_permissions_disabled / other, so a resumable exit never loses the file
# (--resume keeps the same id and expects it to still be there). The
# cross-session index (_active.md) always persists — only the per-session detail
# file is cleared.
#
# SessionEnd cannot block termination and its stdout is ignored by Claude Code:
# this is a pure side-effect cleanup hook. Thin by design — logic lives in the
# session-journal skill's scripts/journal.sh. Always exit 0.

input=$(cat)

# A subagent ending must never touch the main session's detail file. Its
# session_id differs (so cleanup would no-op anyway), but skip explicitly:
# agent_type is only present in subagent contexts.
agent_type=$(printf '%s' "$input" | jq -r '.agent_type // empty' 2>/dev/null)
[ -n "$agent_type" ] && exit 0

sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
reason=$(printf '%s' "$input" | jq -r '.reason // empty' 2>/dev/null)

script="$(dirname "$0")/../scripts/journal.sh"
[ -x "$script" ] && bash "$script" cleanup "$sid" "$reason" >/dev/null 2>&1
exit 0
