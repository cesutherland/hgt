# init.sh — `hgt init`: idempotent scaffold of a target repo (Slice 1).

cmd_init() {
  case "${1:-}" in
    -h | --help)
      printf 'usage: hgt init\n\nIdempotently scaffold hgt into the current repo:\n'
      printf '  - stamp CLAUDE.md, .worktreeinclude, .hgt/hooks/normalize (never clobbers)\n'
      printf '  - create the work-state labels\n'
      printf '  - print the branch-protection script for the default branch\n'
      return 0
      ;;
  esac

  info "hgt init — scaffolding $(pwd)"
  info ""
  info "files:"

  # dest|template|mode  (mode blank = leave default perms)
  local spec dest src mode n_created=0 n_skipped=0
  for spec in \
    "CLAUDE.md|templates/CLAUDE.md|" \
    ".worktreeinclude|templates/.worktreeinclude|" \
    ".hgt/hooks/normalize|templates/hooks/normalize|0755"; do
    IFS='|' read -r dest src mode <<<"$spec"
    stamp_file "$dest" <"$HGT_ROOT/$src"
    if [ "$STAMP_RESULT" = created ]; then
      n_created=$((n_created + 1))
      [ -n "$mode" ] && chmod "$mode" "$dest"
    else
      n_skipped=$((n_skipped + 1))
    fi
  done

  info ""
  info "labels (tracker states):"
  tracker_ensure_states

  info ""
  info "branch protection for the default branch (forge) — review, then run:"
  forge_print_ruleset

  info ""
  info "done: $n_created created, $n_skipped skipped."
  info "next: run the printed ruleset script to protect the default branch."
}
