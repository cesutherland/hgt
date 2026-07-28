#!/usr/bin/env bash
# hgt test shim — srt (@anthropic-ai/sandbox-runtime). Lives here, rather than directly in
# test/shims/, so `test/shims/srt` is a symlink into a real npm-shaped package layout and
# lib/sandbox.sh's version walk (realpath -> up to package.json) is exercised for real. Hence the
# .js name on a bash script: it is the path npm's `bin` entry would point at.
#
# Transparent, like the bwrap shim it replaces: it records the invocation, records its own
# environment (this is what proves the `env -i` scrub — a GH_TOKEN exported in the caller's shell
# must not appear), then walks past srt's own options and execs the wrapped command, so every
# claude-level assertion in the suite still fires through the jail.
#
# Records to $SHIM_LOG:
#   srt <args...>          one line, the argv
#   srt-env <NAME>=<value> one line per environment variable
set -euo pipefail
printf 'srt %s\n' "$*" >>"${SHIM_LOG:?SHIM_LOG not set}"

# The environment the jail would inherit. srt never clears it (ADR 0007 residual #1), so what
# lands here is exactly what `env -i` let through.
for _v in $(compgen -e); do
  printf 'srt-env %s=%s\n' "$_v" "${!_v}"
done >>"$SHIM_LOG"

# Walk srt's options by arity to find where the wrapped command begins. hgt always emits `--`, but
# tolerate its absence so a hand-run invocation still works.
args=("$@"); i=0
while [ "$i" -lt "${#args[@]}" ]; do
  case "${args[$i]}" in
    --) i=$((i + 1)); break ;;
    -d | --debug) i=$((i + 1)) ;;
    -s | --settings | -c | --control-fd) i=$((i + 2)) ;;
    --*=*) i=$((i + 1)) ;;
    --*) i=$((i + 1)) ;;   # unknown flag: assume 0-arg
    *) break ;;            # the wrapped command starts here
  esac
done
cmd=("${args[@]:$i}")

[ "${#cmd[@]}" -gt 0 ] || { echo "srt: no command specified" >&2; exit 1; }
exec "${cmd[@]}"
