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

**Scope is `public_repo` and nothing else; classic, not fine-grained.** Fine-grained PATs can
only target repos the token's account *owns*; the machine user is a collaborator and owns
nothing, so `cesutherland/hgt` is not selectable. `public_repo` suffices for a public repo and
cannot reach private ones.

Note what that does *not* buy: a classic PAT is account-wide, not repo-scoped. `public_repo`
grants write on **every** public repo `hgtbot` can push to, so the real containment is that
`hgtbot` is a collaborator on this repo and nothing else — policy, enforced by nobody. Adding
the account to another repo widens this token retroactively. Don't.

### Why `workflow` scope is excluded

The issue asked for `public_repo` + `workflow`, reasoning that `workflow` is required to push
`.github/workflows/**`. It is — and that is exactly why the executor must not have it.

`on: pull_request` runs the **PR branch's own copy** of the workflow file, and a same-repo PR
gets repository secrets. So a machine-user PAT with `workflow` scope completes this chain, with
no human anywhere in it:

1. An injected executor run (v0 reads the raw issue body — the injection door is open by
   design until #39/#40/#41) edits `ci.yml` to add `permissions: write-all` and a step echoing
   `${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}` / `${{ secrets.HGT_MACHINE_USER_TOKEN }}`.
2. It pushes the branch — allowed, because the PAT has `workflow`.
3. It opens a PR — which now fires `pull_request`, because #79 made executor PRs
   machine-authored (that trigger firing is the whole point of this ADR).
4. The branch's malicious `ci.yml` executes with secrets in scope.

Two independent things used to block that: `GITHUB_TOKEN` couldn't push workflow files, and
bot-authored PRs fired no `pull_request` event at all (#58). #79 deliberately removes the
second. Keeping the first is therefore load-bearing, not vestigial.

Three arguments that look like defenses and are not, recorded so this doesn't get relitigated:

- *"`issues` events run the workflow file from the default branch"* — true, and irrelevant.
  The attack goes through `ci.yml`, not `hgt-execute.yml`.
- *"`ci.yml` is powerless by design"* — true of **main's** copy. The branch's copy writes its
  own `permissions:` block and names its own secrets.
- *"Nothing on a PR branch takes effect until a human merges it"* — false for
  `pull_request`-triggered workflows. That is the trigger #79 exists to make fire.

The cost of excluding `workflow` is near zero: workflow edits go to a human/local session, the
pre-#79 behavior. This PR's own workflow change was made that way.

What remains, and is accepted: `ci.yml` still *runs* branch-supplied code (`./test/run.sh`) on
`pull_request`. That is why §3 keeps it poor and powerless — `contents: read`, no secrets. With
the workflow file itself unpushable, the blast radius of a hostile branch is arbitrary code on a
runner holding nothing worth stealing.

## Why not the alternatives

| Option | Why not |
| --- | --- |
| **Keep the toggle ON** (the stopgap) | A repo-wide standing grant to approve PRs, held so one workflow can create one. No CI on executor PRs (#58) |
| **`GITHUB_TOKEN` + a dispatch/nudge to re-trigger CI** (#58's interim fix) | Treats the symptom. Still needs the toggle ON, still leaves bot-authored PRs |
| **Fine-grained PAT** (the original plan) | Can't target a repo the account doesn't own. Not an option, not a preference |
| **GitHub App** | The right endgame — short-lived install tokens, no resident secret (#56/#68). More setup than this slice, and the PAT is a strictly smaller step toward it (both replace the `github-actions` identity) |
| **Carl's own token** | The author of a PR cannot review it. Destroys the human gate outright (#55/#60/#68) |

## Consequences / residuals

- **A resident credential in the injection surface — #110.** Unlike `GITHUB_TOKEN`, the PAT
  outlives the job, and checkout writes it into the workspace
  `.git/config` where the agent can read it and echo it into the world-readable transcript
  artifact (#64). Scope is what bounds it today: push branches, open PRs, no merge, no approve,
  no private repos, branch protection still owns `main` — injection that succeeds buys the
  attacker a PR a human must still approve. The real fix is to stop handing the agent the
  credential at all (a post-agent ship step), which is a design change, not a wiring fix.
- **The executor still cannot push workflow changes**, unchanged from pre-#79 (see above for
  why). The prompt tells it to STOP loudly and the fail-loud guard names that cause when a run
  touching `.github/workflows/**` produces no PR. Those tasks are human/local work.
- **`hgt-review.yml` still runs as `GITHUB_TOKEN`.** Out of scope here (#79 is the executor's
  PR-creation path). Its #58 gotcha survives, and observed on this very PR the symptom is not
  "no run" but a `pull_request` run created with `actor=github-actions[bot]` that sits at
  `action_required` until a human clicks approve — so the tip of a review-agent-pushed PR
  carries no green check —
  and its success guard filters comments on `github-actions[bot]`, which a token swap would
  break. Its own slice.
- **The local path is #68.** `HGT_SANDBOX_GITHUB_TOKEN` (#81) already carries a machine-user PAT
  into the jail; the two paths converge on the same account but are wired separately.
- **Audit the live PAT's scopes.** The `hgtbot` token in use for the sandbox path today carries
  `repo`, not `public_repo` — broader than this ADR calls for, and `repo` reaches private repos.
  Mint the Actions secret at `public_repo` only and re-scope the sandbox one to match.

## Operator runbook (manual, repo-admin — not done by this PR)

1. `gh secret set HGT_MACHINE_USER_TOKEN --app actions` — paste a classic PAT minted on the
   machine user with **`public_repo` and nothing else**. Not `workflow`, not `repo`.
2. Confirm the machine user has write access:
   `gh api -X PUT repos/cesutherland/hgt/collaborators/hgtbot -f permission=push`. Keep it a
   collaborator on **this repo only** — the PAT's scope is account-wide, so every repo `hgtbot`
   joins is a repo this token can write.
3. Flip the toggle back off — **after** step 1, or the next `ready` issue has no way to open a
   PR: `gh api -X PUT repos/cesutherland/hgt/actions/permissions/workflow -F
   default_workflow_permissions=read -F can_approve_pull_request_reviews=false`.
4. Label a `ready` issue and check the resulting PR: authored by the machine user, `ci / test`
   running on it unprompted, Carl's approval still the only one that counts.

`forge_print_ruleset` (what `hgt init` prints) carries steps 1–3 in this order, after the
ruleset itself — machine user and secret before the toggle, for the reason in step 3.
