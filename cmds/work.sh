# work.sh — `hgt work <n>`: the local execution path (spec §5). Resolve a trusted local
# issue, open-or-resume a git worktree on its feature branch, seed durable work state, and
# launch a named Claude session in it. No `ready` snapshot here on purpose: locally you author
# and trust your own issues; the normalize+snapshot boundary de-fangs the *untrusted* Actions
# path (Phase 2), not this one.

_work_usage() {
  cat <<'EOF'
usage: hgt work <n> [--base <ref>] [--no-session]
       hgt work rm <n> [--force]

Open (or resume) a local worktree + named Claude session for issue <n>.

  --base <ref>    base the new worktree here (default: HEAD — supports stacking)
  --no-session    ensure the worktree, don't launch claude
  rm <n>          tear the worktree down (refuses dirty/unpushed work without --force)
EOF
}

# _worktree_path N — the sibling worktree path for issue N. Override the parent dir with
# HGT_WORKTREE_DIR (the tests point this inside their tmpdir). Default is a sibling of the
# repo, `../<repo>-worktrees/issue-N`, so it lives outside the repo (no .gitignore entry).
_worktree_path() {
  local n="$1" base root
  if [ -n "${HGT_WORKTREE_DIR:-}" ]; then
    base="$HGT_WORKTREE_DIR"
  else
    root=$(git rev-parse --show-toplevel)
    base="$(dirname "$root")/$(basename "$root")-worktrees"
  fi
  printf '%s/issue-%s' "$base" "$n"
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

# _seed_work_state N TITLE URL BODY WT — write the durable plan file (§4) into the worktree
# and, only when it's freshly created, commit it as the first recovery checkpoint on the
# feature branch. stamp_file never clobbers, so a resume keeps any edits the agent committed.
_seed_work_state() {
  local n="$1" title="$2" url="$3" body="$4" wt="$5"
  stamp_file "$wt/.hgt/work/${n}.md" <<EOF
# Issue $n — $title

- **Issue:** #$n
- **URL:** $url
- **Branch:** issue-$n-$(slugify "$title")
- **State:** in-progress (local)

## Task (verbatim from the issue body)

$body

## Checklist

- [ ] Read this file and CLAUDE.md before starting.
- [ ] Implement the slice; commit early and often — every commit is a recovery checkpoint.
- [ ] Open a PR for human review. Do not merge (green is necessary, not sufficient).

## Recovery

If this session dies: re-read this file, check \`git status\`, then resume the named session
\`hgt-issue-$n\` (\`claude --resume\`). git is the durable work state — not the agent's memory.
EOF
  if [ "$STAMP_RESULT" = created ]; then
    run git -C "$wt" add ".hgt/work/${n}.md"
    run git -C "$wt" commit -m "chore(hgt): seed work state for issue #$n"
  fi
}

# launch_session N WT — the launcher seam. Slice 2 launches claude inline in the worktree;
# Slice 2b adds a tmux path behind this same seam (selected by a future --no-tmux). The name
# is deterministic (`hgt-issue-N`) so `claude --resume` is deterministic too (§4).
launch_session() {
  local n="$1" wt="$2"
  local name="hgt-issue-${n}"
  local prompt="Read .hgt/work/${n}.md and CLAUDE.md, then start on issue #${n}. Commit early and often — every commit is a recovery checkpoint. Open a PR for review; do not merge."
  (cd "$wt" && run claude -n "$name" "$prompt")
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
  wtpath=$(_worktree_path "$n")
  [ -d "$wtpath" ] || die "hgt work rm: no worktree for issue $n at $wtpath"

  # Refuse to nuke work that isn't safely recorded elsewhere. A dirty tree (uncommitted) or
  # commits not on any remote (unpushed) would be lost with the worktree — make the human opt
  # in via --force. The PR may be open, so we leave the branch regardless.
  if [ "$force" -ne 1 ]; then
    local dirty unpushed
    dirty=$(git -C "$wtpath" status --porcelain) || true
    # HEAD, not --branches: worktrees share one .git, so --branches would also count unpushed
    # commits on unrelated branches and refuse to remove a fully-pushed issue-<n> worktree.
    unpushed=$(git -C "$wtpath" log HEAD --not --remotes --oneline) || true
    if [ -n "$dirty" ] || [ -n "$unpushed" ]; then
      die "hgt work rm: issue $n has uncommitted or unpushed work — rerun with --force to discard"
    fi
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

  local n="" base="HEAD" session=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) shift; base="${1:?hgt work: --base needs a ref}" ;;
      --base=*) base="${1#--base=}" ;;
      --no-session) session=0 ;;
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

  local slug branch wtpath
  slug=$(slugify "$title"); [ -n "$slug" ] || slug="issue"
  branch="issue-${n}-${slug}"
  wtpath=$(_worktree_path "$n")

  if [ -d "$wtpath" ]; then
    info "resume: worktree exists at $wtpath"
  else
    info "create: worktree $wtpath on $branch (base $base)"
    run git worktree add -b "$branch" "$wtpath" "$base"
    _carry_worktree_includes "$wtpath"
    _seed_work_state "$n" "$title" "$url" "$body" "$wtpath"
  fi

  if [ "$session" -eq 1 ]; then
    launch_session "$n" "$wtpath"
  else
    info "session: skipped (--no-session); worktree ready at $wtpath"
  fi
}
