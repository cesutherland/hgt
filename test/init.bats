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

@test "init repairs the normalize hook's exec bit on an existing non-executable file" {
  "$HGT_BIN" init >/dev/null 2>&1
  chmod -x "$TMP/.hgt/hooks/normalize"
  [ ! -x "$TMP/.hgt/hooks/normalize" ]   # precondition: bit is gone

  run "$HGT_BIN" init                     # re-run skips the file but must restore the bit
  [ "$status" -eq 0 ]
  [ -x "$TMP/.hgt/hooks/normalize" ]
}
