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
  --no-sandbox    launch the agent UNCONFINED (default confines it to the worktree, #67)
  rm <n>          tear the worktree down (refuses dirty/unpushed work without --force)
EOF
}

# Worktree/session naming, sandbox prep, and the paired-pane tmux launcher live in
# lib/session.sh (shared with `hgt respond`, #84) — sourced by the hgt entrypoint.

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

## Getting started

1. Read this file and CLAUDE.md before starting.
2. Implement the slice; commit early and often — every commit is a recovery checkpoint.
3. Open a PR for human review. Do not merge (green is necessary, not sufficient).

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

# launch_session N WT [TMUX] — the `hgt work` kickoff prompt, then the shared paired-pane
# launcher (lib/session.sh::launch_paired_session, #84) does the rest — sandbox prep, tmux
# layout, resume/attach. TMUX=0 (--no-tmux) launches inline instead.
launch_session() {
  local n="$1" wt="$2" use_tmux="${3:-1}"
  local name; name=$(_session_name "$n" "$wt")
  # HGT_WORK_PROMPT overrides the kickoff prompt — an internal seam the conformance suite uses to
  # drive quoting edge-cases (', $, `, newline) through the launcher (issue #25). Local path only,
  # so a self-set env var crosses no trust boundary.
  local prompt="${HGT_WORK_PROMPT:-Read .hgt/work/${n}.md and CLAUDE.md, then start on issue #${n}. Commit early and often — every commit is a recovery checkpoint. Open a PR for review; do not merge.}"
  launch_paired_session "$name" "$wt" "$prompt" "$use_tmux"
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

  session_teardown work issue "$n" "$n" "$wtpath" "$force"
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
      --no-sandbox) export HGT_NO_SANDBOX=1 ;;
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
  wtpath=$(_find_worktree "$n")
  if [ -n "$wtpath" ]; then
    # Resume derives nothing from the title: the slug is recovered from the worktree dir
    # (the durable, N-keyed artifact), so a retitle can't strand the session (#36).
    info "resume: worktree exists at $wtpath"
  else
    slug=$(slug_short "$title"); [ -n "$slug" ] || slug="issue"
    wtpath=$(_worktree_path "$n" "$slug")
    # Namespace the branch under the GitHub login (`<user>/<n>-<slug>`, issue #36). The lookup
    # is non-fatal: `gh issue view` already succeeded above, so this rarely fails, but if it
    # does we fall back to an unprefixed `<n>-<slug>` rather than block local work.
    user=$(forge_current_user) || user=""
    if [ -n "$user" ]; then branch="${user}/${n}-${slug}"; else branch="${n}-${slug}"; fi
    if git show-ref --verify --quiet "refs/heads/$branch"; then
      # Worktree gone but the branch survived — the create-vs-resume split keys on the worktree
      # dir, but `hgt work rm` deliberately leaves the branch intact (issue #23), so N→rm→N
      # lands here. Re-attach to the existing branch: `-b` would fail ("branch already exists").
      # This is a resume — the seed-state commit already lives on the branch, so DON'T re-seed.
      # Still carry includes: the removed worktree took its git-ignored .env-class files with it.
      info "resume: re-attaching worktree $wtpath to existing branch $branch"
      run git worktree add "$wtpath" "$branch"
      _carry_worktree_includes "$wtpath"
    else
      info "create: worktree $wtpath on $branch (base $base)"
      run git worktree add -b "$branch" "$wtpath" "$base"
      _carry_worktree_includes "$wtpath"
      _seed_work_state "$n" "$title" "$url" "$body" "$wtpath" "$branch"
    fi
  fi

  if [ "$session" -eq 1 ]; then
    launch_session "$n" "$wtpath" "$use_tmux"
  else
    info "session: skipped (--no-session); worktree ready at $wtpath"
  fi
}
