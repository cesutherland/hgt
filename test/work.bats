load helper

# Tier-1 black-box conformance for `hgt work` (issue #8). We pin what hgt's contract actually
# is: the boundary calls it issues (asserted via $SHIM_LOG) and its own filesystem writes (the
# plan file + carried files). git is a shimmed boundary — we do NOT re-test git's behavior.

# work_env — every work test points the worktree dir inside $TMP (so nothing leaks past
# teardown) and feeds the gh shim the canned record tracker_issue_view would emit for issue 5.
# Also clears $TMUX so the launcher's attach-vs-switch choice is deterministic regardless of
# whether the suite itself runs inside tmux; tests that exercise the switch path set it back.
work_env() {
  unset TMUX
  export HGT_WORKTREE_DIR="$TMP/wt"
  export SHIM_GH_OUT='number=5
url=https://github.com/cesutherland/hgt/issues/5
title=Add a Widget
---body---
Build the widget.
Wire it up.'
}

@test "work creates a worktree on issue-<n>-<slug> off HEAD, carries includes, seeds + commits the plan file" {
  work_env
  printf 'secret\n' >.env
  printf '.env\n' >.worktreeinclude

  run "$HGT_BIN" work 5 --no-session
  [ "$status" -eq 0 ]

  # resolved through the tracker seam (one gh call)
  grep -q '^gh issue view 5 --json number,title,body,url' "$SHIM_LOG"
  # derived branch + our path + default HEAD base, at the git boundary
  grep -q "^git worktree add -b issue-5-add-a-widget $TMP/wt/issue-5 HEAD\$" "$SHIM_LOG"

  # plan file written with the issue's fields + verbatim body
  [ -f "$TMP/wt/issue-5/.hgt/work/5.md" ]
  grep -q 'Issue 5 — Add a Widget'                              "$TMP/wt/issue-5/.hgt/work/5.md"
  grep -q 'https://github.com/cesutherland/hgt/issues/5'        "$TMP/wt/issue-5/.hgt/work/5.md"
  grep -q 'Build the widget.'                                   "$TMP/wt/issue-5/.hgt/work/5.md"

  # committed as the first recovery checkpoint
  grep -q "^git -C $TMP/wt/issue-5 add .hgt/work/5.md\$"  "$SHIM_LOG"
  grep -q "^git -C $TMP/wt/issue-5 commit -m "            "$SHIM_LOG"

  # .worktreeinclude file carried into the worktree (git worktree add wouldn't)
  [ -f "$TMP/wt/issue-5/.env" ]
}

@test "re-running work resumes the existing worktree: no second add, no re-commit" {
  work_env
  "$HGT_BIN" work 5 --no-session >/dev/null 2>&1
  : >"$SHIM_LOG"  # inspect only the second run

  run "$HGT_BIN" work 5 --no-session
  [ "$status" -eq 0 ]
  [[ "$output" == *"resume: worktree exists"* ]]
  ! grep -q 'worktree add' "$SHIM_LOG"
  ! grep -q 'commit -m'    "$SHIM_LOG"
}

@test "work --base bases the worktree elsewhere (stacking)" {
  work_env
  run "$HGT_BIN" work 5 --base feature-x --no-session
  [ "$status" -eq 0 ]
  grep -q "^git worktree add -b issue-5-add-a-widget $TMP/wt/issue-5 feature-x\$" "$SHIM_LOG"
}

@test "work --no-session ensures the worktree without launching claude or tmux" {
  work_env
  run "$HGT_BIN" work 5 --no-session
  [ "$status" -eq 0 ]
  ! grep -q '^claude ' "$SHIM_LOG"
  ! grep -q '^tmux '   "$SHIM_LOG"
}

@test "work launches the named claude session in a detached tmux session, then attaches" {
  work_env  # $TMUX cleared, and has-session defaults to absent -> fresh create
  run "$HGT_BIN" work 5
  [ "$status" -eq 0 ]
  # created detached, named + rooted in the worktree, running the named claude session
  grep -q "^tmux new-session -d -s hgt-issue-5 -c $TMP/wt/issue-5 claude -n 'hgt-issue-5' " "$SHIM_LOG"
  # outside tmux -> attach, not switch-client
  grep -q '^tmux attach-session -t hgt-issue-5$' "$SHIM_LOG"
  ! grep -q '^tmux switch-client' "$SHIM_LOG"
}

@test "work switches the client instead of attaching when already inside tmux" {
  work_env
  TMUX=/tmp/fake,1,0 run "$HGT_BIN" work 5
  [ "$status" -eq 0 ]
  grep -q '^tmux switch-client -t hgt-issue-5$' "$SHIM_LOG"
  ! grep -q '^tmux attach-session' "$SHIM_LOG"
}

@test "work resumes a live tmux session instead of spawning a second" {
  work_env
  run env SHIM_TMUX_HAS_SESSION=0 "$HGT_BIN" work 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"resume: tmux session hgt-issue-5 is live"* ]]
  ! grep -q '^tmux new-session' "$SHIM_LOG"
  grep -q '^tmux attach-session -t hgt-issue-5$' "$SHIM_LOG"
}

@test "work --no-tmux launches claude inline, no tmux session" {
  work_env
  run "$HGT_BIN" work 5 --no-tmux
  [ "$status" -eq 0 ]
  grep -q '^claude -n hgt-issue-5 ' "$SHIM_LOG"
  ! grep -q '^tmux ' "$SHIM_LOG"
}

@test "work rm tears down a clean worktree, and kills its tmux session when one is live" {
  work_env
  "$HGT_BIN" work 5 --no-session >/dev/null 2>&1
  : >"$SHIM_LOG"
  run env SHIM_TMUX_HAS_SESSION=0 "$HGT_BIN" work rm 5
  [ "$status" -eq 0 ]
  grep -q "^git worktree remove $TMP/wt/issue-5\$" "$SHIM_LOG"
  grep -q '^tmux kill-session -t hgt-issue-5$'      "$SHIM_LOG"
}

@test "work rm leaves tmux alone when no session is live" {
  work_env
  "$HGT_BIN" work 5 --no-session >/dev/null 2>&1
  : >"$SHIM_LOG"
  run "$HGT_BIN" work rm 5  # has-session defaults to absent
  [ "$status" -eq 0 ]
  grep -q "^git worktree remove $TMP/wt/issue-5\$" "$SHIM_LOG"
  ! grep -q '^tmux kill-session' "$SHIM_LOG"
}

@test "work rm refuses uncommitted/unpushed work without --force" {
  work_env
  "$HGT_BIN" work 5 --no-session >/dev/null 2>&1
  : >"$SHIM_LOG"
  SHIM_GIT_OUT=' M somefile' run "$HGT_BIN" work rm 5
  [ "$status" -ne 0 ]
  [[ "$output" == *"uncommitted or unpushed"* ]]
  ! grep -q 'worktree remove' "$SHIM_LOG"
}

@test "work rm --force discards dirty work and removes" {
  work_env
  "$HGT_BIN" work 5 --no-session >/dev/null 2>&1
  : >"$SHIM_LOG"
  SHIM_GIT_OUT=' M somefile' run "$HGT_BIN" work rm 5 --force
  [ "$status" -eq 0 ]
  grep -q "^git worktree remove --force $TMP/wt/issue-5\$" "$SHIM_LOG"
}

@test "work rm errors when there is no worktree for the issue" {
  work_env
  run "$HGT_BIN" work rm 5
  [ "$status" -ne 0 ]
  [[ "$output" == *"no worktree"* ]]
}
