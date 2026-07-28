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
  # The jail launches under `env -i` (ADR 0007), which wipes $SHIM_LOG along with everything else —
  # so the shims that run *inside* it (srt, and claude through it) get it back the same way a real
  # user would add NVM_DIR: through the HGT_SANDBOX_SETENV seam. No back door for the suite.
  export HGT_SANDBOX_SETENV='SHIM_LOG'
  # A fixture $HOME. The generated settings name only paths that exist (SRT has no `--bind-try`
  # equivalent — an absent path aborts the launch), so without this the settings assertions would
  # read differently on every developer's box depending on whether they happen to have a
  # ~/.gitconfig.local. Everything _SANDBOX_RO_DEPS/_SANDBOX_RW_DEPS names is present here.
  export HOME="$TMP/home"
  mkdir -p "$HOME/.nvm" "$HOME/.local" "$HOME/.config/git" "$HOME/.claude"
  : >"$HOME/.gitconfig"; : >"$HOME/.gitconfig.local"; : >"$HOME/.claude.json"
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
  # Confined by the jail (#67/#74): the sandbox prefix (`env -i … srt …`) wraps the claude command.
  grep -q "^tmux send-keys -t hgt/5-add-widget 'env' '-i' .* 'srt' .* claude -n 'hgt/5-add-widget' .* Enter\$" "$SHIM_LOG"
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
  # quote would instead split the prompt, run `id`, or die on a syntax error. The sandbox (#67/#74)
  # prefixes the keys with an _shq'd `env -i … srt …`; a passthrough env() drops its args up to the
  # wrapped command, so the same reconstruction proves quoting survives the full jailed command.
  # (srt re-quotes its argv for its own `bash -c`, with a POSIX single-quoter — verified against
  # 0.0.67 that this prompt survives that second pass byte-for-byte. That's a pinned-version
  # property, which is why _SANDBOX_SRT_VERSION is enforced rather than advisory.)
  run /bin/sh -c 'claude() {
      printf "%s" "$2" >'"$TMP"'/got_name
      printf "%s" "$3" >'"$TMP"'/got_prompt
    }
    env() { while [ "$1" != claude ]; do shift; done; "$@"; }
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

# --- sandbox (#67 + #74, ADR 0007) -------------------------------------------------------------
# The jail is part of hgt's contract: the settings file it generates for srt, the environment it
# hands the jail, and that it fails closed rather than launch an unconfined agent. The srt shim
# execs the wrapped command, so the claude-level assertions above already prove the jail is
# transparent; these pin the jail itself.
#
# Two log streams from the srt shim: `srt <argv>` (what hgt invoked) and `srt-env <NAME>=<value>`
# (the environment the jail actually receives). The second is the interesting one — the env is
# where SRT is weakest (its credentials.envVars is a denylist, so it never clears anything), so
# `env -i` is hgt's own control and it deserves to be asserted on the delivered result, not on the
# argv that was supposed to produce it.

# srt_cfg — the generated settings file for issue 5's worktree.
srt_cfg() { cat "$TMP/wt/5-add-widget/.hgt/srt.json"; }

# bare_path — a PATH holding every shim EXCEPT $1, plus the coreutils hgt shells out to. The
# system dirs can't just be appended: bwrap/socat/rg are plausibly installed for real on a dev box,
# so `type -P` would find them and the missing-dependency path would never be reached.
bare_path() {
  local f n
  mkdir -p "$TMP/bin"
  for f in "$HGT_REPO"/test/shims/*; do
    n=$(basename "$f")
    case "$n" in _shim | "$1") continue ;; esac
    ln -sf "$f" "$TMP/bin/$n"
  done
  for n in sh bash env printenv mkdir rmdir rm cp mv ln find sed grep head tail tr cut sort uniq \
           id readlink realpath mktemp dirname basename cat chmod stat date true false wc diff; do
    [ -x "/usr/bin/$n" ] && ln -sf "/usr/bin/$n" "$TMP/bin/$n"
  done
  printf '%s' "$TMP/bin"
}

@test "sandbox: the settings file denies \$HOME reads and re-allows only the worktree + deps" {
  work_env  # sandbox on by default
  run "$HGT_BIN" work 5 --no-tmux
  [ "$status" -eq 0 ]
  local wt="$TMP/wt/5-add-widget" cfg; cfg=$(srt_cfg)
  # srt is pointed at the generated file, and `--` ends srt's own options so claude's -n is claude's
  grep -q "^srt --settings $wt/.hgt/srt.json -- claude -n hgt/5-add-widget " "$SHIM_LOG"
  # THE boundary: reads default to allowed in SRT, so $HOME is denied wholesale and allowed back
  # piecemeal. The worktree lives under $HOME on a normal setup, hence the explicit re-allow.
  [[ "$cfg" == *"\"denyRead\": [\"$HOME\""* ]]
  [[ "$cfg" == *"\"allowRead\": [\"$wt\",\"$wt/.git\","* ]]
  # worktree + the repo's shared .git (resolved via git rev-parse) are the only writable tree,
  # alongside claude's own state
  [[ "$cfg" == *"\"allowWrite\": [\"$wt\",\"$wt/.git\",\"$HOME/.claude\",\"$HOME/.claude.json\"]"* ]]
  # git identity is readable, so commits carry the human's name without a writable ~/.gitconfig
  [[ "$cfg" == *"\"$HOME/.gitconfig\""* ]]
  # SRT always drops the net namespace and requires a network block, so the swap can't be
  # network-neutral. This fixed list is a placeholder — deriving it belongs to #74.
  [[ "$cfg" == *'"allowedDomains": ["api.anthropic.com","github.com","api.github.com"]'* ]]
  [[ "$cfg" == *'"strictAllowlist": true'* ]]
  # gpg-signing forced off inside — the agent has no ~/.gnupg, can't sign as the human
  grep -q '^srt-env GIT_CONFIG_KEY_0=commit.gpgsign$' "$SHIM_LOG"
  grep -q '^srt-env GIT_CONFIG_VALUE_0=false$'        "$SHIM_LOG"
}

@test "sandbox: the jail can't read ~/.ssh or the admin gh auth, and can't rewrite its own policy" {
  work_env
  # The tmux socket dir can't be fixtured — it's derived from the real uid — and SRT drops a deny
  # for a path that isn't there, so create the same dir tmux itself would. Left behind on purpose:
  # removing it could yank the socket out from under a real tmux session on the developer's box.
  mkdir -p "/tmp/tmux-$(id -u)"
  run "$HGT_BIN" work 5 --no-tmux
  [ "$status" -eq 0 ]
  local wt="$TMP/wt/5-add-widget" cfg; cfg=$(srt_cfg)
  # the two secrets the acceptance criteria name: under the denied $HOME and never allowed back,
  # so they're unreachable without hgt having to enumerate them
  [[ "$cfg" != *".ssh"* ]]
  [[ "$cfg" != *".config/gh"* ]]
  # the settings file sits inside the agent's own write grant, so it denies writes to itself —
  # otherwise a tampered copy would be waiting for the next launch to read
  [[ "$cfg" == *"\"denyWrite\": [\"$wt/.hgt/srt.json\""* ]]
  # .git/config is in the SHARED common dir: core.pager/core.hooksPath written there would execute
  # on the HOST next time the human runs git in this repo. SRT protects these for a repo it's
  # given, but not for a bare git dir handed to it as an allowWrite root — so hgt names them.
  [[ "$cfg" == *"\"$wt/.git/config\""* ]]
  [[ "$cfg" == *"\"$wt/.git/hooks\""* ]]
  [[ "$cfg" == *'"allowGitConfig": false'* ]]
  # host IPC: --unshare-net doesn't isolate AF_UNIX, and an agent that reaches the tmux control
  # socket can send-keys into the human's other panes — unconfined host execution
  [[ "$cfg" == *"\"/tmp/tmux-$(id -u)\""* ]]
}

@test "sandbox: a host-exported secret does not reach the jail; HGT_SANDBOX_SETENV opts one in" {
  work_env
  # THE guardrail. SRT never clears the environment — its credentials.envVars is a denylist, so it
  # can only drop variables you thought to name. hgt keeps ADR 0005's strictly stronger allowlist
  # by invoking srt under `env -i`. This is the test that catches "fixing friction" by widening
  # _SANDBOX_ENV_PASS instead of using the HGT_SANDBOX_SETENV seam.
  TERM=xterm GH_TOKEN=sekret AWS_SECRET_ACCESS_KEY=sekret \
    HGT_SANDBOX_SETENV='SHIM_LOG NVM_DIR' NVM_DIR=/opt/nvm \
    run "$HGT_BIN" work 5 --no-tmux
  [ "$status" -eq 0 ]
  # asserted against the environment the jail actually received, not the argv that built it
  ! grep -q '^srt-env GH_TOKEN='              "$SHIM_LOG"
  ! grep -q '^srt-env AWS_SECRET_ACCESS_KEY=' "$SHIM_LOG"
  grep -q '^srt-env TERM=xterm$'      "$SHIM_LOG"   # allowlisted vars still pass
  grep -q '^srt-env NVM_DIR=/opt/nvm$' "$SHIM_LOG"  # the explicit opt-in seam works
  # /tmp isn't writable in the jail, so temp state goes to a private dir inside the worktree — and
  # gh gets a scratch config dir rather than reaching for the admin one the jail exists to hide
  grep -q "^srt-env TMPDIR=$TMP/wt/5-add-widget/.hgt/tmp\$"         "$SHIM_LOG"
  grep -q "^srt-env GH_CONFIG_DIR=$TMP/wt/5-add-widget/.hgt/tmp/gh\$" "$SHIM_LOG"
}

@test "sandbox: HGT_SANDBOX_RO_BIND extends the readable paths (dogfooding seam)" {
  work_env
  mkdir -p "$TMP/toolchain"
  HGT_SANDBOX_RO_BIND="$TMP/toolchain" run "$HGT_BIN" work 5 --no-tmux
  [ "$status" -eq 0 ]
  [[ "$(srt_cfg)" == *"\"$TMP/toolchain\""* ]]
}

@test "sandbox: paths that don't exist are omitted, not named (SRT has no --bind-try)" {
  work_env
  # ADR 0005 used --ro-bind-try/--bind-try, so an absent ~/.gitconfig.local was silently skipped.
  # SRT has no equivalent: naming a path that isn't there aborts the launch with
  # "bwrap: Can't bind mount ...: No such file or directory". Optional deps are machine-specific
  # by nature, so this is the difference between "works on a fresh box" and "doesn't".
  rm -f "$HOME/.gitconfig.local" "$HOME/.claude.json"
  HGT_SANDBOX_RO_BIND=/definitely/not/here run "$HGT_BIN" work 5 --no-tmux
  [ "$status" -eq 0 ]
  local cfg; cfg=$(srt_cfg)
  [[ "$cfg" != *".gitconfig.local"* ]]
  [[ "$cfg" != *".claude.json"* ]]
  [[ "$cfg" != *"/definitely/not/here"* ]]
  [[ "$cfg" == *"\"$HOME/.gitconfig\""* ]]   # the ones that do exist still land
  [[ "$cfg" == *"\"$HOME/.claude\""* ]]
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

@test "sandbox: fails closed with install remediation when srt/socat/rg/bwrap is missing" {
  work_env
  local dep
  for dep in srt socat rg bwrap; do
    : >"$SHIM_LOG"; rm -rf "$TMP/bin"
    run env PATH="$(bare_path "$dep")" "$HGT_BIN" work 5
    [ "$status" -ne 0 ]
    [[ "$output" == *"sandbox: $dep not found"* ]]
    [[ "$output" == *"--no-sandbox"* ]]      # the opt-out is always named
    ! grep -q '^claude ' "$SHIM_LOG"         # and it never launches an unconfined agent
    # each names the command that fixes it, not just the missing file — and srt's carries the pin,
    # so a fresh box installs the version the suite was green against
    case "$dep" in
      srt) [[ "$output" == *"npm i -g @anthropic-ai/sandbox-runtime@0.0.67"* ]] ;;
      *)   [[ "$output" == *"sudo apt install "* ]] ;;
    esac
  done
}

@test "sandbox: an srt version other than the pin fails closed" {
  work_env
  # SRT is pre-1.0: its config format and its sandbox guarantees can move between patch releases,
  # and two properties hgt depends on (the POSIX-single-quoting arg quoter, seccomp-blocked
  # AF_UNIX) are version-specific. `srt --version` can't answer this — it reports 1.0.0 whatever is
  # installed — so the check walks from the resolved bin up to the package manifest.
  run env HGT_SANDBOX_SRT_VERSION=9.9.9 "$HGT_BIN" work 5
  [ "$status" -ne 0 ]
  [[ "$output" == *"srt 0.0.67 is installed, but hgt pins 9.9.9"* ]]
  [[ "$output" == *"./test/run.sh"* ]]   # the upgrade obligation, spelled out
  ! grep -q '^claude ' "$SHIM_LOG"
}

@test "sandbox: an undeterminable srt version warns but still launches" {
  work_env
  # A bare srt on PATH with no package manifest above it: an install layout hgt didn't anticipate
  # must not become the thing that blocks work. Warn loudly, jail anyway.
  mkdir -p "$TMP/bin2"
  cp "$HGT_REPO/test/fixtures/srt-pkg/dist/cli.js" "$TMP/bin2/srt"
  run env PATH="$TMP/bin2:$PATH" "$HGT_BIN" work 5 --no-tmux
  [ "$status" -eq 0 ]
  [[ "$output" == *"couldn't determine the installed srt version"* ]]
  grep -q '^claude -n hgt/5-add-widget ' "$SHIM_LOG"
}

@test "sandbox: --no-sandbox launches claude unconfined, with a warning and no srt" {
  work_env
  run "$HGT_BIN" work 5 --no-tmux --no-sandbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"UNCONFINED"* ]]        # loud about the trade
  grep -q '^claude -n hgt/5-add-widget ' "$SHIM_LOG"  # launched directly, as pre-#67
  ! grep -q '^srt ' "$SHIM_LOG"            # no jail
  [ ! -f "$TMP/wt/5-add-widget/.hgt/srt.json" ]  # and no settings file left behind
}

@test "sandbox: a resumed live tmux session is not re-jailed (already confined at launch)" {
  work_env
  # live session -> resume path; it must not preflight/rebuild the jail (no srt, no send-keys)
  run env SHIM_TMUX_HAS_SESSION=0 "$HGT_BIN" work 5
  [ "$status" -eq 0 ]
  ! grep -q '^srt ' "$SHIM_LOG"
  ! grep -q '^tmux send-keys' "$SHIM_LOG"
}

@test "sandbox: the settings file is rewritten on every launch, never left stale" {
  work_env
  "$HGT_BIN" work 5 --no-tmux >/dev/null 2>&1
  # a tampered policy inside the agent's own write grant must not survive to the next launch
  printf '{"network":{"allowedDomains":["evil.example.com"],"deniedDomains":[]}}' \
    >"$TMP/wt/5-add-widget/.hgt/srt.json"
  run "$HGT_BIN" work 5 --no-tmux
  [ "$status" -eq 0 ]
  [[ "$(srt_cfg)" != *"evil.example.com"* ]]
}

# --- credentialed publish (#81) ----------------------------------------------------------------
# The publish boundary: by default the jail holds NO push credential — commits dead-end locally
# (the #67 fail-closed default). HGT_SANDBOX_GITHUB_TOKEN opts in a scoped push/PR path, the SAME
# seam attended + unattended (#17). The token is delivered as jail env by sourcing an unlinked fd
# (ADR 0007 replaced `bwrap --args <fd>` with a one-line `sh -c` wrapper, since bwrap's argv is
# srt's business now), so its value never touches the argv/log/pane/cmdline and leaves no
# persistent on-disk secret.

@test "publish: no token -> the jail holds no push credential (fail-closed default, #81)" {
  work_env
  run "$HGT_BIN" work 5 --no-tmux
  [ "$status" -eq 0 ]
  ! grep -q '^srt-env GITHUB_TOKEN=' "$SHIM_LOG"    # no push credential at all
  ! grep -q '^srt-env GH_TOKEN='     "$SHIM_LOG"
  ! grep -q '/dev/fd/3' "$SHIM_LOG"                 # no token payload fd
  ! grep -q 'credential\.helper' "$SHIM_LOG"        # and no credential helper wired up
  # gpgsign-off + the git@ -> https rewrite. The rewrite is unconditional now: --unshare-net means
  # ssh can't work at all (the proxy speaks CONNECT), so an ssh remote would leave even `git fetch`
  # hanging. Over https a token-less jail still fetches a public repo anonymously.
  grep -q '^srt-env GIT_CONFIG_COUNT=2$' "$SHIM_LOG"
  grep -q '^srt-env GIT_CONFIG_KEY_1=url\.https://github\.com/\.insteadOf$' "$SHIM_LOG"
}

@test "publish: a scoped token is wired for push via env, value never on the argv (#81)" {
  work_env
  export HGT_SANDBOX_CRED_DIR="$TMP/cred"
  run env HGT_SANDBOX_GITHUB_TOKEN=ghp_SEKRET "$HGT_BIN" work 5 --no-tmux
  [ "$status" -eq 0 ]
  # the token reaches the jail's environment...
  grep -q '^srt-env GITHUB_TOKEN=ghp_SEKRET$' "$SHIM_LOG"
  grep -q '^srt-env GH_TOKEN=ghp_SEKRET$'     "$SHIM_LOG"
  # ...without ever being spelled on a command line. `run` echoes what it executes, so the argv
  # hgt built is in $output — the same string that would land in /proc/<pid>/cmdline.
  [[ "$output" != *"ghp_SEKRET"* ]]
  [[ "$output" == *". /dev/fd/3"* ]]                 # sourced from the fd instead
  # git's helper reads $GITHUB_TOKEN from env — no gh, no on-disk credential file
  grep -q '^srt-env GIT_CONFIG_COUNT=4$' "$SHIM_LOG"  # gpgsign + url + helper-reset + host-helper
  grep -q '^srt-env GIT_CONFIG_VALUE_3=.*\$GITHUB_TOKEN' "$SHIM_LOG"
  grep -q '^srt-env GIT_CONFIG_KEY_2=credential\.helper$' "$SHIM_LOG"
  ! grep -q 'gh auth git-credential' "$SHIM_LOG"      # push path must not depend on gh
  # gh gets a scratch config dir, never the admin one under the denied $HOME
  grep -q "^srt-env GH_CONFIG_DIR=$TMP/wt/5-add-widget/.hgt/tmp/gh\$" "$SHIM_LOG"
  # the inline launch opened+unlinked the payload: no persistent on-disk secret
  [ -z "$(find "$TMP/cred" -name 'hgt-args.*' 2>/dev/null)" ]
}

@test "publish: the token rides an unlinked mktemp payload, never the pane keystrokes (#81)" {
  work_env  # default tmux path -> send-keys types the launch command into the visible pane
  export HGT_SANDBOX_CRED_DIR="$TMP/cred"
  run env HGT_SANDBOX_GITHUB_TOKEN=ghp_SEKRET "$HGT_BIN" work 5
  [ "$status" -eq 0 ]
  local sk; sk=$(grep '^tmux send-keys' "$SHIM_LOG")
  # the launch is wrapped in a command group: `{ rm -f <payload>; <env -i … srt …>; } 3< <payload>`
  # — fd 3 feeds the `. /dev/fd/3` wrapper and closes when claude exits (not left open in the pane
  # via `exec 3<`, where `cat /proc/self/fd/3` would reprint the PAT)
  [[ "$sk" == *"{ rm -f "* ]]
  [[ "$sk" == *"} 3< "* ]]
  [[ "$sk" != *"exec 3< "* ]]
  [[ "$sk" == *". /dev/fd/3; exec "* ]]
  # the token value is NOT in what gets typed into the pane
  ! grep -q 'ghp_SEKRET' "$SHIM_LOG"
  # it lives only in the mode-600 mktemp payload, as shell the wrapper sources
  local f; f=$(find "$TMP/cred" -name 'hgt-args.*')
  [ -n "$f" ]
  [ "$(stat -c %a "$f")" = 600 ]
  grep -q "^export GITHUB_TOKEN='ghp_SEKRET' GH_TOKEN='ghp_SEKRET'\$" "$f"
}

@test "publish: a token containing a quote can't break out of the sourced payload (#81)" {
  work_env
  export HGT_SANDBOX_CRED_DIR="$TMP/cred"
  # The payload is shell now, not NUL-separated bwrap args — so the escaping is load-bearing in a
  # way it wasn't before. A token carrying `'; touch pwned; :` must stay one string.
  run env HGT_SANDBOX_GITHUB_TOKEN="gh'; touch $TMP/pwned; :" "$HGT_BIN" work 5 --no-tmux
  [ "$status" -eq 0 ]
  [ ! -e "$TMP/pwned" ]
  grep -q "^srt-env GITHUB_TOKEN=gh'; touch $TMP/pwned; :\$" "$SHIM_LOG"
}
