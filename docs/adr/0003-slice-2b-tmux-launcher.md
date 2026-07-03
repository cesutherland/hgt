# ADR 0003 — Slice 2b: detached tmux as the default launcher

- **Status:** accepted
- **Date:** 2026-07-02
- **Context:** Phase 0 / Slice 2b (#9) fills the `launch_session` seam that Slice 2 (#8) left
  as a placeholder inline launch.

## Decision

The default launch is a **detached** tmux session, chosen for recovery, not ergonomics. A
detached session survives the terminal (or ssh) dying, so crash-recovery becomes "reattach if
it's alive, else recreate" instead of "relaunch from scratch" (spec §4) — the durability lesson
of the committed plan file (0002/D2), applied to the live process. `--no-tmux` keeps the inline
launch as the fallback, without that recovery.

## Consequences

- `tmux` graduates from the generic `_shim` symlink to a dedicated shim (as `git` did in
  0002/D1), because hgt branches on `has-session`'s exit code — the one tmux result the suite
  must control independently. hgt's contract stays "which tmux commands it issues," pinned via
  `$SHIM_LOG`; we don't re-test tmux.
- `$TMUX` is now a launcher input, so the conformance suite clears it in `work_env` and sets it
  back only for the switch-client case.
