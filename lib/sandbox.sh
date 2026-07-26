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
# credentialed push/PR path (git@ -> https, gh as the git credential helper), the SAME seam for the
# attended and unattended (#17) paths. The token rides a bound gh config dir, never an env var or
# argv (see _sandbox_credential). Fail-closed stays the default: no token, no push power.

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
  # give git a credential helper that reads the token straight from the bound file, so the jailed
  # agent can push with ONLY that token — never Carl's ~/.ssh or admin gh. Push deliberately does
  # NOT go through gh: gh installed as a snap can't run in the jail (needs snapd/mounts absent
  # here), which would take push down with it (dogfooded on #81). The token never lands in the
  # argv/echo/pane — the helper reads $GH_CONFIG_DIR/token, so only that *path* is ever visible.
  local -a gitcfg=(commit.gpgsign false)
  if [ -n "${HGT_SANDBOX_GITHUB_TOKEN:-}" ]; then
    _sandbox_credential "$wt"
    HGT_SANDBOX_ARGV+=(--setenv GH_CONFIG_DIR "$_SANDBOX_GH_CONFIG_DIR")
    gitcfg+=(
      "url.https://github.com/.insteadOf" "git@github.com:"
      "credential.https://github.com.helper" '!f() { test "$1" = get && printf "username=x-access-token\npassword=%s\n" "$(cat "$GH_CONFIG_DIR/token")"; }; f'
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

# _sandbox_credential WT — provision a jail-only GitHub credential from HGT_SANDBOX_GITHUB_TOKEN
# (#81), the same seam for the attended and unattended paths (#17). The token must NOT ride an env
# var: send-keys would type it straight into the visible tmux pane and `run` would echo it — a live
# credential in scrollback/logs. So it rides a mode-700 dir bound read-write into the jail at the
# same path; only the *path* appears in the argv. `token` (a plain file) is what git's credential
# helper reads to push — no gh in that path. `hosts.yml` is the same token in gh's format, for
# `gh pr create` where gh actually runs. Sets _SANDBOX_GH_CONFIG_DIR and appends the dir bind (+ gh
# binary, best-effort) to HGT_SANDBOX_ARGV. Writes files — a launch-time side effect, unlike the
# rest of this pure argv builder.
#
# NOTE (trust): a readable token + today's --share-net egress is exactly the exfil surface ADR 0005
# flags as gated on #74. This seam is safe to use only while egress is trusted/constrained.
_sandbox_credential() {
  local wt="$1" gh
  # Per-worktree config dir on the host, mode 700, holding only the scoped token. Under a runtime
  # dir (not the worktree, which is bound rw and would surface it as untracked / risk a commit);
  # HGT_SANDBOX_CRED_DIR overrides (the suite points it inside its tmpdir).
  local base="${HGT_SANDBOX_CRED_DIR:-${XDG_RUNTIME_DIR:-/tmp}/hgt-cred}"
  _SANDBOX_GH_CONFIG_DIR="$base/$(basename "$wt")"
  # umask scoped to a subshell so it doesn't leak into the caller's later file writes.
  ( umask 077
    mkdir -p "$_SANDBOX_GH_CONFIG_DIR"
    printf '%s' "$HGT_SANDBOX_GITHUB_TOKEN" >"$_SANDBOX_GH_CONFIG_DIR/token"
    cat >"$_SANDBOX_GH_CONFIG_DIR/hosts.yml" <<EOF
github.com:
    oauth_token: $HGT_SANDBOX_GITHUB_TOKEN
    git_protocol: https
EOF
  )
  HGT_SANDBOX_ARGV+=(--bind "$_SANDBOX_GH_CONFIG_DIR" "$_SANDBOX_GH_CONFIG_DIR")
  # gh is only for `gh pr create` — push reads the token file directly, so a missing/broken gh must
  # never block it. Bind gh best-effort; skip a snap gh, which can't run in the jail (no snapd/mounts
  # here) and would only spew errors. Warn so PR-from-jail isn't a silent mystery.
  gh=$(command -v gh) || { warn "sandbox: gh not on PATH — jailed \`gh pr create\` unavailable (push still works via the token file)"; return 0; }
  case "$gh" in
    /snap/*) warn "sandbox: gh is a snap ($gh) — can't run in the jail, so \`gh pr create\` won't work there (push still works); install a non-snap gh for in-jail PRs"; return 0 ;;
  esac
  HGT_SANDBOX_ARGV+=(--ro-bind "$gh" "$gh")
}

# sandbox_credential_cleanup WT — remove the jail-only gh config dir (token) for worktree WT, if
# any. Called by `hgt work rm` so a scoped token doesn't outlive its worktree. No-op when absent.
sandbox_credential_cleanup() {
  local base="${HGT_SANDBOX_CRED_DIR:-${XDG_RUNTIME_DIR:-/tmp}/hgt-cred}"
  local dir="$base/$(basename "$1")"
  [ -d "$dir" ] && run rm -rf "$dir"
  return 0
}
