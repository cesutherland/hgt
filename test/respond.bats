load helper

# Tier-1 black-box conformance for `hgt respond` (issue #84). Mirrors work.bats: we pin what
# hgt's contract actually is (the boundary calls it issues via $SHIM_LOG, plus its own
# filesystem writes) — git/gh/tmux are shimmed boundaries, not re-tested.

# respond_env — every respond test points the worktree dir inside $TMP, pins the repo label
# (like work_env), clears $TMUX, and feeds the gh shim the canned record forge_pr_view would
# emit for PR 12: branch testuser/12-widget-review, title "Widget review notes" (no leading
# conventional-commit-type or stopword token, so slug_short doesn't drop anything: worktree
# pr-12-widget-review-notes, session hgt/pr-12-widget-review-notes throughout), not a fork.
respond_env() {
  unset TMUX
  export HGT_WORKTREE_DIR="$TMP/wt"
  export HGT_REPO_NAME=hgt
  export SHIM_GH_OUT='number=12
url=https://github.com/cesutherland/hgt/pull/12
title=Widget review notes
branch=testuser/12-widget-review
fork=false'
}

@test "respond creates a worktree on the PR's own branch (fetched from origin), carries includes, seeds an uncommitted marker" {
  respond_env
  printf 'secret\n' >.env
  printf '.env\n' >.worktreeinclude

  run "$HGT_BIN" respond 12 --no-session
  [ "$status" -eq 0 ]

  # resolved through the forge seam
  grep -q '^gh pr view 12 --json number,title,url,headRefName,isCrossRepository' "$SHIM_LOG"
  # branch not present locally -> fetch it, then attach the worktree to origin's copy
  grep -q '^git fetch origin testuser/12-widget-review$'                                            "$SHIM_LOG"
  grep -q "^git worktree add -b testuser/12-widget-review $TMP/wt/pr-12-widget-review-notes origin/testuser/12-widget-review\$" "$SHIM_LOG"

  # marker written with the PR's fields
  [ -f "$TMP/wt/pr-12-widget-review-notes/.hgt/respond/12.md" ]
  grep -q 'PR 12 — Widget review notes'                        "$TMP/wt/pr-12-widget-review-notes/.hgt/respond/12.md"
  grep -q '\*\*Branch:\*\* testuser/12-widget-review'           "$TMP/wt/pr-12-widget-review-notes/.hgt/respond/12.md"
  grep -q 'https://github.com/cesutherland/hgt/pull/12'        "$TMP/wt/pr-12-widget-review-notes/.hgt/respond/12.md"

  # unlike `hgt work`'s plan file, the marker is NOT committed — this isn't hgt's branch
  ! grep -q 'commit -m' "$SHIM_LOG"

  # .worktreeinclude file carried into the worktree
  [ -f "$TMP/wt/pr-12-widget-review-notes/.env" ]
}

@test "re-running respond resumes the existing worktree: no second gh call, no re-fetch, no re-add" {
  respond_env
  "$HGT_BIN" respond 12 --no-session >/dev/null 2>&1
  : >"$SHIM_LOG"  # inspect only the second run

  run "$HGT_BIN" respond 12 --no-session
  [ "$status" -eq 0 ]
  [[ "$output" == *"resume: worktree exists"* ]]
  ! grep -q '^gh pr view'      "$SHIM_LOG"
  ! grep -q '^git fetch'       "$SHIM_LOG"
  ! grep -q 'worktree add'     "$SHIM_LOG"
}

@test "respond re-attaches to the surviving local branch when the worktree is gone, without re-fetching" {
  respond_env
  "$HGT_BIN" respond 12 --no-session >/dev/null 2>&1
  rm -rf "$TMP/wt/pr-12-widget-review-notes"
  : >"$SHIM_LOG"  # inspect only the resume run

  # SHIM_GIT_BRANCH_EXISTS=0 -> the branch-existence probe reports the branch survives locally
  run env SHIM_GIT_BRANCH_EXISTS=0 "$HGT_BIN" respond 12 --no-session
  [ "$status" -eq 0 ]
  [[ "$output" == *"create: worktree"*"on existing local branch"* ]]
  grep -q "^git worktree add $TMP/wt/pr-12-widget-review-notes testuser/12-widget-review\$" "$SHIM_LOG"
  ! grep -q '^git fetch'      "$SHIM_LOG"
  ! grep -q 'worktree add -b' "$SHIM_LOG"
}

@test "respond declines a fork PR rather than set up a worktree that can never push" {
  respond_env
  export SHIM_GH_OUT='number=13
url=https://github.com/cesutherland/hgt/pull/13
title=External contribution
branch=someuser:fix-thing
fork=true'

  run "$HGT_BIN" respond 13 --no-session
  [ "$status" -ne 0 ]
  [[ "$output" == *"fork"* ]]
  ! grep -q 'worktree add' "$SHIM_LOG"
}

@test "respond launches the sandboxed agent + privileged shell panes in a detached tmux session" {
  respond_env  # $TMUX cleared, has-session defaults to absent -> fresh create
  run "$HGT_BIN" respond 12
  [ "$status" -eq 0 ]
  grep -q "^tmux new-session -d -s hgt/pr-12-widget-review-notes -c $TMP/wt/pr-12-widget-review-notes\$" "$SHIM_LOG"
  # the agent pane is jailed (#67): the sandbox prefix wraps the claude command
  grep -q "^tmux send-keys -t hgt/pr-12-widget-review-notes 'bwrap' .* claude -n 'hgt/pr-12-widget-review-notes' .* Enter\$" "$SHIM_LOG"
  # the privileged shell pane: split beside it, unsandboxed, cwd = the worktree
  grep -q "^tmux split-window -h -t hgt/pr-12-widget-review-notes -c $TMP/wt/pr-12-widget-review-notes\$" "$SHIM_LOG"
  grep -q '^tmux select-pane -t hgt/pr-12-widget-review-notes -L$' "$SHIM_LOG"
  grep -q '^tmux attach-session -t hgt/pr-12-widget-review-notes$' "$SHIM_LOG"
}

@test "respond --no-tmux launches claude inline, no tmux session" {
  respond_env
  run "$HGT_BIN" respond 12 --no-tmux
  [ "$status" -eq 0 ]
  grep -q '^claude -n hgt/pr-12-widget-review-notes ' "$SHIM_LOG"
  ! grep -q '^tmux ' "$SHIM_LOG"
}

@test "respond rm tears down a clean worktree, and kills its tmux session when one is live" {
  respond_env
  "$HGT_BIN" respond 12 --no-session >/dev/null 2>&1
  : >"$SHIM_LOG"
  run env SHIM_TMUX_HAS_SESSION=0 "$HGT_BIN" respond rm 12
  [ "$status" -eq 0 ]
  grep -q "^git worktree remove $TMP/wt/pr-12-widget-review-notes\$" "$SHIM_LOG"
  grep -q '^tmux kill-session -t hgt/pr-12-widget-review-notes$'     "$SHIM_LOG"
}

@test "respond rm refuses uncommitted/unpushed work without --force" {
  respond_env
  "$HGT_BIN" respond 12 --no-session >/dev/null 2>&1
  : >"$SHIM_LOG"
  SHIM_GIT_OUT=' M somefile' run "$HGT_BIN" respond rm 12
  [ "$status" -ne 0 ]
  [[ "$output" == *"uncommitted or unpushed"* ]]
  ! grep -q 'worktree remove' "$SHIM_LOG"
}

@test "respond rm --force discards dirty work and removes" {
  respond_env
  "$HGT_BIN" respond 12 --no-session >/dev/null 2>&1
  : >"$SHIM_LOG"
  SHIM_GIT_OUT=' M somefile' run "$HGT_BIN" respond rm 12 --force
  [ "$status" -eq 0 ]
  grep -q "^git worktree remove --force $TMP/wt/pr-12-widget-review-notes\$" "$SHIM_LOG"
}

@test "respond rm errors when there is no worktree for the PR" {
  respond_env
  run "$HGT_BIN" respond rm 12
  [ "$status" -ne 0 ]
  [[ "$output" == *"no worktree"* ]]
}

@test "respond errors on a missing or non-numeric PR argument" {
  respond_env
  run "$HGT_BIN" respond
  [ "$status" -ne 0 ]

  run "$HGT_BIN" respond abc
  [ "$status" -ne 0 ]
}
