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
# Host env vars passed through --clearenv. Curated so shell-exported secrets (GH_TOKEN, cloud
# creds) don't leak into the jail via the environment. Extend via HGT_SANDBOX_SETENV.
_SANDBOX_ENV_PASS='HOME PATH TERM LANG LC_ALL LC_CTYPE'

# sandbox_enabled — is the jail in force? On by default (fail closed); HGT_NO_SANDBOX=1 or the
# --no-sandbox flag (which sets it) is the explicit opt-out.
sandbox_enabled() { [ "${HGT_NO_SANDBOX:-0}" != 1 ]; }

# _sandbox_userns_ok — can bwrap actually create a user namespace here? A cheap real probe: on
# Ubuntu 24.04 unprivileged userns is AppArmor-restricted and bwrap isn't setuid, so this fails
# with "setting up uid map: Permission denied" until the profile (templates/apparmor/bwrap) is
# installed. Cheaper to just try than to parse sysctls + profile state.
_sandbox_userns_ok() {
  bwrap --unshare-user --ro-bind /usr /usr true 2>/dev/null
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
  # dir (objects, refs) to do anything. Resolve it absolute so the bind target is stable.
  gitdir=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)

  HGT_SANDBOX_ARGV=(
    bwrap
    --die-with-parent          # jail dies if hgt/the pane does — no orphaned confined process
    --unshare-all --share-net  # own ns for everything EXCEPT net (agent needs Anthropic + remote)
    --clearenv                 # start empty; re-add only the curated allowlist below
    --ro-bind /usr /usr
    --ro-bind-try /bin /bin --ro-bind-try /sbin /sbin
    --ro-bind-try /lib /lib --ro-bind-try /lib64 /lib64
    --ro-bind /etc /etc
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
    --setenv GIT_CONFIG_COUNT 1
    --setenv GIT_CONFIG_KEY_0 commit.gpgsign
    --setenv GIT_CONFIG_VALUE_0 false
  )
}
