# ADR 0002 — Slice 2: `hgt work`

- **Status:** accepted
- **Date:** 2026-06-12
- **Context:** Phase 0 / Slice 2 (issue #8) — `hgt work <n>`, the local execution path (spec §5).
  We **flip the spec's Phase-0 order**, building `work` before `issue`: the `ready`
  normalize+snapshot trust boundary exists to de-fang *untrusted* issue text on the Actions
  path (Phase 2), but locally you author and trust your own issues, so `work` reads the live
  issue body directly — and this is the slice that unlocks dogfooding. `hgt issue` CRUD and the
  `ready` snapshot follow once we're self-hosting. These four decisions are recorded so later
  slices don't relitigate them.

## Decisions

**D1 — git is a shimmed boundary (refines 0001/D3).** Like `gh` / `claude` / `tmux`, `git` is
an external tool hgt orchestrates, not behavior hgt owns. hgt's contract is *which* git commands
it issues (pinned via `SHIM_LOG`) plus its own filesystem writes (plan-file content, carried
files) — asserting git's *effects* would re-test git, not hgt. So `git` graduates from a generic
`_shim` symlink to a thin shim script that still logs every call and honors `SHIM_GIT_OUT` /
`SHIM_GIT_EXIT`, with exactly one bit of fake behavior: `worktree add` `mkdir -p`s the target
path, so hgt's plan-file write + `.worktreeinclude` copy have somewhere to land. **ADR note:** a
dumb shim won't catch git-*semantic* failures (a bad `--base`, a path collision, a busted slug);
those aren't hgt's contract, and dogfooding (Phase 1) surfaces them.

**D2 — the plan file is committed to the feature branch.** `.hgt/work/<n>.md` (number, title,
URL, verbatim body, checklist, recovery note) is written into the worktree and committed as the
first recovery checkpoint (§4 — git is the durable work state, not the agent's memory). Accepted
cost: it appears in the eventual PR diff. "Move hgt work-state off the feature branch" is a
deliberate later concern, not gold-plated now. On resume the file is never clobbered (it reuses
`stamp_file`), so committed agent edits survive.

**D3 — worktree location is a repo sibling.** `../<repo>-worktrees/issue-<n>` — outside the repo,
so no `.gitignore` entry is needed and worktrees never pollute the tree. The parent dir is
overridable via `HGT_WORKTREE_DIR`; the conformance suite points it inside `$TMP` so worktrees
don't leak past teardown. (Consequence: the default-path computation needs real `git
rev-parse`, so it's the one path the hermetic suite doesn't exercise — see D1's note.)

**D4 — default base is `HEAD`, not `origin/HEAD`.** Per spec §7 `baseRef: "head"`: basing the new
worktree off `HEAD` supports stacking by default (build issue B atop unmerged issue A). `--base
<ref>` pins elsewhere when you want to branch from `main`/`origin/HEAD` instead.

## Consequences

- The conformance suite stays hermetic and fast, and pins hgt's real contract (boundary calls +
  its own writes) without a real git, repo, or network — the language bet (0001/D1) stays hedged.
- `tracker_issue_view` (one `gh issue view --json … --jq …` call, serialized for core to parse
  without touching JSON) is the one new tracker verb; Slice 3's `issue show` builds on it.
- The tmux launcher is deferred to Slice 2b behind the `launch_session` seam (a future
  `--no-tmux` selector); this slice launches `claude -n hgt-issue-<n>` inline in the worktree.
