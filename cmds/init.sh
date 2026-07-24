# init.sh — `hgt init`: idempotent scaffold of a target repo (Slice 1).

cmd_init() {
  case "${1:-}" in
    -h | --help)
      printf 'usage: hgt init\n\nIdempotently scaffold hgt into the current repo:\n'
      printf '  - stamp CLAUDE.md, .worktreeinclude, .hgt/hooks/normalize,\n'
      printf '    .claude/skills/review-response/SKILL.md (never clobbers)\n'
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
    ".hgt/hooks/normalize|templates/hooks/normalize|0755" \
    ".claude/skills/review-response/SKILL.md|templates/skills/review-response/SKILL.md|"; do
    IFS='|' read -r dest src mode <<<"$spec"
    stamp_file "$dest" <"$HGT_ROOT/$src"
    if [ "$STAMP_RESULT" = created ]; then
      n_created=$((n_created + 1))
    else
      n_skipped=$((n_skipped + 1))
    fi
    # Enforce mode every run, not just on create: a pre-existing hook with the wrong
    # perms (external checkout, a partial earlier run, a user's hand-rolled file) must
    # end up executable, or it dies at the `ready` trust boundary. Perms aren't content,
    # so this doesn't violate never-clobber — we repair the bit, not the bytes.
    [ -n "$mode" ] && chmod "$mode" "$dest"
  done

  info ""
  info "labels (tracker states):"
  # Non-fatal: gh auth/network can fail here, but the branch-protection ruleset below is
  # pure text with no gh dependency and is the security-critical output — it must never be
  # held hostage to label creation. Warn and carry on; an idempotent re-run fixes labels.
  local labels_ok=1
  if ! tracker_ensure_states; then
    labels_ok=0
    warn "could not create one or more state labels (gh auth/network?) — re-run 'hgt init' once fixed"
  fi

  info ""
  info "branch protection for the default branch (forge) — review, then run:"
  forge_print_ruleset

  info ""
  info "done: $n_created created, $n_skipped skipped."
  info "next: run the printed ruleset script to protect the default branch."
  [ "$labels_ok" -eq 1 ] || die "labels were not created — see the warning above"
}
