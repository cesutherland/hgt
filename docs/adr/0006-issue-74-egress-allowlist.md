# ADR 0006 — Issue #74: egress allowlist for the jail

- **Status:** accepted
- **Date:** 2026-07-24
- **Context:** ADR 0005 (#67) jailed the Claude session's filesystem but left two residuals that
  *combine* into a real exfiltration path: `~/.claude.json` (the Anthropic credential) is bound
  **readable**, and `--share-net` gives the jail the full host network, unfiltered. A
  prompt-injected agent can read the token it's handed and phone it — plus the whole worktree —
  to any host on the internet. AC #2's "can't act as admin `gh`" still holds structurally (no
  `~/.config/gh`, no `~/.ssh`), but "reach **only** a scoped credential/network" doesn't, until
  egress is constrained. This ticket is the exfil half of the escape+exfil pair with #73.

## Decision

Keep `--share-net` (the jail still shares the host's network namespace — simplest path to
loopback), but make it non-blanket two ways:

1. **A local CONNECT-only allowlisting proxy** (`templates/egress-proxy.py`, stdlib Python, no
   deps) that every proxy-aware tool in the jail is pinned to via `HTTPS_PROXY`/`HTTP_PROXY`. It
   never terminates TLS — it reads the plaintext `CONNECT host:port` line, checks `host` against
   an allowlist (the Anthropic API + the worktree's git remote, extendable via
   `HGT_SANDBOX_EGRESS_ALLOW`), then splices raw bytes end-to-end. It runs on the **host**, never
   inside the jail, and does its own DNS resolution — the jail never needs to resolve a name
   itself.
2. **A dedicated cgroup, confined by a one-time nftables install.** Sharing the netns is not
   enough by itself: a prompt-injected agent can just ignore `HTTPS_PROXY` and open a raw socket.
   So every jailed `bwrap` runs inside its own scope under `hgt-sandbox.slice`
   (`systemd-run --slice=hgt-sandbox --scope`), and a host-installed nftables rule
   (`templates/nftables/hgt-egress.nft`) DROPs all egress from that slice except to the proxy's
   loopback port. This is what makes the allowlist real rather than advisory: the confined
   process is "root" inside its own bwrap-created user+mount namespaces, but it was never a
   member of the *host's* pre-existing network namespace's privileged operations — it can't
   reach or modify a firewall rule scoped to a cgroup it doesn't control.

`sandbox_preflight` fails closed (same posture as the AppArmor check) if the nftables rule isn't
installed — printing the exact `sudo install` + `sudo nft -f` remediation, mirroring ADR 0005's
AppArmor two-liner.

## Why this over the alternatives

**Why not a dedicated net namespace (`--unshare-net` + slirp4netns/pasta)?** True isolation would
be stronger in principle, but a userspace NAT gateway (slirp4netns, pasta) gives the guest a full,
*unfiltered* virtual internet connection by design — it solves connectivity, not filtering. Egress
control still has to live somewhere the confined process can't reach, which for a namespace bwrap
itself creates means either (a) firewalling from *outside* that namespace (the veth's host-side
end) or (b) dropping CAP_NET_ADMIN before exec after configuring rules inside it. Both are real
mechanisms, but (a) needs privileged veth setup in the host's root netns (the docker-group
problem ADR 0005 already rejected, just relocated) and (b) needs a capsh/setpriv choreography
around bwrap that can't be smoke-tested without a live bwrap on this box (still blocked on the
AppArmor profile install). The cgroup+nftables design gets the same "the confined process cannot
touch its own leash" property without either — it's enforced by the *host's* original network
namespace, which an unprivileged user namespace has no capability over, full stop.

**Why a proxy instead of pure IP allowlisting?** nftables matches addresses, and the Anthropic
API / GitHub sit behind CDNs with IPs that rotate. A hostname-based CONNECT proxy is the stable
allowlist; nftables' job shrinks to "can this cgroup reach the proxy," which never changes.

**Why keep `--share-net` at all, given the issue asks to replace the "blanket" grant?** The
*blanket* part — unfiltered reachability — is what's actually removed; the flag name is
incidental. Swapping to `--unshare-net` would mean re-deriving loopback reachability to the proxy
through a veth/slirp bridge anyway (see above), for no isolation gain once the cgroup+nftables
layer is the real enforcement point.

## Consequences / residuals

- **Live validation is deferred**, same as ADR 0005: this box can't create a bwrap userns until
  the AppArmor profile lands, so neither jail could be run end-to-end this slice. Validated by
  construction + shimmed conformance tests (`systemd-run`/`python3` as exported bash functions in
  `test/helper.bash`, not dedicated PATH-shim files — the sandboxed environment this was authored
  in couldn't `chmod +x` a new file, so a function-based stand-in was the available equivalent;
  a future slice can graduate them to real files if that constraint doesn't hold elsewhere).
- **nftables preflight is a file-existence check, not a live ruleset probe** (unlike
  `_sandbox_userns_ok`'s real bwrap probe). Reading nft state needs the same privilege the
  ruleset itself is gating, so this catches "never installed," not "installed, then flushed."
- **SSH git remotes aren't proxied.** The CONNECT proxy speaks HTTP; an `ssh://`/`git@` remote's
  host is still added to the allowlist for completeness, but a push over it hits the nft DROP,
  not the proxy — it'll hang, not silently succeed unfiltered. HTTPS remotes (the `gh`/HTTPS
  default) are the supported case.
- **The proxy's allowlist is fixed at first start.** It's a singleton on `HGT_SANDBOX_EGRESS_PORT`
  (default 8874), reused across sessions so a resumed tmux session's jail still has a live proxy.
  A second repo with a different git remote host won't reach it until the proxy is restarted
  (kill the pid file's process, or set `HGT_SANDBOX_EGRESS_ALLOW` up front). Dynamic reload is a
  follow-up, not this slice.
- **`systemd-run --scope` assumes a systemd user session that can create transient units**,
  which typically works out of the box for an active local session but may hit a polkit "not the
  active session" wall over bare SSH. `--no-sandbox` remains the documented escape hatch (loud,
  unconfined — ADR 0005/0006), not a silent fallback.
- **The `~/.claude.json` credential itself is still readable** (ADR 0005's other residual,
  unchanged) — this ticket caps *where the bytes can go*, per its own non-goals; it doesn't make
  the credential itself unreadable (a scoped machine-user PAT is its own slice).
- **Port collisions**: the nftables rule's dport is fixed at install time (8874). Overriding
  `HGT_SANDBOX_EGRESS_PORT` requires editing and re-installing the `.nft` file too — noted in the
  template's own header.
