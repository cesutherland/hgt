# ADR 0003 — Slice 2b: tmux launcher for `hgt work`

- **Status:** accepted
- **Date:** 2026-07-02
- **Context:** Phase 0 / Slice 2b (issue #9) — a fast-follow of Slice 2 (#8) that swaps the
  `launch_session` seam's inline default for a detached tmux session. Slice 2 deliberately left
  this seam (0002/Consequences) with the inline `claude -n hgt-issue-<n>` as a placeholder. Two
  decisions here are worth pinning so later slices don't relitigate them.

## Decisions

**D1 — the default launch is a *detached* tmux session, for recovery, not ergonomics.** `hgt work
<n>` runs `tmux new-session -d -s hgt-issue-<n> -c <worktree> 'claude -n hgt-issue-<n> …'` and then
attaches. The point isn't a nicer terminal; it's spec §4: a detached session running the named
claude session **survives the terminal (or ssh) dying**. That collapses crash-recovery from
"relaunch from scratch" to "reattach if it's alive, else recreate" — the same durability lesson as
the committed plan file (0002/D2), applied to the live process. The tmux session name is the claude
session name (`hgt-issue-<n>`), so both `tmux`-resume and `claude --resume` key off one deterministic
id. `--no-tmux` keeps the Slice 2 inline launch for anyone not living in tmux (accepted cost: no
detached-recovery on that path — it's the fallback, not the paved road).

**D2 — attach vs. switch-client is chosen by `$TMUX`, and resume never spawns a second session.**
Inside tmux (`$TMUX` set) `attach-session` is refused (no nesting), so we `switch-client` the current
client instead; outside tmux we `attach-session`. Before creating, `tmux has-session -t
hgt-issue-<n>` gates create-vs-reuse: a live session is reattached, never duplicated. Teardown is
symmetric — `hgt work rm <n>` `kill-session`s the session (guarded on `has-session`) alongside the
worktree removal, so `--no-tmux` and already-dead runs don't error.

## Consequences

- `tmux` graduates from a generic `_shim` symlink to a dedicated shim (as `git` did in 0002/D1),
  because hgt branches on `has-session`'s exit code — the one tmux result the suite must control
  independently (default absent, like real tmux; `SHIM_TMUX_HAS_SESSION=0` simulates live). hgt's
  contract stays "which tmux commands it issues," pinned via `$SHIM_LOG`; we don't re-test tmux.
- The Tier-1 suite gains coverage for launch, attach-vs-switch (`$TMUX` unset vs. set),
  resume-existing, and teardown-kills-session, all through the shim.
- `$TMUX` is now a launcher input, so the conformance suite clears it in `work_env` (the suite may
  itself run inside tmux) and sets it back only for the switch-client case.
