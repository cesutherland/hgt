# ADR 0004 — Issue #36: branch / worktree / session naming

- **Status:** accepted
- **Date:** 2026-07-04
- **Context:** The old names failed in opposite directions (#36): the branch
  `issue-<n>-<full-title-slug>` was unwieldy; the session `hgt-issue-<n>` was a stable machine
  key but inscrutable with three sessions open. Rebalanced below.

## Decision

**D1 — the three names.** `<repo>` is the repo dir basename; `<user>` the authenticated GitHub
login (`gh api user`, forge_ axis); `<slug>` per D2. The old `hgt-` prefix is gone — a hardcoded
literal that only *looked* meaningful in this repo.

| Name     | Format              | Example                                       |
|----------|---------------------|-----------------------------------------------|
| Branch   | `<user>/<n>-<slug>` | `cesutherland/36-branch-names-too-long-tmux`  |
| Worktree | `<n>-<slug>`        | `36-branch-names-too-long-tmux`               |
| Session  | `<repo>/<n>-<slug>` | `hgt/36-branch-names-too-long-tmux`           |

**D2 — bounded, deterministic slug (`slug_short`).** slugify, then drop a leading
conventional-commit type word, drop stopwords, cap at 5 words. Re-derivable from the same title
— **no LLM suggester** (it would reintroduce the run-to-run instability the naming key exists to
prevent, and add a network failure point before any session exists). One seam to swap later if
wanted. Follow-up: human-named branches, tracked separately.

**D3 — `<n>` is the stable join key; the slug is a cosmetic suffix.** The issue's second option,
not "slug re-derivable from `<n>` alone." Nothing keys off the slug: the **worktree dir is the
durable `<n>`-keyed artifact carrying it** — `_find_worktree` globs `<base>/<n>-*`, and the
session name peels `<n>-` off that basename. So teardown/resume need **no title lookup** (the
property the old bare-`<n>` key had) and are **drift-proof** — a retitle can't strand the
session. Rejected: recomputing the slug from the live title at teardown, which adds a network
call to a local `rm` and orphans the session on any retitle.

## Consequences

- tmux forbids `.`/`:` in session names but allows `/`; `slug_short` emits only `[a-z0-9-]` and
  `_repo_slug` slugifies the repo label, so a dotted repo dir can't break it. `claude -n` is a
  display name, so the tmux and claude names stay unified.
- `gh` graduates to a dedicated test shim (like `git`/`tmux`): `work` now issues two distinct gh
  calls (`gh issue view` tracker, `gh api user` forge) needing independent results.
- `_repo_slug`'s git-toplevel default isn't exercised hermetically (pinned via `HGT_REPO_NAME`),
  same carve-out as the worktree base in 0002/D3.
- Supersedes the naming in 0002/D3 and 0003. Existing branches/worktrees/sessions are **not**
  renamed (issue non-goal) — new work only.
