# hgt

Issue-driven development harness. GitHub Issues are the work queue; work executes via a GitHub Action (async) or `hgt work <n>` locally — both consuming the same frozen, normalized snapshot.

The full spec lives at [docs/SPEC.md](docs/SPEC.md). Read it in full before doing anything: it covers vision, architecture, the trust boundary at `ready`, non-negotiable guardrails, the bootstrap phases, and the open decisions to resolve in Phase 0.

We are currently in **Phase 0 — manual bootstrap**. `hgt` does not exist yet; vanilla Claude Code is building the CLI skeleton + `hgt init` + `hgt issue` basics by hand until the CLI is self-hosting. Do not scope beyond the current slice.
