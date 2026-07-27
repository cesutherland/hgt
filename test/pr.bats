load helper

# Black-box conformance for `hgt pr open` (issue #97): the gh-free, curl+jq REST path that
# replaces the jail's one real use of `gh` (opening a PR). git and curl are shimmed boundaries;
# we assert the calls hgt makes (URL, method, payload), not GitHub's actual behavior.

pr_env() {
  export GITHUB_TOKEN=ghp_SEKRET
  export SHIM_GIT_REMOTE=git@github.com:cesutherland/hgt.git
  export SHIM_GIT_BRANCH=testuser/5-add-widget
}

@test "pr open: no existing PR -> creates one against the given base, prints the URL" {
  pr_env
  export SHIM_CURL_PULLS_OUT='[]'
  export SHIM_CURL_CREATE_OUT='{"html_url":"https://github.com/cesutherland/hgt/pull/42"}'

  run "$HGT_BIN" pr open --base main --title "Add pr helper" --body "does the thing"
  [ "$status" -eq 0 ]
  [[ "$output" == *"https://github.com/cesutherland/hgt/pull/42"* ]]

  # probe first (idempotent by construction — not create-then-catch-422)
  grep -q '^curl GET https://api.github.com/repos/cesutherland/hgt/pulls?head=cesutherland:testuser/5-add-widget&state=open$' "$SHIM_LOG"
  # --base given explicitly: no default-branch lookup
  ! grep -q '^curl GET https://api.github.com/repos/cesutherland/hgt$' "$SHIM_LOG"
  # then create, with the given title/body/head/base
  grep -q '^curl POST https://api.github.com/repos/cesutherland/hgt/pulls$' "$SHIM_LOG"
  local data; data=$(grep '^curl-data' "$SHIM_LOG" | tail -1)
  [[ "$data" == *'"title":"Add pr helper"'* ]]
  [[ "$data" == *'"body":"does the thing"'* ]]
  [[ "$data" == *'"head":"testuser/5-add-widget"'* ]]
  [[ "$data" == *'"base":"main"'* ]]
  # no gh, anywhere
  ! grep -q '^gh ' "$SHIM_LOG"
}

@test "pr open: no --base -> resolves the repo's default branch first" {
  pr_env
  export SHIM_CURL_REPO_OUT='{"default_branch":"trunk"}'
  export SHIM_CURL_PULLS_OUT='[]'
  export SHIM_CURL_CREATE_OUT='{"html_url":"https://github.com/cesutherland/hgt/pull/42"}'

  run "$HGT_BIN" pr open --title "Add pr helper"
  [ "$status" -eq 0 ]
  grep -q '^curl GET https://api.github.com/repos/cesutherland/hgt$' "$SHIM_LOG"
  local data; data=$(grep '^curl-data' "$SHIM_LOG" | tail -1)
  [[ "$data" == *'"base":"trunk"'* ]]
}

@test "pr open: no --title on create -> defaults to the branch's latest commit subject" {
  pr_env
  export SHIM_GIT_LOG_OUT='chore(hgt): seed work state for issue #5'
  export SHIM_CURL_PULLS_OUT='[]'
  export SHIM_CURL_CREATE_OUT='{"html_url":"https://github.com/cesutherland/hgt/pull/42"}'

  run "$HGT_BIN" pr open --base main
  [ "$status" -eq 0 ]
  local data; data=$(grep '^curl-data' "$SHIM_LOG" | tail -1)
  [[ "$data" == *'"title":"chore(hgt): seed work state for issue #5"'* ]]
}

@test "pr open: an already-open PR with no --title/--body is success, untouched (idempotent)" {
  pr_env
  export SHIM_CURL_PULLS_OUT='[{"number":7,"html_url":"https://github.com/cesutherland/hgt/pull/7"}]'

  run "$HGT_BIN" pr open --base main
  [ "$status" -eq 0 ]
  [[ "$output" == *"https://github.com/cesutherland/hgt/pull/7"* ]]
  ! grep -q '^curl PATCH' "$SHIM_LOG"   # nothing to update -> no PATCH issued
  ! grep -q '^curl POST'  "$SHIM_LOG"   # and no duplicate create
}

@test "pr open: an already-open PR with --title/--body updates it via PATCH" {
  pr_env
  export SHIM_CURL_PULLS_OUT='[{"number":7,"html_url":"https://github.com/cesutherland/hgt/pull/7"}]'
  export SHIM_CURL_UPDATE_OUT='{"html_url":"https://github.com/cesutherland/hgt/pull/7"}'

  run "$HGT_BIN" pr open --base main --title "New title" --body "New body"
  [ "$status" -eq 0 ]
  [[ "$output" == *"https://github.com/cesutherland/hgt/pull/7"* ]]
  grep -q '^curl PATCH https://api.github.com/repos/cesutherland/hgt/pulls/7$' "$SHIM_LOG"
  local data; data=$(grep '^curl-data' "$SHIM_LOG" | tail -1)
  [[ "$data" == *'"title":"New title"'* ]]
  [[ "$data" == *'"body":"New body"'* ]]
  ! grep -q '^curl POST' "$SHIM_LOG"    # update, not a second create
}

@test "pr open: an https origin remote resolves owner/repo the same as git@" {
  pr_env
  export SHIM_GIT_REMOTE=https://github.com/cesutherland/hgt.git
  export SHIM_CURL_PULLS_OUT='[]'
  export SHIM_CURL_CREATE_OUT='{"html_url":"https://github.com/cesutherland/hgt/pull/42"}'

  run "$HGT_BIN" pr open --base main --title x
  [ "$status" -eq 0 ]
  grep -q '^curl GET https://api.github.com/repos/cesutherland/hgt/pulls?head=cesutherland:testuser/5-add-widget&state=open$' "$SHIM_LOG"
}

@test "pr open: fails closed without GITHUB_TOKEN, no curl call made" {
  export SHIM_GIT_REMOTE=git@github.com:cesutherland/hgt.git
  export SHIM_GIT_BRANCH=testuser/5-add-widget
  unset GITHUB_TOKEN

  run "$HGT_BIN" pr open --base main --title x
  [ "$status" -ne 0 ]
  [[ "$output" == *"GITHUB_TOKEN"* ]]
  ! grep -q '^curl ' "$SHIM_LOG"
}
