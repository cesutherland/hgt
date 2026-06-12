# gh.sh — the single swappable GitHub-access module (spec §7, decision D2).
#
# Two axes hide inside "GitHub"; keep them separable (decision D4) so a future config
# (e.g. beads-as-tracker + GitHub-as-forge) is a change confined to this file:
#   tracker_*  — the work queue: issues, states, snapshots   (GitHub Issues today)
#   forge_*    — the code host:  branches, PRs, ruleset       (GitHub repo today)
#
# Core code calls these neutral verbs and never invokes `gh` directly, and never speaks
# "label" or "issue number" — that vocabulary belongs to the adapter.

# Canonical hgt work-states and their GitHub label encoding. Core speaks state names;
# this table owns the colors/descriptions and the states are mutually exclusive by design.
#   name|color|description
_HGT_STATES='
ready|0e8a16|Reviewed + snapshotted; an executor may pick this up
in-progress|fbca04|An executor or human is actively working this
needs-human|d93f0b|Blocked on a human decision (Mayor / Witness / Deacon)
'

# tracker_states — canonical state names, one per line.
tracker_states() {
  printf '%s\n' "$_HGT_STATES" | awk -F'|' 'NF>=3 {print $1}'
}

# tracker_ensure_states — idempotently ensure every hgt state label exists with the right
# color/description (create if absent, update if present). First real use of the gh module.
# Returns non-zero if any label could not be created. Fed via here-string (not a pipe) so
# the loop runs in this shell: rc survives, and `return $rc` reports a real status instead
# of the trailing-blank-line `continue` (always 0) that a pipe-subshell would hand back.
tracker_ensure_states() {
  local name color desc rc=0
  while IFS='|' read -r name color desc; do
    [ -n "$name" ] || continue
    run gh label create "$name" --color "$color" --description "$desc" --force || rc=1
  done <<<"$_HGT_STATES"
  return "$rc"
}

# forge_print_ruleset — print (do NOT apply) the §3 branch-protection script for `main`.
# Slice 1 prints; applying from the CLI is a later slice. The human reviews then runs it.
forge_print_ruleset() {
  cat <<'EOF'
# --- hgt: branch protection for the default branch (spec §3) -------------------
# Review before running. Requires `gh` authenticated with admin on the repo.
# Adjust OWNER/REPO if `gh` can't infer them from the current directory.

# 1) Ruleset: require a PR + >=1 human review, require approval of the most recent
#    push, and forbid deletion / non-fast-forward on the default branch. bypass_actors
#    is empty on purpose: no executor app may skip the human gate.
gh api -X POST repos/{owner}/{repo}/rulesets --input - <<'JSON'
{
  "name": "hgt: protect default branch",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "bypass_actors": [],
  "rules": [
    { "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 1,
        "require_last_push_approval": true,
        "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": false,
        "required_review_thread_resolution": false
      }
    },
    { "type": "deletion" },
    { "type": "non_fast_forward" }
  ]
}
JSON

# 2) Disable "Allow GitHub Actions to create and approve pull requests" and default the
#    workflow token to read-only. The executor workflow requests the narrow writes it
#    needs (contents: write, pull-requests: write) explicitly — nothing more.
gh api -X PUT repos/{owner}/{repo}/actions/permissions/workflow \
  -F default_workflow_permissions=read \
  -F can_approve_pull_request_reviews=false
# -------------------------------------------------------------------------------
EOF
}
