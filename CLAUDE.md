# hgt

Issue-driven development harness. GitHub Issues are the work queue; work executes via a GitHub Action (async) or `hgt work <n>` locally — both consuming the same frozen, normalized snapshot.

The full spec lives at [docs/SPEC.md](docs/SPEC.md). Read it in full before doing anything: it covers vision, architecture, the trust boundary at `ready`, non-negotiable guardrails, the bootstrap phases, and the open decisions to resolve in Phase 0.

We are currently in **Phase 0 — manual bootstrap**. `hgt` does not exist yet; vanilla Claude Code is building the CLI skeleton + `hgt init` + `hgt issue` basics by hand until the CLI is self-hosting. Do not scope beyond the current slice.

## Writing style

Applies to everything you generate — chat, commits, PRs, issues. Fewer words wins. Global "be concise" gets ignored, so these are shapes you can check, not vibes. Meta-rule: **the budget is reviewer-minutes**, not tokens or diff size — every shape below is downstream of that.

- **Global:** don't spell it out unless asked. No preamble, no restating what's already visible (the diff, the file, the question), no "Summary/Overview" throat-clearing.
- **Names:** committed text uses role terms (operator / reviewer / the human) — never personal names, usernames, or author credits. Repo slugs in URLs are the one exception.
- **Chat:** lead with the answer. Group, don't enumerate. Levity and bluntness are fine.
- **Commit subject:** `type(#n): imperative, lowercase, ≤70 chars`. The subject carries the change.
- **Commit body:** why, not what; ≤3 lines. Omit it when the subject says enough.
- **PR body:** ≤3 sentences + a per-AC verification list — each item says how it was verified, or why it isn't. Root cause and investigation live in the issue — link it, never re-derive it. No `## Summary`, no restating the diff, no checklist theater.
- **Issue body:** the problem + the shape of done. Durable guidance only — the §2 snapshot excludes comments, so nothing load-bearing lives in a comment. Tight.
- **Code comments:** match the density of the surrounding code. Explain *why*, not *what*; no narrating the obvious, no commented-out code. `file_path:line` beats prose. Full guide: [docs/style.md](docs/style.md).
- **Templates:** fill the `.github/ISSUE_TEMPLATE/` skeleton, don't hand-roll.
- **Self-check before send:** could this be half as long without losing signal? If yes, cut.

## Session memory

Session memory is cache, never repo law. Hardened feedback graduates to
CLAUDE.md/docs and the memory shrinks to a pointer *in the same session* —
graduation includes the shrink, so there's no standing audit.
