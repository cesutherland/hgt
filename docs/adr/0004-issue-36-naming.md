# ADR 0004 — Issue #36: branch / worktree / session naming

- **Status:** accepted
- **Date:** 2026-07-04
- **Context:** The two names `hgt work` generated failed in opposite directions (issue #36).
  The branch was `issue-<n>-<full-title-slug>` — long and unwieldy. The tmux/claude session was
  `hgt-issue-<n>` — a stable machine key, but inscrutable to a human with three sessions open.
  This ADR records the rebalanced convention and, per the issue, **calls out which stability
  option we took** for the session key.

## Decision

**D1 — the three names.** For issue `<n>` with short slug `<slug>` (see D2), author login
`<user>`, and repo label `<repo>`:

| Name     | Format                  | Example                                    |
|----------|-------------------------|--------------------------------------------|
| Branch   | `<user>/<n>-<slug>`     | `cesutherland/36-branch-names-too-long-tmux` |
| Worktree | `<n>-<slug>`            | `36-branch-names-too-long-tmux`            |
| Session  | `<repo>/<n>-<slug>`     | `hgt/36-branch-names-too-long-tmux`        |

`<repo>` is the repo dir basename, and `<user>` is the authenticated GitHub login (`gh api
user`, on the forge_ axis — who authors the branch on the code host, not a tracker concern).
The `hgt-` literal prefix is gone: it was a hardcoded string that only *looked* meaningful
because we work in the `hgt` repo. The session is now repo-namespaced for real.

**D2 — the slug is bounded and deterministic (`slug_short`).** Full slugify, then drop a
leading conventional-commit type word (redundant with the issue context), drop stopwords, and
cap at 5 words. It is **re-derivable from the same title** — no LLM suggester. We deliberately
rejected an LLM-chosen slug: it would reintroduce the exact naming *instability* the constraint
exists to prevent (non-deterministic run-to-run), add a synchronous network failure point
*before* any session exists, and force us to build the deterministic fallback anyway. A future
self-hosted `hgt` can swap the one `slug_short` seam if we ever actually want it. (Follow-up:
let the human name the branch explicitly — tracked separately.)

**D3 — `<n>` stays the stable join key; the slug is a cosmetic suffix.** This is the
issue's second option ("keep `N` as the stable key with the slug as a cosmetic suffix"),
**not** the "slug re-derivable from `N` alone" one. Nothing keys off the slug: teardown and
resume find the session/worktree by the `<n>` prefix. Concretely, the **worktree dir is the
durable, `<n>`-keyed artifact that carries the slug** — `_find_worktree` globs `<base>/<n>-*`,
and the session name is rebuilt by peeling `<n>-` off that dir's basename (`_slug_of`). So:

- **No title lookup on teardown/resume** — the constraint the old bare-`<n>` key protected
  (`work.sh`: "chosen as bare N so resume needs no title lookup") is preserved.
- **Drift-proof** — retitle the issue and the original worktree dir (hence the original session
  name) still resolves; we never recompute the slug from a mutable title.

We rejected recomputing the slug from the live title at teardown (Option A): it adds a network
call to a local `rm` and silently orphans the tmux session whenever the issue was retitled after
the worktree was created.

## Consequences

- tmux session names forbid `.` and `:` (reserved for `session:window.pane` targets) but allow
  `/`. `slug_short` emits only `[a-z0-9-]`; `_repo_slug` runs the repo label through `slugify`
  too, so a dotted repo dir (`my.tool`) can't break the session name. `claude -n` takes a
  *display name*, so its `/` is cosmetic — the tmux and claude names stay unified.
- `gh` graduates from the generic `_shim` symlink to a dedicated shim (as `git`/`tmux` did in
  0002/D1, 0003), because `work` now issues two distinct gh calls — `gh issue view` (tracker)
  and `gh api user` (forge) — that need independently controllable results.
- `_repo_slug`'s git-toplevel default isn't exercised by the hermetic suite (it's pinned via
  `HGT_REPO_NAME`), same carve-out as the worktree base in 0002/D3.
- Supersedes the `hgt-issue-<n>` / `issue-<n>-<slug>` conventions in 0002/D3 and 0003. Existing
  branches/worktrees/sessions are **not** renamed (issue non-goal); this is new work only.
