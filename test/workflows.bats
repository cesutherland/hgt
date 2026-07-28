#!/usr/bin/env bats
#
# Assertions on hgt's own workflow files. These are the only tests that read the repo rather
# than driving $HGT_BIN — justified because the invariants below fail SILENTLY in production:
# a run that pushes as the wrong identity, or with a token that outlives its need, still goes
# green. The suite is the only place that notices.

load helper

EXEC_WF="$HGT_REPO/.github/workflows/hgt-execute.yml"

@test "hgt-execute: both machine-user token wirings are present (#79)" {
  # Two spots, not one. `github_token:` alone leaves checkout persisting the ambient token as
  # the push credential — the branch then lands as `github-actions`, the create+approve toggle
  # has to come back ON, and every other knob still looks correct. That is the whole failure.
  grep -q 'github_token: ${{ secrets.HGT_MACHINE_USER_TOKEN }}' "$EXEC_WF"
  grep -q 'token: ${{ secrets.HGT_MACHINE_USER_TOKEN }}' "$EXEC_WF"
  [ "$(grep -c 'secrets.HGT_MACHINE_USER_TOKEN' "$EXEC_WF")" -ge 3 ]  # + the preflight
}

@test "hgt-execute: the ambient workflow token stays read-only (#79)" {
  # Exact-match, not a substring check: every write goes through the PAT, so the block must
  # equal precisely this. A write grant, an extra key, or a reorder flips it red; "doesn't
  # contain the word write" would miss all three and only catch the literal string.
  run grep -A 3 '^permissions:' "$EXEC_WF"
  [ "$status" -eq 0 ]
  [ "$output" = $'permissions:\n  contents: read\n  issues: read\n  pull-requests: read' ]
}
