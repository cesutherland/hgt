# Comment style

The codebase runs a deliberate heavy-narrative style on gnarly bash — `set -e`
traps, glob edges, tmux ordering. It earns its keep there. This guide is the
line between that and noise, so PRs stop re-litigating density by taste (#36).

## Proportionality: prose scales with the diff, not the investigation

The investigation behind a one-line fix can take an hour; the writeup doesn't
inherit that length. If an explanation is longer than the diff it justifies,
cut it or move it to the issue — the issue is where the investigation lives.

Inline comments cap at two lines. Spend them on the constraint that bites —
never on the old code, and never arguing that the new code is right. `git
diff` already shows both.

## Classification gates documentation, asked first

Before writing anything, classify the change:

- **Plain bug** — a commit subject + a regression test. No ADR.
- **Decision or coupling** — an ADR, written or amended.

Decide this before drafting the PR body. It's what tells you whether there's
an ADR to write at all.

## Comment the why, not the what

Mechanism is already in the code. A comment restating it is dead weight the
next edit will silently invalidate. Reserve comments for what the code can't
say for itself: a non-obvious decision, a language footgun, an ordering
constraint.

```sh
# bad — restates the next line
# Loop over the worktrees
for wt in "${worktrees[@]}"; do

# good — the why isn't visible in the code
# Iterate in reverse so removing the current entry doesn't skip the next one.
for ((i = ${#worktrees[@]} - 1; i >= 0; i--)); do
```

## Comments describe the code, not the change

A comment addressed to the reviewer — "now also handles the empty case",
"fixed per review", "this ensures the retry works" — is meaningless the
moment the PR merges. Write for the next reader of the file, who sees only
the code as it stands. Corollary: when you edit code, the comment above it
is part of the edit — update it or delete it, don't orphan it.

## Kill ritual suffixes

`# Prints to stdout.` tacked onto every function comment is noise once it's
the default assumption for the file. Say it only when the stream is genuinely
ambiguous (stdout vs. stderr, or a function that does both).

## Traceability lives in git blame, not every line

An issue/ADR ref belongs once, at the load-bearing spot — the top of the
file or function where the decision was actually made. Don't re-stamp it on
every subsequent comment in the same block; `git blame` already answers "why
did this line change."

## Point at the ADR, don't restate it

If the rationale is written down in `docs/adr/`, the code comment is a
pointer, not a re-argued case:

```sh
# bad — re-derives the ADR's argument inline
# We chose bubblewrap over Docker because Docker needs a daemon and
# root-ish privileges, which we don't want to require on dev machines...

# good — one line, points at the source of truth
# Sandbox mechanism: see ADR 0007.
```

## ADR amendments document what remains coupled, never what was removed

An amendment isn't a changelog of what got deleted — `git log` already has
that. It exists so the next pin bump knows what to re-check. ADR 0007's
`#112` amendment is the model: it says nothing about `TMPDIR` being dropped
from the sandbox prefix, only that the jail's tmp rides
`CLAUDE_CODE_TMPDIR` and that its target must exist inside `allowWrite`.
That's the coupling that can still break; the removal can't.

## Issue refs in code point forward only

A code comment cites an issue for open work only — residual scope, a known
gap, a follow-up. Never the issue a change fixed; `type(#n)` commit subjects
and `git blame` already carry that traceability. If a comment reads as
confusing once the ref is deleted, the constraint isn't standing on its own
yet — rewrite it so it does.

## Non-goals

This is forward-looking. It doesn't rewrite existing comments (that's the
sweep ticket) and it isn't enforced by lint/CI yet.
