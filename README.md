# session-journal-skill

A **cross-session task-state journal** for coding agents — a [Claude Code](https://docs.claude.com/en/docs/claude-code) skill + hooks that make your work state survive context compaction, `/clear`, and `--resume`.

It is deliberately small: three shell hooks, one script, one skill file. No dependencies beyond `bash`, `jq`, and `git`. Your journal is plain Markdown on disk, gitignored, and never leaves your machine.

---

## The problem it solves

Long agent sessions lose the thread. Specifically, **context compaction and `/clear` silently drop the load-bearing scaffolding** you need to keep working:

- *Which* tasks are in flight right now?
- **WHERE does each one live** — which worktree, which branch, which PR, which tracked issue?
- How do the threads relate (this one is blocked on that one)?
- What was decided, and **why**?

The harness auto-summary keeps the *gist of the conversation* but throws away exactly these facts. The classic failure: a session starts as a small bug fix in its own git worktree, drifts into planning a different feature after an auto-compaction, and the agent — no longer remembering which tree it is in — gets confused and nearly redoes shipped work.

The root cause is an **asymmetry**: reading state can be made deterministic (a hook injects it every session), but *writing* it usually relies on the model remembering to — which it doesn't, reliably. This skill closes both sides.

## How it works

**Two tiers of plain-Markdown state under `docs/session-journal/` (gitignored):**

| File | Scope | Survives |
|---|---|---|
| `_active.md` | Cross-session index — every *unclosed* thread + a back-link | `/clear`, new sessions, everything |
| `<session-id>/_detail.md` | This session's full thread detail + a bounded conversation-compression block | This session's compactions + `--resume` |

**Three hooks make it deterministic:**

- **`SessionStart` → inject.** Every startup / resume / clear / compact, the index + this session's detail are injected straight into context. Reading is never left to chance. It even reads the current git branch and, when it *uniquely* matches a thread, banners "you are in *this* thread" — so a `/clear`'d worktree session resumes the right work without being told.
- **`PostToolUse` → nudge.** The single highest-value field is *where a thread lives*, and it is created mid-session — exactly when the SessionStart reminder has scrolled out of context. So a hook fires a one-shot, non-blocking reminder the moment you enter a worktree or run `gh pr create` / `git worktree add` / `git push -u`: *record where this lives now.* Writing stops being purely discretionary.
- **`SessionEnd` → cleanup.** On a terminal end (`/clear` / logout) the per-session detail file is trashed (recoverably) — **unless** an open thread still references it. The cross-session index always persists. Stale orphans are garbage-collected at session start, chain-aware (older members of a still-active session chain are kept).

Everything mechanical lives in one script, `journal.sh` (init / inject / cleanup / gc / list), so the hooks and the skill never drift.

## Install

```bash
git clone https://github.com/kai-tw/session-journal-skill.git
cd session-journal-skill
./install.sh /path/to/your/project      # omit the path to install into the current dir
```

The installer:
1. copies the skill → `<project>/.claude/skills/session-journal/`
2. copies the three hooks → `<project>/.claude/hooks/`
3. **non-destructively merges** the hook registrations into `<project>/.claude/settings.json` (existing hooks are preserved; re-running is idempotent)
4. adds `docs/session-journal/` to `<project>/.gitignore`

Then restart your agent session so the `SessionStart` hook fires. **Requirements:** `bash`, `jq`, `git`. Tested on macOS and Linux.

> Prefer to wire it by hand? The payload is a literal drop-in `.claude/` tree — copy the files and add the three hook entries from [`install.sh`](install.sh) to your `settings.json` yourself.

### Windows

The hooks are POSIX shell scripts, so on Windows use one of the two environments where bash is present:

- **WSL** — behaves exactly like Linux; everything works out of the box.
- **Git for Windows (Git Bash)** — Claude Code uses Git Bash by default to run shell hooks on native Windows, so `.sh` hooks and `$CLAUDE_PROJECT_DIR` work. Run `install.sh` from a Git Bash prompt.

Only native Windows with **no** Git Bash installed is unsupported — Claude Code then falls back to PowerShell, which cannot execute `.sh` hooks. Installing [Git for Windows](https://git-scm.com/downloads/win) resolves it. (The scripts are portable across BSD/macOS and GNU/Linux/MSYS `stat` and `trash`/`rm`, so no per-OS variant is needed.)

## Uninstall

```bash
./uninstall.sh /path/to/your/project
```

Removes the skill + hooks and strips the hook registrations from `settings.json`. It **does not** delete your `docs/session-journal/` contents — remove those yourself if you want them gone.

## What it is *not*

- **Not your issue tracker or plan DB.** It holds working state + pointers; link to your tracker (GitHub Issues / Linear / Jira / Notion / …), don't duplicate plan bodies here.
- **Not long-term memory.** Persistent preferences/corrections belong in your agent's memory system. This is task/thread working-state only.
- **Not a commit log.** Git owns history; the journal tracks *current* state and is updated in place.

## Privacy & data

The journal is **local-only and gitignored** — the installer adds the ignore rule for you, so your task notes (and anything sensitive you jot in them) stay out of version control. Deletion uses `trash` where available (recoverable) and falls back to `rm`. Nothing is sent anywhere; there is no network access in any script.

## Layout

```
.claude/
├── skills/session-journal/
│   ├── SKILL.md                     # the skill contract (when/how to write)
│   └── scripts/journal.sh           # all mechanical ops (init/inject/cleanup/gc/list)
└── hooks/
    ├── session-journal-inject.sh    # SessionStart  → inject index + detail
    ├── session-journal-cleanup.sh   # SessionEnd    → trash detail on terminal end
    └── session-journal-nudge.sh     # PostToolUse   → nudge to record where a thread lives
```

## License

MIT — see [LICENSE](LICENSE).
