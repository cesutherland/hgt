# session.sh — the paired-pane session launcher shared by `hgt work` (#8/#67) and `hgt respond`
# (#84): a sandboxed agent pane (left) confined to a worktree, plus a privileged, unconfined
# human shell pane (right) for "shell in if it gets dicey" intervention. Factored here because
# #84 needs byte-identical confinement + layout to `hgt work` (#17 parity), not a reimplementation.
#
# Everything below is keyed by a caller-chosen string KEY (an issue number for `work`, `pr-<n>`
# for `respond`) — nothing here assumes "issue." Callers own what KEY means and how they title
# the session; this file owns the worktree path convention, the sandbox jail, and the tmux layout.

# _repo_root — the MAIN worktree's root, from any worktree or the main checkout. NOT
# --show-toplevel: that returns the *current* worktree's root, so from inside `<base>/<key>`
# every sibling path mis-derives (issue #65). The shared .git is the one path that's stable
# everywhere; the main root is its dirname. Prints to stdout.
_repo_root() {
  dirname "$(git rev-parse --path-format=absolute --git-common-dir)"
}

# _worktree_base — the parent dir that holds all session worktrees. Override with
# HGT_WORKTREE_DIR (the tests point this inside their tmpdir). Default is a sibling of the repo,
# `../<repo>-worktrees`, so worktrees live outside the repo (no .gitignore entry).
_worktree_base() {
  if [ -n "${HGT_WORKTREE_DIR:-}" ]; then
    printf '%s' "$HGT_WORKTREE_DIR"
  else
    local root; root=$(_repo_root)
    printf '%s/%s-worktrees' "$(dirname "$root")" "$(basename "$root")"
  fi
}

# _worktree_path KEY SLUG — the worktree path for KEY, `<base>/<key>-<slug>` (issue #36). The
# slug rides along for human readability; KEY is the stable join key. Used at *create*, where
# the slug is in hand. Prints to stdout.
_worktree_path() { printf '%s/%s-%s' "$(_worktree_base)" "$1" "$2"; }

# _find_worktree KEY — the existing worktree dir for KEY, found by globbing `<base>/<key>-*`,
# empty if none. This is how resume + teardown recover the (drift-carrying) slug from KEY alone:
# the worktree dir is the durable, KEY-keyed artifact, so no title lookup is needed and a
# retitled issue/PR still resolves to its original dir. Prints the first match to stdout.
_find_worktree() {
  local key="$1" base d
  base=$(_worktree_base)
  for d in "$base/$key"-*; do
    [ -d "$d" ] && { printf '%s' "$d"; return 0; }
  done
  return 0  # no match: print nothing, succeed (an unmatched glob must not trip set -e)
}

# _slug_of KEY WT — recover the slug from a worktree dir path `<base>/<key>-<slug>` (strip the
# `<key>-` prefix off the basename). The dir is the source of truth, so the slug survives a
# retitle. Prints to stdout.
_slug_of() { local base; base="${2##*/}"; printf '%s' "${base#"$1"-}"; }

# _repo_slug — the repo label that namespaces sessions (`<repo>/...`). Slugified so it's safe in
# a tmux session name (tmux forbids `.`/`:`, which a repo dir like `my.tool` could carry).
# Overridable via HGT_REPO_NAME (the hermetic suite usually sets it). Defaults off _repo_root,
# not --show-toplevel: from inside a worktree the toplevel is `<key>-<slug>`, not the repo (#65).
_repo_slug() {
  local name; name="${HGT_REPO_NAME:-$(basename "$(_repo_root)")}"
  slugify "$name"
}

# _session_name KEY WT — the human-readable session id `<repo>/<key>-<slug>` (issue #36),
# derived wholly from KEY and the worktree dir. It's the join key across tmux create/attach/
# resume, tmux kill, and `claude --resume`. The slug is a cosmetic suffix recovered from the
# worktree dir (the durable, KEY-keyed artifact), so create and teardown reconstruct the *same*
# name from KEY alone — no title lookup, and no create-vs-kill drift by construction. Prints to
# stdout.
_session_name() {
  printf '%s/%s-%s' "$(_repo_slug)" "$1" "$(_slug_of "$1" "$2")"
}

# _carry_worktree_includes WT — copy the files named in ./.worktreeinclude (e.g. .env) into
# the new worktree. `git worktree add` doesn't carry git-ignored files, so this is what makes
# that scaffolded file mean something. Patterns are globbed against the repo's working tree.
_carry_worktree_includes() {
  local wt="$1" pattern f
  [ -f .worktreeinclude ] || return 0
  while IFS= read -r pattern; do
    case "$pattern" in '' | '#'*) continue ;; esac
    for f in $pattern; do
      [ -e "$f" ] || continue
      mkdir -p "$wt/$(dirname "$f")"
      cp -a "$f" "$wt/$f"
      info "  carry  $f -> worktree"
    done
  done <.worktreeinclude
}

# session_teardown CMD NOUN N KEY WTPATH FORCE — shared teardown for `hgt work rm` / `hgt
# respond rm`: refuse dirty/unpushed work without FORCE (git is the durable state — losing it
# needs an explicit opt-in), kill the tmux session if one is live, then remove the worktree.
# CMD/NOUN are only for messages (e.g. "work"/"issue" vs "respond"/"PR"); KEY rebuilds the tmux
# session name the same way create did.
session_teardown() {
  local cmd="$1" noun="$2" n="$3" key="$4" wtpath="$5" force="$6"

  # Fail closed: no `|| true`. If git errors here (corrupt worktree, bad path) let set -e
  # abort, rather than read an empty result as "clean" and delete the worktree. Note: porcelain
  # also lists carried .worktreeinclude files when they aren't gitignored, so those read as
  # dirty — expected, since such files are typically .env-class.
  if [ "$force" -ne 1 ]; then
    local dirty unpushed
    dirty=$(git -C "$wtpath" status --porcelain)
    # HEAD, not --branches: worktrees share one .git, so --branches would also count unpushed
    # commits on unrelated branches and refuse to remove a fully-pushed worktree.
    unpushed=$(git -C "$wtpath" log HEAD --not --remotes --oneline)
    if [ -n "$dirty" ] || [ -n "$unpushed" ]; then
      die "hgt $cmd rm: $noun $n has uncommitted or unpushed work — rerun with --force to discard"
    fi
  fi

  # Kill the tmux session before the worktree it's rooted in disappears: ordering kill-session
  # ahead of `git worktree remove` keeps a live detached claude from ending up with a deleted
  # cwd, and stops a failing remove from stranding the session. Guard on has-session so an
  # inline (--no-tmux) or already-dead run doesn't error.
  local name; name=$(_session_name "$key" "$wtpath")
  if tmux has-session -t "$name" 2>/dev/null; then
    run tmux kill-session -t "$name"
  fi

  if [ "$force" -eq 1 ]; then
    run git worktree remove --force "$wtpath"
  else
    run git worktree remove "$wtpath"
  fi

  info "removed worktree for $noun $n (branch left intact)"
}

# _shq STRING — single-quote STRING so the pane's shell (/bin/sh is dash) re-reads it as one
# literal word. tmux send-keys types the command into that shell, which then parses it: wrap in
# '...' and rewrite every embedded ' as '\'' (close-quote, backslash-escaped literal quote,
# reopen-quote). This is the only quoting dash honors — it has no bash $'...' — so ', $, `, and
# newlines all survive verbatim (issue #25). Prints to stdout, no trailing newline.
_shq() {
  local s=${1//\'/\'\\\'\'}
  printf "'%s'" "$s"
}

# _prepare_sandbox WT — build the confinement prefix for a claude launch in worktree WT (#67).
# Enabled (default): preflight bwrap and fail closed, then set HGT_SANDBOX_ARGV (a real argv, for
# the inline path) and _SANDBOX_SQ (the same _shq-quoted with a trailing space, for the send-keys
# string). Disabled (--no-sandbox / HGT_NO_SANDBOX=1): warn loudly and leave both empty, so the
# unconfined launch matches the pre-#67 behavior byte-for-byte.
_prepare_sandbox() {
  local wt="$1" a
  HGT_SANDBOX_ARGV=()
  _SANDBOX_SQ=""
  if ! sandbox_enabled; then
    warn "sandbox: disabled — launching the agent UNCONFINED (full FS + credential access, #67)"
    return 0
  fi
  sandbox_preflight
  sandbox_argv "$wt"
  for a in "${HGT_SANDBOX_ARGV[@]}"; do _SANDBOX_SQ+="$(_shq "$a") "; done
}

# _tmux_attach NAME — join session NAME without nesting. Inside tmux ($TMUX set) you can't
# attach (tmux refuses), so switch the current client instead; otherwise attach fresh.
# Attaching is best-effort: the detached session is the durable artifact, so a headless/non-tty
# caller (where attach fails "open terminal failed") must not abort hgt under set -e when the
# session is alive and reattachable — warn how to reach it and move on.
_tmux_attach() {
  local name="$1"
  if [ -n "${TMUX:-}" ]; then
    run tmux switch-client -t "$name" || warn "couldn't switch to tmux session $name (attach manually: tmux attach -t $name)"
  else
    run tmux attach-session -t "$name" || warn "couldn't attach tmux session $name (attach manually: tmux attach -t $name)"
  fi
}

# launch_paired_session NAME WT PROMPT [USE_TMUX] — the launcher seam (spec §4/§5, #67, #84).
# Default (USE_TMUX=1): run the named claude session inside a *detached* tmux session NAME, then
# attach/switch to it. The detached session outlives your terminal, so crash-recovery becomes
# "reattach if it's alive, else recreate" instead of "relaunch from scratch" (ADR 0003). Resume
# reuses a live session rather than spawning a second. USE_TMUX=0 launches inline instead (no
# tmux, no privileged shell pane) — used by --no-tmux and tests.
#
# Sandbox seam (#67, ADR 0005): confine claude to the worktree. _prepare_sandbox preflights (fail
# closed) and populates HGT_SANDBOX_ARGV (the bwrap prefix) + _SANDBOX_SQ (the same, _shq-quoted,
# for the send-keys string the pane shell re-parses). Both are empty when --no-sandbox /
# HGT_NO_SANDBOX=1 opts out, so the unconfined launch is byte-identical to pre-#67. Called only on
# the paths that actually spawn claude — a resume reattaches an already-jailed session, so it
# neither preflights nor rebuilds the prefix.
launch_paired_session() {
  local name="$1" wt="$2" prompt="$3" use_tmux="${4:-1}"

  if [ "$use_tmux" -eq 0 ]; then
    _prepare_sandbox "$wt"
    # Expanding an empty HGT_SANDBOX_ARGV (--no-sandbox) under set -u is safe on bash 4.4+ (the
    # target; Kubuntu ships 5.x) — it'd trip on 3.2/4.3 if hgt ever claims broader portability.
    (cd "$wt" && run "${HGT_SANDBOX_ARGV[@]}" claude -n "$name" "$prompt")
    return
  fi

  if tmux has-session -t "$name" 2>/dev/null; then
    # Resume reattaches the live session *untouched* — no re-split. Re-running split-window here
    # would stack a third pane onto an already-2-pane layout on every resume (#24); the durable
    # session already carries whatever layout the last launch established.
    info "resume: tmux session $name is live"
  else
    # Fresh launch: two panes — the sandboxed agent left, a privileged shell right, cwd = the
    # worktree (#24, #84). new-session -d starts the window as a *plain shell*; send-keys types
    # the claude command into it; then split-window -h adds a second shell beside it (no
    # command = your default shell, unsandboxed — the human intervention surface) and
    # select-pane -L returns focus to claude so you land on the agent, not the shell.
    #
    # Why send-keys instead of `new-session ... "<cmd>"` (#47): running claude as the pane's PID 1
    # couples its lifecycle to the pane's — when claude exits for *any* reason (e.g. a bad inherited
    # env) the pane closes, and being the last pane, the whole session evaporates. The next
    # split-window then fails "can't find pane", masking the real cause: a total, silent failure
    # contradicting ADR 0003's "the detached session is the durable artifact." Launching claude
    # *into* a live shell decouples them: if claude dies you land in a shell in the worktree with
    # its stderr on screen — session intact, `claude --resume` available, failure visible.
    #
    # send-keys types this string into the pane's shell, which parses it — so every interpolated
    # value must be shell-safe, not just this launcher's own string (issue #25). _shq single-quotes
    # each so ', $, `, and even a newline reach claude as one literal arg instead of breaking the
    # command apart. A newline is safe *because* it's quoted: send-keys injects it as an Enter, but
    # inside the open '...' the shell treats that as line continuation (the `quote>` prompt), not an
    # early submit — the final Enter (a separate send-keys arg) runs the whole command once the
    # closing quote lands. An *unquoted* newline would split it; quoting is exactly what prevents
    # that. (Verified against real tmux, not just an sh -c parse — see PR #49.)
    _prepare_sandbox "$wt"
    run tmux new-session -d -s "$name" -c "$wt"
    run tmux send-keys -t "$name" "${_SANDBOX_SQ}claude -n $(_shq "$name") $(_shq "$prompt")" Enter
    run tmux split-window -h -t "$name" -c "$wt"
    run tmux select-pane -t "$name" -L
  fi
  _tmux_attach "$name"
}
