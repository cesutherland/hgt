# respond.sh — `hgt respond <pr>`: local review-response session (issue #84). The attended
# counterpart to the future Actions review-responder (#83), the way `hgt work` is the local
# counterpart to the #51 executor. Opens (or resumes) a worktree on the PR's own branch, then a
# tmux session pairing a sandboxed agent pane (#67 — reads the PR's review comments + diff,
# addresses them, commits + pushes) with a privileged, unconfined shell pane (the human's own
# identity — "shell in if it gets dicey"). Does not merge; the human stays the gate.
#
# Naming: ADR 0006. `respond`, not `review` — #18 ("hgt review — list + reply to PR comments")
# keeps that name for its mechanical primitives; this is the session/orchestration layer on top.
# The mechanical comment-listing itself is #18's job, a deliberate non-goal here (see the issue):
# until #18 lands (or the sandbox carries a scoped GitHub credential, ADR 0005's residual), what
# the agent pane can actually reach inside the jail is the same `gh`-auth gap `hgt work` already
# has for pushing — this ticket wires the session/guidance, not that plumbing.
#
# Worktrees/sessions are keyed `pr-<n>` (never bare `<n>`) so a PR and an issue of the same
# number can't collide under lib/session.sh's shared `<base>/<key>-<slug>` convention.

_respond_usage() {
  cat <<'EOF'
usage: hgt respond <pr> [--no-session] [--no-tmux] [--no-sandbox]
       hgt respond rm <pr> [--force]

Open (or resume) a local review-response session for PR <pr>: a worktree on the PR's own
branch, a sandboxed agent pane addressing review comments (#67), and a privileged shell pane
for you to intervene in.

  --no-session    ensure the worktree, don't launch claude
  --no-tmux       launch claude inline instead of in a detached tmux session
  --no-sandbox    launch the agent UNCONFINED (default confines it to the worktree, #67)
  rm <pr>         tear the worktree down (refuses dirty/unpushed work without --force)
EOF
}

# _pr_key N — the worktree/session join key for PR N. See the naming note above.
_pr_key() { printf 'pr-%s' "$1"; }

# _seed_respond_state N TITLE URL BRANCH WT — write a durable marker recording which PR this
# session responds to (mirrors _seed_work_state's plan file, cmds/work.sh), so the kickoff
# prompt can point at a fixed file instead of re-deriving the PR on every resume. NOT committed,
# unlike the work plan file: `hgt respond` doesn't own this branch's history, and slipping an
# hgt-authored commit into someone else's review branch would be a surprise nobody asked for.
# stamp_file never clobbers, so a resume leaves it untouched.
_seed_respond_state() {
  local n="$1" title="$2" url="$3" branch="$4" wt="$5"
  stamp_file "$wt/.hgt/respond/${n}.md" <<EOF
# PR $n — $title

- **PR:** #$n
- **URL:** $url
- **Branch:** $branch
- **State:** in-progress (local review-response session)

## Getting started

1. Read the review comments (unresolved threads) and the current diff against the base branch.
2. Address them on this branch: make the changes, don't post questions back as comments.
3. Commit with clear messages; push to this branch when done.
4. Do NOT open a new PR. Do NOT merge — a human is watching the other pane and is the gate.
EOF
}

# _respond_prompt N — the kickoff prompt for the agent pane: the #19 review-response guidance
# (#17 parity with #83), inlined here until #19 gives it a dedicated, shared home. Overridable
# via HGT_RESPOND_PROMPT (the same internal seam as HGT_WORK_PROMPT, issue #25) — local path
# only, so a self-set env var crosses no trust boundary.
_respond_prompt() {
  local n="$1"
  printf '%s' "${HGT_RESPOND_PROMPT:-"Read .hgt/respond/${n}.md and CLAUDE.md, then address PR #${n}'s review comments on this branch. Stay confined to this worktree and its branch — the base branch is out of bounds. Commit and push when done; do NOT open a new PR, do NOT merge."}"
}

# launch_respond_session KEY WT [TMUX] — the agent-pane kickoff prompt, then the shared
# paired-pane launcher (lib/session.sh::launch_paired_session, shared with `hgt work`) does the
# rest — sandbox prep, tmux layout, resume/attach.
launch_respond_session() {
  local key="$1" wt="$2" use_tmux="${3:-1}"
  local name; name=$(_session_name "$key" "$wt")
  local n="${key#pr-}"
  launch_paired_session "$name" "$wt" "$(_respond_prompt "$n")" "$use_tmux"
}

cmd_respond_rm() {
  local n="" force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -f | --force) force=1 ;;
      -h | --help) _respond_usage; return 0 ;;
      -*) die "hgt respond rm: unknown flag $1" ;;
      *) [ -z "$n" ] && n="$1" || die "hgt respond rm: unexpected argument $1" ;;
    esac
    shift
  done
  [ -n "$n" ] || die "hgt respond rm: missing PR number (try 'hgt respond rm <n>')"
  case "$n" in *[!0-9]*) die "hgt respond rm: PR must be a number, got '$n'" ;; esac

  local key; key=$(_pr_key "$n")
  local wtpath; wtpath=$(_find_worktree "$key")
  [ -n "$wtpath" ] || die "hgt respond rm: no worktree for PR $n under $(_worktree_base)"

  session_teardown respond PR "$n" "$key" "$wtpath" "$force"
}

cmd_respond() {
  case "${1:-}" in
    -h | --help) _respond_usage; return 0 ;;
    rm) shift; cmd_respond_rm "$@"; return ;;
    '') die "hgt respond: missing PR number (try 'hgt respond <n>')" ;;
  esac

  local n="" session=1 use_tmux=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-session) session=0 ;;
      --no-tmux) use_tmux=0 ;;
      --no-sandbox) export HGT_NO_SANDBOX=1 ;;
      -h | --help) _respond_usage; return 0 ;;
      -*) die "hgt respond: unknown flag $1" ;;
      *) [ -z "$n" ] && n="$1" || die "hgt respond: unexpected argument $1" ;;
    esac
    shift
  done
  [ -n "$n" ] || die "hgt respond: missing PR number (try 'hgt respond <n>')"
  case "$n" in *[!0-9]*) die "hgt respond: PR must be a number, got '$n'" ;; esac

  local key; key=$(_pr_key "$n")
  local wtpath; wtpath=$(_find_worktree "$key")
  if [ -n "$wtpath" ]; then
    # Resume derives nothing from the PR record: the slug is recovered from the worktree dir,
    # so a retitled PR can't strand the session (mirrors #36 for `hgt work`).
    info "resume: worktree exists at $wtpath"
  else
    local record line title="" url="" branch="" fork=""
    record=$(forge_pr_view "$n") || die "hgt respond: could not resolve PR $n (gh auth/network?)"
    while IFS= read -r line; do
      case "$line" in
        url=*) url="${line#url=}" ;;
        title=*) title="${line#title=}" ;;
        branch=*) branch="${line#branch=}" ;;
        fork=*) fork="${line#fork=}" ;;
        number=*) ;;  # we already have n
      esac
    done <<<"$record"

    # Cross-repository PRs live on a fork's branch, on a remote we have no write access to (and
    # `hgt respond` pushes to origin) — decline rather than silently set up a worktree that can
    # never push the agent's commits.
    [ "$fork" = true ] && die "hgt respond: PR $n is from a fork ($branch) — not supported yet"

    local slug; slug=$(slug_short "$title"); [ -n "$slug" ] || slug="pr"
    wtpath=$(_worktree_path "$key" "$slug")

    # Unlike `hgt work` (which creates a fresh branch off a base), `hgt respond` attaches to the
    # PR's OWN existing branch — the review comments are already on it. Reuse the local branch if
    # we already have it (e.g. pushed from here before); otherwise fetch it from origin first.
    if git show-ref --verify --quiet "refs/heads/$branch"; then
      info "create: worktree $wtpath on existing local branch $branch"
      run git worktree add "$wtpath" "$branch"
    else
      info "create: worktree $wtpath tracking origin/$branch"
      run git fetch origin "$branch"
      run git worktree add -b "$branch" "$wtpath" "origin/$branch"
    fi
    _carry_worktree_includes "$wtpath"
    _seed_respond_state "$n" "$title" "$url" "$branch" "$wtpath"
  fi

  if [ "$session" -eq 1 ]; then
    launch_respond_session "$key" "$wtpath" "$use_tmux"
  else
    info "session: skipped (--no-session); worktree ready at $wtpath"
  fi
}
