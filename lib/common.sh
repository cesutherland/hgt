# common.sh — shared helpers, sourced by the hgt entrypoint. No top-level side effects.

# Color only on a tty (stderr).
if [ -t 2 ]; then
  _c_red=$'\033[31m'; _c_yel=$'\033[33m'; _c_dim=$'\033[2m'; _c_rst=$'\033[0m'
else
  _c_red=''; _c_yel=''; _c_dim=''; _c_rst=''
fi

# Human-facing chatter goes to stderr so stdout stays reserved for machine output.
info() { printf '%s\n' "$*" >&2; }
warn() { printf '%swarn:%s %s\n' "$_c_yel" "$_c_rst" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$_c_red" "$_c_rst" "$*" >&2; exit 1; }

# run CMD... — echo a shell-out (dimmed) to stderr, then execute it.
run() {
  printf '%s+ %s%s\n' "$_c_dim" "$*" "$_c_rst" >&2
  "$@"
}

# slugify STRING — derive a branch-safe slug: lowercase, every run of non-alphanumerics
# collapsed to a single '-', leading/trailing '-' trimmed. Matches the existing branch
# convention (title "Claude md" -> "claude-md" in issue-1-claude-md). Prints to stdout.
slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

# A leading conventional-commit type is redundant with the issue/PR context, and stopwords
# are noise in a name — both get dropped from short slugs (issue #36). Space-padded so a
# whole-word `case` match (`*" $tok "*`) can't fire on a substring.
_SLUG_CC_TYPES=' feat fix chore docs refactor test build ci perf style revert wip '
_SLUG_STOPWORDS=' a an the to of for and or in on at is be with '
_slug_in_list() { case "$1" in *" $2 "*) return 0 ;; *) return 1 ;; esac; }

# slug_short STRING — a short, human-readable slug for branch/worktree/session names
# (issue #36). Full slugify, then: drop a leading conventional-commit type word, drop
# stopwords, and cap at 5 words. Deterministic and re-derivable from the same title, so it
# stays a stable naming key (no LLM, no drift). May print empty (title was all noise); callers
# fall back to a literal. Prints to stdout.
slug_short() {
  local tok out="" n=0 first=1 IFS=-
  for tok in $(slugify "$1"); do
    [ -n "$tok" ] || continue
    if [ "$first" -eq 1 ]; then
      first=0
      _slug_in_list "$_SLUG_CC_TYPES" "$tok" && continue
    fi
    _slug_in_list "$_SLUG_STOPWORDS" "$tok" && continue
    out="${out:+$out-}$tok"
    n=$((n + 1))
    [ "$n" -ge 5 ] && break
  done
  printf '%s' "$out"
}

# confirm PROMPT — y/N prompt; 0 on yes. Non-interactive stdin => no (safe default).
confirm() {
  local reply
  [ -t 0 ] || return 1
  printf '%s [y/N] ' "$1" >&2
  read -r reply || return 1
  case "$reply" in [yY] | [yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# stamp_file DEST < content — idempotent writer for the scaffold. Creates DEST from
# stdin when absent; if it already exists, leaves it untouched (never clobbers a user's
# edits) and reports a skip. Sets STAMP_RESULT to created|skipped for caller summaries.
stamp_file() {
  local dest="$1"
  if [ -e "$dest" ]; then
    STAMP_RESULT=skipped
    cat >/dev/null   # drain stdin so the caller's redirect closes cleanly
    info "  skip   $dest (exists)"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  cat >"$dest"
  STAMP_RESULT=created
  info "  create $dest"
}
