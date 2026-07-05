load helper

# golden == templates by design: init stamps templates verbatim, so the contract is
# "stamped bytes match the source template" — asserted with diff, no duplicated fixtures.

@test "init on a fresh repo stamps the scaffold faithfully" {
  run "$HGT_BIN" init
  [ "$status" -eq 0 ]

  diff "$TMP/CLAUDE.md"             "$HGT_REPO/templates/CLAUDE.md"
  diff "$TMP/.worktreeinclude"      "$HGT_REPO/templates/.worktreeinclude"
  diff "$TMP/.hgt/hooks/normalize"  "$HGT_REPO/templates/hooks/normalize"
  [ -x "$TMP/.hgt/hooks/normalize" ]
}

@test "init creates the three state labels through the gh module, idempotently (--force)" {
  run "$HGT_BIN" init
  [ "$status" -eq 0 ]

  [ "$(grep -c '^gh label create ' "$SHIM_LOG")" -eq 3 ]
  grep -q '^gh label create ready .*--force'       "$SHIM_LOG"
  grep -q '^gh label create in-progress .*--force' "$SHIM_LOG"
  grep -q '^gh label create needs-human .*--force' "$SHIM_LOG"
}

@test "init prints (does not apply) the branch-protection ruleset with the §3 invariants" {
  run "$HGT_BIN" init
  [ "$status" -eq 0 ]

  [[ "$output" == *"require_last_push_approval"* ]]            # require approval of latest push
  [[ "$output" == *'"required_approving_review_count": 1'* ]]  # PR + >=1 human review
  [[ "$output" == *'"bypass_actors": []'* ]]                   # no executor-app bypass
  [[ "$output" == *"can_approve_pull_request_reviews=false"* ]] # no actions self-approval

  # printed, not applied: the shim log shows no ruleset/api mutation call
  ! grep -q 'rulesets' "$SHIM_LOG"
}

@test "init's printed ruleset shows how to require CI checks, without hardcoding hgt's own" {
  run "$HGT_BIN" init
  [ "$status" -eq 0 ]

  # teaches the generic shape (required_status_checks) so each repo plugs in its own contexts
  [[ "$output" == *"required_status_checks"* ]]
  [[ "$output" == *"YOUR_CI_JOB_NAME"* ]]
  # but stays decoupled: the generic template must NOT bake in hgt's own `conformance` context
  # as an active JSON rule — that belongs only in hgt's applier script, referenced by name here.
  [[ "$output" == *"require this repo's CI status checks"* ]]
}

@test "init is idempotent: re-running skips existing files" {
  "$HGT_BIN" init >/dev/null 2>&1
  run "$HGT_BIN" init
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip   CLAUDE.md (exists)"* ]]
  [[ "$output" == *"0 created, 3 skipped"* ]]
}

@test "init never clobbers a user's edits" {
  "$HGT_BIN" init >/dev/null 2>&1
  printf 'LOCAL EDIT\n' >"$TMP/CLAUDE.md"
  run "$HGT_BIN" init
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP/CLAUDE.md")" = "LOCAL EDIT" ]
}

@test "init still prints the branch-protection ruleset even when label creation fails" {
  SHIM_GH_EXIT=1 run "$HGT_BIN" init     # every `gh label create` fails

  [ "$status" -ne 0 ]                                          # failure is still signalled
  [[ "$output" == *"could not create one or more state labels"* ]]  # warned, not silent
  [[ "$output" == *"require_last_push_approval"* ]]            # ...and the §3 ruleset printed anyway
}

@test "init repairs the normalize hook's exec bit on an existing non-executable file" {
  "$HGT_BIN" init >/dev/null 2>&1
  chmod -x "$TMP/.hgt/hooks/normalize"
  [ ! -x "$TMP/.hgt/hooks/normalize" ]   # precondition: bit is gone

  run "$HGT_BIN" init                     # re-run skips the file but must restore the bit
  [ "$status" -eq 0 ]
  [ -x "$TMP/.hgt/hooks/normalize" ]
}
