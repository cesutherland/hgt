#!/usr/bin/env bash
# require-test-check.sh — make hgt's own `test` CI check (see .github/workflows/ci.yml)
# a REQUIRED status check on the default branch, so a red suite blocks merge (issue #21).
# Human-run, idempotent, needs `gh` with admin on the repo.
#
# Why this is hgt-specific and NOT baked into `forge_print_ruleset` (lib/gh.sh): status-check
# contexts are per-repo — they're your workflow's job names. Any repo you run `hgt init` on has
# its own CI with its own check names, so the generic §3 ruleset must not hardcode `test`
# (that would demand a check no other repo has, and wedge its PRs un-mergeable). The generic
# template teaches the *shape*; this script wires hgt's *concrete* gate onto hgt's own ruleset.
#
# Prereq: the §3 base ruleset must already exist (run the branch-protection script that
# `hgt init` prints — forge_print_ruleset — first). This script only ADDS the required check
# to that ruleset; it deliberately touches nothing else in §3.
#
# Usage: scripts/require-test-check.sh [owner/repo]   (defaults to the current repo)
set -euo pipefail

repo="${1:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
name="hgt: protect default branch"   # must match forge_print_ruleset's ruleset name
context="test"                       # must match the job name in .github/workflows/ci.yml

id="$(gh api "repos/$repo/rulesets" \
  | jq -r --arg n "$name" 'map(select(.name == $n)) | .[0].id // empty')"
if [ -z "$id" ]; then
  printf 'error: no ruleset named "%s" on %s.\n' "$name" "$repo" >&2
  printf 'Run the branch-protection script from `hgt init` (forge_print_ruleset) first, then re-run this.\n' >&2
  exit 1
fi

# GET the full ruleset, MERGE our required-status-checks context in (preserving any the repo
# already requires), then PUT it back. Idempotent: re-running is a no-op once `test` is
# present. We reduce the GET to the writable fields the PUT accepts, so round-tripping doesn't
# choke on read-only metadata (id, node_id, _links, timestamps, …).
payload="$(gh api "repos/$repo/rulesets/$id" | jq --arg ctx "$context" '
  { name, target, enforcement, conditions, bypass_actors, rules }
  | ( [ .rules[]? | select(.type == "required_status_checks") | .parameters.required_status_checks // [] ] | add // [] ) as $existing
  | ( [ .rules[]? | select(.type != "required_status_checks") ] ) as $others
  | .rules = ( $others + [ {
        type: "required_status_checks",
        parameters: {
          strict_required_status_checks_policy: false,
          required_status_checks: (
            $existing + ( if ( [ $existing[].context ] | index($ctx) ) then [] else [ { context: $ctx } ] end )
          )
        }
      } ] )')"

printf '%s' "$payload" | gh api -X PUT "repos/$repo/rulesets/$id" --input - >/dev/null
printf 'ok: "%s" is now a required status check on %s (ruleset %s).\n' "$context" "$repo" "$id"
