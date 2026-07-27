# sandbox.sh — confine the Claude session `hgt work` spawns to its worktree (#67) and to a
# hostname allowlist (#74). ADR 0007 supersedes ADR 0005's *mechanism* only: we no longer hand-
# assemble thirty bwrap flags, we generate a settings file for `@anthropic-ai/sandbox-runtime`
# (`srt`, pinned) and let it build the jail. The threat model, the wrap-claude-only constraint,
# and the fail-closed posture are unchanged.
#
# We wrap ONLY the claude process; tmux and the human's shell pane stay on the host, so
# `tmux attach` and "shell in if it gets dicey" survive untouched.
#
# Why SRT and not our own proxy + firewall: SRT's jail is `--unshare-net` and reaches its egress
# proxy over a unix socket forwarded into the namespace. A program that ignores HTTPS_PROXY gets
# NO network rather than an unfiltered one — the enforcement is the missing net namespace, not the
# env var. No host firewall, no cgroup scope, no polkit. (Measured: a denied host gets connection
# refused; an allowed host connects.)
#
# This is a shared seam: launch_session prefixes it onto claude on both the inline and tmux paths,
# and the future local-listener executor reuses it — identical confinement, attended or not (#17).
#
# The publish boundary (#81): by default the jail holds NO push credential — commits land locally
# and stop there. Set HGT_SANDBOX_GITHUB_TOKEN to a scoped machine-user PAT and the jail gains a
# credentialed push/PR path. `bwrap --args <fd>` is gone with the hand-rolled argv, so the token
# now reaches the jail by sourcing an unlinked fd inside a one-line `sh -c` wrapper — its value
# still never hits the argv, the `run` echo, the tmux pane, or the world-readable /proc cmdline.

# Pinned exactly: SRT is pre-1.0 and its config format may evolve. Two properties we depend on are
# version-specific — the arg quoter being a POSIX single-quoter (so a prompt with ' $ ` and a
# newline survives, #25) and `socket(AF_UNIX)` being seccomp-blocked (which is what keeps the
# jailed agent off the host's tmux control socket). Treat a bump as a change that re-runs the
# conformance suite. Set HGT_SANDBOX_SRT_VERSION= (empty) to skip the check.
_SANDBOX_SRT_VERSION="${HGT_SANDBOX_SRT_VERSION-0.0.67}"

# Egress: what the agent may talk to, beyond its own git remote (derived per-worktree below).
# Extend via HGT_SANDBOX_EGRESS_ALLOW (space-separated) — same dogfooding seam as the binds.
_SANDBOX_EGRESS_DEFAULT='api.anthropic.com'

# Runtime deps under $HOME re-allowed for reading over the blanket `denyRead: [$HOME]`.
# Machine-specific (node via nvm, the claude launcher under ~/.local), so extend via
# HGT_SANDBOX_RO_BIND (space-separated, $HOME-relative or absolute).
_SANDBOX_RO_DEPS='.nvm .local .gitconfig .gitconfig.local .config/git'
# claude's own state + the Anthropic credential it must hold to call the API — read-write because
# claude updates them at runtime. Unavoidable exposure (ADR 0005 residuals; #73 narrows it).
_SANDBOX_RW_DEPS='.claude .claude.json'
# Host env vars that survive into the jail. SRT has no --clearenv: its `credentials.envVars` is a
# DENYlist, so it can only drop variables you thought to name. We keep ADR 0005's strictly stronger
# allowlist by invoking srt from an `env -i` baseline — you cannot forget to deny a var you never
# knew was exported. (Measured: without this, a GH_TOKEN exported in the host shell walks straight
# into the jail.) PATH is load-bearing twice over: `env -i` resolves `srt` itself through the PATH
# it sets. Extend via HGT_SANDBOX_SETENV rather than widening this default.
_SANDBOX_ENV_PASS='HOME USER LOGNAME PATH TERM LANG LC_ALL LC_CTYPE'

# sandbox_enabled — is the jail in force? On by default (fail closed); HGT_NO_SANDBOX=1 or the
# --no-sandbox flag (which sets it) is the explicit opt-out.
sandbox_enabled() { [ "${HGT_NO_SANDBOX:-0}" != 1 ]; }

# _sandbox_userns_ok — can bwrap actually create a user namespace here? A cheap real probe: on
# Ubuntu 24.04 unprivileged userns is AppArmor-restricted and bwrap isn't setuid, so this fails
# with "setting up uid map: Permission denied" until the profile (templates/apparmor/bwrap) is
# installed. SRT drives bubblewrap too, so this gate is unchanged by ADR 0007.
#
# Bind the loader dirs (/lib, /lib64) alongside /usr and exec an ABSOLUTE /usr/bin/true: it's
# dynamically linked, so a /usr-only jail can't find its ELF interpreter under /lib64 and execvp
# fails with ENOENT ("No such file or directory") *even when userns setup — the thing we're
# testing — succeeded*. A too-thin probe would misread that as "userns blocked" and wrongly emit
# the AppArmor remediation. So the probe mirrors the real jail's system binds.
_sandbox_userns_ok() {
  bwrap --unshare-user --ro-bind /usr /usr --ro-bind-try /lib /lib --ro-bind-try /lib64 /lib64 \
    /usr/bin/true 2>/dev/null
}

# _sandbox_srt_version — the installed SRT's version, or nothing if it can't be determined.
# `srt --version` is useless: it prints `process.env.npm_package_version || '1.0.0'`, so outside
# an npm lifecycle script it always says 1.0.0. The version only exists in the package manifest,
# so resolve the bin through its symlink and walk up to the nearest package.json that actually
# names the package (npm's global layout is <prefix>/lib/node_modules/<pkg>/dist/cli.js).
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
# `command -v`: command -v also matches shell functions, and a function named after the binary
# reads as present here while SRT (which spawns it) can't find it at all.
_sandbox_require() {
  type -P "$1" >/dev/null 2>&1 || die "sandbox: $1 not found — $2
     hgt confines the Claude session to its worktree; it won't launch an unsandboxed agent by default (ADR 0007)."
}

# sandbox_preflight — fail closed with exact remediation if we can't jail. Called before every
# sandboxed launch. The userns probe goes last: it forks bwrap, the others are PATH lookups.
sandbox_preflight() {
  _sandbox_require srt "install it (\`npm i -g @anthropic-ai/sandbox-runtime@$_SANDBOX_SRT_VERSION\`) or opt out with --no-sandbox."
  # SRT's own Linux dependencies: bwrap builds the jail, socat bridges the egress proxy's unix
  # socket into it, and ripgrep scans the write-allowed tree for files SRT protects unconditionally.
  _sandbox_require bwrap "install it (\`sudo apt install bubblewrap\`) or opt out with --no-sandbox."
  _sandbox_require socat "install it (\`sudo apt install socat\`) or opt out with --no-sandbox."
  _sandbox_require rg "install ripgrep (\`sudo apt install ripgrep\`) or opt out with --no-sandbox."

  if [ -n "$_SANDBOX_SRT_VERSION" ]; then
    local have; have=$(_sandbox_srt_version)
    if [ -z "$have" ]; then
      warn "sandbox: couldn't determine the installed srt version (unusual install layout) — expected $_SANDBOX_SRT_VERSION"
    elif [ "$have" != "$_SANDBOX_SRT_VERSION" ]; then
      die "sandbox: srt $have is installed, but hgt pins $_SANDBOX_SRT_VERSION.
     SRT is pre-1.0 — its config format and its sandbox guarantees can change between patch releases.
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

# _json_str VALUE — VALUE as a JSON string literal. Only \ and " need escaping here: every value
# we emit is a filesystem path or a hostname, so control characters aren't reachable.
_json_str() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '"%s"' "$s"
}

# _json_arr [VALUE...] — the arguments as a JSON array of strings.
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

# _sandbox_remote_host WT — the hostname of WT's push remote, for the egress allowlist, or nothing.
# Salvaged from PR #90 with its URL parsing fixed. Order matters: cut the authority off FIRST, then
# strip userinfo, then the port. Stripping userinfo first eats the wrong '@' in a path like
# https://github.com/a@b/c.git; leaving a port or userinfo in place is worse than useless, because
# SRT rejects a domain pattern containing ':' outright and a credentialed remote would put its
# token on srt's argv. Prints a lowercase bare host.
_sandbox_remote_host() {
  local wt="$1" url host
  url=$(git -C "$wt" remote get-url --push origin 2>/dev/null) || return 0
  [ -n "$url" ] || return 0
  case "$url" in
    https://* | http://* | git://* | ssh://*)
      host=${url#*://}; host=${host%%/*}; host=${host#*@}; host=${host%%:*} ;;
    *:*)                              # scp-like: git@host:owner/repo.git
      host=${url%%:*}; host=${host#*@} ;;
    *) return 0 ;;                    # a local path or relative remote — nothing to allow
  esac
  case "$host" in '' | */*) return 0 ;; esac
  printf '%s' "$host" | tr '[:upper:]' '[:lower:]'
}

# _sandbox_allowlist WT — the hostnames the jail may reach, one per line: the Anthropic API, WT's
# git remote, and (on github.com) the API host `gh pr create` talks to — the git host serves
# fetch/push over https, the api host serves the REST call, and #81's PAT is useless without both.
# HGT_SANDBOX_EGRESS_ALLOW appends. A remote we can't parse (local path, IPv6 literal) contributes
# nothing rather than a bogus pattern SRT would reject.
_sandbox_allowlist() {
  local wt="$1" host extra
  printf '%s\n' $_SANDBOX_EGRESS_DEFAULT
  host=$(_sandbox_remote_host "$wt")
  if [ -n "$host" ]; then
    printf '%s\n' "$host"
    # GitHub Enterprise serves its API from the same host (/api/v3); only github.com splits them.
    [ "$host" = github.com ] && printf 'api.%s\n' "$host"
  fi
  for extra in ${HGT_SANDBOX_EGRESS_ALLOW:-}; do printf '%s\n' "$extra"; done
}

# _sandbox_settings WT — generate the SRT settings file that defines the jail, and the private
# scratch dir the jail uses for temp state. Sets _SANDBOX_SETTINGS_FILE and _SANDBOX_SCRATCH.
# Writes files — a launch-time side effect, not a source-time one.
#
# The file is rewritten unconditionally on every launch, never stamped: it sits inside the agent's
# own write grant, so a never-clobber write would let a tampered copy survive to the next launch.
# It's also in its own denyWrite, which closes the window entirely. `.hgt/.gitignore` keeps it out
# of `git status` — otherwise every worktree reads as dirty and `hgt work rm` refuses it forever.
_sandbox_settings() {
  local wt="$1" gitdir owndir dep p uid
  # A worktree's .git points into <main-repo>/.git/worktrees/<name>; git needs the shared common
  # dir (objects, refs) to do anything. Resolve it absolute so the grant is stable. Fail closed
  # with a legible message rather than letting raw set -e surface git's error mid-build.
  gitdir=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir) \
    || die "sandbox: couldn't resolve the git dir for worktree $wt (not a git worktree?)"
  owndir=$(git -C "$wt" rev-parse --path-format=absolute --git-dir) || owndir="$gitdir"
  uid=$(id -u)

  _SANDBOX_SCRATCH="$wt/.hgt/tmp"
  _SANDBOX_SETTINGS_FILE="$wt/.hgt/srt.json"
  mkdir -p "$_SANDBOX_SCRATCH/gh"

  # Reads are deny-then-allow in SRT and default to ALLOWED — the inverse of ADR 0005's tmpfs
  # $HOME. `denyRead: [$HOME]` restores deny-by-default for the interesting half of the filesystem
  # (~/.ssh, the admin gh auth, sibling repos), then we allow back only what the agent needs.
  # Linux SRT takes literal paths — no globs — so every entry here is a real path.
  local -a deny_read=("$HOME") allow_read=("$wt" "$gitdir") allow_write=("$wt" "$gitdir")
  # The worktree lives under $HOME on a normal setup, so it has to be re-allowed explicitly:
  # allowRead is documented to beat denyRead; allowWrite is not documented to imply read at all.
  for dep in $_SANDBOX_RO_DEPS ${HGT_SANDBOX_RO_BIND:-}; do
    case "$dep" in /*) p="$dep" ;; *) p="$HOME/$dep" ;; esac
    allow_read+=("$p")
  done
  for dep in $_SANDBOX_RW_DEPS; do
    allow_read+=("$HOME/$dep"); allow_write+=("$HOME/$dep")
  done

  # Host IPC is the one class ADR 0005 got for free (--unshare-all + tmpfs $HOME) that SRT does
  # not: it hands the jail a normal filesystem, and --unshare-net doesn't isolate AF_UNIX. The
  # tmux control socket is the sharp one — an agent that can reach it does `tmux send-keys` into
  # Carl's other panes, which is unconfined host execution and defeats this whole slice. SRT
  # blocks socket(AF_UNIX) via seccomp by default (measured: EPERM), but that fails OPEN with a
  # warning when seccomp is unavailable, so name the directories too. We deliberately do NOT deny
  # /tmp wholesale — SRT stages its own proxy socket there when XDG_RUNTIME_DIR is unset, which
  # `env -i` guarantees. Writes are denied by default anyway; TMPDIR points at the scratch dir.
  deny_read+=("/tmp/tmux-$uid" "/run/user/$uid")

  # allowGitConfig stays false (SRT's default). .git/config lives in the SHARED common dir, so a
  # jailed agent writing core.pager / core.hooksPath there executes on the HOST the next time you
  # run git in this repo. The cost is that `git push -u` and gh's fork disambiguation fail; use
  # `git push origin HEAD`. config.worktree gets an explicit deny — it is NOT in SRT's mandatory
  # list, and extensions.worktreeConfig would otherwise reopen the same door per-worktree.
  local -a deny_write=("$_SANDBOX_SETTINGS_FILE" "$gitdir/config" "$gitdir/hooks" "$owndir/config.worktree")

  {
    printf '{\n'
    printf '  "network": {\n'
    printf '    "allowedDomains": %s,\n' "$(_json_arr $(_sandbox_allowlist "$wt"))"
    printf '    "deniedDomains": [],\n'
    # Without this, an unlisted host consults an ask-callback. In a detached tmux pane that either
    # hangs forever or auto-allows; both turn the allowlist into a suggestion.
    printf '    "strictAllowlist": true\n'
    printf '  },\n'
    printf '  "filesystem": {\n'
    printf '    "denyRead": %s,\n'   "$(_json_arr "${deny_read[@]}")"
    printf '    "allowRead": %s,\n'  "$(_json_arr "${allow_read[@]}")"
    printf '    "allowWrite": %s,\n' "$(_json_arr "${allow_write[@]}")"
    printf '    "denyWrite": %s,\n'  "$(_json_arr "${deny_write[@]}")"
    printf '    "allowGitConfig": false\n'
    printf '  },\n'
    # The jail maps to a different uid, so git would otherwise refuse both trees as "dubious
    # ownership". safeDirectories grants that and nothing else — explicitly not write access.
    printf '  "git": { "safeDirectories": %s }\n' "$(_json_arr "$wt" "$gitdir")"
    printf '}\n'
  } >"$_SANDBOX_SETTINGS_FILE"
}

# sandbox_argv WT — populate the global array HGT_SANDBOX_ARGV with the prefix that jails a process
# to worktree WT. Caller appends the real command (`claude -n ...`); the prefix ends with `--` so
# srt can't mistake claude's own flags for its own. A global array (not stdout) so both consumers
# get a real argv: the inline path expands it directly, the tmux path _shq-quotes each element into
# the send-keys string. WT must be absolute.
sandbox_argv() {
  local wt="$1" var i
  _sandbox_settings "$wt"

  # `env -i` is our --clearenv: start empty, re-add only the curated allowlist. It is an
  # approximation, not an equivalent — the pane's dash re-adds PWD on the way through, and SRT
  # overlays its own proxy variables. Neither carries anything the agent didn't already know.
  HGT_SANDBOX_ARGV=(env -i)
  for var in $_SANDBOX_ENV_PASS ${HGT_SANDBOX_SETENV:-}; do
    [ -n "${!var:-}" ] && HGT_SANDBOX_ARGV+=("$var=${!var}")
  done
  # A private temp dir inside the worktree, because /tmp is not writable in the jail (writes are
  # deny-by-default and we grant only the worktree + git dir). GH_CONFIG_DIR points there too: the
  # old tmpfs $HOME used to hand gh a scratch config for free, and without one gh would reach for
  # the real ~/.config/gh — the admin credential this jail exists to keep away from the agent.
  HGT_SANDBOX_ARGV+=("TMPDIR=$_SANDBOX_SCRATCH" "GH_CONFIG_DIR=$_SANDBOX_SCRATCH/gh")

  # git config injected via the numbered GIT_CONFIG_* env (no ~/.gitconfig write needed). Always
  # force gpg-signing off — the jail has no ~/.gnupg, so the agent can't sign as Carl and its
  # commits are unsigned by design. Always rewrite git@ -> https: --unshare-net means ssh cannot
  # work at all (the proxy speaks CONNECT, not SSH), so an ssh remote would leave even `git fetch`
  # hanging. Over https a token-less jail still fetches a public repo anonymously, and a private
  # one fails with a legible auth error instead. With a scoped push token (#81) we also give git a
  # credential helper that reads $GITHUB_TOKEN, so the jailed agent can push with ONLY that token —
  # never Carl's ~/.ssh or admin gh. Push deliberately does NOT go through gh: a snap gh can't run
  # in the jail and would take push down with it (dogfooded on #81); git reads the env directly.
  local -a gitcfg=(
    commit.gpgsign false
    "url.https://github.com/.insteadOf" "git@github.com:"
  )
  if [ -n "${HGT_SANDBOX_GITHUB_TOKEN:-}" ]; then
    _sandbox_credential "$wt"
    gitcfg+=(
      # Empty reset first: clears any credential.helper inherited from the readable ~/.gitconfig,
      # so only ours is consulted (git tries helpers in list order). Then the env-reading helper:
      # `get` emits the token, and it exits 0 on git's follow-up `store`/`erase` calls (a bare `&&`
      # would exit non-zero on a non-get op and make git grumble).
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

  # #81: the PAT rides fd 3, never argv. This one-liner sources the fd (launch_session opens it on
  # the command group and unlinks the file) and execs the rest, so GITHUB_TOKEN lands in srt's
  # environment — and therefore the jail's — without ever appearing in /proc/<pid>/cmdline.
  if [ -n "${_SANDBOX_ARGS_FILE:-}" ]; then
    HGT_SANDBOX_ARGV+=(sh -c '. /dev/fd/3; exec "$@"' hgt)
  fi

  HGT_SANDBOX_ARGV+=(srt --settings "$_SANDBOX_SETTINGS_FILE")
  [ -n "${HGT_SANDBOX_DEBUG:-}" ] && HGT_SANDBOX_ARGV+=(--debug)
  HGT_SANDBOX_ARGV+=(--)
}

# _sandbox_credential WT — stage the scoped PAT (HGT_SANDBOX_GITHUB_TOKEN) for delivery INTO the
# jail as an env var (#81), the same seam attended + unattended (#17). The value must never ride
# the argv: send-keys would type it into the visible tmux pane, `run` would echo it, and
# /proc/<pid>/cmdline is world-readable. So it goes on fd 3 as a shell fragment that the `sh -c`
# wrapper in sandbox_argv sources — landing only in the child's environ (owner-only) and dying with
# the process. No persistent on-disk secret: the fd is sourced from a mktemp'd file (O_EXCL +
# random name + mode 600 → safe even on a shared base) that launch_session opens then immediately
# unlinks. git's helper reads $GITHUB_TOKEN; gh reads $GH_TOKEN natively. Sets _SANDBOX_ARGS_FILE.
# Writes a file — a launch-time side effect.
#
# (Pre-ADR-0007 this was a NUL-separated `bwrap --args <fd>` payload. bwrap's argv is SRT's business
# now, so the payload became shell instead; the fd lifecycle in launch_session is unchanged.)
_sandbox_credential() {
  local wt="$1" gh
  # A safe host dir for the transient payload: XDG_RUNTIME_DIR (per-user, 0700, tmpfs) when set,
  # else $TMPDIR / /tmp. HGT_SANDBOX_CRED_DIR overrides (the suite points it inside its tmpdir).
  local base="${HGT_SANDBOX_CRED_DIR:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}}"
  ( umask 077; mkdir -p "$base" )
  # Reaper: launch unlinks the payload, but if a launch dies before its pane gets there (tmux/
  # send-keys fails, pane exits early, user Ctrl-Cs) the file is stranded with no cleaner — an EXIT
  # trap in hgt would race the pane. Sweep payloads older than 5 min at the next launch instead.
  find "$base" -maxdepth 1 -name 'hgt-args.*' -mmin +5 -delete 2>/dev/null || true
  _SANDBOX_ARGS_FILE=$(umask 077; mktemp "$base/hgt-args.XXXXXX") \
    || die "sandbox: couldn't stage the credential payload under $base"
  # Shell, sourced by the `sh -c` wrapper. Single-quoted with the standard '\'' escape so a token
  # containing a quote can't break out into the sourcing shell.
  local tok=${HGT_SANDBOX_GITHUB_TOKEN//\'/\'\\\'\'}
  printf "export GITHUB_TOKEN='%s' GH_TOKEN='%s'\n" "$tok" "$tok" >"$_SANDBOX_ARGS_FILE"
  # gh is only for `gh pr create` (reads GH_TOKEN from env) — push never needs it. Nothing to bind
  # any more: SRT leaves the system filesystem readable, so /usr/bin/gh is simply there. A snap gh
  # still can't run in the jail (no snapd mounts), so keep warning about it.
  gh=$(type -P gh) || { warn "sandbox: gh not on PATH — jailed \`gh pr create\` unavailable (push still works)"; return 0; }
  case "$gh" in
    /snap/*) warn "sandbox: gh is a snap ($gh) — can't run in the jail, so \`gh pr create\` won't work there (push still works); install a non-snap gh for in-jail PRs" ;;
  esac
  return 0
}
