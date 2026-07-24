# ADR 0006 — Issue #19: review-response skill (Slice 4b)

- **Status:** accepted
- **Date:** 2026-07-24
- **Context:** Slice 4a (#18, unmerged as of this writing) defines the mechanical verbs
  `hgt review list` / `hgt review reply <id> --body …`. This slice is the judgment layer on
  top: classify each outstanding comment into fix/ack/discuss/reject/defer, act, and reply —
  packaged so the identical logic drives both the local (attended) and Actions (unattended)
  paths (#17 parity). Three open questions were left for this slice to resolve.

## Decisions

**D1 — skill, not subagent.** Per the design call already made in the issue: this is the
driver loop, not an isolated context spawned and thrown away. It reads durable state
(plan file, `git`, `hgt review list`) and drives the mechanical verbs directly in the calling
session — a subagent would hide that loop behind a boundary this slice needs to keep visible
(so a human, or the Unattended executor's own trace, sees each classify/act/reply step).

**D2 — install path: `templates/skills/review-response/SKILL.md`, stamped by `hgt init`.**
Not a repo-local `.claude/skills/` file authored once and left to drift. It's scaffolded the
same way as `CLAUDE.md`/`.worktreeinclude`/the normalize hook — idempotent, never-clobbers,
`hgt init`-owned — so every target repo gets it and a `hgt` upgrade can re-stamp a fresh
default without fighting a hand-edited copy. Installs to `.claude/skills/review-response/
SKILL.md`, the path Claude Code itself discovers project skills from.

**D3 — attended/unattended parity via an explicit mode argument, not environment sniffing.**
The skill takes one argument: `auto` means unattended (act and reply immediately); anything
else — the default — means attended (propose, wait for human approval, then act and reply).
The caller states the mode; the skill never infers it from a TTY or an env var. This keeps
the *only* legitimate difference between the two paths exactly where the issue said it should
be — a checkpoint before the same act+reply step — instead of letting environment detection
become a second, driftable source of truth. The Actions responder's driving prompt passes
`auto` explicitly; a local session omits it.

**D4 — `defer`'s interim: try `hgt issue create`, fall back to `gh issue create`.** Slice 3
doesn't exist everywhere yet. Rather than picking one now and rewriting the skill later, the
skill tries the hgt-native verb first and falls back to `gh issue create --title … --body …`
on failure/absence. The reply always cites whichever issue number actually got filed. This
needs no edit when Slice 3 lands — the try-path just stops falling through.

**D5 — one document, not two prompts.** The Actions responder (#83, built ahead of this
slice with the guidance inlined directly in `.github/workflows/hgt-review.yml`, since #18
didn't exist yet) should come to load this file rather than keep a second copy of the
classification guidance. Tuning happens in one place; the workflow-side follow-up is tracked
separately since it touches a file this executor can't push (`workflows: write` withheld,
spec §3).

## Consequences

- No `hgt review` verbs exist on `main` yet (#18), so this skill can't be exercised
  end-to-end today. It's written directly against the CLI contract the issue specifies
  (`hgt review list`, `hgt review reply <id> --body …`) and is dogfooded once #18 lands —
  consistent with the issue's own testability note: judgment is tuned by dogfooding, not
  pinned by `bats`.
- `hgt init`'s stamp count grows from 3 to 4; `test/init.bats` is updated for the new file
  (golden diff + created/skipped counts) — the one seam that *is* mechanically testable here.
- Supersedes nothing; the naming stays clear of `hgt respond` (#84, unmerged), which is the
  local *session* wrapper, not the skill.
