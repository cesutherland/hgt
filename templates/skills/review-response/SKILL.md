---
name: review-response
description: Triage outstanding PR review feedback into fix/ack/discuss/reject/defer, act on each, and reply — one atomic step per comment. Use when addressing review comments on an hgt-managed PR, whether attended (a human is driving) or unattended (the Actions responder).
---

# review-response

Drives `hgt review list` → classify → act → `hgt review reply`, one comment at a time. This
is the judgment layer on top of those mechanical verbs — the triage decision, not the plumbing.

## Run this stateless — every time

Never rely on anything remembered from earlier in the conversation. Re-orient from durable
state on every invocation, cold-start or not, so the identical procedure works whether this is
turn one of a long local session or a fresh, zero-context Actions run:

1. `git status` and `git log --oneline -10` — what branch, what's already committed, what's
   dirty.
2. If `.hgt/work/<n>.md` exists for this issue/PR, read it for the task's context.
3. `hgt review list` — the current, authoritative set of outstanding comments. Treat it as a
   fresh read, not a cache: comments may have been added, edited, or resolved since any state
   you think you remember.

Only `hgt review list`'s output decides what's outstanding. Nothing here is a queue you carry
in your head across turns.

## Mode: attended vs. unattended

Same classification logic, one checkpoint difference (the *only* legitimate surface
difference between the two paths):

- **Attended** (default — a human is present, e.g. a local `hgt work` session): for each
  comment, propose the category and the drafted reply (and the diff, for `fix`) and **wait for
  the human's explicit approval or edit** before acting.
- **Unattended / auto** (the Actions responder invokes this skill with the argument `auto`):
  skip the approval wait — act and reply immediately.

The caller states the mode explicitly via the invocation argument; this skill never guesses
it from environment or TTY. No argument (or anything other than `auto`) means attended.

## Per-comment protocol

For each outstanding comment from `hgt review list`, in order:

1. **Classify** into exactly one of the five categories below.
2. **Act** — perform that category's side-effect (a fix commit, a filed issue, or nothing).
3. **Reply** with `hgt review reply <id> --body "…"`, atomically with the side-effect: the
   commit/issue and the reply land in the same step, so a crash mid-run can't leave state
   drifted (a reply claiming a fix that isn't committed, or a fix with no reply). Attended
   mode's approval gate sits *before* this step, not between act and reply.
4. Move to the next comment. Do not batch — replying only after processing every comment
   means a crash loses the whole batch instead of just the in-flight one.

The human resolves the review thread afterward — this skill never resolves threads (by
design; that's the human's confirmation that the reply actually settled it).

## The five categories

| category | side-effect | reply |
|---|---|---|
| **fix** | code change + commit | `"done in <sha>"` |
| **ack** | none | `"noted / agreed"` |
| **discuss** | none — expects a human round-trip | a genuine question back |
| **reject** | none | `"won't do, because…"` |
| **defer** | file a follow-up issue | `"valid but out of scope — filed #N"` |

### Classification guidance

**Anti-sycophancy is the sharp edge.** The default failure mode is caving to every comment —
turning all of them into `fix` or `ack` because agreement is the path of least resistance.
`reject` is explicitly licensed: when the human's suggestion is wrong, or contradicts a
decision already settled elsewhere (an ADR, the spec, this PR's own stated scope), push back
with the concrete reason instead of complying. A `reject` with a real rationale is a better
outcome than a `fix` that quietly re-opens a settled question.

- **`fix` vs `defer`:** in-scope and actionable now → `fix`. Valid but outside this PR's scope
  → `defer` — file it, don't let the PR scope-creep to absorb it.
- **`discuss` vs `reject`:** a genuinely open question, where you don't have enough context to
  decide unilaterally → `discuss`. A question whose answer you already know (because it's
  settled by the spec, an ADR, or explicit earlier guidance) → `reject` with that answer as the
  rationale. Don't leave a thread limping in `discuss` when the honest answer is "no" — that's
  deferral dressed up as open-mindedness.
- **`ack`** is for nits, agreement, and FYIs that need no artifact — the comment was correct
  and needs no code change to act on it (e.g. it's already true, or duplicate of another
  thread already being fixed).
- When unsure between two categories, prefer the one with the smaller side-effect footprint
  (`ack`/`discuss`/`reject` over `fix`/`defer`) and say why in the reply — a human can always
  ask for more.

## `defer`: filing the issue

`hgt issue create` (Slice 3) doesn't exist yet in every target repo. Try it first; if it's
unavailable or fails, fall back to `gh issue create --title "…" --body "…"` directly. Either
way, the reply cites the real issue number returned by whichever path succeeded — never a
placeholder. Swap the fallback out once `hgt issue create` is universally available; the
try-then-fallback means this skill needs no change when that lands.

## Parity note (#17)

This file is the single source of the triage logic for both paths. A local session loads it
directly; the Actions responder's driving prompt should load and follow it too rather than
re-deriving the same guidance inline — one tuned document, not two copies that drift.

## Not tested by the hermetic suite

Judgment (which category a comment gets) is tuned by dogfooding, not pinned by `bats` — there
is no oracle for "is this the right call." What *is* mechanically testable — that
`hgt review list`/`hgt review reply` get invoked with the right arguments — belongs to their
own verb-level test coverage, not a fake judgment test here.

> Scaffolded by `hgt init`. Safe to edit — tune the classification guidance for this repo as
> dogfooding reveals gaps.
