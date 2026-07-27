# ADR 0008 — Issue #79: the Actions executor opens PRs as a machine user

- **Status:** accepted
- **Date:** 2026-07-26
- **Amends:** SPEC §3's "runner gets only `ANTHROPIC_API_KEY` + a minimal `GITHUB_TOKEN`" —
  the GitHub half is now a scoped machine-user PAT. §3's *intent* (one narrow credential,
  nothing else worth stealing, human owns the merge) is unchanged; the identity behind it is not.
- **Context:** GitHub bundles *create* and *approve* into the single "Allow GitHub Actions to
  create and approve pull requests" switch. §3 mandates that switch OFF (anti-rubber-stamp), but
  with it off `gh pr create` as `github-actions` is rejected — surfaced by #69, run 29973468423.
  The stopgap was to flip it ON. That was self-approval-safe (author≠reviewer returns 422 for any
  Actions identity) but left two costs: `github-actions[bot]`-authored PRs don't fire
  `on: pull_request`, so executor PRs arrived with no CI (#58), and ON is a standing repo-wide
  grant that any workflow could use to approve a non-bot PR.

## Decision

The executor's GitHub credential is a **classic PAT on a dedicated machine user** —
`hgtbot`, a write-access collaborator that is neither `github-actions` nor Carl — stored as
`secrets.HGT_MACHINE_USER_TOKEN` and wired in `.github/workflows/hgt-execute.yml` two places:

- `github_token:` on the action step, and
- `token:` on `actions/checkout` — checkout persists whatever token it is given as the
  workspace push credential, so leaving it default would push as `github-actions` and undo the
  whole change with every other knob still looking correct.

The toggle goes back OFF. The ambient `GITHUB_TOKEN` drops to `contents/issues/pull-requests:
read` — every write now flows through the PAT, and the only remaining consumer is the fail-loud
guard's GraphQL query. A preflight step fails the run by name when the secret is absent.

**Scope is `public_repo` + `workflow`, and classic not fine-grained.** Fine-grained PATs can
only target repos the token's account *owns*; the machine user is a collaborator and owns
nothing, so `cesutherland/hgt` is not selectable. `public_repo` suffices for a public repo and
cannot reach private ones — containment by construction, not by policy. `workflow` is what lets
a PR branch carry `.github/workflows/**` changes.

## Why not the alternatives

| Option | Why not |
| --- | --- |
| **Keep the toggle ON** (the stopgap) | A repo-wide standing grant to approve PRs, held so one workflow can create one. No CI on executor PRs (#58) |
| **`GITHUB_TOKEN` + a dispatch/nudge to re-trigger CI** (#58's interim fix) | Treats the symptom. Still needs the toggle ON, still leaves bot-authored PRs |
| **Fine-grained PAT** (the original plan) | Can't target a repo the account doesn't own. Not an option, not a preference |
| **GitHub App** | The right endgame — short-lived install tokens, no resident secret (#56/#68). More setup than this slice, and the PAT is a strictly smaller step toward it (both replace the `github-actions` identity) |
| **Carl's own token** | The author of a PR cannot review it. Destroys the human gate outright (#55/#60/#68) |

## Consequences / residuals

- **A resident credential in the injection surface.** Unlike `GITHUB_TOKEN`, the PAT outlives
  the job, and checkout writes it into the workspace `.git/config` where the agent can read it.
  Secrecy is not the containment — scope is: push branches, open PRs, no merge, no approve, no
  private repos, and branch protection still owns `main`. Injection that succeeds buys the
  attacker a PR that a human must still approve.
- **The executor can now push workflow changes.** `workflow` scope grants what §3 withheld from
  `GITHUB_TOKEN`. This is not the self-escalation §3 warns about: `issues` events run
  `hgt-execute.yml` from the default branch, `ci.yml` is powerless by design, and nothing on a
  PR branch takes effect until a human merges it. The prompt makes the executor flag such
  changes in the PR body, and the guard's workflow-specific error now points at a missing
  `workflow` scope rather than at policy.
- **`hgt-review.yml` still runs as `GITHUB_TOKEN`.** Out of scope here (#79 is the executor's
  PR-creation path). Its #58 gotcha survives — pushes to a PR branch still don't re-trigger CI —
  and its success guard filters comments on `github-actions[bot]`, which a token swap would
  break. Its own slice.
- **The local path is #68.** `HGT_SANDBOX_GITHUB_TOKEN` (#81) already carries a machine-user PAT
  into the jail; the two paths converge on the same account but are wired separately.
- **Audit the live PAT's scopes.** The `hgtbot` token in use for the sandbox path today carries
  `repo`, not `public_repo` — broader than this ADR calls for, and `repo` reaches private repos.
  Mint the Actions secret at `public_repo` + `workflow` and re-scope the sandbox one to match.

## Operator runbook (manual, repo-admin — not done by this PR)

1. `gh secret set HGT_MACHINE_USER_TOKEN --app actions` — paste a classic PAT minted on the
   machine user with **`public_repo` + `workflow`** only.
2. Confirm the machine user has write access:
   `gh api -X PUT repos/cesutherland/hgt/collaborators/hgtbot -f permission=push`.
3. Flip the toggle back off — **after** step 1, or the next `ready` issue has no way to open a
   PR: `gh api -X PUT repos/cesutherland/hgt/actions/permissions/workflow -F
   default_workflow_permissions=read -F can_approve_pull_request_reviews=false`.
4. Label a `ready` issue and check the resulting PR: authored by the machine user, `ci / test`
   running on it unprompted, Carl's approval still the only one that counts.

`hgt init` prints steps 1–3 as part of the branch-protection script (`forge_print_ruleset`).
