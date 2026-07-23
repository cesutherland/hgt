# ADR 0005 — Issue #67: sandbox the Claude session `hgt work` spawns

- **Status:** accepted
- **Date:** 2026-07-22
- **Context:** Local execution runs Claude Code with full access to the machine — `$HOME`,
  `~/.ssh`, the admin `gh` auth, sibling repos, arbitrary FS — while `hgt work` reads the
  live, unnormalized issue body (spec §5: no `ready` snapshot locally). So a prompt
  injection executes against the laptop. §3's "poor and powerless" was a property of the
  disposable Actions runner; running locally throws it away. This is the *blast-radius*
  defense (confine the actor), complementary to the input-side normalize+snapshot boundary
  (#39/#40/#41).

## Decision

Wrap **only the `claude` process** in a [bubblewrap](https://github.com/containers/bubblewrap)
(`bwrap`) filesystem jail. tmux, and the human's shell pane, stay on the host.

**Why wrap-claude-only.** The hard requirement is that `tmux attach` — "shell in if it gets
dicey" — keeps working. If claude is the only thing jailed, the tmux server and both panes
live on the host unchanged: `tmux attach` is untouched, and the right-hand shell pane is a
full host shell in the worktree — exactly the human intervention escape hatch we want
*outside* the jail (it's Carl's shell, not the agent's). The agent (claude, left pane) is the
only thing confined. A container would jail the whole session and force tmux-in-container
ergonomics; bwrap sidesteps that entirely.

**Why bwrap over the other candidates.** Lightest OS-level option, strong FS isolation, no
daemon. A container (podman/docker) is stronger but heavier and drags in the tmux problem
above; podman isn't installed and docker needs `carl` in the `docker` group (≈ root — a poor
trade for a *security* feature). A low-priv unix user shares the FS namespace (weaker). Claude
Code's own permission mode is tool-level, not OS-level — a complement, not a substitute.

**The jail (what the agent can reach).**

- **rw:** the issue's worktree, and the repo's shared `.git` common dir (a worktree's `.git`
  is a pointer into `<main-repo>/.git/worktrees/<name>`, so git needs the common dir to
  function — commit, log, push).
- **ro:** system dirs (`/usr`, `/etc`, `/bin`…), the git identity (`~/.gitconfig[.local]` —
  name/email, not a credential), and the claude runtime, which lives under `$HOME` on this box
  (`~/.nvm` for node, `~/.local` for the launcher). These are re-bound over the tmpfs below.
- **rw, unavoidable:** `~/.claude` + `~/.claude.json` — claude's own state and the Anthropic
  credential it must have to call the API. See residuals.
- **tmpfs (gone):** the rest of `$HOME`. This is the security property, by construction —
  anything not re-bound simply isn't in the jail: `~/.ssh`, `~/.config/gh` (admin `gh` auth),
  `~/.npmrc`, `~/.gnupg`, sibling repos, arbitrary FS.
- **env:** `--clearenv` then a curated allowlist (`HOME`, `PATH`, `TERM`, `LANG`/`LC_*`), so
  secrets exported in Carl's shell (`GH_TOKEN`, cloud creds…) don't leak in via the
  environment. gpg-signing is forced off inside the jail (`commit.gpgsign=false`) — the agent
  has no `~/.gnupg`, so it can't sign as Carl, and its commits are unsigned by design; the
  human's own commits (review, merge) stay signed on the host.

This satisfies the acceptance criteria structurally: the agent can't read `~/.ssh` or anything
outside the worktree (not mounted), and can't act as admin `gh` (no `~/.config/gh`, no
`~/.ssh`). A **scoped** push credential is an opt-in seam (`HGT_SANDBOX_GITHUB_TOKEN` →
`GITHUB_TOKEN` inside), not yet provisioned — see residuals.

**Parity (#17).** The jail is a shared seam (`lib/sandbox.sh::sandbox_argv`) that
`launch_session` prefixes onto the claude invocation on both the inline and tmux paths. The
future local-listener executor reuses the same seam — identical confinement, attended or not.

**Fail closed.** Sandbox is the default and mandatory: `launch_session` preflights bwrap and
dies with exact remediation if it can't jail (missing bwrap, or unprivileged userns blocked).
`--no-sandbox` / `HGT_NO_SANDBOX=1` is the explicit, warned opt-out. A security feature that
silently no-ops is worse than none.

## The AppArmor enable (one-time, requires root)

Ubuntu 24.04+ restricts unprivileged user namespaces
(`kernel.apparmor_restrict_unprivileged_userns=1`) and ships bwrap **not** setuid, so bwrap
can't create its namespace until an AppArmor profile grants it `userns` — the same mechanism
every browser and container tool on the box already uses (`/etc/apparmor.d/{chrome,firefox,crun,buildah}`).
`templates/apparmor/bwrap` is that profile. Install once:

```sh
sudo install -m644 templates/apparmor/bwrap /etc/apparmor.d/bwrap
sudo apparmor_parser -r /etc/apparmor.d/bwrap
```

The preflight prints these commands verbatim when the jail can't start.

## Consequences / residuals

- **Live validation is deferred to the profile install.** bwrap can't create a userns on this
  box until the AppArmor profile lands (root, password-gated), so this slice is validated by
  construction + shim conformance tests (the argv hgt emits), not by running claude jailed.
  Carl validates AC #1/#2 live the first time he installs the profile and runs `hgt work`.
- **`~/.claude` rw is an escape vector, not just a confidentiality leak (#73, next slice).**
  Claude Code executes hooks/settings from user-level `~/.claude/settings.json`. Binding that
  dir **writable** lets a prompt-injected agent write a malicious hook that then runs
  **unsandboxed on the host** the next time Carl launches Claude — a write-back that round-trips
  straight out of the jail with full privileges. (The confidentiality angle — global MCP config,
  cross-project history — is the lesser half.) Fix: a dedicated minimal config home
  (`CLAUDE_CONFIG_DIR`) that carries only the credential and no host settings/hooks. Bumped from
  "someday" to the next slice.
- **A readable credential + unfiltered egress exfiltrates (#74).** `~/.claude.json` is bound
  readable and `--share-net` gives the full host network (the agent needs the Anthropic API + the
  git remote). Individually tolerable; **together** an injected agent can steal the Anthropic
  token — and the whole worktree — to any host. So AC #2 holds *structurally* (no admin `gh`), but
  "reach **only** a scoped credential/network" does not until egress is constrained (proxy or
  netns+nftables). Prioritized alongside #73 — the two are the escape+exfil pair.
- **Scoped push token not provisioned.** The `HGT_SANDBOX_GITHUB_TOKEN` seam exists but no
  machine-user PAT is wired yet, so pushes from inside the jail fail closed until one is. That
  provisioning is its own slice.
- **Bind set is machine-specific** (nvm version, install layout). Overridable via
  `HGT_SANDBOX_RO_BIND` (extra ro paths) and `HGT_SANDBOX_SETENV` (extra env passthrough) so
  dogfooding friction is a config change, not a code change.
