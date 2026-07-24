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

# Egress allowlist (#74, ADR 0006). The jail still shares the host netns below (--share-net) for
# simple loopback reachability, but every jailed session is also placed in a dedicated cgroup
# (systemd-run --slice=hgt-sandbox) that a one-time nftables install (templates/nftables/
# hgt-egress.nft) confines to this port and nothing else — so sharing the netns no longer means
# unfiltered internet, only "can reach the proxy." The proxy (templates/egress-proxy.py) is what
# actually decides which hostnames are reachable through it: the Anthropic API + the worktree's
# git remote, extendable via HGT_SANDBOX_EGRESS_ALLOW.
_SANDBOX_EGRESS_PORT="${HGT_SANDBOX_EGRESS_PORT:-8874}"
_SANDBOX_EGRESS_ANTHROPIC_HOST="${HGT_SANDBOX_ANTHROPIC_HOST:-api.anthropic.com}"
_SANDBOX_EGRESS_NFT_FILE="${HGT_SANDBOX_EGRESS_NFT_FILE:-/etc/nftables.d/hgt-egress.nft}"
_SANDBOX_EGRESS_PIDFILE="${HGT_SANDBOX_EGRESS_PIDFILE:-${XDG_RUNTIME_DIR:-/tmp}/hgt-egress-proxy.pid}"

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
# sandboxed launch. Missing bwrap -> install hint; userns blocked -> the AppArmor two-liner;
# egress allowlist not installed -> the nftables three-liner (#74).
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
  _sandbox_egress_preflight
}

# _sandbox_egress_preflight — fail closed if the one-time nftables install (templates/nftables/
# hgt-egress.nft) hasn't landed. A file-existence check, not a live ruleset probe: reading nft
# state needs the same privilege the ruleset itself is gating, so unlike _sandbox_userns_ok this
# can't cheaply verify by doing the real thing — it catches "never installed," not "installed,
# then flushed" (ADR 0006 residuals).
_sandbox_egress_preflight() {
  [ -f "$_SANDBOX_EGRESS_NFT_FILE" ] && return 0
  local nft_tpl="$HGT_ROOT/templates/nftables/hgt-egress.nft"
  die "sandbox: egress allowlist not installed ($_SANDBOX_EGRESS_NFT_FILE missing).
   Install the nftables egress rule once, then re-run:
     sudo install -d $(dirname "$_SANDBOX_EGRESS_NFT_FILE")
     sudo install -m644 $nft_tpl $_SANDBOX_EGRESS_NFT_FILE
     sudo nft -f $_SANDBOX_EGRESS_NFT_FILE
   Or opt out with --no-sandbox (runs the agent unconfined, and unfiltered — see ADR 0005/0006)."
}

# _sandbox_egress_remote_host WT — the git remote's hostname, for the egress allowlist (#74).
# Only an https:// remote actually proxies (the CONNECT proxy speaks HTTP, not SSH); an ssh:// /
# git@ remote's host is still returned (best-effort, for the allowlist to be complete) but a push
# over it will hang against the nft rule rather than reach anywhere — see ADR 0006 residuals.
_sandbox_egress_remote_host() {
  local wt="$1" url
  url=$(git -C "$wt" remote get-url origin 2>/dev/null) || return 0
  case "$url" in
    https://*) url="${url#https://}"; printf '%s' "${url%%/*}" ;;
    git@*) url="${url#git@}"; printf '%s' "${url%%:*}" ;;
    ssh://*) url="${url#ssh://}"; url="${url#*@}"; printf '%s' "${url%%[:/]*}" ;;
  esac
}

# _sandbox_egress_allowlist WT — the proxy's allowed hostnames: the Anthropic API + the
# worktree's git remote, plus any HGT_SANDBOX_EGRESS_ALLOW extras (dogfooding seam, same pattern
# as HGT_SANDBOX_RO_BIND). Space-separated, printed to stdout.
_sandbox_egress_allowlist() {
  local wt="$1" host remote
  printf '%s' "$_SANDBOX_EGRESS_ANTHROPIC_HOST"
  remote=$(_sandbox_egress_remote_host "$wt")
  [ -n "$remote" ] && printf ' %s' "$remote"
  for host in ${HGT_SANDBOX_EGRESS_ALLOW:-}; do printf ' %s' "$host"; done
}

# _sandbox_egress_proxy_ensure ALLOWLIST... — lazily start the CONNECT-only allowlisting proxy
# (templates/egress-proxy.py) as a detached host process. It's a singleton on
# _SANDBOX_EGRESS_PORT, reused across sessions (a resumed tmux session's jail needs the same
# proxy still running) and keyed by a pidfile so a live proxy isn't respawned on every launch.
# NOTE: the allowlist is fixed at first start — a later repo with a different git remote host
# won't reach it until the proxy is restarted (kill the pid, or set HGT_SANDBOX_EGRESS_ALLOW up
# front). See ADR 0006 residuals.
_sandbox_egress_proxy_ensure() {
  local pid
  if [ -f "$_SANDBOX_EGRESS_PIDFILE" ]; then
    pid=$(cat "$_SANDBOX_EGRESS_PIDFILE" 2>/dev/null) || pid=""
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && return 0
  fi
  info "sandbox: starting egress proxy on 127.0.0.1:$_SANDBOX_EGRESS_PORT (allow: $*)"
  setsid python3 "$HGT_ROOT/templates/egress-proxy.py" "$_SANDBOX_EGRESS_PORT" "$@" >/dev/null 2>&1 &
  disown
  echo $! >"$_SANDBOX_EGRESS_PIDFILE"
}

# sandbox_argv WT — populate the global array HGT_SANDBOX_ARGV with the bwrap prefix that jails a
# process to worktree WT. Caller appends the real command (`claude -n ...`). A global array (not
# stdout) so both consumers get a real argv: the inline path expands it directly, the tmux path
# _shq-quotes each element into the send-keys string. WT must be absolute.
sandbox_argv() {
  local wt="$1" gitdir dep extra allow proxy_url
  # A worktree's .git points into <main-repo>/.git/worktrees/<name>; git needs the shared common
  # dir (objects, refs) to do anything. Resolve it absolute so the bind target is stable. Fail
  # closed with a legible message rather than letting raw set -e surface git's error mid-argv.
  gitdir=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir) \
    || die "sandbox: couldn't resolve the git dir for worktree $wt (not a git worktree?)"

  # Egress allowlist (#74, ADR 0006): make sure the proxy this jail will be pinned to is up
  # before building the argv that depends on it.
  allow=$(_sandbox_egress_allowlist "$wt")
  proxy_url="http://127.0.0.1:$_SANDBOX_EGRESS_PORT"
  # shellcheck disable=SC2086  # $allow is deliberately word-split: a space-separated host list
  _sandbox_egress_proxy_ensure $allow

  HGT_SANDBOX_ARGV=(
    # Dedicated cgroup (#74): the nftables egress rule (templates/nftables/hgt-egress.nft)
    # scopes to hgt-sandbox.slice, so every jailed session needs its own scope under it — nothing
    # else on the host is affected. --collect cleans up the unit once bwrap exits.
    systemd-run --unit="hgt-sandbox-$(basename "$wt")" --slice=hgt-sandbox
    --scope --collect --quiet
    --
    bwrap
    --die-with-parent          # jail dies if hgt/the pane does — no orphaned confined process
    # own ns for everything EXCEPT net: --share-net is still the full host netns (loopback
    # reaches the egress proxy trivially), but it's no longer "blanket" — the cgroup above is
    # what the nftables rule confines it to just the proxy's port, and the proxy itself decides
    # which hostnames a CONNECT tunnel through it may reach (#74, ADR 0006).
    --unshare-all --share-net
    --clearenv                 # start empty; re-add only the curated allowlist below
    --ro-bind /usr /usr
    --ro-bind-try /bin /bin --ro-bind-try /sbin /sbin
    --ro-bind-try /lib /lib --ro-bind-try /lib64 /lib64
    --ro-bind /etc /etc
    # DNS: on systemd-resolved boxes /etc/resolv.conf symlinks into /run, which the jail doesn't
    # bind — the link would dangle and glibc falls back to 127.0.0.1:53 (the stub is on
    # 127.0.0.53), killing name resolution. Bind the resolver dir so the link resolves; -try keeps
    # plain-/etc/resolv.conf boxes working. Harmless now that egress is proxied (#74): the jail
    # never needs to resolve a name itself (it CONNECTs to the proxy by IP), so a tool that
    # bypasses HTTPS_PROXY and tries direct DNS+connect just fails closed at the nft rule instead.
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

  # Env: pass through the curated allowlist (skip unset), then force gpg-signing off — the jail
  # has no ~/.gnupg, so the agent can't sign as Carl and its commits are unsigned by design.
  local var
  for var in $_SANDBOX_ENV_PASS ${HGT_SANDBOX_SETENV:-}; do
    [ -n "${!var:-}" ] && HGT_SANDBOX_ARGV+=(--setenv "$var" "${!var}")
  done
  HGT_SANDBOX_ARGV+=(
    # Pin every proxy-aware tool (git, npm, claude's own HTTP client) at the egress proxy (#74).
    # Both cases: some tools only honor the lowercase form. NO_PROXY empty on purpose — nothing
    # should bypass the proxy, not even localhost (there's nothing else in the jail to reach).
    --setenv HTTPS_PROXY "$proxy_url" --setenv https_proxy "$proxy_url"
    --setenv HTTP_PROXY "$proxy_url" --setenv http_proxy "$proxy_url"
    --setenv NO_PROXY "" --setenv no_proxy ""
    --setenv GIT_CONFIG_COUNT 1
    --setenv GIT_CONFIG_KEY_0 commit.gpgsign
    --setenv GIT_CONFIG_VALUE_0 false
  )
}
