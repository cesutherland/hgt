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
