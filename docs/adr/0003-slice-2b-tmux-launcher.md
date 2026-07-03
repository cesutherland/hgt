# ADR 0003 — Slice 2b: detached tmux as the default launcher

- **Status:** accepted
- **Date:** 2026-07-02
- **Context:** Phase 0 / Slice 2b (#9) fills the `launch_session` seam that Slice 2 (#8) left
  as a placeholder inline launch.

## Decision

The default launch is a **detached** tmux session, for recovery — not ergonomics. `hgt work
<n>` runs `tmux new-session -d -s hgt-issue-<n> -c <worktree> 'claude -n hgt-issue-<n> …'` and
then attaches. The point isn't a nicer terminal: a detached session **survives the terminal
(or ssh) dying**, so crash-recovery collapses from "relaunch from scratch" to "reattach if it's
alive, else recreate" (spec §4) — the same durability lesson as the committed plan file
(0002/D2), applied to the live process. The tmux session name is the claude session name, so
`tmux`-resume and `claude --resume` key off one id. `--no-tmux` keeps the inline launch as the
fallback (accepted cost: no detached-recovery there).

Everything downstream of that choice is mechanical and lives in code comments, not here:
attach-vs-`switch-client` is forced by `$TMUX` (tmux refuses a nested attach), resume reuses a
live session rather than duplicating it, and `hgt work rm` kills it on teardown. None of those
is a real decision worth pinning.

## Consequences

- `tmux` graduates from the generic `_shim` symlink to a dedicated shim (as `git` did in
  0002/D1), because hgt branches on `has-session`'s exit code — the one tmux result the suite
  must control independently. hgt's contract stays "which tmux commands it issues," pinned via
  `$SHIM_LOG`; we don't re-test tmux.
- `$TMUX` is now a launcher input, so the conformance suite clears it in `work_env` and sets it
  back only for the switch-client case.
