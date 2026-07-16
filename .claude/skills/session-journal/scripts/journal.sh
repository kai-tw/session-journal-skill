#!/bin/bash
# session-journal: shared mechanical operations for the cross-session task-state
# journal. The SessionStart / SessionEnd hooks AND the /session-journal skill all
# call THIS script, so path resolution, the file skeletons, the cleanup gate, and
# garbage collection have one stable implementation instead of ad-hoc bash
# duplicated per caller.
#
# Storage: docs/session-journal/ under the MAIN repo root, anchored via
# git-common-dir so it resolves to the SAME directory from inside any linked
# worktree (the failure mode this system prevents is worktree-related). The
# directory is gitignored — local-only working state, never committed. Each
# session is a DIRECTORY `<sid>/` holding `_detail.md` + any per-session scratch
# / draft files authored that session; LEGACY sessions are a flat `<sid>.md` file
# and coexist (they gc away over time — no migration).
#
# Subcommands:
#   dir                    print the canonical journal directory
#   active-path            print the cross-session index path (_active.md)
#   detail-path [SID]      print a session's detail-file path (default $CLAUDE_CODE_SESSION_ID)
#   plan-path SID ARTIFACT print a per-session scratch-file path inside the session dir (<sid>/<artifact>.md)
#   init [SID]             ensure the dir + _active.md + this session's detail file exist
#   inject SID             print the text to inject at SessionStart (index + detail)
#   cleanup SID REASON     trash the session's store (dir incl. scratch files) IF the reason is terminal
#   list [DAYS]            show every session with age + keep/GC status
#   gc [DAYS] [SID]        trash stale ORPHAN sessions (default 14d; see do_gc)
#
# The unifying retention rule (cleanup AND gc obey it): NEVER delete a detail
# file that is still back-linked from an open thread in _active.md, the current
# session's file, or _active.md itself. Everything else is an orphan, eligible
# only once it is genuinely stale. "Stale" is measured against the NEWEST session
# in the chain, not wall-clock now — so older members of a still-active chain are
# kept (they are still useful while the chain is being worked).
#
# Designed to never hard-fail a hook: benign no-ops exit 0.

set -u
cmd="${1:-}"
shift || true

GC_DEFAULT_DAYS=14

# --- portable mtime (epoch seconds) ------------------------------------------
# GNU coreutils (Linux, and Git Bash / MSYS on Windows) use `stat -c %Y`; BSD
# (macOS) uses `stat -f %m`. GNU-FIRST is deliberate: on GNU, `stat -f %m` does
# NOT error — it silently prints the mount point — so a BSD-first probe would
# succeed with garbage on Linux. `stat -c` is unknown to BSD stat and hard-errors
# there, so this ordering degrades correctly on both.
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

# --- path resolution (main-root anchored; worktree-stable) -------------------
resolve_dir() {
  local root
  root="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  if [ -n "$root" ]; then
    root="$(dirname "$root")"
  else
    root="${CLAUDE_PROJECT_DIR:-$(pwd)}"
  fi
  printf '%s/docs/session-journal' "$root"
}

JDIR="$(resolve_dir)"
ACTIVE="$JDIR/_active.md"

# A session's storage is a per-session DIRECTORY (`<sid>/`) holding `_detail.md`
# plus any per-session scratch/draft files authored during the session. LEGACY
# sessions are a flat `<sid>.md` file; these helpers resolve either shape so old
# and new coexist (legacy flat files gc away over time, no migration needed).
session_store() {  # the path to TRASH for a session (dir or legacy flat file); empty if none
  local sid="$1"
  if [ -d "$JDIR/$sid" ]; then printf '%s/%s' "$JDIR" "$sid"
  elif [ -f "$JDIR/$sid.md" ]; then printf '%s/%s.md' "$JDIR" "$sid"; fi
}

detail_path() {  # the detail FILE to read / write
  local sid="${1:-${CLAUDE_CODE_SESSION_ID:-}}"
  [ -n "$sid" ] || return 1
  if [ -f "$JDIR/$sid.md" ] && [ ! -d "$JDIR/$sid" ]; then
    printf '%s/%s.md' "$JDIR" "$sid"            # legacy flat file
  else
    printf '%s/%s/_detail.md' "$JDIR" "$sid"    # dir model (new, or existing dir)
  fi
}

plan_path() {  # a scratch/draft file inside the session dir (dir model only)
  local sid="${1:-${CLAUDE_CODE_SESSION_ID:-}}" artifact="${2:-}"
  [ -n "$sid" ] && [ -n "$artifact" ] || return 1
  printf '%s/%s/%s.md' "$JDIR" "$sid" "$artifact"
}

# Enumerate every session as "sid<TAB>store<TAB>mtimefile" (one per line) across
# BOTH legacy flat files and session dirs. mtimefile is what `stat` reads for age
# (a dir's `_detail.md` if present, else the store itself).
each_session() {
  local f d base sid mf
  shopt -s nullglob
  for f in "$JDIR"/*.md; do
    base="$(basename "$f")"
    [ "$base" = "_active.md" ] && continue
    sid="${base%.md}"
    [ -d "$JDIR/$sid" ] && continue             # a dir supersedes a stray flat file
    printf '%s\t%s\t%s\n' "$sid" "$f" "$f"
  done
  for d in "$JDIR"/*/; do
    d="${d%/}"; sid="$(basename "$d")"
    mf="$d/_detail.md"; [ -f "$mf" ] || mf="$d"
    printf '%s\t%s\t%s\n' "$sid" "$d" "$mf"
  done
  shopt -u nullglob
}

# Is this session id still back-linked from _active.md (an open thread needs it)?
# Match the 8-char id prefix so it works whether the back-link is written in full
# (docs/session-journal/<full-id>.md) or abbreviated (<8char>-…md). UUID prefixes
# are unique enough within one user's journal that collisions are not a concern.
referenced_in_active() {
  local sid="$1"
  [ -n "$sid" ] && [ -f "$ACTIVE" ] && grep -q "${sid:0:8}" "$ACTIVE"
}

# mtime (epoch seconds) of the newest session — the "latest session" in the
# chain (_active.md is the index, not a session, so it is excluded). 0 if none.
newest_detail_mtime() {
  local sid store mf m max=0
  while IFS=$'\t' read -r sid store mf; do
    m="$(mtime "$mf")"; [ -n "$m" ] || continue
    [ "$m" -gt "$max" ] && max="$m"
  done < <(each_session)
  printf '%s' "$max"
}

# Always-keep predicate shared by cleanup + gc + list (each_session already
# excludes the _active.md index, so this is purely session-scoped).
must_keep() {
  local sid="$1"
  [ -n "${CUR:-}" ] && [ "$sid" = "$CUR" ] && return 0                    # current session
  referenced_in_active "$sid" && return 0                                 # open thread still links it
  return 1
}

# --- file skeletons (the script owns the structure; the skill fills content) --
write_active_template() {
  cat >"$ACTIVE" <<'EOF'
# In-flight threads — cross-session index

<!-- Every UNCLOSED thread across all sessions. New / cleared sessions read this
(the SessionStart hook injects it) to learn what is globally in flight. One
compact block per thread + a back-link to the owning session's detail file.
PRUNE a thread the moment it closes (merged / shipped / abandoned) — a stale
"open" thread re-injected every session is worse than none. Maintained by the
session-journal skill. -->

<!-- ## <thread title> · <status>
- **Lives:** <worktree path / branch / PR# / main tree>
- **Plan:** <tracker or issue link + id · status/gate>   (omit if no plan)
- **Next:** <one concrete line>
- **Detail:** docs/session-journal/<session-id>/ · **Relations:** <deferred-behind / blocks / sibling / parent / supersedes> -->
EOF
}

write_detail_template() {
  local sid="$1" path="$2"
  cat >"$path" <<EOF
# Session journal — \`$sid\`

<!-- This session's working state (lives in docs/session-journal/<sid>/ alongside
any per-session scratch files). Survives this session's compactions & resume (same id); a
/clear starts a NEW id + NEW dir and trashes this one (unless an open _active.md
thread still links it). Update IN PLACE — never append-grow. Keep under ~150
lines. Maintained by the session-journal skill. -->

## Threads

<!-- ## Thread <n> — <title> · status: <…>
- **Lives:** <worktree / branch / PR# / main tree>
- **Plan:** <tracker or issue link + id · status/gate>
- **Progress:** <where it stands>
- **Next:** <next concrete action>
- **Relations:** <deferred-behind / blocks / sibling / parent / supersedes> -->

## Conversation compression

<!-- The bounded summary the harness auto-summary drops: structured, not a
transcript dump. Fill each line; leave blank if genuinely empty. -->

- **Key decisions:**
- **Open questions:**
- **User corrections / direction:**
- **Current focus:**
- **Next action:**
EOF
}

# Trash a file OR a session directory (recoverable). `-rf` fallback covers dirs
# on the rare host without `trash`; `trash` is present on most macOS setups.
trash_file() {
  if command -v trash >/dev/null 2>&1; then
    trash "$1" >/dev/null 2>&1 || rm -rf "$1"
  else
    rm -rf "$1"
  fi
}

# --- subcommand implementations ----------------------------------------------
do_init() {
  local sid="${1:-${CLAUDE_CODE_SESSION_ID:-}}"
  mkdir -p "$JDIR"
  [ -f "$ACTIVE" ] || write_active_template
  if [ -n "$sid" ]; then
    local dp; dp="$(detail_path "$sid")"
    mkdir -p "$(dirname "$dp")"                 # new session → creates <sid>/
    [ -f "$dp" ] || write_detail_template "$sid" "$dp"
    printf '%s\n' "$dp"
  fi
}

# Worktree self-identification. Given the current branch, return the SINGLE
# _active.md thread whose block mentions it (its `Lives:` line records the
# worktree/branch) — so a /clear'd session in a worktree resumes the right thread
# without being told. Returns empty on 0 or >1 match: ambiguity falls back to the
# plain index, never an auto-bind to the wrong thread. A shared main-tree branch
# (dev/main/master) never binds — planning threads all sit on it, so there the
# model picks from the listed index instead.
thread_for_branch() {
  local branch="$1"
  case "$branch" in ''|dev|main|master|HEAD) return 0 ;; esac
  [ -f "$ACTIVE" ] || return 0
  awk -v b="$branch" '
    /^## / { t=$0; sub(/^## /,"",t); sub(/ · .*/,"",t); cur=t; next }
    cur != "" && index($0, b) > 0 { hit[cur]=1 }
    END { n=0; for (k in hit) { n++; last=k } if (n==1) printf "%s", last }
  ' "$ACTIVE"
}

do_inject() {
  local sid="${1:-}" branch="${2:-}" body="" dp match
  [ -n "$branch" ] || branch="$(git branch --show-current 2>/dev/null || true)"
  if [ -f "$ACTIVE" ]; then
    match="$(thread_for_branch "$branch")"
    if [ -n "$match" ]; then
      body+="▶ This tree (branch \`$branch\`) is the **$match** thread. Resume THAT thread: read its block in the index below, follow its Detail back-link, then read its linked plan / tracker before acting. Confirm with the user before any irreversible step.

"
    fi
    body+="--- cross-session in-flight index (docs/session-journal/_active.md) ---
$(cat "$ACTIVE")

"
  fi
  if dp="$(detail_path "$sid" 2>/dev/null)" && [ -f "$dp" ]; then
    body+="--- this session's detail (docs/session-journal/${dp#"$JDIR"/}) ---
$(cat "$dp")
"
  fi
  printf '%s' "$body"
}

do_cleanup() {
  local sid="${1:-}" reason="${2:-}" store
  # Resume-safe gate: only delete on reasons that are TERMINAL for this id.
  # /clear mints a new id (old won't be resumed in practice) and is the user's
  # "done with this task" signal; logout ends the machine session. Everything
  # else — resume, prompt_input_exit, bypass_permissions_disabled, other — may be
  # resumed (same id expects the file to still be there), so keep the file.
  case "$reason" in
    clear | logout) ;;
    *) return 0 ;;
  esac
  [ -n "$sid" ] || return 0
  # Even on a terminal end, keep the store while an open thread still links it.
  referenced_in_active "$sid" && return 0
  store="$(session_store "$sid")"
  [ -n "$store" ] && trash_file "$store"        # dir (incl. plan drafts) or legacy flat
}

# Trash stale ORPHAN detail files. An orphan is eligible only when it is more
# than DAYS older than the NEWEST session in the chain (not wall-clock now), so
# while a chain is active its older members survive; once the whole chain goes
# quiet the reference stops advancing and nothing new becomes eligible. Always
# exempt: _active.md, the current session, and any session an open _active.md
# thread still links to.
do_gc() {
  local days="${1:-$GC_DEFAULT_DAYS}" CUR="${2:-${CLAUDE_CODE_SESSION_ID:-}}"
  local ref window sid store mf m
  [ -d "$JDIR" ] || return 0
  ref="$(newest_detail_mtime)"
  [ "$ref" -gt 0 ] 2>/dev/null || return 0
  window=$((days * 86400))
  while IFS=$'\t' read -r sid store mf; do
    must_keep "$sid" && continue
    m="$(mtime "$mf")"; [ -n "$m" ] || continue
    [ $((ref - m)) -gt "$window" ] && trash_file "$store"
  done < <(each_session)
}

do_list() {
  local days="${1:-$GC_DEFAULT_DAYS}" CUR="${CLAUDE_CODE_SESSION_ID:-}"
  local now ref window sid store mf m age status label
  [ -d "$JDIR" ] || {
    echo "(no journal directory yet: $JDIR)"
    return 0
  }
  now="$(date +%s)"
  ref="$(newest_detail_mtime)"
  window=$((days * 86400))
  printf '%-42s %7s  %s\n' "session (dir/ or legacy .md)" "age(d)" "status"
  [ -f "$ACTIVE" ] && printf '%-42s %7s  %s\n' "_active.md" "-" "cross-session index — KEEP always"
  while IFS=$'\t' read -r sid store mf; do
    m="$(mtime "$mf")"; [ -n "$m" ] || continue
    age=$(((now - m) / 86400))
    label="$(basename "$store")"; [ -d "$store" ] && label="$label/"
    if [ -n "$CUR" ] && [ "$sid" = "$CUR" ]; then
      status="current session — KEEP"
    elif referenced_in_active "$sid"; then
      status="referenced by open thread — KEEP"
    elif [ "$ref" -gt 0 ] && [ $((ref - m)) -gt "$window" ]; then
      status="GC-eligible (>${days}d behind latest session)"
    else
      status="orphan, kept (within ${days}d of latest session)"
    fi
    printf '%-42s %7s  %s\n' "$label" "$age" "$status"
  done < <(each_session)
}

case "$cmd" in
  dir) printf '%s\n' "$JDIR" ;;
  active-path) printf '%s\n' "$ACTIVE" ;;
  detail-path) detail_path "${1:-}" && echo ;;
  plan-path) plan_path "${1:-}" "${2:-}" && echo ;;
  init) do_init "${1:-}" ;;
  inject) do_inject "${1:-}" "${2:-}" ;;
  cleanup) do_cleanup "${1:-}" "${2:-}" ;;
  list) do_list "${1:-}" ;;
  gc) do_gc "${1:-}" "${2:-}" ;;
  *)
    echo "usage: journal.sh {dir|active-path|detail-path [SID]|plan-path SID ARTIFACT|init [SID]|inject SID [BRANCH]|cleanup SID REASON|list [DAYS]|gc [DAYS] [SID]}" >&2
    exit 2
    ;;
esac
