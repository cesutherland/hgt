load helper

# Tier-1 black-box conformance for `hgt work` (issue #8). We pin what hgt's contract actually
# is: the boundary calls it issues (asserted via $SHIM_LOG) and its own filesystem writes (the
# plan file + carried files). git is a shimmed boundary — we do NOT re-test git's behavior.

# work_env — every work test points the worktree dir inside $TMP (so nothing leaks past
# teardown), pins the repo label (the git-toplevel default isn't exercised hermetically, like
# the worktree base — ADR 0002/D3), and feeds the gh shim the canned record tracker_issue_view
# would emit for issue 5. Also clears $TMUX so the launcher's attach-vs-switch choice is
# deterministic regardless of whether the suite itself runs inside tmux; tests that exercise the
# switch path set it back. The branch author defaults to the gh shim's SHIM_GH_USER (testuser),
# and "Add a Widget" short-slugs to "add-widget" (the stopword "a" is dropped) — so issue 5 is
# worktree 5-add-widget, branch testuser/5-add-widget, session hgt/5-add-widget throughout.
work_env() {
  unset TMUX
  export HGT_WORKTREE_DIR="$TMP/wt"
  export HGT_REPO_NAME=hgt
  export SHIM_GH_OUT='number=5
url=https://github.com/cesutherland/hgt/issues/5
title=Add a Widget
---body---
Build the widget.
Wire it up.'
}

@test "work creates a worktree on <n>-<slug> under <user>/<n>-<slug>, carries includes, seeds + commits the plan file" {
  work_env
  printf 'secret\n' >.env
  printf '.env\n' >.worktreeinclude

  run "$HGT_BIN" work 5 --no-session
  [ "$status" -eq 0 ]

  # resolved through the tracker seam, and the branch author through the forge seam
  grep -q '^gh issue view 5 --json number,title,body,url' "$SHIM_LOG"
  grep -q '^gh api user --jq .login'                       "$SHIM_LOG"
  # short slug + user-namespaced branch + our path + default HEAD base, at the git boundary
  grep -q "^git worktree add -b testuser/5-add-widget $TMP/wt/5-add-widget HEAD\$" "$SHIM_LOG"

  # plan file written with the issue's fields, the real branch, and the verbatim body
  [ -f "$TMP/wt/5-add-widget/.hgt/work/5.md" ]
  grep -q 'Issue 5 — Add a Widget'                              "$TMP/wt/5-add-widget/.hgt/work/5.md"
  grep -q '\*\*Branch:\*\* testuser/5-add-widget'               "$TMP/wt/5-add-widget/.hgt/work/5.md"
  grep -q 'hgt/5-add-widget'                                    "$TMP/wt/5-add-widget/.hgt/work/5.md"
  grep -q 'https://github.com/cesutherland/hgt/issues/5'        "$TMP/wt/5-add-widget/.hgt/work/5.md"
  grep -q 'Build the widget.'                                   "$TMP/wt/5-add-widget/.hgt/work/5.md"

  # committed as the first recovery checkpoint
  grep -q "^git -C $TMP/wt/5-add-widget add .hgt/work/5.md\$"  "$SHIM_LOG"
  grep -q "^git -C $TMP/wt/5-add-widget commit -m "           "$SHIM_LOG"

  # .worktreeinclude file carried into the worktree (git worktree add wouldn't)
  [ -f "$TMP/wt/5-add-widget/.env" ]
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
  # resume never needs the branch author again (no re-derivation, no title lookup)
  ! grep -q '^gh api user' "$SHIM_LOG"
}

@test "work re-attaches to the surviving branch when the worktree is gone (issue #23)" {
  work_env
  "$HGT_BIN" work 5 --no-session >/dev/null 2>&1
  # simulate `hgt work rm 5`: worktree dir gone, branch left intact. (The git shim doesn't
  # actually remove the dir, so we drop it ourselves to reach the branch-exists/worktree-absent
  # state.)
  rm -rf "$TMP/wt/5-add-widget"
  : >"$SHIM_LOG"  # inspect only the resume run

  # SHIM_GIT_BRANCH_EXISTS=0 -> the branch-existence probe reports the branch survives
  run env SHIM_GIT_BRANCH_EXISTS=0 "$HGT_BIN" work 5 --no-session
  [ "$status" -eq 0 ]
  [[ "$output" == *"re-attaching worktree"* ]]
  # re-attach to the existing branch — NOT `-b`, which would fail ("branch already exists")
  grep -q "^git worktree add $TMP/wt/5-add-widget testuser/5-add-widget\$" "$SHIM_LOG"
  ! grep -q 'worktree add -b' "$SHIM_LOG"
  # resume: the seed commit already lives on the branch, so no re-seed / re-commit
  ! grep -q 'commit -m' "$SHIM_LOG"
}

@test "work --base bases the worktree elsewhere (stacking)" {
  work_env
  run "$HGT_BIN" work 5 --base feature-x --no-session
  [ "$status" -eq 0 ]
  grep -q "^git worktree add -b testuser/5-add-widget $TMP/wt/5-add-widget feature-x\$" "$SHIM_LOG"
}

@test "work falls back to an unprefixed branch when the gh login lookup fails" {
  work_env
  run env SHIM_GH_USER_EXIT=1 "$HGT_BIN" work 5 --no-session
  [ "$status" -eq 0 ]
  # no <user>/ prefix, just <n>-<slug> — a failed login lookup must not block local work
  grep -q "^git worktree add -b 5-add-widget $TMP/wt/5-add-widget HEAD\$" "$SHIM_LOG"
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
  # session created detached as a plain shell, named <repo>/<n>-<slug> + rooted in the worktree
  grep -q "^tmux new-session -d -s hgt/5-add-widget -c $TMP/wt/5-add-widget\$" "$SHIM_LOG"
  # claude launched *into* that shell via send-keys (#47) — not as the pane's PID 1, so a
  # claude exit/failure leaves the session alive with a live shell, not an evaporated session.
  # Confined by the bwrap jail (#67): the sandbox prefix wraps the claude command.
  grep -q "^tmux send-keys -t hgt/5-add-widget 'bwrap' .* claude -n 'hgt/5-add-widget' .* Enter\$" "$SHIM_LOG"
  # outside tmux -> attach, not switch-client
  grep -q '^tmux attach-session -t hgt/5-add-widget$' "$SHIM_LOG"
  ! grep -q '^tmux switch-client' "$SHIM_LOG"
}

@test "fresh launch splits into two panes: claude left, shell right (cwd worktree), focus on claude" {
  work_env  # has-session absent -> fresh create
  run "$HGT_BIN" work 5
  [ "$status" -eq 0 ]
  # shell pane added to the right, rooted in the worktree
  grep -q "^tmux split-window -h -t hgt/5-add-widget -c $TMP/wt/5-add-widget\$" "$SHIM_LOG"
  # focus returns to the left (claude) pane, not the freshly-split shell
  grep -q '^tmux select-pane -t hgt/5-add-widget -L$' "$SHIM_LOG"
}

@test "fresh launch sequences the tmux calls new-session -> send-keys -> split-window -> select-pane (#47)" {
  work_env  # has-session absent -> fresh create
  run "$HGT_BIN" work 5
  [ "$status" -eq 0 ]
  # claude must be sent into a live shell (send-keys) only after the session exists, and the
  # split/focus must follow — so a claude startup failure can never strand a half-built layout
  grep '^tmux ' "$SHIM_LOG" | grep -Eo 'new-session|send-keys|split-window|select-pane' | head -4 | tr '\n' ' ' | grep -q '^new-session send-keys split-window select-pane $'
}

@test "tmux launch shell-escapes the command so ', \$, \`, and a newline reach claude intact (#25)" {
  work_env  # has-session absent -> fresh create
  # A prompt loaded with every char that breaks naive single-quoting: an apostrophe (closes the
  # quote early), a $ and a backtick (expansion/command-substitution if unquoted), plus a newline
  # (a control key send-keys injects as Enter). Driven in via the HGT_WORK_PROMPT seam.
  export HGT_WORK_PROMPT=$'do \'not\' $merge `id`\nsecond line'
  export SHIM_TMUX_SENDKEYS_FILE="$TMP/keys"  # tmux shim dumps the literal keystrokes here

  run "$HGT_BIN" work 5
  [ "$status" -eq 0 ]

  # Re-parse the exact keystrokes hgt typed the way the pane's shell parses them (dash) and assert
  # claude ends up with three intact args (-n, name, the whole prompt). This models the *quoting*,
  # which is where the bug lived; it doesn't run a pty, but for _shq's single-quoted content the
  # two converge — a newline inside the open '...' is line continuation in a real pane too, not an
  # early submit, so the argv is identical (manually verified against tmux, see PR #49). A broken
  # quote would instead split the prompt, run `id`, or die on a syntax error. The sandbox (#67)
  # prefixes the keys with an _shq'd bwrap jail; a passthrough bwrap() drops its args up to the
  # wrapped command, so the same reconstruction proves quoting survives the full jailed command.
  run /bin/sh -c 'claude() {
      printf "%s" "$2" >'"$TMP"'/got_name
      printf "%s" "$3" >'"$TMP"'/got_prompt
    }
    bwrap() { while [ "$1" != claude ]; do shift; done; "$@"; }
    '"$(cat "$TMP/keys")"
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP/got_name")" = hgt/5-add-widget ]
  # ', $, `, and the newline all survive verbatim — byte-for-byte, nothing dropped or expanded.
  diff <(printf '%s' "$HGT_WORK_PROMPT") "$TMP/got_prompt"
}

@test "work switches the client instead of attaching when already inside tmux" {
  work_env
  TMUX=/tmp/fake,1,0 run "$HGT_BIN" work 5
  [ "$status" -eq 0 ]
  grep -q '^tmux switch-client -t hgt/5-add-widget$' "$SHIM_LOG"
  ! grep -q '^tmux attach-session' "$SHIM_LOG"
}

@test "work resumes a live tmux session instead of spawning a second" {
  work_env
  run env SHIM_TMUX_HAS_SESSION=0 "$HGT_BIN" work 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"resume: tmux session hgt/5-add-widget is live"* ]]
  ! grep -q '^tmux new-session' "$SHIM_LOG"
  # resume reattaches untouched — no re-split onto the already-2-pane layout (#24)
  ! grep -q '^tmux split-window' "$SHIM_LOG"
  grep -q '^tmux attach-session -t hgt/5-add-widget$' "$SHIM_LOG"
}

@test "work --no-tmux launches claude inline, no tmux session" {
  work_env
  run "$HGT_BIN" work 5 --no-tmux
  [ "$status" -eq 0 ]
  grep -q '^claude -n hgt/5-add-widget ' "$SHIM_LOG"
  ! grep -q '^tmux ' "$SHIM_LOG"
}

@test "work rm tears down a clean worktree, and kills its tmux session when one is live" {
  work_env
  "$HGT_BIN" work 5 --no-session >/dev/null 2>&1
  : >"$SHIM_LOG"
  run env SHIM_TMUX_HAS_SESSION=0 "$HGT_BIN" work rm 5
  [ "$status" -eq 0 ]
  grep -q "^git worktree remove $TMP/wt/5-add-widget\$" "$SHIM_LOG"
  # session name rebuilt from N alone (repo label + slug recovered off the worktree dir)
  grep -q '^tmux kill-session -t hgt/5-add-widget$'     "$SHIM_LOG"
}

@test "work rm leaves tmux alone when no session is live" {
  work_env
  "$HGT_BIN" work 5 --no-session >/dev/null 2>&1
  : >"$SHIM_LOG"
  run "$HGT_BIN" work rm 5  # has-session defaults to absent
  [ "$status" -eq 0 ]
  grep -q "^git worktree remove $TMP/wt/5-add-widget\$" "$SHIM_LOG"
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
  grep -q "^git worktree remove --force $TMP/wt/5-add-widget\$" "$SHIM_LOG"
}

@test "work rm errors when there is no worktree for the issue" {
  work_env
  run "$HGT_BIN" work rm 5
  [ "$status" -ne 0 ]
  [[ "$output" == *"no worktree"* ]]
}

# --- default path derivation (#65) -------------------------------------------------------------
# No HGT_WORKTREE_DIR / HGT_REPO_NAME here: these pin the git-derived defaults the rest of the
# suite overrides away. Base + repo label must come off the MAIN repo (dirname of the shared
# .git), never cwd's worktree — from inside `<base>/5-add-widget`, --show-toplevel would double
# the tail into `…/5-add-widget-worktrees` and rm would find nothing.

@test "work rm works from inside the issue's worktree (#65)" {
  unset TMUX
  mkdir -p "$TMP/hgt" "$TMP/hgt-worktrees/5-add-widget"
  export SHIM_GIT_COMMON_DIR="$TMP/hgt/.git"  # what real git answers from any worktree
  cd "$TMP/hgt-worktrees/5-add-widget"

  run env SHIM_TMUX_HAS_SESSION=0 "$HGT_BIN" work rm 5
  [ "$status" -eq 0 ]
  grep -q "^git worktree remove $TMP/hgt-worktrees/5-add-widget\$" "$SHIM_LOG"
  # repo label also derived off the main repo (hgt), not the worktree dir (5-add-widget)
  grep -q '^tmux kill-session -t hgt/5-add-widget$' "$SHIM_LOG"
}

@test "work rm works from the main checkout with the default worktree base (#65)" {
  unset TMUX
  mkdir -p "$TMP/hgt" "$TMP/hgt-worktrees/5-add-widget"
  cd "$TMP/hgt"  # SHIM_GIT_COMMON_DIR unset -> shim answers $PWD/.git, the main-checkout case

  run "$HGT_BIN" work rm 5
  [ "$status" -eq 0 ]
  grep -q "^git worktree remove $TMP/hgt-worktrees/5-add-widget\$" "$SHIM_LOG"
}

@test "work create lands the new worktree flat under the main repo, not nested under cwd's worktree (#78)" {
  unset TMUX
  mkdir -p "$TMP/hgt" "$TMP/hgt-worktrees/9-other-issue"
  export SHIM_GIT_COMMON_DIR="$TMP/hgt/.git"  # what real git answers from any worktree
  export SHIM_GH_OUT='number=5
url=https://github.com/cesutherland/hgt/issues/5
title=Add a Widget
---body---
Build the widget.'
  cd "$TMP/hgt-worktrees/9-other-issue"  # inside an unrelated, already-existing worktree

  run "$HGT_BIN" work 5 --no-session
  [ "$status" -eq 0 ]
  # flat: <main-repo>-worktrees/5-<slug>, a sibling of 9-other-issue, never nested under it
  grep -q "^git worktree add -b testuser/5-add-widget $TMP/hgt-worktrees/5-add-widget HEAD\$" "$SHIM_LOG"
  ! grep -q '9-other-issue/5-add-widget' "$SHIM_LOG"
}

@test "work create names the session hgt/<n>-<slug>, never <worktree-slug>/<n>-<slug>, from inside a worktree (#78)" {
  unset TMUX
  mkdir -p "$TMP/hgt" "$TMP/hgt-worktrees/9-other-issue"
  export SHIM_GIT_COMMON_DIR="$TMP/hgt/.git"
  export SHIM_GH_OUT='number=5
url=https://github.com/cesutherland/hgt/issues/5
title=Add a Widget
---body---
Build the widget.'
  cd "$TMP/hgt-worktrees/9-other-issue"  # has-session absent (default) -> fresh create

  run "$HGT_BIN" work 5
  [ "$status" -eq 0 ]
  grep -q "^tmux new-session -d -s hgt/5-add-widget -c $TMP/hgt-worktrees/5-add-widget\$" "$SHIM_LOG"
  ! grep -q '9-other-issue/5-add-widget' "$SHIM_LOG"
}

# --- work rm: from-within inference + tmux hop (#86) -------------------------------------------
# `hgt work rm` run with no <n>, from inside the target worktree/session: infer <n> off the
# worktree dir, and — from that session's own tmux — hop to the most-recently-active surviving
# session before killing it, instead of dumping the caller to a bare shell.

@test "work rm infers <n> from the worktree dir when run from inside it, no <n> given" {
  unset TMUX
  mkdir -p "$TMP/hgt" "$TMP/hgt-worktrees/5-add-widget"
  export SHIM_GIT_COMMON_DIR="$TMP/hgt/.git"  # what real git answers from any worktree
  cd "$TMP/hgt-worktrees/5-add-widget"

  run "$HGT_BIN" work rm
  [ "$status" -eq 0 ]
  grep -q "^git worktree remove $TMP/hgt-worktrees/5-add-widget\$" "$SHIM_LOG"
}

@test "work rm explicit <n> overrides inference" {
  unset TMUX
  mkdir -p "$TMP/hgt" "$TMP/hgt-worktrees/5-add-widget" "$TMP/hgt-worktrees/9-other-issue"
  export SHIM_GIT_COMMON_DIR="$TMP/hgt/.git"
  cd "$TMP/hgt-worktrees/5-add-widget"  # would infer 5, but we say 9

  run "$HGT_BIN" work rm 9
  [ "$status" -eq 0 ]
  grep -q "^git worktree remove $TMP/hgt-worktrees/9-other-issue\$" "$SHIM_LOG"
  ! grep -q '5-add-widget' "$SHIM_LOG"
}

@test "work rm with no <n> and not inside a worktree errors instead of guessing" {
  unset TMUX
  mkdir -p "$TMP/hgt"
  cd "$TMP/hgt"  # the main checkout, not one of hgt's issue worktrees

  run "$HGT_BIN" work rm
  [ "$status" -ne 0 ]
  [[ "$output" == *"no issue given and not inside a worktree"* ]]
}

@test "work rm hops to the most-recently-active surviving session before killing the current one" {
  work_env
  "$HGT_BIN" work 5 --no-session >/dev/null 2>&1
  : >"$SHIM_LOG"
  export TMUX=/tmp/fake,1,0
  export SHIM_TMUX_CURRENT=hgt/5-add-widget  # attached to the session being torn down
  export SHIM_TMUX_SESSIONS='100 hgt/5-add-widget
300 hgt/2-other
200 hgt/3-third'

  run env SHIM_TMUX_HAS_SESSION=0 "$HGT_BIN" work rm 5
  [ "$status" -eq 0 ]
  # newest OTHER session (2-other, last_attached 300) wins, and switch-client lands before
  # kill-session — killing the attached session first would detach the client before it can hop
  grep '^tmux ' "$SHIM_LOG" | grep -Eo 'switch-client|kill-session' | tr '\n' ' ' | grep -q '^switch-client kill-session $'
  grep -q '^tmux switch-client -t hgt/2-other$' "$SHIM_LOG"
}

@test "work rm falls back to a plain teardown when no other session survives" {
  work_env
  "$HGT_BIN" work 5 --no-session >/dev/null 2>&1
  : >"$SHIM_LOG"
  export TMUX=/tmp/fake,1,0
  export SHIM_TMUX_CURRENT=hgt/5-add-widget
  export SHIM_TMUX_SESSIONS='100 hgt/5-add-widget'  # only the target itself is live

  run env SHIM_TMUX_HAS_SESSION=0 "$HGT_BIN" work rm 5
  [ "$status" -eq 0 ]
  ! grep -q '^tmux switch-client' "$SHIM_LOG"
  grep -q '^tmux kill-session -t hgt/5-add-widget$' "$SHIM_LOG"
}

@test "work rm does not hop when attached to a different session than the one being killed" {
  work_env
  "$HGT_BIN" work 5 --no-session >/dev/null 2>&1
  : >"$SHIM_LOG"
  export TMUX=/tmp/fake,1,0
  export SHIM_TMUX_CURRENT=hgt/9-other  # attached elsewhere, e.g. removing issue 5 remotely
  export SHIM_TMUX_SESSIONS='100 hgt/5-add-widget
300 hgt/9-other'

  run env SHIM_TMUX_HAS_SESSION=0 "$HGT_BIN" work rm 5
  [ "$status" -eq 0 ]
  ! grep -q '^tmux switch-client' "$SHIM_LOG"
  grep -q '^tmux kill-session -t hgt/5-add-widget$' "$SHIM_LOG"
}

@test "work rm attempts no hop outside tmux" {
  work_env  # $TMUX unset
  "$HGT_BIN" work 5 --no-session >/dev/null 2>&1
  : >"$SHIM_LOG"

  run env SHIM_TMUX_HAS_SESSION=0 "$HGT_BIN" work rm 5
  [ "$status" -eq 0 ]
  ! grep -q '^tmux display-message' "$SHIM_LOG"
  ! grep -q '^tmux switch-client'   "$SHIM_LOG"
  grep -q '^tmux kill-session -t hgt/5-add-widget$' "$SHIM_LOG"
}

@test "work rm --no-switch skips the hop even when attached to the killed session" {
  work_env
  "$HGT_BIN" work 5 --no-session >/dev/null 2>&1
  : >"$SHIM_LOG"
  export TMUX=/tmp/fake,1,0
  export SHIM_TMUX_CURRENT=hgt/5-add-widget
  export SHIM_TMUX_SESSIONS='100 hgt/5-add-widget
300 hgt/2-other'

  run env SHIM_TMUX_HAS_SESSION=0 "$HGT_BIN" work rm 5 --no-switch
  [ "$status" -eq 0 ]
  ! grep -q '^tmux display-message' "$SHIM_LOG"
  ! grep -q '^tmux switch-client'   "$SHIM_LOG"
  grep -q '^tmux kill-session -t hgt/5-add-widget$' "$SHIM_LOG"
}

# --- sandbox (#67, ADR 0005) -------------------------------------------------------------------
# The jail is part of hgt's contract now: which bwrap flags it wraps claude in, and that it fails
# closed rather than launch an unconfined agent. The bwrap shim execs the wrapped command, so the
# claude-level assertions above already prove the jail is transparent; these pin the jail itself.

@test "sandbox: the jail binds the worktree + shared .git rw, tmpfs's \$HOME, and clears the env" {
  work_env  # sandbox on by default
  run "$HGT_BIN" work 5 --no-tmux  # inline path -> bwrap prefix lands on its own log line
  [ "$status" -eq 0 ]
  local bw; bw=$(grep '^bwrap ' "$SHIM_LOG")
  # worktree read-write, and the repo's shared .git (resolved via git rev-parse) read-write
  [[ "$bw" == *"--bind $TMP/wt/5-add-widget $TMP/wt/5-add-widget"* ]]
  [[ "$bw" == *"--bind $TMP/wt/5-add-widget/.git $TMP/wt/5-add-widget/.git"* ]]
  # $HOME is a tmpfs (the boundary) and the env starts empty
  [[ "$bw" == *"--tmpfs $HOME"* ]]
  [[ "$bw" == *"--clearenv"* ]]
  # DNS survives: the systemd-resolved dir is bound so /etc/resolv.conf's symlink resolves
  [[ "$bw" == *"--ro-bind-try /run/systemd/resolve /run/systemd/resolve"* ]]
  # gpg-signing forced off inside — the agent has no ~/.gnupg, can't sign as the human
  [[ "$bw" == *"--setenv GIT_CONFIG_KEY_0 commit.gpgsign"* ]]
  [[ "$bw" == *"GIT_CONFIG_VALUE_0 false"* ]]
}

@test "sandbox: the jail never binds ~/.ssh or the admin gh auth" {
  work_env
  run "$HGT_BIN" work 5 --no-tmux
  [ "$status" -eq 0 ]
  local bw; bw=$(grep '^bwrap ' "$SHIM_LOG")
  # the two secrets the acceptance criteria name: never mounted, so unreachable by construction
  [[ "$bw" != *".ssh"* ]]
  [[ "$bw" != *".config/gh"* ]]
}

@test "sandbox: a host-exported secret does not cross --clearenv; HGT_SANDBOX_SETENV opts one in" {
  work_env
  # the guardrail: env crosses the jail only via the curated allowlist. A shell-exported secret
  # must NOT surface as --setenv — this is the test that catches "fixing friction" by widening
  # _SANDBOX_ENV_PASS instead of using the HGT_SANDBOX_SETENV seam.
  TERM=xterm GH_TOKEN=sekret AWS_SECRET_ACCESS_KEY=sekret \
    HGT_SANDBOX_SETENV=NVM_DIR NVM_DIR=/opt/nvm \
    run "$HGT_BIN" work 5 --no-tmux
  [ "$status" -eq 0 ]
  local bw; bw=$(grep '^bwrap ' "$SHIM_LOG")
  [[ "$bw" != *"GH_TOKEN"* ]]
  [[ "$bw" != *"AWS_SECRET_ACCESS_KEY"* ]]
  [[ "$bw" == *"--setenv TERM "* ]]                 # allowlisted vars still pass
  [[ "$bw" == *"--setenv NVM_DIR /opt/nvm"* ]]      # the explicit opt-in seam works
}

@test "sandbox: HGT_SANDBOX_RO_BIND extends the read-only binds (dogfooding seam)" {
  work_env
  HGT_SANDBOX_RO_BIND=/opt/toolchain run "$HGT_BIN" work 5 --no-tmux
  [ "$status" -eq 0 ]
  grep '^bwrap ' "$SHIM_LOG" | grep -q -- '--ro-bind-try /opt/toolchain /opt/toolchain'
}

@test "sandbox: fails closed with the AppArmor remediation when userns is blocked" {
  work_env
  # SHIM_BWRAP_USERNS=1 simulates the Ubuntu-restricted box: the preflight probe can't make a userns
  run env SHIM_BWRAP_USERNS=1 "$HGT_BIN" work 5
  [ "$status" -ne 0 ]
  [[ "$output" == *"user namespace"* ]]
  [[ "$output" == *"apparmor_parser -r"* ]]  # the exact fix, printed
  # fail closed: no claude, no tmux session spawned
  ! grep -q '^claude ' "$SHIM_LOG"
  ! grep -q '^tmux new-session' "$SHIM_LOG"
}

@test "sandbox: --no-sandbox launches claude unconfined, with a warning and no bwrap" {
  work_env
  run "$HGT_BIN" work 5 --no-tmux --no-sandbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"UNCONFINED"* ]]        # loud about the trade
  grep -q '^claude -n hgt/5-add-widget ' "$SHIM_LOG"  # launched directly, as pre-#67
  ! grep -q '^bwrap ' "$SHIM_LOG"          # no jail
}

@test "sandbox: a resumed live tmux session is not re-jailed (already confined at launch)" {
  work_env
  # live session -> resume path; it must not preflight/rebuild the jail (no bwrap, no send-keys)
  run env SHIM_TMUX_HAS_SESSION=0 "$HGT_BIN" work 5
  [ "$status" -eq 0 ]
  ! grep -q '^bwrap ' "$SHIM_LOG"
  ! grep -q '^tmux send-keys' "$SHIM_LOG"
}
