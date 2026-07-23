# ADR 0006 — Issue #84: `hgt respond`, not `hgt review`

- **Status:** accepted
- **Date:** 2026-07-23
- **Context:** #18 ("hgt review — list + reply to PR comments, the mechanical layer") already
  claims the `hgt review` name. #84 needed a verb for the *session/orchestration* layer built on
  top: a tmux session pairing a sandboxed agent pane (#67) with a privileged human shell pane,
  kicked off against a PR. #84 left this as an open decision: fold under `hgt review` (with #18
  as its plumbing) or use a distinct verb (`hgt respond` / `hgt address`).

## Decision

`hgt respond <pr>`. Keeps `hgt review` free for #18's mechanical primitives (list/reply to
review comments) — lower-level, reusable outside a tmux session, and plausibly wanted directly
by the future Actions responder (#83) without a session wrapper. `respond` names exactly what
this verb does: kick off a session that responds to review feedback. That mirrors `hgt work`'s
pattern — the verb names the session's action (`work` an issue, `respond` to a review), not a
noun over a resource — rather than `hgt review <pr>`, which reads as "look at" more than "act on."

## Consequences

- #18, whenever it lands, is free to take the bare `hgt review` verb (e.g. `hgt review list|
  reply <pr>`) without colliding with this ticket's surface.
- If #18 later wants a session entry point under its own name, it can shell out to
  `hgt respond <pr>` rather than re-implementing the launcher.
- Worktrees/sessions for `hgt respond` are keyed `pr-<n>`, not bare `<n>` — `hgt work` and
  `hgt respond` share one worktree-naming convention (`lib/session.sh`), and an issue and a PR
  can carry the same number.
