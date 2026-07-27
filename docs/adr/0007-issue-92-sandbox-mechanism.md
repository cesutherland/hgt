# ADR 0007 — Issue #92: adopt `@anthropic-ai/sandbox-runtime` as the sandbox mechanism

- **Status:** accepted
- **Date:** 2026-07-26
- **Supersedes:** ADR 0005's **mechanism** (the hand-rolled `bwrap` argv in `lib/sandbox.sh`).
  ADR 0005's threat model, its wrap-claude-only constraint, and its fail-closed posture all
  stand — this changes *what builds the jail*, not *what the jail is for*.
- **Context:** #92 asked whether `@anthropic-ai/sandbox-runtime` (SRT) should be #67's
  mechanism. It was filed before #67 shipped, so the question is now retrospective: we have a
  hand-rolled bwrap jail (ADR 0005) and a hand-rolled egress allowlist in flight (#74, PR #90).
  Reviewing PR #90 forced the issue — it reimplements, in ~470 lines of bash + Python + an
  nftables ruleset, a thing Anthropic ships as a supported package.

## Verdict (#92's deliverable)

- **Does SRT satisfy #67's confinement + tmux-attach + identity isolation on Linux?** Yes on
  confinement and tmux. `srt <cmd>` wraps a single arbitrary process using the same bubblewrap
  primitives ADR 0005 chose by hand, so the "wrap only `claude`, leave tmux and the human's
  pane on the host" requirement is met unchanged — it is a command prefix, same seam. Identity
  isolation is *partial*: SRT inherits the caller's full environment and offers only a
  named-variable denylist, so hgt keeps owning `--clearenv`'s job (see residuals).
- **Does it also cover #74?** Yes, and better than PR #90 does. One tool, both halves.
- **Maturity/dependency risk?** Real but acceptable: `0.0.67`, Apache-2.0, published
  2026-07-23, four runtime deps. Pre-1.0 with an explicit "configuration formats may evolve"
  warning. Pin the version; the fallback (below) is cheap.
- **Recommendation:** adopt. Close PR #90 unmerged.

## Decision

Replace hgt's hand-built bwrap argv with a pinned `@anthropic-ai/sandbox-runtime` invocation
plus a generated settings file, covering **both** #67 (filesystem) and #74 (egress).

```sh
srt --settings <worktree>/.hgt/srt.json claude -n 'hgt/5-add-widget' '<prompt>'
```

```json
{
  "network":    { "allowedDomains": ["api.anthropic.com", "github.com"] },
  "filesystem": {
    "denyRead":   ["~/"],
    "allowRead":  ["~/.nvm", "~/.local", "~/.gitconfig"],
    "allowWrite": ["<worktree>", "<git-common-dir>", "~/.claude", "~/.claude.json", "/tmp"]
  }
}
```

`sandbox_argv` stops assembling thirty-odd bwrap flags and starts writing this file. The
allowlist derivation (Anthropic API + the worktree's git remote) is the one piece of PR #90
worth keeping.

**The decision that actually matters is `--share-net` vs `--unshare-net`.** PR #90 keeps the
host network namespace and therefore needs a cgroup scope plus a host nftables install to stop
the agent ignoring `HTTPS_PROXY` and opening a raw socket. SRT drops the namespace and
forwards loopback to its proxy over a unix socket, so a program that bypasses the proxy env
vars gets **no network at all** rather than an unfiltered one. Fail-closed by construction,
with no host firewall to install, no `systemd-run --scope`, and no polkit dependency. That
single architectural difference deletes the entire enforcement layer PR #90 was building.

## Why not the alternatives

| Option | Boundary | Why not |
| --- | --- | --- |
| **Build here** (PR #90) | bwrap `--share-net` + own proxy + nftables/cgroup | Most code, most host setup, and the only option with a silent fail-open mode (see below) |
| **DIY-lite** | own bwrap `--unshare-net` + `socat` → tinyproxy/squid | SRT's architecture, our maintenance. The documented fallback if SRT's pre-1.0 config churns |
| **Firejail** | own netns + `--netfilter=<iptables-save>` | setuid-root binary with a CVE history; `--net` needs veth/root; filtering is IP-based, and the Anthropic API and GitHub sit behind rotating CDN addresses |
| **Anthropic devcontainer** + `init-firewall.sh` | Docker, default-deny iptables + ipset | Needs Docker — ADR 0005 already rejected putting `carl` in the `docker` group (≈ root) as a poor trade for a security feature — and jails the whole session, breaking `tmux attach` into a host pane beside the agent |
| **Third-party agent sandboxes** (agentbox, ClaudeBox, Docker Sandboxes, iron-proxy) | container-shaped | Same objections as the devcontainer. `iron-proxy` is a useful proxy *component*, not a boundary |
| **systemd `IPAddressDeny=any`** | per-unit eBPF | Not a substitute: IP-based, same CDN problem. Only a belt under a proxy |
| **Claude Code's built-in `/sandbox`** | Bash subprocesses only | MCP servers, hooks, and file tools run unconstrained on the host. A near-free second layer, not the boundary |
| **VM / Claude Code on the web** | full OS | Out of scope for Phase 0 local execution |

ADR 0005's wrap-claude-only constraint eliminates every container option in one stroke, and
SRT is the only shipped product that wraps a *single arbitrary process* with both filesystem
and hostname-based egress control. There is no third contender.

## What PR #90 got wrong, and why that's evidence

The review found the mechanism unvalidated in a way that argues for buying rather than
building. `systemd-run` defaults to `--system`, which needs polkit auth on every launch; the
obvious fix — adding `--user` — moves the scope to
`/user.slice/user-1000.slice/user@1000.service/hgt-sandbox.slice/…`, so the ruleset's
`socket cgroupv2 level 1 "hgt-sandbox.slice"` match silently stops matching and the jail runs
unfiltered with the preflight still green. A security control with a silent fail-open mode is
worse than the residual it closes. Separately, `/etc/nftables.d` is not included by Ubuntu's
default `nftables.conf`, so the rule does not survive a reboot while the file-existence
preflight keeps reporting "installed."

That is not a criticism of the author so much as a measure of the surface: this is a lot of
load-bearing systems plumbing to own for a Phase 0 harness whose actual product is issue-driven
development.

## What this deletes

`templates/egress-proxy.py`, `templates/nftables/hgt-egress.nft`, the `systemd-run` scope
wrapper, the egress pidfile lifecycle, the nftables preflight, and most of `sandbox_argv`'s
bind list. Net host setup *decreases*: `socat` and `ripgrep` become dependencies, the nftables
install goes away, and the Ubuntu AppArmor `bwrap` profile is still required (SRT uses
bubblewrap too), so #72 survives unchanged.

(In the event none of those files needed deleting: they only ever existed on PR #90's branch,
which was closed unmerged. Implementing #95 was purely additive on `lib/sandbox.sh`.)

## Amendment — implementation notes (#95)

Measured against 0.0.67 while implementing, since several decisions below were contingent on
behaviour the spike could only guess at. Re-run these when the pin moves.

- **The env really is inherited.** A `GH_TOKEN` exported in the calling shell shows up
  unmodified inside the jail. There is no default `unsetEnvVars` denylist — it is `?? []`
  throughout — so `credentials.envVars` drops only what you name. `env -i` is therefore load-
  bearing, not belt-and-braces. Confirmed both ways: same run under `env -i`, `GH_TOKEN` unset.
  It also means SRT ships no surprise denial of `GITHUB_TOKEN`, so #81's push path survives.
- **`denyRead` surfaces as `ENOENT`, not `EACCES`.** A denied file reads as "No such file or
  directory". Git and friends shrug at a missing optional config rather than fataling, so the
  blanket `denyRead: [$HOME]` doesn't need per-tool exceptions to avoid hard failures.
- **`socket(AF_UNIX)` is blocked by seccomp** (`EPERM`). This matters more than it looks:
  `--unshare-net` does *not* isolate unix sockets, and an agent that reaches the host's tmux
  control socket can `send-keys` into the human's other panes — unconfined host execution, which
  would defeat the entire slice. SRT closes it structurally. But the README says the block
  *fails open with a warning* when seccomp is unavailable, so `lib/sandbox.sh` also names
  `/tmp/tmux-<uid>` and `/run/user/<uid>` in `denyRead`. Belt and braces, cheap.
- **The arg quoter is a correct POSIX single-quoter** (`src/utils/shell-quote.ts`), so #25's
  prompt — `'`, `$`, backtick, literal newline — survives SRT's re-quote for its own `bash -c`
  byte-for-byte. Had it been the backslash style, `\`+newline would be a line continuation and
  the newline would vanish. The conformance suite cannot catch this (its `srt` shim just
  `exec`s), which is the sharpest argument for enforcing the pin rather than warning about it.
- **`srt --version` is useless**: it prints `process.env.npm_package_version || '1.0.0'`, so
  outside an npm lifecycle script it always says `1.0.0`. The pin check resolves the bin through
  its symlink and walks up to the package manifest instead.
- **Proxy variables are set in both cases** (`HTTPS_PROXY` and `https_proxy`, `ALL_PROXY` and
  `all_proxy`), so curl's deliberate lowercase-only handling of `http_proxy` isn't a problem.
- **The allowlist enforces.** An unlisted host fails to connect; `api.anthropic.com` returns
  its normal 401. `strictAllowlist: true` is set so an unlisted host is denied outright instead
  of being referred to an ask-callback, which in a detached tmux pane would hang or auto-allow.

Two decisions departed from the sketch in the Decision section:

- **`allowWrite` does not include `/tmp`.** That would hand the agent write access to the tmux
  control socket. `TMPDIR` points at a private dir inside the worktree instead. `/tmp` stays
  *readable* — SRT stages its own proxy socket there when `XDG_RUNTIME_DIR` is unset, which
  `env -i` guarantees.
- **The settings file is `<worktree>/.hgt/srt.json` as planned, but is rewritten unconditionally
  every launch and listed in its own `denyWrite`.** It sits inside the agent's own write grant,
  so a never-clobber write would let a tampered policy survive to the next launch. A stamped
  `.hgt/.gitignore` keeps it and the scratch dir out of `git status` — without that, every
  worktree reads as dirty and `hgt work rm` refuses to tear it down, permanently.

## Consequences / residuals

- **Pre-1.0 dependency.** `0.0.67`, "research preview," config format may evolve. Pin an exact
  version; treat an upgrade as a change that re-runs the conformance suite. The DIY-lite
  fallback above stays documented precisely so this is reversible.
- **SRT's env controls are a denylist; ADR 0005's were an allowlist.** SRT never emits
  `--clearenv`, so the sandboxed child **inherits the full environment of whatever invoked
  `srt`** (`dist/sandbox/linux-sandbox-utils.js`: "composes against the child's actual starting
  env — `process.env` inherited, `unsetEnvVars` dropped, `setEnvVars` overlaid"). It does have a
  `credentials.envVars` settings key, with `deny` (→ bwrap `--unsetenv`) and `mask` modes — but
  you must name each variable. ADR 0005 cleared everything and named the survivors, which is
  strictly stronger: you cannot forget to deny a variable you never knew was exported. hgt keeps
  owning this — invoke `srt` from an `env -i` baseline carrying only `_SANDBOX_ENV_PASS`.
- **`credentials.envVars` `mask` mode is worth revisiting for #81.** The jail sees a per-session
  sentinel; SRT's proxy substitutes the real value on egress to declared `injectHosts`. That is
  a better shape for the scoped push PAT than handing the jail a live token — it needs
  `network.tlsTerminate`, so it's a later slice, not this one.
- **Filesystem reads default to allowed.** ADR 0005's tmpfs-`$HOME` is deny-by-default on
  reads. Preserving that property requires explicit `denyRead: ["~/"]` plus `allowRead`
  entries, and Linux SRT takes **literal paths only — no globs**. Config, not code, but it must
  be got right or the jail is quietly more permissive than the one it replaces.
- **Domain fronting is unsolved, here and everywhere.** SRT allowlists on the client-supplied
  hostname without inspecting TLS — identical to PR #90's proxy. Allowing `github.com` still
  leaves a general-purpose exfiltration channel; what keeps that honest is the jail holding no
  admin `gh` credential (ADR 0005), not the allowlist. `network.tlsTerminate` exists but is
  experimental and buys inspection, not filtering.
- **The `~/.claude.json` credential is still readable** (ADR 0005's residual, unchanged) and
  `~/.claude` still needs write access, so **#73 stands** — a minimal `CLAUDE_CONFIG_DIR` is
  still its own slice, now expressed as `allowWrite` entries rather than bwrap binds.
- **#75 changes shape.** Confining the `.git` bind becomes an `allowWrite`/`denyWrite` pair
  instead of selective bwrap re-binds — likely simpler, still its own slice.
- **`git push -u` does not work in the jail**, nor does `gh pr create`'s fork disambiguation:
  both write `.git/config`, and `allowGitConfig` stays `false`. That is deliberate, not an
  oversight — `.git/config` lives in the *shared* common dir, so `core.pager` / `core.hooksPath`
  written by the jailed agent would execute on the **host** the next time the human runs git in
  that repo. `git push origin HEAD` is the workaround. `config.worktree` gets an explicit
  `denyWrite` because it is *not* in SRT's mandatory list and would reopen the same door.
- **ssh remotes are unreachable.** `--unshare-net` plus a CONNECT proxy means ssh cannot work at
  all, so `git@…` is rewritten to https unconditionally (not only when a push token is present) —
  otherwise a token-less jail has *zero* remote access and even `git fetch` hangs rather than
  failing. Anonymous https fetch works for a public repo; a private one fails with a legible
  auth error.
- **`~/.cache` and `~/.npm` are unreadable and unwritable**, so in-jail `npm install` / `npx`
  will need `HGT_SANDBOX_RO_BIND` entries. Expected first friction on a live run; a config
  change, not code.
- **The PAT reaches SRT's own host-side proxy process.** The payload is sourced before `exec
  srt`, so the proxy inherits `GITHUB_TOKEN` too. Same uid, same user, so it grants nothing the
  caller didn't already have — but it is a wider blast radius than `bwrap --args` had, and the
  `credentials.envVars` `mask` mode above is the eventual fix.
- **`env -i` is an approximation of `--clearenv`, not an equivalent.** The pane's dash re-adds
  `PWD` on the way through, and SRT overlays its proxy variables. Neither carries anything the
  agent didn't already know.
- **IPv6 remote URLs mis-parse.** `https://[2001:db8::1]:443/x.git` yields `[2001`, which SRT
  rejects as a domain pattern. Nobody has one; documented rather than handled.
- **Live validation is partial.** The static and single-command behaviours above are measured
  (see the amendment). What still needs a real `hgt work` run: whether claude's TUI gets a
  usable pty through SRT's `bash -c` spawn, whether the jail dies with its parent the way
  `--die-with-parent` guaranteed, and which hosts beyond `api.anthropic.com` claude actually
  needs (statsig/sentry telemetry, OAuth refresh) before `HGT_SANDBOX_EGRESS_ALLOW` stops being
  necessary.
- **ADR numbering:** PR #90 authored its ADR as 0006, which was already taken by the
  review-response skill (#19, merged in PR #91). This is 0007.
