# sandbox.sh — confine the Claude session `hgt work` spawns to its worktree (issue #67).
#
# ADR 0007 supersedes ADR 0005's *mechanism*: instead of hand-assembling bwrap flags we generate a
# settings file for `@anthropic-ai/sandbox-runtime` (`srt`, pinned) and let it build the jail. The
# threat model, the wrap-claude-only constraint, and the fail-closed posture are unchanged.
#
# We wrap ONLY the claude process; tmux and the human's shell pane stay on the host, so
# `tmux attach` and "shell in if it gets dicey" survive untouched. This is a shared seam:
# launch_session prefixes it onto claude on both the inline and tmux paths, and the future
# local-listener executor reuses it — identical confinement, attended or not (#17).
#
# The publish boundary (#81): by default the jail holds NO push credential. Set
# HGT_SANDBOX_GITHUB_TOKEN to a scoped machine-user PAT and it gains a credentialed push/PR path.
# `bwrap --args <fd>` went away with the hand-rolled argv, so the token now reaches the jail by
# sourcing an unlinked fd — its value still never touches the argv, the pane, or /proc/<pid>/cmdline.
# That "scoped" is an assumption, not an enforced property, so _sandbox_check_token_scope probes
# the token's own scopes before the jail launches and warns or refuses (#98).

# Pinned exactly: SRT is pre-1.0, so treat a bump as a change that re-runs the conformance suite.
# HGT_SANDBOX_SRT_VERSION overrides; empty skips the check.
_SANDBOX_SRT_VERSION="${HGT_SANDBOX_SRT_VERSION-0.0.67}"

# SRT's jail is always `--unshare-net` and `network` is a required settings key, so adopting it
# forces a network decision — there is no unrestricted mode to defer to. This fixed list is the
# minimum that keeps the agent working (the API it talks to, and the forge it pushes to). Deriving
# it from the worktree's own remote, and the seam to extend it, belong to #74.
_SANDBOX_ALLOWED_DOMAINS='api.anthropic.com github.com api.github.com'

# Runtime deps under $HOME re-allowed for reading over the blanket `denyRead: [$HOME]`.
# Machine-specific (node via nvm, the claude launcher under ~/.local), so extend via
# HGT_SANDBOX_RO_BIND (space-separated, $HOME-relative or absolute).
_SANDBOX_RO_DEPS='.nvm .local .gitconfig .gitconfig.local .config/git'
# claude's state + the Anthropic credential it holds, read-write because claude updates them at
# runtime. Unavoidable exposure (ADR 0005 residuals; #73 narrows it).
_SANDBOX_RW_DEPS='.claude .claude.json'
# Host env vars that survive into the jail. SRT never clears the environment, so hgt keeps ADR
# 0005's allowlist by invoking srt from an `env -i` baseline. PATH is load-bearing twice over:
# `env -i` resolves `srt` itself through the PATH it sets. Extend via HGT_SANDBOX_SETENV.
_SANDBOX_ENV_PASS='HOME USER LOGNAME PATH TERM LANG LC_ALL LC_CTYPE'

# sandbox_enabled — is the jail in force? On by default (fail closed); HGT_NO_SANDBOX=1 or the
# --no-sandbox flag (which sets it) is the explicit opt-out.
sandbox_enabled() { [ "${HGT_NO_SANDBOX:-0}" != 1 ]; }

# _sandbox_userns_ok — can bwrap actually create a user namespace here? A cheap real probe: on
# Ubuntu 24.04 unprivileged userns is AppArmor-restricted and bwrap isn't setuid, so this fails
# until the profile (templates/apparmor/bwrap) is installed. SRT drives bubblewrap too, so the
# gate is unchanged by ADR 0007.
#
# Bind the loader dirs (/lib, /lib64) alongside /usr and exec an ABSOLUTE /usr/bin/true: it's
# dynamically linked, so a /usr-only jail can't find its ELF interpreter and execvp fails with
# ENOENT *even when userns setup — the thing we're testing — succeeded*. A too-thin probe would
# misread that as "userns blocked" and wrongly emit the AppArmor remediation.
_sandbox_userns_ok() {
  bwrap --unshare-user --ro-bind /usr /usr --ro-bind-try /lib /lib --ro-bind-try /lib64 /lib64 \
    /usr/bin/true 2>/dev/null
}

# _sandbox_srt_version — the installed SRT's version, or nothing if it can't be determined.
# `srt --version` is useless (it prints `npm_package_version || '1.0.0'`, so always 1.0.0 outside
# an npm script), so resolve the bin through its symlink and walk up to the package manifest.
_sandbox_srt_version() {
  local bin dir i
  bin=$(type -P srt) || return 0
  bin=$(readlink -f "$bin" 2>/dev/null) || return 0
  dir=${bin%/*}
  for i in 1 2 3; do
    if grep -q '"@anthropic-ai/sandbox-runtime"' "$dir/package.json" 2>/dev/null; then
      sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$dir/package.json" | head -1
      return 0
    fi
    dir=${dir%/*}
    [ -n "$dir" ] || return 0
  done
}

# _sandbox_require BIN MSG — fail closed unless BIN is a real executable on PATH. `type -P`, not
# `command -v`: command -v also matches shell functions, so a function named after the binary reads
# as present here while srt, which spawns it, can't find it at all.
_sandbox_require() {
  type -P "$1" >/dev/null 2>&1 || die "sandbox: $1 not found — $2
     hgt confines the Claude session to its worktree; it won't launch an unsandboxed agent by default (ADR 0007)."
}

# sandbox_preflight — fail closed with exact remediation if we can't jail. The userns probe goes
# last: it forks bwrap, the others are PATH lookups.
sandbox_preflight() {
  _sandbox_require srt "install it (\`npm i -g @anthropic-ai/sandbox-runtime@$_SANDBOX_SRT_VERSION\`) or opt out with --no-sandbox."
  # SRT's Linux dependencies: bwrap builds the jail, socat bridges its proxy socket into it, and
  # ripgrep scans the write-allowed tree for files SRT protects unconditionally.
  _sandbox_require bwrap "install it (\`sudo apt install bubblewrap\`) or opt out with --no-sandbox."
  _sandbox_require socat "install it (\`sudo apt install socat\`) or opt out with --no-sandbox."
  _sandbox_require rg "install ripgrep (\`sudo apt install ripgrep\`) or opt out with --no-sandbox."

  if [ -n "$_SANDBOX_SRT_VERSION" ]; then
    local have; have=$(_sandbox_srt_version)
    if [ -z "$have" ]; then
      warn "sandbox: couldn't determine the installed srt version (unusual install layout) — expected $_SANDBOX_SRT_VERSION"
    elif [ "$have" != "$_SANDBOX_SRT_VERSION" ]; then
      die "sandbox: srt $have is installed, but hgt pins $_SANDBOX_SRT_VERSION.
       npm i -g @anthropic-ai/sandbox-runtime@$_SANDBOX_SRT_VERSION
     To adopt $have instead: re-run ./test/run.sh, then bump _SANDBOX_SRT_VERSION in lib/sandbox.sh.
     Or set HGT_SANDBOX_SRT_VERSION= to skip this check."
    fi
  fi

  if ! _sandbox_userns_ok; then
    local profile="$HGT_ROOT/templates/apparmor/bwrap"
    die "sandbox: bwrap can't create a user namespace (Ubuntu restricts unprivileged userns).
     Install the AppArmor profile once, then re-run:
       sudo install -m644 $profile /etc/apparmor.d/bwrap
       sudo apparmor_parser -r /etc/apparmor.d/bwrap
     Or opt out with --no-sandbox (runs the agent unconfined — see ADR 0005)."
  fi
}

# _json_str VALUE / _json_arr [VALUE...] — JSON string / array of strings. Only \ and " need
# escaping: every value we emit is a filesystem path or a hostname.
_json_str() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '"%s"' "$s"
}
_json_arr() {
  local first=1 v
  printf '['
  for v in "$@"; do
    [ "$first" -eq 1 ] || printf ','
    first=0
    _json_str "$v"
  done
  printf ']'
}

# _sandbox_extant [PATH...] — the arguments that actually exist, in order. This is ADR 0005's
# `--ro-bind-try`/`--bind-try`, which SRT has no equivalent for: a settings path that doesn't
# exist doesn't get skipped, it kills the launch. Optional deps (~/.gitconfig.local, ~/.claude.json)
# are absent on plenty of boxes.
_sandbox_extant() {
  local p
  for p in "$@"; do [ -e "$p" ] && printf '%s\n' "$p"; done
  return 0
}

# _sandbox_settings WT — write the settings file that defines the jail, plus the private scratch
# dir it uses for temp state. Sets _SANDBOX_SETTINGS_FILE and _SANDBOX_SCRATCH. Rewritten on every
# launch, never stamped: it sits inside the agent's own write grant, so a never-clobber write would
# let a tampered copy survive to the next launch. `.hgt/.gitignore` keeps it out of `git status`.
_sandbox_settings() {
  local wt="$1" gitdir dep p uid
  # A worktree's .git points into <main-repo>/.git/worktrees/<name>; git needs the shared common
  # dir to do anything. Fail closed with a legible message rather than letting set -e surface git's
  # error mid-build.
  gitdir=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir) \
    || die "sandbox: couldn't resolve the git dir for worktree $wt (not a git worktree?)"
  uid=$(id -u)

  _SANDBOX_SCRATCH="$wt/.hgt/tmp"
  _SANDBOX_SETTINGS_FILE="$wt/.hgt/srt.json"
  mkdir -p "$_SANDBOX_SCRATCH/gh"

  # Reads default to ALLOWED in SRT — the inverse of ADR 0005's tmpfs $HOME. `denyRead: [$HOME]`
  # restores deny-by-default (~/.ssh, the admin gh auth, sibling repos), then we allow back only
  # what the agent needs. The worktree lives under $HOME on a normal setup, so it must be named
  # explicitly: allowRead beats denyRead, and allowWrite isn't documented to imply read.
  # Everything optional goes through _sandbox_extant, since a missing entry aborts the launch.
  local -a deny_read=("$HOME") allow_read=("$wt" "$gitdir") allow_write=("$wt" "$gitdir")
  local -a opt_read=() opt_rw=()
  for dep in $_SANDBOX_RO_DEPS ${HGT_SANDBOX_RO_BIND:-}; do
    case "$dep" in /*) p="$dep" ;; *) p="$HOME/$dep" ;; esac
    opt_read+=("$p")
  done
  for dep in $_SANDBOX_RW_DEPS; do opt_rw+=("$HOME/$dep"); done
  while IFS= read -r p; do allow_read+=("$p"); done < <(_sandbox_extant "${opt_read[@]}")
  while IFS= read -r p; do allow_read+=("$p"); allow_write+=("$p"); done < <(_sandbox_extant "${opt_rw[@]}")
  # ADR 0005's --unshare-all made host IPC absent by construction; SRT hands the jail a normal
  # filesystem instead. Denying the tmux socket dir keeps an agent from send-keys'ing into the
  # human's other panes. Unlike the allows, denies skip _sandbox_extant: on a fresh boot
  # /tmp/tmux-<uid> is created by `tmux new-session` *after* this file is generated, and SRT drops
  # an absent deny at its own launch (inside the pane) — so an unconditional entry lands exactly
  # when the socket exists to protect.
  deny_read+=("/tmp/tmux-$uid" "/run/user/$uid")

  # .git/config lives in the SHARED common dir, so a core.pager written there executes on the HOST
  # next time the human runs git in this repo. SRT protects .git/config and .git/hooks
  # automatically for a *repo* it's given, but not for a bare git dir handed to it as an allowWrite
  # root (verified against 0.0.67), so name them. Cost: `git push -u` doesn't work in the jail.
  local -a deny_write=("$_SANDBOX_SETTINGS_FILE" "$gitdir/config" "$gitdir/hooks")

  {
    printf '{\n'
    printf '  "network": {\n'
    printf '    "allowedDomains": %s,\n' "$(_json_arr $_SANDBOX_ALLOWED_DOMAINS)"
    printf '    "deniedDomains": [],\n'
    # Without this an unlisted host consults an ask-callback, which in a detached pane either hangs
    # or auto-allows.
    printf '    "strictAllowlist": true\n'
    printf '  },\n'
    printf '  "filesystem": {\n'
    printf '    "denyRead": %s,\n'   "$(_json_arr "${deny_read[@]}")"
    printf '    "allowRead": %s,\n'  "$(_json_arr "${allow_read[@]}")"
    printf '    "allowWrite": %s,\n' "$(_json_arr "${allow_write[@]}")"
    printf '    "denyWrite": %s,\n'  "$(_json_arr "${deny_write[@]}")"
    printf '    "allowGitConfig": false\n'
    printf '  },\n'
    # The jail maps to a different uid, so git would refuse both trees as "dubious ownership".
    printf '  "git": { "safeDirectories": %s }\n' "$(_json_arr "$wt" "$gitdir")"
    printf '}\n'
  } >"$_SANDBOX_SETTINGS_FILE"
}

# sandbox_argv WT — populate the global array HGT_SANDBOX_ARGV with the prefix that jails a process
# to worktree WT. Caller appends the real command (`claude -n ...`); the prefix ends with `--` so
# srt can't mistake claude's flags for its own. A global array (not stdout) so both consumers get a
# real argv: the inline path expands it directly, the tmux path _shq-quotes each element into the
# send-keys string. WT must be absolute.
sandbox_argv() {
  local wt="$1" var i
  _sandbox_settings "$wt"

  # `env -i` is our --clearenv. An approximation, not an equivalent: the pane's dash re-adds PWD,
  # and SRT overlays its proxy variables.
  HGT_SANDBOX_ARGV=(env -i)
  for var in $_SANDBOX_ENV_PASS ${HGT_SANDBOX_SETENV:-}; do
    [ -n "${!var:-}" ] && HGT_SANDBOX_ARGV+=("$var=${!var}")
  done
  # /tmp isn't writable in the jail (writes are deny-by-default and we grant only the worktree and
  # git dir), so temp state goes to a private dir. GH_CONFIG_DIR points there too: the old tmpfs
  # $HOME gave gh a scratch config for free, and without one gh reaches for the real ~/.config/gh —
  # the admin credential this jail exists to keep away from the agent.
  HGT_SANDBOX_ARGV+=("TMPDIR=$_SANDBOX_SCRATCH" "GH_CONFIG_DIR=$_SANDBOX_SCRATCH/gh")

  # git config injected via the numbered GIT_CONFIG_* env (no ~/.gitconfig write needed). Always
  # force gpg-signing off — the jail has no ~/.gnupg, so the agent can't sign as the human. Always
  # rewrite git@ -> https: the jail has no net namespace, so ssh can't work at all and an ssh remote
  # would leave even `git fetch` hanging. With a scoped push token (#81) also give git a credential
  # helper that reads $GITHUB_TOKEN, so the agent pushes with ONLY that token — never the human's
  # ~/.ssh or admin gh. Push deliberately does NOT go through gh: a snap gh can't run in the jail
  # and would take push down with it (dogfooded on #81); git reads the env directly.
  local -a gitcfg=(
    commit.gpgsign false
    "url.https://github.com/.insteadOf" "git@github.com:"
  )
  if [ -n "${HGT_SANDBOX_GITHUB_TOKEN:-}" ]; then
    _sandbox_credential "$wt"
    gitcfg+=(
      # Empty reset first: clears any credential.helper inherited from the readable ~/.gitconfig,
      # so only ours is consulted. Then the env-reading helper: `get` emits the token, and it exits
      # 0 on git's follow-up store/erase calls (a bare `&&` would make git grumble).
      "credential.helper" ""
      "credential.https://github.com.helper" '!f() { test "$1" = get && printf "username=x-access-token\npassword=%s\n" "$GITHUB_TOKEN"; true; }; f'
    )
  fi
  HGT_SANDBOX_ARGV+=("GIT_CONFIG_COUNT=$(( ${#gitcfg[@]} / 2 ))")
  i=0
  while [ "$i" -lt "${#gitcfg[@]}" ]; do
    HGT_SANDBOX_ARGV+=("GIT_CONFIG_KEY_$((i / 2))=${gitcfg[i]}" "GIT_CONFIG_VALUE_$((i / 2))=${gitcfg[i + 1]}")
    i=$((i + 2))
  done

  # #81: the PAT rides fd 3, never the argv. This sources the fd (launch_session opens it on the
  # command group and unlinks the file) and execs the rest, so GITHUB_TOKEN lands in srt's
  # environment — and the jail's — without appearing in /proc/<pid>/cmdline.
  if [ -n "${_SANDBOX_ARGS_FILE:-}" ]; then
    HGT_SANDBOX_ARGV+=(sh -c '. /dev/fd/3; exec "$@"' hgt)
  fi

  HGT_SANDBOX_ARGV+=(srt --settings "$_SANDBOX_SETTINGS_FILE" --)
}

# _sandbox_check_token_scope — probe HGT_SANDBOX_GITHUB_TOKEN's classic OAuth scopes before the
# jail launches (issue #98) and react to what's detectable. #81 verified the merge gate against
# branch protection + can_approve_pull_request_reviews=false (SPEC §3) but never checked the
# *premise* that the token itself is a narrow machine-user PAT — an admin/broad token is consumed
# byte-identically and hands the jailed agent the power to merge/approve its own PR, defeating
# that gate. `X-OAuth-Scopes` on a cheap authenticated call is the only cheap signal classic PATs
# expose; fine-grained PATs and GitHub App tokens don't carry classic scopes at all, so GitHub
# omits the header for them and there's nothing more to cheaply introspect (non-goal — warn on
# what's detectable, document the rest). Silent when the header is absent/empty — that's the
# expected shape for a correctly scoped token, and noise there would cry wolf on every launch.
_sandbox_check_token_scope() {
  local out scopes s deny=() broad=()
  command -v gh >/dev/null 2>&1 || {
    warn "sandbox: gh not on PATH — couldn't verify HGT_SANDBOX_GITHUB_TOKEN's scopes; proceeding on trust. ADR 0005 assumes a narrowly scoped machine-user PAT (contents+PRs on this repo only) — an admin/broad token in the jail could let the agent merge or approve its own PR, bypassing the human-merge gate (SPEC §3)."
    return 0
  }
  out=$(GH_TOKEN="$HGT_SANDBOX_GITHUB_TOKEN" GITHUB_TOKEN="$HGT_SANDBOX_GITHUB_TOKEN" gh api -i user 2>/dev/null) || {
    warn "sandbox: couldn't probe HGT_SANDBOX_GITHUB_TOKEN's scopes (gh api call failed) — proceeding on trust. ADR 0005 assumes a narrowly scoped machine-user PAT (contents+PRs on this repo only) — an admin/broad token in the jail could let the agent merge or approve its own PR, bypassing the human-merge gate (SPEC §3)."
    return 0
  }
  scopes=$(printf '%s' "$out" | grep -i '^x-oauth-scopes:' | head -1) || true
  scopes="${scopes#*:}"
  scopes="${scopes//$'\r'/}"
  [ -z "${scopes// /}" ] && return 0  # no classic scopes to read (fine-grained PAT / App token / none)

  local -a scope_list; IFS=',' read -ra scope_list <<<"$scopes"
  for s in "${scope_list[@]}"; do
    s="${s# }"
    case "$s" in
      admin:*|delete_repo) deny+=("$s") ;;
      repo|workflow|public_repo) broad+=("$s") ;;
    esac
  done

  if [ "${#deny[@]}" -gt 0 ]; then
    die "sandbox: HGT_SANDBOX_GITHUB_TOKEN carries admin-level scope(s): ${deny[*]}. ADR 0005 assumes a narrowly scoped machine-user PAT (contents+PRs on this repo only); an admin token hands the jailed agent that power — it could merge or approve its own PR, or push straight to main, bypassing the human-merge gate (SPEC §3). Refusing to launch — mint a scoped/fine-grained PAT limited to Contents+PRs on this repo, or unset HGT_SANDBOX_GITHUB_TOKEN to fall back to no push credential."
  fi
  if [ "${#broad[@]}" -gt 0 ]; then
    warn "sandbox: HGT_SANDBOX_GITHUB_TOKEN carries broader scope(s) than push/PR needs: ${broad[*]}. ADR 0005 assumes a narrowly scoped machine-user PAT (contents+PRs on this repo only); an over-scoped token hands the jailed agent that power — it could merge or approve its own PR, bypassing the human-merge gate (SPEC §3). Prefer a fine-grained PAT limited to Contents+PRs on this repo."
  fi
}

# _sandbox_credential WT — stage the scoped PAT (HGT_SANDBOX_GITHUB_TOKEN) for delivery INTO the
# jail as an env var (#81), the same seam attended + unattended (#17). The value must never ride
# the argv: send-keys would type it into the visible tmux pane, `run` would echo it, and
# /proc/<pid>/cmdline is world-readable. So it goes on fd 3 as a shell fragment the `sh -c` wrapper
# in sandbox_argv sources — landing only in the child's environ and dying with the process. The fd
# is sourced from a mktemp'd file (O_EXCL + random name + mode 600) that launch_session opens then
# immediately unlinks. git's helper reads $GITHUB_TOKEN; gh reads $GH_TOKEN natively.
# Sets _SANDBOX_ARGS_FILE. Writes a file — a launch-time side effect.
_sandbox_credential() {
  local wt="$1" gh
  _sandbox_check_token_scope   # #98: warn/fail-closed BEFORE staging the payload or touching the jail
  # A safe host dir for the transient payload: XDG_RUNTIME_DIR (per-user, 0700, tmpfs) when set,
  # else $TMPDIR / /tmp. HGT_SANDBOX_CRED_DIR overrides (the suite points it inside its tmpdir).
  local base="${HGT_SANDBOX_CRED_DIR:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}}"
  ( umask 077; mkdir -p "$base" )
  # Reaper: launch unlinks the payload, but if a launch dies before its pane gets there the file is
  # stranded with no cleaner — an EXIT trap in hgt would race the pane. Sweep old ones instead.
  find "$base" -maxdepth 1 -name 'hgt-args.*' -mmin +5 -delete 2>/dev/null || true
  _SANDBOX_ARGS_FILE=$(umask 077; mktemp "$base/hgt-args.XXXXXX") \
    || die "sandbox: couldn't stage the credential payload under $base"
  # Single-quoted with the standard '\'' escape, so a token containing a quote can't break out
  # into the sourcing shell.
  local tok=${HGT_SANDBOX_GITHUB_TOKEN//\'/\'\\\'\'}
  printf "export GITHUB_TOKEN='%s' GH_TOKEN='%s'\n" "$tok" "$tok" >"$_SANDBOX_ARGS_FILE"
  # gh is only for `gh pr create` (reads GH_TOKEN from env) — push never needs it. Nothing to bind
  # any more: SRT leaves the system filesystem readable. A snap gh still can't run in the jail.
  gh=$(type -P gh) || { warn "sandbox: gh not on PATH — jailed \`gh pr create\` unavailable (push still works)"; return 0; }
  case "$gh" in
    /snap/*) warn "sandbox: gh is a snap ($gh) — can't run in the jail, so \`gh pr create\` won't work there (push still works); install a non-snap gh for in-jail PRs" ;;
  esac
  return 0
}
