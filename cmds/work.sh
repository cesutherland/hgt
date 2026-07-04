# work.sh — `hgt work <n>`: the local execution path (spec §5). Resolve a trusted local
# issue, open-or-resume a git worktree on its feature branch, seed durable work state, and
# launch a named Claude session in it. No `ready` snapshot here on purpose: locally you author
# and trust your own issues; the normalize+snapshot boundary de-fangs the *untrusted* Actions
# path (Phase 2), not this one.

_work_usage() {
  cat <<'EOF'
usage: hgt work <n> [--base <ref>] [--no-session] [--no-tmux]
       hgt work rm <n> [--force]

Open (or resume) a local worktree + named Claude session for issue <n>.

  --base <ref>    base the new worktree here (default: HEAD — supports stacking)
  --no-session    ensure the worktree, don't launch claude
  --no-tmux       launch claude inline instead of in a detached tmux session
  rm <n>          tear the worktree down (refuses dirty/unpushed work without --force)
EOF
}

# _worktree_base — the parent dir that holds all issue worktrees. Override with HGT_WORKTREE_DIR
# (the tests point this inside their tmpdir). Default is a sibling of the repo,
# `../<repo>-worktrees`, so worktrees live outside the repo (no .gitignore entry).
_worktree_base() {
  if [ -n "${HGT_WORKTREE_DIR:-}" ]; then
    printf '%s' "$HGT_WORKTREE_DIR"
  else
    local root; root=$(git rev-parse --show-toplevel)
    printf '%s/%s-worktrees' "$(dirname "$root")" "$(basename "$root")"
  fi
}

# _worktree_path N SLUG — the worktree path for issue N, `<base>/<n>-<slug>` (issue #36). The
# slug rides along for human readability; N is the stable key. Used at *create*, where the slug
# is in hand. Prints to stdout.
_worktree_path() { printf '%s/%s-%s' "$(_worktree_base)" "$1" "$2"; }

# _find_worktree N — the existing worktree dir for issue N, found by globbing `<base>/<n>-*`,
# empty if none. This is how resume + teardown recover the (drift-carrying) slug from N alone:
# the worktree dir is the durable, N-keyed artifact, so no title lookup is needed and a retitled
# issue still resolves to its original dir. Prints the first match to stdout.
_find_worktree() {
  local n="$1" base d
  base=$(_worktree_base)
  for d in "$base/$n"-*; do
    [ -d "$d" ] && { printf '%s' "$d"; return 0; }
  done
  return 0  # no match: print nothing, succeed (an unmatched glob must not trip set -e)
}

# _slug_of N WT — recover the slug from a worktree dir path `<base>/<n>-<slug>` (strip the
# `<n>-` prefix off the basename). The dir is the source of truth, so the slug survives a
# retitle. Prints to stdout.
_slug_of() { local base; base="${2##*/}"; printf '%s' "${base#"$1"-}"; }

# _repo_slug — the repo label that namespaces sessions (`<repo>/...`). Slugified so it's safe in
# a tmux session name (tmux forbids `.`/`:`, which a repo dir like `my.tool` could carry).
# Overridable via HGT_REPO_NAME (the hermetic suite sets it; the git-toplevel default, like
# _worktree_base's, isn't exercised there — see ADR 0002/D3). Prints to stdout.
_repo_slug() {
  local name; name="${HGT_REPO_NAME:-$(basename "$(git rev-parse --show-toplevel)")}"
  slugify "$name"
}

# _session_name N WT — the human-readable session id `<repo>/<n>-<slug>` (issue #36), derived
# wholly from N and the worktree dir. It's the join key across tmux create/attach/resume, tmux
# kill, and `claude --resume`. The slug is a cosmetic suffix recovered from the worktree dir (the
# durable, N-keyed artifact), so create and teardown reconstruct the *same* name from N alone —
# no title lookup, and no create-vs-kill drift by construction. Prints to stdout.
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

# _seed_work_state N TITLE URL BODY WT BRANCH — write the durable plan file (§4) into the
# worktree and, only when it's freshly created, commit it as the first recovery checkpoint on
# the feature branch. stamp_file never clobbers, so a resume keeps any edits the agent committed.
_seed_work_state() {
  local n="$1" title="$2" url="$3" body="$4" wt="$5" branch="$6"
  local name; name=$(_session_name "$n" "$wt")
  stamp_file "$wt/.hgt/work/${n}.md" <<EOF
# Issue $n — $title

- **Issue:** #$n
- **URL:** $url
- **Branch:** $branch
- **State:** in-progress (local)

## Task (verbatim from the issue body)

$body

## Checklist

- [ ] Read this file and CLAUDE.md before starting.
- [ ] Implement the slice; commit early and often — every commit is a recovery checkpoint.
- [ ] Open a PR for human review. Do not merge (green is necessary, not sufficient).

## Recovery

If this session dies: re-read this file, check \`git status\`, then resume the named session
\`$name\` (\`claude --resume\`). git is the durable work state — not the agent's memory.
EOF
  if [ "$STAMP_RESULT" = created ]; then
    # Committed-plan-file mode (ADR 0002 D2). If .hgt/ is gitignored this add no-ops and the
    # commit fails — making tracked vs. gitignored a real choice is tracked in #10.
    run git -C "$wt" add ".hgt/work/${n}.md"
    run git -C "$wt" commit -m "chore(hgt): seed work state for issue #$n"
  fi
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

# launch_session N WT [TMUX] — the launcher seam (spec §4/§5). Default (TMUX=1): run the named
# claude session inside a *detached* tmux session `<repo>/<n>-<slug>`, then attach/switch to it. The
# detached session outlives your terminal, so crash-recovery becomes "reattach if it's alive,
# else recreate" instead of "relaunch from scratch" (see ADR 0003). Resume reuses a live session
# rather than spawning a second. TMUX=0 (--no-tmux) keeps the Slice 2 inline launch. The tmux
# session name matches the claude session name so `claude --resume` stays deterministic too.
launch_session() {
  local n="$1" wt="$2" use_tmux="${3:-1}"
  local name; name=$(_session_name "$n" "$wt")
  local prompt="Read .hgt/work/${n}.md and CLAUDE.md, then start on issue #${n}. Commit early and often — every commit is a recovery checkpoint. Open a PR for review; do not merge."

  if [ "$use_tmux" -eq 0 ]; then
    (cd "$wt" && run claude -n "$name" "$prompt")
    return
  fi

  if tmux has-session -t "$name" 2>/dev/null; then
    # Resume reattaches the live session *untouched* — no re-split. Re-running split-window here
    # would stack a third pane onto an already-2-pane layout on every resume (#24); the durable
    # session already carries whatever layout the last launch established.
    info "resume: tmux session $name is live"
  else
    # Fresh launch: two panes — claude left, a shell right, cwd = the worktree (#24). new-session
    # -d starts the window running claude; split-window -h adds the shell beside it (no command =
    # your default shell); select-pane -L returns focus to claude so you land on the agent, not
    # the shell.
    # claude + args become the session's shell command (tmux runs it via `sh -c`). The prompt
    # is a fixed internal string with no single quotes, so single-quoting it is safe here.
    run tmux new-session -d -s "$name" -c "$wt" "claude -n '$name' '$prompt'"
    run tmux split-window -h -t "$name" -c "$wt"
    run tmux select-pane -t "$name" -L
  fi
  _tmux_attach "$name"
}

cmd_work_rm() {
  local n="" force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -f | --force) force=1 ;;
      -h | --help) _work_usage; return 0 ;;
      -*) die "hgt work rm: unknown flag $1" ;;
      *) [ -z "$n" ] && n="$1" || die "hgt work rm: unexpected argument $1" ;;
    esac
    shift
  done
  [ -n "$n" ] || die "hgt work rm: missing issue number (try 'hgt work rm <n>')"
  case "$n" in *[!0-9]*) die "hgt work rm: issue must be a number, got '$n'" ;; esac

  local wtpath
  wtpath=$(_find_worktree "$n")
  [ -n "$wtpath" ] || die "hgt work rm: no worktree for issue $n under $(_worktree_base)"

  # Refuse to nuke work that isn't safely recorded elsewhere. A dirty tree (uncommitted) or
  # commits not on any remote (unpushed) would be lost with the worktree — make the human opt
  # in via --force. The PR may be open, so we leave the branch regardless.
  if [ "$force" -ne 1 ]; then
    # Fail closed: no `|| true`. If git errors here (corrupt worktree, bad path) let set -e
    # abort, rather than read an empty result as "clean" and delete the worktree. Note: porcelain
    # also lists carried .worktreeinclude files when they aren't gitignored, so those read as
    # dirty — expected, since such files are typically .env-class.
    local dirty unpushed
    dirty=$(git -C "$wtpath" status --porcelain)
    # HEAD, not --branches: worktrees share one .git, so --branches would also count unpushed
    # commits on unrelated branches and refuse to remove a fully-pushed issue-<n> worktree.
    unpushed=$(git -C "$wtpath" log HEAD --not --remotes --oneline)
    if [ -n "$dirty" ] || [ -n "$unpushed" ]; then
      die "hgt work rm: issue $n has uncommitted or unpushed work — rerun with --force to discard"
    fi
  fi

  # Kill the tmux session before the worktree it's rooted in disappears (Slice 2b): ordering
  # kill-session ahead of `git worktree remove` keeps a live detached claude from ending up
  # with a deleted cwd, and stops a failing remove from stranding the session. Guard on
  # has-session so an inline (--no-tmux) or already-dead run doesn't error.
  local name; name=$(_session_name "$n" "$wtpath")
  if tmux has-session -t "$name" 2>/dev/null; then
    run tmux kill-session -t "$name"
  fi

  if [ "$force" -eq 1 ]; then
    run git worktree remove --force "$wtpath"
  else
    run git worktree remove "$wtpath"
  fi

  info "removed worktree for issue $n (branch left intact)"
}

cmd_work() {
  case "${1:-}" in
    -h | --help) _work_usage; return 0 ;;
    rm) shift; cmd_work_rm "$@"; return ;;
    '') die "hgt work: missing issue number (try 'hgt work <n>')" ;;
  esac

  local n="" base="HEAD" session=1 use_tmux=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) shift; base="${1:?hgt work: --base needs a ref}" ;;
      --base=*) base="${1#--base=}" ;;
      --no-session) session=0 ;;
      --no-tmux) use_tmux=0 ;;
      -h | --help) _work_usage; return 0 ;;
      -*) die "hgt work: unknown flag $1" ;;
      *) [ -z "$n" ] && n="$1" || die "hgt work: unexpected argument $1" ;;
    esac
    shift
  done
  [ -n "$n" ] || die "hgt work: missing issue number (try 'hgt work <n>')"
  case "$n" in *[!0-9]*) die "hgt work: issue must be a number, got '$n'" ;; esac

  # Resolve the issue through the tracker seam and parse its stable record. number/url/title
  # are single-line `key=` lines; everything after the `---body---` sentinel is the body.
  local record line title="" url="" body="" in_body=0
  record=$(tracker_issue_view "$n") || die "hgt work: could not resolve issue $n (gh auth/network?)"
  while IFS= read -r line; do
    if [ "$in_body" -eq 1 ]; then
      body+="$line"$'\n'
      continue
    fi
    case "$line" in
      ---body---) in_body=1 ;;
      url=*) url="${line#url=}" ;;
      title=*) title="${line#title=}" ;;
      number=*) ;;  # we already have n
    esac
  done <<<"$record"

  local slug branch wtpath user
  slug=$(slug_short "$title"); [ -n "$slug" ] || slug="issue"

  wtpath=$(_find_worktree "$n")
  if [ -n "$wtpath" ]; then
    info "resume: worktree exists at $wtpath"
  else
    wtpath=$(_worktree_path "$n" "$slug")
    # Namespace the branch under the GitHub login (`<user>/<n>-<slug>`, issue #36). The lookup
    # is non-fatal: `gh issue view` already succeeded above, so this rarely fails, but if it
    # does we fall back to an unprefixed `<n>-<slug>` rather than block local work.
    user=$(forge_current_user) || user=""
    if [ -n "$user" ]; then branch="${user}/${n}-${slug}"; else branch="${n}-${slug}"; fi
    info "create: worktree $wtpath on $branch (base $base)"
    run git worktree add -b "$branch" "$wtpath" "$base"
    _carry_worktree_includes "$wtpath"
    _seed_work_state "$n" "$title" "$url" "$body" "$wtpath" "$branch"
  fi

  if [ "$session" -eq 1 ]; then
    launch_session "$n" "$wtpath" "$use_tmux"
  else
    info "session: skipped (--no-session); worktree ready at $wtpath"
  fi
}
