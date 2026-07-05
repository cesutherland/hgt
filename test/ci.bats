load helper

# The CI workflow (.github/workflows/ci.yml) is a security-sensitive artifact under spec §3:
# a poor-and-powerless test gate. These tests ENCODE the §3 invariants so a well-meaning edit
# (bump permissions, swap to pull_request_target, unpin an action) fails the suite instead of
# sailing through review. They assert on hgt's OWN repo file, not on anything `hgt init` stamps.

WF="$HGT_REPO/.github/workflows/ci.yml"

@test "CI workflow exists" {
  [ -f "$WF" ]
}

@test "CI workflow is poor and powerless: contents: read, never write (§3)" {
  grep -Eq '^permissions:' "$WF"
  grep -Eq '^[[:space:]]+contents:[[:space:]]+read$' "$WF"
  # no write-scoped permission may creep into the test gate
  ! grep -Eq ':[[:space:]]*write' "$WF"
}

@test "CI workflow triggers on PRs to the default branch (§3 gate target)" {
  grep -Eq '^[[:space:]]+pull_request:' "$WF"
  grep -Eq 'branches:[[:space:]]*\[main\]' "$WF"
}

@test "CI workflow uses pull_request, NOT pull_request_target (no base-repo context to forks)" {
  # as a trigger key, not merely mentioned in a comment explaining why we avoid it
  ! grep -Eq '^[[:space:]]+pull_request_target:' "$WF"
}

@test "CI workflow references no secrets (poor: nothing worth stealing)" {
  # the leak vector is a ${{ secrets.* }} interpolation into the runner; prose mentions
  # of secrets in comments are fine and expected (they explain the §3 stance).
  ! grep -Eq '\$\{\{[[:space:]]*secrets\.' "$WF"
}

@test "CI workflow pins every third-party action to a full commit SHA (§3: don't drift)" {
  # every `uses:` must reference a 40-hex commit SHA, not a floating tag/branch
  local bad
  bad="$(grep -E '^[[:space:]]+.*uses:' "$WF" | grep -Ev 'uses:[[:space:]]+[^@]+@[0-9a-f]{40}([[:space:]]|$)' || true)"
  [ -z "$bad" ]
}

@test "CI workflow runs the conformance suite via test/run.sh" {
  grep -Eq 'run:[[:space:]]*\./test/run\.sh' "$WF"
}

@test "CI job is named 'test' — the exact context the §3 ruleset requires" {
  # The required-status-check context (scripts/require-test-check.sh, context=test) must match
  # the job's reported check name, or the gate never goes green. Pin them together.
  grep -Eq '^[[:space:]]+name:[[:space:]]+test$' "$WF"
}

# --- scripts/require-test-check.sh ---------------------------------------------------------

RCC="$HGT_REPO/scripts/require-test-check.sh"

@test "require-test-check.sh exists and is executable" {
  [ -x "$RCC" ]
}

@test "require-test-check.sh errors clearly when the §3 ruleset is absent" {
  # gh (shimmed) returns no rulesets -> the script must refuse, not silently PUT nothing.
  SHIM_GH_OUT='[]' run "$RCC" owner/repo
  [ "$status" -ne 0 ]
  [[ "$output" == *"no ruleset named"* ]]
  [[ "$output" == *"hgt init"* ]]                 # points the human at the prerequisite step
  ! grep -q 'rulesets/.* -X PUT' "$SHIM_LOG"      # never attempted a mutation
}
