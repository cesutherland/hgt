# ADR 0001 — Slice 1 foundations

- **Status:** accepted
- **Date:** 2026-06-11
- **Context:** Phase 0 / Slice 1 (issue #3) — CLI skeleton + `hgt init`. Resolves the spec §7
  open decisions that gate writing any code, and records the seams chosen so later slices
  don't relitigate them.

## Decisions

**D1 — Language: Bash.** hgt is a thin orchestrator over `gh` / `git` / `claude` / `tmux`;
shell is the native tongue and the fastest path to dogfood a phase-disposable POC. The cost
(weak typing, quoting footguns) is real but bounded — see D3 (reversible) and D6 (checkpoint).

**D2 — GitHub access via `gh` shell-outs behind one module** (`lib/gh.sh`), per §7. It is the
single seam to the outside world; nothing else calls `gh` directly.

**D3 — Testing is two-tier; Slice 1 ships Tier 1 only.** Tier 1 is implementation-agnostic
black-box conformance: run the `hgt` executable as a subprocess and assert on exit code /
merged output / filesystem, with PATH-shims for `gh`/`git`/`tmux`/`claude` (`test/shims/`) to
stay hermetic. The suite pins *behavior, not internals*, which is what makes D1 reversible —
a future rewrite (or language change) either passes the same suite or flags a real regression.
Tier 2 (language-local unit tests) is deferred until a gnarly internal exists — the normalizer.

**D4 — forge / tracker seam.** Two axes hide inside "GitHub": **tracker** (issues, states,
snapshots) and **forge** (branches, PRs, ruleset). A future config can split them (e.g.
beads-as-tracker + GitHub-as-forge). So: core speaks **"state"** (`ready` / `in-progress` /
`needs-human`) and an opaque issue ref — never "label" or "issue number"; `lib/gh.sh` functions
are prefixed `tracker_*` / `forge_*`; states are mutually exclusive in core, with the adapter
owning the (looser) GitHub label encoding. **No** adapter registry / plugin system yet (YAGNI).

**D5 — labels live-created, ruleset printed.** `hgt init` idempotently creates the three state
labels via `tracker_ensure_states` (using `gh label create --force`), and **prints** the §3
branch-protection script for the default branch rather than applying it. File scaffold is
stamped create-if-absent (never clobbers a user's edits).

**D6 — the `ready`-snapshot slice is the language re-evaluation checkpoint.** Bash's one weak
spot is the security-sensitive normalization + snapshot glue at the `ready` trust boundary.
That is not in Slice 1 (the hook is a stub *surface* only). When `hgt issue ready` is built,
decide whether that module graduates to a stronger language. Normalization itself shells out
to a vetted unicode library regardless of host language.

## Consequences

- Distribution is friction-free (no build, no runtime dep beyond `bash`/`gh`/`git`/coreutils).
- The language bet is hedged: the conformance suite outlives the implementation.
- The biggest future refactor is pre-paid: forge/tracker functions are already name-separated.
