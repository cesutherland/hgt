# This repo is worked via hgt

**hgt** is an issue-driven development harness. GitHub Issues are the work queue. You (the
human) hold exactly three seats, and nothing else:

- **Mayor** — what's worth doing, and in what order.
- **Witness** — is the result correct.
- **Deacon** — is it safe to land.

Agents do the work in between. This is a paved road with a human at both ends — scoping and
review — not an autonomous swarm. Nothing auto-merges; green CI is necessary, not sufficient.

## The `ready` trust boundary

Issue text is untrusted until reviewed. An issue is picked up **only** once it enters the
`ready` state. Entering `ready` **normalizes** the body (strips invisible / bidi /
unicode-tag-block payloads) and takes a **frozen snapshot**. Executors consume that snapshot —
never the live issue — so later edits, later comments, and body-embedded URLs are simply not
in their input.

Work states are mutually exclusive: `ready` · `in-progress` · `needs-human`.

## How work runs

- **Async:** a GitHub Action picks up `ready` issues and opens a PR you review.
- **Local:** `hgt work <n>` opens a git worktree + a named Claude session for issue `<n>`.

Both consume the same frozen snapshot.

> Scaffolded by `hgt init`. Safe to edit — tune it for this repo.
