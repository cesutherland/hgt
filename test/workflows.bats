#!/usr/bin/env bats
#
# Assertions on hgt's own workflow files. These are the only tests that read the repo rather
# than driving $HGT_BIN — justified because the invariants below fail SILENTLY in production:
# a run that pushes as the wrong identity, or with a token that outlives its need, still goes
# green. The suite is the only place that notices.

load helper

EXEC_WF="$HGT_REPO/.github/workflows/hgt-execute.yml"

@test "hgt-execute: both machine-user token wirings are present (#79)" {
  # Two spots, not one: `github_token:` alone leaves checkout persisting the ambient token
  # as the push credential, and the branch lands as `github-actions` with every other knob
  # looking right (ADR 0008).
  #
  # Anchored whole-line because `token:` is a suffix of `github_token:` — unanchored, the
  # action's line satisfies the grep with checkout's wiring deleted. Occurrence-counting
  # fails the same way: the preflight's error message also names the secret.
  grep -qE '^ +github_token: \$\{\{ secrets\.HGT_MACHINE_USER_TOKEN \}\}$' "$EXEC_WF"
  grep -qE '^ +token: \$\{\{ secrets\.HGT_MACHINE_USER_TOKEN \}\}$' "$EXEC_WF"
}

@test "hgt-execute: the ambient workflow token stays read-only (#79)" {
  # Exact-match, not a substring check: every write goes through the PAT, so the block must
  # equal precisely this. A write grant, an extra key, or a reorder flips it red.
  run grep -A 3 '^permissions:' "$EXEC_WF"
  [ "$status" -eq 0 ]
  [ "$output" = $'permissions:\n  contents: read\n  issues: read\n  pull-requests: read' ]
}
