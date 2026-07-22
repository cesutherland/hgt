# ADR 0005 — Issue #58: CI nudge for executor PRs

- **Status:** accepted
- **Date:** 2026-07-22
- **Context:** The executor opens its PR via `GITHUB_TOKEN`. GitHub's recursion guard
  suppresses `pull_request`-triggered workflow runs on events attributed to `GITHUB_TOKEN`,
  so `ci.yml` never runs on executor PRs — no `test` status on exactly the PRs trusted
  least (#58).

## Decision

**Ship (a), the human nudge.** The executor's PR body tells the reviewing human to close
and reopen the PR (or push an empty commit) before merging. Either action is
human-attributed, so it fires `pull_request` CI normally as a real PR check — no plumbing,
no new credential. A human is already the merge gate (§3); cost is one click.

Rejected for now: **(b) dispatch** (`workflow_dispatch` after PR-open, wired back as a
commit status) — more moving parts than a one-click nudge is worth today. Revisit if the
manual step becomes the bottleneck it's designed to surface. Rejected outright: **(c)**
App/PAT PR authorship — puts a non-powerless credential on the runner, breaking §3.

## Consequences

- `hgt-execute.yml`'s prompt instructs the executor to append the nudge note to every PR
  body, so it isn't tribal knowledge.
- `test` still is not a required check (#55's job); a human who skips the nudge just merges
  without seeing green, same risk profile as before this fix.
- No workflow or permissions changes — `ci.yml` and `hgt-execute.yml`'s trigger/permissions
  are untouched.
