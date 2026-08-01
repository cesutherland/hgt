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

You hold three seats, and nothing else:

- **Mayor** — what's worth doing, in what order; sling it.
- **Witness** — keep it moving: watch the runs, unstick the stuck, answer `needs-human`.
- **Judge** — is it right, does it land: review the PR, approve the merge.

Two of those names are stolen from Steve Yegge's
[Gas Town](https://steve-yegge.medium.com/welcome-to-gas-town-4f25ee16dd04), and the
theft is an inversion, on purpose. In Gas Town the Mayor (the concierge that dispatches
work) and the Witness (the babysitter that unsticks workers) are *agents*; the human —
the Overseer — feeds the machine ideas. hgt hands those seats to the human: our Mayor is
Overseer + Mayor collapsed into one (you decide *and* you sling — `hgt issue ready <n>`
is the dispatch), and the Witness's unsticking rounds are yours.

**Judge** is not a Gas Town name because Gas Town has no such seat. Its Refinery merges
autonomously — conflict serialization, not judgment; quality is amortized into up-front
specs and redundancy, and some work is simply lost. That gap is hgt's thesis: gt is
one-sided — sling work (GUPP: "if there is work on your hook, you must run it"). hgt is
two-sided — sling work, then take responsibility for the result. Specs won't be perfect
in advance, and things drift between spec and landing, so judgment stays a live human
act at the back end.

(Gas Town's Deacon — a daemon patrolling the agents to keep them on task — gets no human
seat here. The name is reserved, pointed backwards: a future patrol that nudges *you* —
PRs waiting on review, stale `needs-human`, an idle queue. The human is the propellant,
and the propellant needs keeping on task too.)

The harness is **not** an autonomous swarm. It borrows two Gas Town ideas:

- **Self-propelling work** (our phrase; Yegge's concept is GUPP): once an issue is
  scoped and labeled, it moves itself to a reviewable PR without you driving each step.
- **Persistent work state:** the durable state lives in git (issue + committed plan file),
  not in an agent's memory, so a crash or `--resume` doesn't lose the thread.

— and drops the rest of the chaos: the 20–30-agent burn, the auto-merge, and the
rampaging supervisor.

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

- **Secrets:** the runner gets only a Claude auth secret and one narrow GitHub credential.
  No cloud creds, no publish/deploy tokens. No `id-token: write` unless we actually
  federate to a cloud provider.
- **Executor identity:** the Actions executor pushes and opens PRs as a **machine user** on
  a classic PAT scoped `public_repo` only — never as `github-actions`, never as the human
  reviewer, never with `workflow` scope (a pushable workflow file is a self-escalation —
  [ADR 0008](docs/adr/0008-issue-79-machine-user-prs.md) walks the chain). That keeps the
  create+approve toggle off, fires CI on executor PRs, and leaves the ambient
  `GITHUB_TOKEN` read-only.
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
  creates the labels, applies the `main` ruleset, writes `.worktreeinclude`, installs the
  unicode-normalization hook, and installs the `review-response` skill (triages PR review
  feedback into fix/ack/discuss/reject/defer; see
  [templates/skills/review-response/SKILL.md](templates/skills/review-response/SKILL.md)).
- **`hgt issue ready <n>`** is the security-critical verb: unicode-normalize the body,
  write a frozen snapshot, apply the `ready` label. This is the trust boundary — treat it
  as security-sensitive code.
- **`hgt work <n>`** creates a git worktree and a named Claude session (in a detached tmux
  session by default; `--no-tmux` launches inline), wires in the frozen snapshot, and
  handles teardown / `--resume`. The Claude session is **sandboxed** to its worktree
  (issue #67, [ADR 0007](docs/adr/0007-issue-92-sandbox-mechanism.md) superseding ADR 0005's
  mechanism). `hgt` generates a settings file and hands it to a pinned
  [`@anthropic-ai/sandbox-runtime`](https://www.npmjs.com/package/@anthropic-ai/sandbox-runtime)
  (`srt`), which builds the jail: worktree + shared `.git` read-write, the rest of `$HOME`
  (`~/.ssh`, admin `gh` auth, sibling repos) unreadable, while tmux and the human's shell pane
  stay on the host so `tmux attach` is untouched. On by default and fail-closed; `--no-sandbox`
  opts out.
  - **Setup:** `npm i -g @anthropic-ai/sandbox-runtime@0.0.67` plus
    `sudo apt install bubblewrap socat ripgrep`. The version is pinned exactly — SRT is pre-1.0,
    and a mismatch fails closed with the install command (`HGT_SANDBOX_SRT_VERSION=` skips the
    check). On Ubuntu 24.04+ install the one-time AppArmor profile first; the preflight prints
    how. Every missing piece dies with its own remediation rather than launching unconfined.
  - **Egress:** SRT's jail always drops the net namespace, so hgt has to name the hosts the
    agent may reach. Today that's a fixed list (the Anthropic API and GitHub); deriving it from
    the worktree's own remote is [#74](https://github.com/cesutherland/hgt/issues/74).
  - **Seams:** `HGT_SANDBOX_SETENV` (extra env vars into the jail) and `HGT_SANDBOX_RO_BIND`
    (extra readable paths), both space-separated. Reach for these before widening the defaults.
  - **Publish boundary (issue #81):** by default the jail holds **no push credential**, so
    the agent's commits dead-end locally. Set `HGT_SANDBOX_GITHUB_TOKEN` to a scoped
    machine-user PAT and the jail gains a credentialed push/PR path (`git@`→https, plus a git
    credential helper that reads `$GITHUB_TOKEN`) — the *same* seam for attended and unattended
    runs. The token is delivered as an environment variable **into** the jail by sourcing an
    unlinked file descriptor, so its value never touches the argv, the command echo, the tmux
    pane, or `/proc/<pid>/cmdline`, and it dies with the process (no persistent on-disk secret).
    **Precondition:** a token usable in the jail wants egress locked down (issue #74).
  - **Commit authorship (issue #102):** auth != authorship, so the token's identity is also the
    commit identity — one `GET /user` derives the login + noreply email and stamps
    `GIT_AUTHOR_NAME/EMAIL` + `GIT_COMMITTER_NAME/EMAIL` as jail env (never a `~/.gitconfig`
    write), so the operator can approve the resulting PR as a clean third-party reviewer instead
    of rubber-stamping their own commit. `HGT_SANDBOX_GIT_AUTHOR`/`HGT_SANDBOX_GIT_COMMITTER`
    (`"Name <email>"`) override verbatim with no API call; a token set but undecodable dies
    rather than silently falling back to the host identity. No token, no override: nothing is
    stamped and the host identity stands.
  - **Known friction:** jail writes are deny-by-default (allowed: worktree + git dir). The jail's
    `TMPDIR` is the worktree's own scratch dir (`.hgt/tmp`), so `mktemp` and friends work —
    and each jail's tmp is private to it; a tool that hardcodes `/tmp` will fail.

## Tests & CI

The conformance suite is [bats](https://github.com/bats-core/bats-core); run it with
`./test/run.sh`. It's hermetic — external commands (`gh`/`git`/`tmux`/`claude`/`srt`/`bwrap`/
`socat`/`rg`) are PATH-shimmed in `test/shims/`, so there's no network, no secrets, and no real
repo mutation. Shims are **files**, never exported bash functions: `setsid`/`exec` walk straight
past a function. The `srt` shim is a symlink into `test/fixtures/srt-pkg/`, a real npm-shaped
package layout, so the version-pin check is exercised rather than stubbed.

CI (`.github/workflows/ci.yml`) runs that suite on every PR to `main` and reports a
`test` status check. Per spec §3 the workflow is deliberately poor and powerless:
`permissions: contents: read`, no secrets, pinned action SHAs, `pull_request` (never
`pull_request_target`). A red suite is meant to **block** merge — green is necessary, not
sufficient; a human still reviews and merges. Making `test` a *required* check is a
one-time repo-admin step (add it to the `main` ruleset) once branch protection is applied.

## Status

**Phase 0 — manual bootstrap.** `hgt` does not exist yet; vanilla Claude Code is building
the CLI skeleton + `hgt init` + `hgt issue` basics by hand until the CLI is self-hosting
("the compiler written in assembly" stage). Later phases: dogfood the local loop (1), wire
the async Actions path with full guardrails (2), harden (3).

The full design lives in [docs/SPEC.md](docs/SPEC.md).
