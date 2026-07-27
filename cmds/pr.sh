# pr.sh — `hgt pr open`: a gh-free, one-shot PR open/update against the REST API (issue #97).
#
# The jail (lib/sandbox.sh) drops `gh` entirely: a snap `gh` can't run inside bwrap anyway, and
# the only real in-jail use was `gh pr create`. This is that use, minus `gh` — POST/PATCH straight
# to /repos/{owner}/{repo}/pulls using $GITHUB_TOKEN, the same scoped PAT the jail's git credential
# helper already reads for push. Probe-then-create-or-update, not create-then-catch-422: an
# already-open PR for this branch is success, not an error (idempotent by construction).

_pr_usage() {
  cat <<'EOF'
usage: hgt pr open [--title <title>] [--body <body>] [--base <branch>]

Open a pull request for the current branch, or update it if one is already open
(idempotent — safe to re-run). Talks to the GitHub REST API directly with
$GITHUB_TOKEN; no `gh` involved.

  --title <title>  PR title (default: the branch's latest commit subject; on an
                    update, omitting this leaves the existing title untouched)
  --body <body>    PR body (default: on create, none; on update, untouched)
  --base <branch>  base branch to target (default: the repo's default branch)

Prints the PR URL to stdout.
EOF
}

# _pr_slug — this repo's "owner/repo", parsed from the `origin` remote (git@ or https form).
# Prints to stdout.
_pr_slug() {
  local url
  url=$(git remote get-url origin) || die "hgt pr open: no 'origin' remote"
  case "$url" in
    git@github.com:*) url="${url#git@github.com:}" ;;
    https://github.com/*) url="${url#https://github.com/}" ;;
    *) die "hgt pr open: origin remote '$url' isn't a github.com remote" ;;
  esac
  printf '%s' "${url%.git}"
}

# _pr_api METHOD PATH [DATA] — call the GitHub REST API. The bearer token rides a curl config fed
# over stdin (`-K -`), never `-H` on the argv: an argv secret sits in /proc/<pid>/cmdline,
# world-readable — the exact leak vector the jail's own token delivery (lib/sandbox.sh's
# `--args <fd>`) exists to avoid. `run` still echoes the call (method/URL only, never the header),
# same visibility as every other shell-out in hgt. Fails loud (`-f`) on a non-2xx response.
_pr_api() {
  local method="$1" path="$2" data="${3:-}"
  local -a args=(-fsS -X "$method")
  [ -n "$data" ] && args+=(-d "$data")
  printf 'header = "Authorization: Bearer %s"\nheader = "Accept: application/vnd.github+json"\n' \
    "$GITHUB_TOKEN" | run curl -K - "${args[@]}" "https://api.github.com$path"
}

cmd_pr_open() {
  local title="" body="" base=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --title) shift; title="${1:?hgt pr open: --title needs a value}" ;;
      --body) shift; body="${1:?hgt pr open: --body needs a value}" ;;
      --base) shift; base="${1:?hgt pr open: --base needs a value}" ;;
      -h | --help) _pr_usage; return 0 ;;
      *) die "hgt pr open: unknown argument $1" ;;
    esac
    shift
  done

  [ -n "${GITHUB_TOKEN:-}" ] || die "hgt pr open: GITHUB_TOKEN not set (no scoped push token in this jail)"

  local slug owner branch
  slug=$(_pr_slug)
  owner="${slug%%/*}"
  branch=$(git rev-parse --abbrev-ref HEAD)

  # Probe: an open PR already targeting this branch means success, not a 422 to catch later.
  local existing number
  existing=$(_pr_api GET "/repos/$slug/pulls?head=$owner:$branch&state=open") \
    || die "hgt pr open: couldn't query existing PRs for $slug"
  number=$(printf '%s' "$existing" | jq -r '.[0].number // empty')

  local payload url
  if [ -n "$number" ]; then
    payload=$(jq -nc --arg title "$title" --arg body "$body" \
      '{} + (if $title != "" then {title: $title} else {} end)
          + (if $body  != "" then {body:  $body}  else {} end)')
    if [ "$payload" = '{}' ]; then
      url=$(printf '%s' "$existing" | jq -r '.[0].html_url')
      info "pr: #$number already open, nothing to update ($url)"
    else
      url=$(_pr_api PATCH "/repos/$slug/pulls/$number" "$payload" | jq -r .html_url) \
        || die "hgt pr open: couldn't update PR #$number"
      info "pr: updated #$number ($url)"
    fi
  else
    [ -n "$title" ] || title=$(git log -1 --format=%s)
    [ -n "$base" ] || base=$(_pr_api GET "/repos/$slug" | jq -r .default_branch) \
      || die "hgt pr open: couldn't resolve the default branch for $slug"
    payload=$(jq -nc --arg title "$title" --arg body "$body" --arg head "$branch" --arg base "$base" \
      '{title: $title, head: $head, base: $base} + (if $body != "" then {body: $body} else {} end)')
    url=$(_pr_api POST "/repos/$slug/pulls" "$payload" | jq -r .html_url) \
      || die "hgt pr open: couldn't open a PR ($branch -> $base)"
    info "pr: opened $url"
  fi
  printf '%s\n' "$url"
}

cmd_pr() {
  case "${1:-}" in
    -h | --help | '') _pr_usage; return 0 ;;
    open) shift; cmd_pr_open "$@" ;;
    *) die "hgt pr: unknown subcommand $1 (try 'hgt pr open')" ;;
  esac
}
