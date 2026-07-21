# hgt

Issue-driven development harness. GitHub Issues are the work queue; work executes via a GitHub Action (async) or `hgt work <n>` locally — both consuming the same frozen, normalized snapshot.

The full spec lives at [docs/SPEC.md](docs/SPEC.md). Read it in full before doing anything: it covers vision, architecture, the trust boundary at `ready`, non-negotiable guardrails, the bootstrap phases, and the open decisions to resolve in Phase 0.

We are currently in **Phase 0 — manual bootstrap**. `hgt` does not exist yet; vanilla Claude Code is building the CLI skeleton + `hgt init` + `hgt issue` basics by hand until the CLI is self-hosting. Do not scope beyond the current slice.

## Writing style

Applies to everything you generate — chat, commits, PRs, issues. Fewer words wins. Global "be concise" gets ignored, so these are shapes you can check, not vibes.

- **Global:** don't spell it out unless asked. No preamble, no restating what's already visible (the diff, the file, the question), no "Summary/Overview" throat-clearing.
- **Chat:** lead with the answer. Group, don't enumerate. Levity and bluntness are fine.
- **Commit subject:** `type(#n): imperative, lowercase, ≤70 chars`. The subject carries the change.
- **Commit body:** why, not what; ≤3 lines. Omit it when the subject says enough.
- **PR body:** what changed + why, ≤5 lines unless asked. No `## Summary`, no restating the diff, no checklist theater. Link the issue.
- **Issue body:** the problem + the shape of done. Durable guidance only — the §2 snapshot excludes comments, so nothing load-bearing lives in a comment. Tight.
- **Code comments:** match the density of the surrounding code. Explain *why*, not *what*; no narrating the obvious, no commented-out code. `file_path:line` beats prose.
- **Templates:** fill the `.github/ISSUE_TEMPLATE/` skeleton, don't hand-roll.
- **Self-check before send:** could this be half as long without losing signal? If yes, cut.
