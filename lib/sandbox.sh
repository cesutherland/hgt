# sandbox.sh — confine the Claude session `hgt work` spawns to its worktree (issue #67, ADR 0005).
#
# We wrap ONLY the claude process in a bubblewrap FS jail; tmux and the human's shell pane stay
# on the host, so `tmux attach` and "shell in if it gets dicey" survive untouched. The security
# property is by construction: $HOME is a tmpfs, so anything not re-bound (~/.ssh, the admin
# `gh` auth under ~/.config/gh, ~/.npmrc, sibling repos, arbitrary FS) simply isn't in the jail.
#
# This is a shared seam: launch_session prefixes it onto claude on both the inline and tmux
# paths, and the future local-listener executor reuses it — identical confinement, attended or
# not (#17). Everything here is a pure argv builder + preflight; no side effects at source time.
#
# The publish boundary (#81): by default the jail holds NO push credential — commits land locally
# and stop there. Set HGT_SANDBOX_GITHUB_TOKEN to a scoped machine-user PAT and the jail gains a
# credentialed push/PR path (git@ -> https + a git credential helper reading $GITHUB_TOKEN), the
# SAME seam attended and unattended (#17). The token is delivered as an env var INTO the jail via
# `bwrap --args <fd>`, so its value never hits the argv / the `run` echo / the tmux pane / the
# world-readable /proc cmdline, and it dies with the process (no on-disk secret). Fail-closed stays
# the default: no token, no push power.

# Runtime deps under $HOME re-bound read-only over the tmpfs. Machine-specific (node via nvm,
# the claude launcher under ~/.local), so extend via HGT_SANDBOX_RO_BIND (space-separated,
# $HOME-relative or absolute). See ADR 0005 "residuals".
_SANDBOX_RO_DEPS='.nvm .local .gitconfig .gitconfig.local'
# claude's own state + the Anthropic credential it must hold to call the API — read-write
# because claude updates them at runtime. Unavoidable exposure (ADR 0005 residuals).
_SANDBOX_RW_DEPS='.claude .claude.json'
# Host env vars passed through --clearenv. Deliberately thin — curated so shell-exported secrets
# (GH_TOKEN, cloud creds) don't leak into the jail via the environment. This is the likeliest
# first friction on a live run (a runtime that wants NVM_DIR/XDG_*/etc. won't find it); the fix
# is a config change, not code — extend via HGT_SANDBOX_SETENV rather than widening this default.
_SANDBOX_ENV_PASS='HOME USER LOGNAME PATH TERM LANG LC_ALL LC_CTYPE'

# sandbox_enabled — is the jail in force? On by default (fail closed); HGT_NO_SANDBOX=1 or the
# --no-sandbox flag (which sets it) is the explicit opt-out.
sandbox_enabled() { [ "${HGT_NO_SANDBOX:-0}" != 1 ]; }

# _sandbox_userns_ok — can bwrap actually create a user namespace here? A cheap real probe: on
# Ubuntu 24.04 unprivileged userns is AppArmor-restricted and bwrap isn't setuid, so this fails
# with "setting up uid map: Permission denied" until the profile (templates/apparmor/bwrap) is
# installed. Cheaper to just try than to parse sysctls + profile state.
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

# sandbox_preflight — fail closed with exact remediation if we can't jail. Called before every
# sandboxed launch. Missing bwrap -> install hint; userns blocked -> the AppArmor two-liner.
sandbox_preflight() {
  if ! command -v bwrap >/dev/null 2>&1; then
    die "sandbox: bwrap not found — install it (\`sudo apt install bubblewrap\`) or opt out with --no-sandbox.
     hgt confines the Claude session to its worktree; it won't launch an unsandboxed agent by default (ADR 0005)."
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

# sandbox_argv WT — populate the global array HGT_SANDBOX_ARGV with the bwrap prefix that jails a
# process to worktree WT. Caller appends the real command (`claude -n ...`). A global array (not
# stdout) so both consumers get a real argv: the inline path expands it directly, the tmux path
# _shq-quotes each element into the send-keys string. WT must be absolute.
sandbox_argv() {
  local wt="$1" gitdir dep extra
  # A worktree's .git points into <main-repo>/.git/worktrees/<name>; git needs the shared common
  # dir (objects, refs) to do anything. Resolve it absolute so the bind target is stable. Fail
  # closed with a legible message rather than letting raw set -e surface git's error mid-argv.
  gitdir=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir) \
    || die "sandbox: couldn't resolve the git dir for worktree $wt (not a git worktree?)"

  HGT_SANDBOX_ARGV=(
    bwrap
    --die-with-parent          # jail dies if hgt/the pane does — no orphaned confined process
    --unshare-all --share-net  # own ns for everything EXCEPT net (agent needs Anthropic + remote)
    --clearenv                 # start empty; re-add only the curated allowlist below
    --ro-bind /usr /usr
    --ro-bind-try /bin /bin --ro-bind-try /sbin /sbin
    --ro-bind-try /lib /lib --ro-bind-try /lib64 /lib64
    --ro-bind /etc /etc
    # DNS: on systemd-resolved boxes /etc/resolv.conf symlinks into /run, which the jail doesn't
    # bind — the link would dangle and glibc falls back to 127.0.0.1:53 (the stub is on
    # 127.0.0.53), killing name resolution. Bind the resolver dir so the link resolves; -try keeps
    # plain-/etc/resolv.conf boxes working. NOTE: this only works because --share-net shares
    # loopback — an --unshare-net egress allowlist (#74) must handle DNS explicitly.
    --ro-bind-try /run/systemd/resolve /run/systemd/resolve
    --proc /proc --dev /dev --tmpfs /tmp
    --tmpfs "$HOME"            # THE boundary: everything under $HOME is gone unless re-bound below
  )

  # Runtime deps re-bound read-only over the tmpfs (node, the claude launcher, git identity).
  for dep in $_SANDBOX_RO_DEPS ${HGT_SANDBOX_RO_BIND:-}; do
    case "$dep" in /*) extra="$dep" ;; *) extra="$HOME/$dep" ;; esac
    HGT_SANDBOX_ARGV+=(--ro-bind-try "$extra" "$extra")
  done
  # claude's state + Anthropic credential, read-write (unavoidable — ADR 0005 residuals).
  for dep in $_SANDBOX_RW_DEPS; do
    HGT_SANDBOX_ARGV+=(--bind-try "$HOME/$dep" "$HOME/$dep")
  done

  HGT_SANDBOX_ARGV+=(
    --bind "$wt" "$wt"          # the worktree: read-write
    --bind "$gitdir" "$gitdir"  # the repo's shared .git: read-write (commit/log/push)
    --chdir "$wt"
  )

  # Env: pass through the curated allowlist (skip unset).
  local var
  for var in $_SANDBOX_ENV_PASS ${HGT_SANDBOX_SETENV:-}; do
    [ -n "${!var:-}" ] && HGT_SANDBOX_ARGV+=(--setenv "$var" "${!var}")
  done

  # git config injected via the numbered GIT_CONFIG_* env (no ~/.gitconfig write needed). Always
  # force gpg-signing off — the jail has no ~/.gnupg, so the agent can't sign as Carl and its
  # commits are unsigned by design. With a scoped push token (#81) also rewrite git@ -> https and
  # give git a credential helper that reads $GITHUB_TOKEN, so the jailed agent can push with ONLY
  # that token — never Carl's ~/.ssh or admin gh. The token reaches the jail as an env var delivered
  # via `bwrap --args 3` (see _sandbox_credential + launch_session): the fd stream carries the
  # `--setenv GITHUB_TOKEN <tok>` pair, so the value never hits the argv, the `run` echo, the tmux
  # pane, or the world-readable /proc cmdline, and it dies with the process (no on-disk secret to
  # locate or reap). Push deliberately does NOT go through gh at all (#97): a snap gh can't even run
  # in the jail, so git reads the env directly and `hgt pr open` (cmds/pr.sh) hits the REST API
  # straight with the same token for the one other thing gh bought — opening the PR.
  local -a gitcfg=(commit.gpgsign false)
  if [ -n "${HGT_SANDBOX_GITHUB_TOKEN:-}" ]; then
    _sandbox_credential "$wt"
    HGT_SANDBOX_ARGV+=(--args 3)  # fd 3 injects `--setenv GITHUB_TOKEN <tok>` etc.; launch opens it
    gitcfg+=(
      "url.https://github.com/.insteadOf" "git@github.com:"
      # Empty reset first: clears any credential.helper inherited from the ro-bound ~/.gitconfig, so
      # only ours is consulted (git tries helpers in list order). Then the env-reading helper: `get`
      # emits the token, and it exits 0 on git's follow-up `store`/`erase` calls (bare `&&` would
      # exit non-zero on a non-get op and make git grumble).
      "credential.helper" ""
      "credential.https://github.com.helper" '!f() { test "$1" = get && printf "username=x-access-token\npassword=%s\n" "$GITHUB_TOKEN"; true; }; f'
    )
  fi
  HGT_SANDBOX_ARGV+=(--setenv GIT_CONFIG_COUNT "$(( ${#gitcfg[@]} / 2 ))")
  local i=0
  while [ "$i" -lt "${#gitcfg[@]}" ]; do
    HGT_SANDBOX_ARGV+=(
      --setenv "GIT_CONFIG_KEY_$((i / 2))" "${gitcfg[i]}"
      --setenv "GIT_CONFIG_VALUE_$((i / 2))" "${gitcfg[i + 1]}"
    )
    i=$((i + 2))
  done
}

# _sandbox_credential WT — stage the scoped PAT (HGT_SANDBOX_GITHUB_TOKEN) for delivery INTO the
# jail as an env var (#81), the same seam attended + unattended (#17). The value must never ride
# bwrap's argv: send-keys would type it into the visible tmux pane, `run` would echo it, and
# /proc/<pid>/cmdline is world-readable. So we hand it to bwrap via `--args <fd>` — the fd stream
# sets GITHUB_TOKEN inside the jail, landing only in the child's environ (owner-only) and dying
# with the process. No persistent on-disk secret: the fd is sourced from a mktemp'd file (O_EXCL +
# random name + mode 600 → safe even on a shared base, #1) that launch_session opens then
# immediately unlinks (#2). git's credential helper reads $GITHUB_TOKEN for push; `hgt pr open`
# (cmds/pr.sh) reads the same var straight from its environment for the PR API call — no `gh`, no
# `hosts.yml`, nothing else written or bound (#97). Sets _SANDBOX_ARGS_FILE (the payload path), the
# one file this seam writes. Writes a file — a launch-time side effect.
#
# NOTE (trust): a usable token in the jail + today's --share-net egress is the exfil surface ADR
# 0005 flags as gated on #74. Safe to use only while egress is trusted/constrained.
_sandbox_credential() {
  local wt="$1"
  # A safe host dir for the transient payload: XDG_RUNTIME_DIR (per-user, 0700, tmpfs) when set,
  # else $TMPDIR / /tmp. HGT_SANDBOX_CRED_DIR overrides (the suite points it inside its tmpdir).
  local base="${HGT_SANDBOX_CRED_DIR:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}}"
  ( umask 077; mkdir -p "$base" )
  # Reaper: launch unlinks the payload, but if a launch dies before its pane gets there (tmux/
  # send-keys fails, pane exits early, user Ctrl-Cs) the file is stranded with no cleaner — an EXIT
  # trap in hgt would race the pane. Sweep payloads older than 5 min at the next launch instead.
  find "$base" -maxdepth 1 -name 'hgt-args.*' -mmin +5 -delete 2>/dev/null || true
  # mktemp: O_EXCL + unpredictable name + mode 600 — no symlink / pre-create attack even on a shared
  # base (#1). Holds the token on disk only from here until launch opens+unlinks it: microseconds on
  # the inline path, tmux+shell-startup on the tmux path — brief, owner-only, tmpfs under XDG (#2).
  _SANDBOX_ARGS_FILE=$(umask 077; mktemp "$base/hgt-args.XXXXXX") \
    || die "sandbox: couldn't stage the credential payload under $base"
  # NUL-separated bwrap args, injected where `--args 3` sits: set the scoped token as jail env.
  printf '%s\0' --setenv GITHUB_TOKEN "$HGT_SANDBOX_GITHUB_TOKEN" >"$_SANDBOX_ARGS_FILE"
}
