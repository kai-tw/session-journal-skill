#!/usr/bin/env bash
# PostToolUse(Bash|EnterWorktree|ExitWorktree) — session-journal WRITE-side nudge.
#
# The journal's READ side is deterministic (the SessionStart inject hook). Its
# WRITE side used to rely entirely on the model remembering, mid-session, to go
# record where a thread lives. The single highest-value field — `Lives:`
# (worktree / branch / PR#) — is created exactly when the model runs a
# worktree/PR/push action, long after the SessionStart reminder scrolled out of
# context, so it is the field most often lost to compaction. This hook fires a
# one-shot, NON-BLOCKING reminder at that moment, converting "record where the
# thread lives" from model self-discipline into a deterministic prod — the same
# read-vs-write asymmetry the inject hook already closes on the read side.
#
# Non-blocking: emits `additionalContext` on exit 0 (verified supported for
# PostToolUse); never blocks the tool, never uses exit 2. Because it is a
# PostToolUse(Bash) matcher it fires on EVERY Bash call, so — like
# commit-isolation.sh — it FAST-BAILS on a cheap raw-string `case` and only
# spends a jq parse on the rare command that actually mentions a trigger.
set -euo pipefail

input="$(cat)"

# Fast bail: the raw JSON must mention a tool/command we care about. This keeps
# the common Bash call at a single string match — no jq, negligible latency.
case "$input" in
  *EnterWorktree*|*ExitWorktree*|*"pr create"*|*"worktree add"*|*"set-upstream"*|*"push -u"*) ;;
  *) exit 0 ;;
esac

tool="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)"

msg=""
case "$tool" in
  EnterWorktree)
    msg='You just entered a git worktree. Record it in the session journal NOW via the session-journal skill: set the thread Lives line — worktree path, branch, base, and PR number once opened — in both _active.md and this session detail file. This is the highest-value journal field and the one compaction most often drops.'
    ;;
  ExitWorktree)
    msg='You just exited a git worktree. Reconcile the session journal via the session-journal skill: if the thread merged or shipped, PRUNE it from _active.md and delete its detail block; otherwise update its status and Next line so a resumed session knows where it stands.'
    ;;
  Bash)
    cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
    if printf '%s' "$cmd" | grep -Eq 'gh[[:space:]]+pr[[:space:]]+create'; then
      msg='You just opened a PR. Record its number on the thread Lives line in the session journal via the session-journal skill (both _active.md and this session detail file) so a compacted or cleared session still knows the PR exists.'
    elif printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+worktree[[:space:]]+add'; then
      msg='You just created a git worktree from the CLI. Record its Lives line (worktree path, branch, base) in the session journal via the session-journal skill — _active.md and this session detail file.'
    elif printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+push[[:space:]]+(-u|--set-upstream)'; then
      msg='You just pushed a branch upstream. Make sure the thread Lives line in the session journal names this branch (and its PR number if open), via the session-journal skill.'
    fi
    ;;
esac

[ -n "$msg" ] || exit 0

printf '%s' "$msg" | jq -Rs '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: .}}'
exit 0
