#!/bin/bash
# SessionStart hook -> inject the session journal so task / plan / worktree state
# survives context compaction, /clear, resume, and fresh startup.
#
# Fires on sources startup | resume | clear | compact. Auto-compaction and
# --resume keep the SAME session_id (so this session's detail file is found);
# /clear and a new session get a NEW id (empty detail) but still receive the
# cross-session index _active.md. Injecting here is DETERMINISTIC — it does not
# rely on the model remembering to read the file, which is the failure mode this
# system prevents.
#
# Thin by design: all journal logic lives in the session-journal skill's
# scripts/journal.sh; this file only handles the SessionStart I/O contract.
# Stay fast, silent, and never fail the session — exit 0 on every path.

input=$(cat)

# Subagents fire SessionStart too, carrying an agent_type. The journal is the
# MAIN session's continuity surface — don't inject it into every spawned
# sub-agent (noise + tokens). agent_type is only present in subagent contexts.
agent_type=$(printf '%s' "$input" | jq -r '.agent_type // empty' 2>/dev/null)
[ -n "$agent_type" ] && exit 0

sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)

script="$(dirname "$0")/../scripts/journal.sh"
body=""
if [ -x "$script" ]; then
  # Self-maintain: trash stale orphan detail files (default 14d, chain-aware).
  # Passing $sid keeps the current session exempt even on a fresh startup.
  bash "$script" gc "" "$sid" >/dev/null 2>&1
  # The project's current branch (resolved from the hook's cwd = the project
  # root, NOT the script's own dir — so this is correct whether the skill was
  # copied in or mounted as a git submodule) lets inject auto-identify which
  # thread this tree is, so a /clear'd worktree session resumes the right one.
  branch="$(git branch --show-current 2>/dev/null || true)"
  body="$(bash "$script" inject "$sid" "$branch" 2>/dev/null)"
fi

if [ -z "$body" ]; then
  ctx="No session journal yet (docs/session-journal/). When you pick up or start a task, use the session-journal skill to record it — task / plan / where it lives (worktree, branch, PR, issue or tracker link) / next step — so it survives context compaction and /clear."
else
  ctx="Persistent session journal (in-repo, gitignored; survives compaction / clear / resume). Read it to recover which task threads are in flight and WHERE each one lives (worktree / branch / PR# / issue or tracker link) before acting; keep it current via the session-journal skill.

$body"
fi

printf '%s' "$ctx" | jq -Rs '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: .}}'
exit 0
