# hgt

An issue-driven development harness. GitHub Issues are the work queue; work executes
against that queue two ways — asynchronously via a GitHub Action, or locally via
`hgt work <n>` — both consuming the same frozen, normalized snapshot of the issue.

The name carries some lore:

- **hgt** is **Human Gas Town** — which is about how we've all been feeling.
- **hgt** is also **Mercury Town** — which is most definitely toxic.
- **hgt** is in anticipation of whatever other thing is happening right now, that wins
  later — a nod to mercurial vs. git.

## What it is

You are the **Mayor** (what's worth doing, and in what order), the **Witness** (is it
correct), and the **Deacon** (is it safe to land). Agents are Polecats. The harness keeps
a human in exactly those three seats and nowhere else.

This is **not** an autonomous swarm. The human holds three seats — scope, review, merge —
and the machine drives everything between. That buys two specific things, both borrowed
from Steve Yegge's Gastown:

- **Self-propelling work:** once an issue is scoped and labeled, it moves itself to a
  reviewable PR without you driving each step — you queue work, you don't babysit it.
- **Persistent work state:** the durable state lives in git (issue + committed plan file),
  not in an agent's memory, so a crash or `--resume` doesn't lose the thread.

We keep those two ideas and drop the rest of Gastown's chaos: the 20–30-agent burn, the
auto-merge, and the rampaging supervisor.

## How it works

Two surfaces, one queue:

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
normalized snapshot** of the issue body. Executors consume **the snapshot, never the live
issue**. This closes the two holes that defeat a naive "a human read it" gate:

- **Invisibility:** raw issue text can carry zero-width / Unicode-tag-block / bidi
  payloads that render blank to a human but are obeyed by the model. Normalize before
  anyone — human or agent — reads it.
- **TOCTOU / indirection:** issues can be edited after review, comments added after
  labeling, URLs fetched at runtime. The frozen snapshot means later edits, later
  comments, and body-embedded URLs are simply not in the executor's input.

The thing that reads untrusted input and the thing that holds write power are never the
same context. The executor consumes the de-fanged snapshot and holds only the narrow
write it needs — push a feature branch, open a PR. It **never** writes to `main` and
holds **no** secret beyond the two it requires.

## Guardrails

These are settled design decisions, not suggestions:

- **Secrets:** the runner gets only `ANTHROPIC_API_KEY` + a minimal `GITHUB_TOKEN`
  (`contents: write` + `pull-requests: write`, nothing more). No cloud creds, no
  publish/deploy tokens. No `id-token: write` unless we actually federate to a cloud
  provider.
- **Branch protection on `main`:** require a PR and at least one **human** review before
  merge; no executor app on any bypass list; disable "Allow GitHub Actions to create and
  approve pull requests"; enable "Require approval of the most recent reviewable push."
- **Input handling:** only `ready`-labeled issues are picked up; `ready` normalizes then
  snapshots the body; executors never fetch arbitrary URLs from issue bodies.
- **Action hygiene:** pin `anthropics/claude-code-action` to ≥ v1.0.94 (the auth-bypass
  fix); gate who/what can trigger the workflow; treat workflow files on PR branches as an
  escalation vector.
- **Merge discipline:** the human is the merge gate. Never auto-merge on green —
  green is necessary, not sufficient.

When in doubt, the executor should be **poor and powerless**: injection that succeeds
against a context with no secrets and no `main` access is a non-event.

## Persistence & recovery

Agent coordination state is ephemeral and dies on crash; **git is durable**. So the issue
plus a committed plan file in the worktree *is* the durable work state. Crash recovery is
re-read the plan file, check `git status`, and `claude --resume` (named sessions:
`claude -n <repo>/<n>-<slug>` so resume is deterministic). By default the named session runs
inside a **detached** tmux session (`<repo>/<n>-<slug>`) that outlives the terminal, so recovery
is "reattach if it's still alive, else recreate." The `<n>` is the stable join key; the slug is
a human-readable hint recovered from the worktree dir, so teardown needs no title lookup. Commit
early and often so every commit is a recovery checkpoint.

## CLI surface

```
hgt init                 # idempotent scaffold of hgt into a new/existing repo
hgt issue ...            # manage the issue queue (create, list, show, ready)
hgt work <n>             # local execution: worktree + Claude session for issue <n>
```

- **`hgt init`** drops a lean `CLAUDE.md` and gated, least-privilege workflow file(s),
  creates the labels, applies the `main` ruleset, writes `.worktreeinclude`, and installs
  the unicode-normalization hook.
- **`hgt issue ready <n>`** is the security-critical verb: unicode-normalize the body,
  write a frozen snapshot, apply the `ready` label. This is the trust boundary — treat it
  as security-sensitive code.
- **`hgt work <n>`** creates a git worktree and a named Claude session (in a detached tmux
  session by default; `--no-tmux` launches inline), wires in the frozen snapshot, and
  handles teardown / `--resume`.

## Tests & CI

The conformance suite is [bats](https://github.com/bats-core/bats-core); run it with
`./test/run.sh`. It's hermetic — external commands (`gh`/`git`/`tmux`/`claude`) are
PATH-shimmed in `test/shims/`, so there's no network, no secrets, and no real repo mutation.

CI (`.github/workflows/ci.yml`) runs that suite on every PR to `main` and reports a
`conformance` status check. Per spec §3 the workflow is deliberately poor and powerless:
`permissions: contents: read`, no secrets, pinned action SHAs, `pull_request` (never
`pull_request_target`). A red suite is meant to **block** merge — green is necessary, not
sufficient; a human still reviews and merges.

Making `conformance` an actually-*required* check is a one-time, admin-only step on this
repo (it mutates branch protection, so it's not run automatically):

```
# 1) apply the §3 base ruleset if it doesn't exist yet (review the printed script first):
hgt init            # prints the branch-protection script — run it
# 2) add the conformance suite as a required status check on that ruleset:
scripts/require-conformance-check.sh
```

This is hgt-specific on purpose: check contexts are your workflow's job names, so
`hgt init`'s generic ruleset never hardcodes `conformance` — it only shows the shape for
you to plug in your own repo's CI checks.

## Status

**Phase 0 — manual bootstrap.** `hgt` does not exist yet; vanilla Claude Code is building
the CLI skeleton + `hgt init` + `hgt issue` basics by hand until the CLI is self-hosting
("the compiler written in assembly" stage). Later phases: dogfood the local loop (1), wire
the async Actions path with full guardrails (2), harden (3).

The full design lives in [docs/SPEC.md](docs/SPEC.md).
