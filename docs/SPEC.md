# hgt — Bootstrap & Handoff Spec

> Seed document for the `hgt` ("human gas town") POC. Commit this at repo root as the
> starting `CLAUDE.md` (or `docs/SPEC.md` + a thin `CLAUDE.md` that links to it).
> It exists so a fresh Claude Code session has full context without re-deriving it.

---

## 0. How to start (the flip-over)

1. Create an empty repo, commit this file.
2. Open a **vanilla Claude Code session** in it (no `hgt` exists yet — this is Phase 0).
3. Paste the kickoff prompt below.

```
Read CLAUDE.md (this repo's hgt handoff spec) in full before doing anything.
We are in Phase 0: manual bootstrap. hgt does not exist yet, so we build it by hand
until the CLI is self-hosting.

Start with Phase 0 / Slice 1 only: the CLI skeleton + `hgt init`. Propose a plan,
including the language/tooling decision (see "Open decisions"), and wait for my
approval before writing code. Do not scope beyond Slice 1. I review everything.
```

The first thing Claude Code should do is help you resolve the **Open decisions** (§7), then split this file into a lean `CLAUDE.md` + per-slice issues.

---

## 1. Vision

`hgt` is an issue-driven development harness: GitHub Issues are the work queue, and work
executes two ways against the same queue —

- **Actions path (async):** a GitHub Action picks up *ready* issues and produces PRs.
- **CLI path (local):** `hgt` shells out to local git worktrees + Claude Code sessions
  for issues you want to drive by hand.

You are the **Mayor** (what's worth doing, in what order), the **Witness** (is it
correct), and the **Deacon** (is it safe to land). Agents are Polecats. The harness keeps
a human in exactly those three seats and nowhere else. We are **not** building an
autonomous swarm; we are building a paved road with a human at both ends — scoping and
review — and automation in the middle.

Inspiration is Steve Yegge's Gastown, minus the chaos: keep the persistent-work-state and
self-propelling-work ideas, drop the 20–30-agent burn, the auto-merge, and the rampaging
supervisor.

---

## 2. Architecture

### Two surfaces, one queue

```
GitHub Issues (the queue)
   │
   ├─ ready label ──► Actions executor ──► PR ──► human review ──► merge
   │
   └─ hgt work <n> ─► local worktree + Claude session ──► PR ──► human review ──► merge
```

### The trust boundary is the `ready` snapshot

Everything **before** `ready` is untrusted: humans scope it, a human reviews it, and the
text is unicode-normalized. The moment an issue goes `ready`, `hgt` takes a **frozen,
normalized snapshot** of the issue body. Executors (Action or local) consume **the
snapshot, never the live issue**. This closes the two holes that defeat a naive
"a human read it" gate:

- **Invisibility:** raw issue text can carry zero-width / Unicode-tag-block / bidi
  payloads that render blank to a human but are obeyed by the model. Normalize before
  anyone — human or agent — reads it.
- **TOCTOU / indirection:** issues can be edited after review, comments added after
  labeling, URLs fetched at runtime. The frozen snapshot means later edits, later
  comments, and body-embedded URLs are simply not in the executor's input.

### Powerless reader / privileged actor

The thing that reads untrusted-ish input and the thing that holds write power are never
the same context. In the POC this collapses to: the executor consumes the *frozen,
normalized, human-reviewed snapshot* (low-trust input, de-fanged) and holds only the
narrow write it needs (push a feature branch, open a PR) — **never** write to `main`,
**never** any secret beyond the two it requires.

---

## 3. Non-negotiable guardrails

These are settled decisions from design. Do not relitigate them in code review; encode
them. (See §8 for the "why" links.)

**Secrets / tokens**
- Runner gets **only** `ANTHROPIC_API_KEY` + a minimal `GITHUB_TOKEN`. No cloud creds,
  no npm/publish/deploy tokens — nothing else worth stealing.
- Do **not** grant `id-token: write` unless we actually federate to a cloud provider.
  Omitting it means the OIDC request token is never minted, removing that exfil target.
- `GITHUB_TOKEN` permissions: `contents: write` + `pull-requests: write`, nothing more.

**Branch protection on `main`** (a ruleset)
- Require PR + at least one **human** review before merge.
- Do **not** add `github-actions` (or any executor app) to any bypass list.
- **Disable** "Allow GitHub Actions to create and approve pull requests" — otherwise an
  agent can rubber-stamp its own PR and the human gate evaporates.
- **Enable** "Require approval of the most recent reviewable push."
- Per-branch write isn't a token scope — it's branch protection applied to the ref. The
  executor pushes feature branches freely; `main` rejects direct writes automatically.

**Input handling**
- Only issues labeled `ready` are ever picked up.
- `ready` is set by `hgt issue ready <n>`, which **normalizes then snapshots** the body.
- Executors read the snapshot. No fetching arbitrary URLs out of issue bodies.

**Action version & triggers**
- Pin `anthropics/claude-code-action` to **≥ v1.0.94** (the auth-bypass fix). Track the
  action README for newer advisories.
- Gate who/what can trigger the workflow. Treat workflow files on PR branches as an
  escalation vector (a branch can ship a workflow that escalates itself).

**Merge discipline**
- Human is the merge gate. Never auto-merge on green. Green is necessary, not sufficient.

---

## 4. Persistence & recovery (the Gastown "beads" lesson)

Agent coordination state is ephemeral and dies on crash; **git is durable**. So:

- The **issue + a committed plan file** in the worktree *is* the durable work state.
- Crash recovery = re-read the plan file, check `git status`, `claude --resume` (use
  **named** sessions: `claude -n <repo>/<n>-<slug>` so resume is deterministic — `<n>` is the
  stable join key, the slug a human-readable hint recovered from the worktree dir; see ADR 0004).
- Do **not** depend on Agent Teams' in-process task/inbox state for anything you can't
  afford to lose — it's wiped on restart. For this POC, prefer a single named, resumable
  session per issue over a team.
- Commit early and often so every commit is a recovery checkpoint.

---

## 5. CLI surface (the three jobs)

```
hgt init                 # scaffold hgt into a new/existing repo
hgt issue ...            # manage the issue queue
hgt work <n>             # local execution: worktree + Claude session for issue <n>
```

**`hgt init`** — idempotent scaffold of a target repo:
- drop a lean `CLAUDE.md`, the gated + least-privilege workflow file(s)
- create labels: `ready`, `in-progress`, `needs-human`, etc.
- apply (or print a script to apply) the `main` ruleset from §3
- write `.worktreeinclude` (so worktrees get `.env` etc.)
- install the unicode-normalization hook used by the `ready` transition

**`hgt issue`** — at minimum: `create`, `list`, `show`, and the security-critical one:
- `hgt issue ready <n>` → unicode-normalize the body, write a **frozen snapshot**
  (committed plan file and/or a locked field), apply the `ready` label. This is the
  trust boundary; treat it as security-sensitive code.

**`hgt work <n>`** — local worktree + session lifecycle:
- create a git worktree for the issue's branch and a **named** Claude session in it
- wire the frozen plan/snapshot into the session
- handle teardown / `--resume`
- respect branch stacking: default `--worktree` bases off `origin/HEAD`, which breaks
  stacks — use `worktree.baseRef: "head"` or fall back to manual
  `git worktree add -b <branch> <base>` for stacked work.

---

## 6. Bootstrap plan (self-hosting in phases)

**Phase 0 — Manual bootstrap (no hgt).** Vanilla Claude Code builds the CLI skeleton +
`hgt init` + `hgt issue` basics by hand. This is the "compiler written in assembly" stage.
Exit criteria: you can create/label/snapshot issues and `hgt work <n>` opens a worktree +
session.

**Phase 1 — CLI self-hosting (local loop).** Use `hgt work` to drive `hgt`'s own
remaining development. You're now dogfooding the CLI half; human is Mayor/Witness/Deacon.
Exit criteria: building hgt features through hgt's own local loop feels better than raw
Claude Code.

**Phase 2 — Actions path (async loop).** Wire `claude-code-action` with the full §3
guardrails, `ready`-gating, frozen snapshot, normalization, branch protection. Move
suitable issues to the Actions executor. Now hgt builds hgt via PRs you review.
Exit criteria: a `ready` issue reliably becomes a reviewable PR with zero local babysitting.

**Phase 3 — Expand & harden.** More CLI verbs, more action recipes, the powerless-reader/
privileged-actor split made explicit if/when an executor needs to read richer untrusted
context, observability on the queue.

---

## 7. Open decisions (resolve in Phase 0, slice 1)

- **Language/runtime.** Two sane defaults: **TypeScript/Node** (fastest to dogfood given
  a frontend-deep author; thin `commander`/`oclif`) or **Go** (single static binary like
  Gastown, trivial distribution). Pick one before writing code; don't drift.
- **GitHub access from the CLI.** `gh` CLI shell-outs (fast to start) vs. Octokit/API
  (typed, testable). Lean `gh` for the POC, abstract behind one module so it's swappable.
- **Snapshot storage.** Committed plan file in the worktree vs. a locked issue comment vs.
  both. Recommend: committed plan file is the source of truth (durable, diffable);
  optionally mirror to a locked comment for visibility.
- **Worktree strategy default.** Native `--worktree`/`--tmux` vs. manual. Given stacking
  matters, default to `baseRef: "head"` and keep a manual path for stacked series.

---

## 8. Reference (verify current before relying on setup specifics)

- claude-code-action (setup, triggers, security): https://github.com/anthropics/claude-code-action
- Claude Code GitHub Actions docs: https://code.claude.com/docs/en/github-actions
- Worktrees (flags, baseRef, subagent isolation): https://code.claude.com/docs/en/worktrees
- Agent teams (and their state-persistence limits): https://code.claude.com/docs/en/agent-teams
- GitHub rulesets / branch protection: https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository

> Security context baked into §3 comes from: the June 2026 `claude-code-action` permission-
> bypass + prompt-injection disclosures (patched v1.0.94), Microsoft's credential-exfil
> demonstration, and the invisible-Unicode (ASCII-smuggling) injection class. When in
> doubt, the executor should be **poor and powerless** — injection that succeeds against a
> context with no secrets and no `main` access is a non-event.
