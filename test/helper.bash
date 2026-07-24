# Shared bats helpers. Tests are black-box: they only touch $HGT_BIN, the filesystem, and
# the PATH-shimmed external commands — never hgt's internals. So this suite is agnostic to
# how hgt is implemented (bash today; could be anything).

HGT_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HGT_BIN="$HGT_REPO/hgt"

setup() {
  TMP="$(mktemp -d)"
  SHIM_LOG="$TMP/shim.log"
  : >"$SHIM_LOG"
  export SHIM_LOG
  export PATH="$HGT_REPO/test/shims:$PATH"
  cd "$TMP"
}

# Function-based shims for python3 and systemd-run (issue #74, ADR 0006's egress allowlist):
# unlike git/gh/tmux/bwrap (dedicated PATH-shim files under test/shims), these are exported shell
# functions. bash resolves a plain command name against shell functions before searching PATH, so
# an exported function shadows the real python3/systemd-run in any child bash process (hgt is
# bash) without a script file on disk — real python3/systemd-run are heavier to stand in for
# (one actually binds a port and backgrounds a listener, the other talks to the system/user
# systemd manager), so a function is the cheaper, equally hermetic fake.

# python3 — the egress proxy launcher (lib/sandbox.sh::_sandbox_egress_proxy_ensure). Logs
# "python3 <args...>" like the generic _shim and returns immediately (no real listener).
python3() {
  printf 'python3 %s\n' "$*" >>"$SHIM_LOG"
  return "${SHIM_PYTHON3_EXIT:-0}"
}
export -f python3

# systemd-run — the egress cgroup wrapper hgt prefixes onto bwrap (lib/sandbox.sh::sandbox_argv).
# Logs "systemd-run <args...>", then execs past the literal `--` separator so the bwrap-level
# assertions underneath still fire — same transparency trick as the bwrap shim's probe-vs-exec
# split.
systemd-run() {
  printf 'systemd-run %s\n' "$*" >>"$SHIM_LOG"
  local args=("$@") i
  for i in "${!args[@]}"; do
    if [ "${args[$i]}" = -- ]; then
      "${args[@]:$((i + 1))}"
      return
    fi
  done
  "$@"
}
export -f systemd-run

teardown() {
  cd /
  rm -rf "$TMP"
}
