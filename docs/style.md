# Comment style

The codebase runs a deliberate heavy-narrative style on gnarly bash — `set -e`
traps, glob edges, tmux ordering. It earns its keep there. This guide is the
line between that and noise, so PRs stop re-litigating density by taste (#36).

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
# Sandbox mechanism: see ADR 0005.
```

## Non-goals

This is forward-looking. It doesn't rewrite existing comments (that's the
sweep ticket) and it isn't enforced by lint/CI yet.
