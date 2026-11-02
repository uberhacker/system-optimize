#!/usr/bin/env bash
# tests/lint.sh - bash -n on every script, shellcheck -x, and a build.
#
# The entry point is checked with -x so the whole program (core and tweak
# modules are sourced statically) is analysed as one unit. The single-file
# build is assembled into a temporary file and checked on its own too.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

stubs=(tests/stubs/stub.sh tests/stubs/sudo tests/stubs/curl tests/stubs/sysctl tests/stubs/systemctl
       tests/stubs/rpm tests/stubs/modinfo tests/stubs/optional/powerprofilesctl tests/stubs/optional/tuned-adm)

rc=0
for f in bin/system-optimize system-optimize install.sh build.sh tests/*.sh tests/test_helper.bash \
         "${stubs[@]}" completions/*.bash lib/core/*.sh lib/tweaks/*.sh; do
  bash -n "$f" || { echo "bash -n failed: $f"; rc=1; }
done

# install_file in a pipeline runs in a subshell and loses the snapshot.
if grep -nE '^[^#]*\|[[:space:]]*(install_file|remove_file|snap_record|snap_file|write_sysfs|unit_set)\b' lib/*/*.sh; then
  echo "a snapshot helper is called at the end of a pipeline (see install_file)"
  rc=1
fi

bundle=$(mktemp -d)
trap 'rm -rf -- "$bundle"' EXIT
./build.sh "$bundle/system-optimize" >/dev/null || { echo "build.sh failed"; rc=1; }

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x bin/system-optimize system-optimize install.sh build.sh tests/*.sh tests/test_helper.bash \
    "${stubs[@]}" || rc=1
  shellcheck -s bash completions/*.bash || rc=1
  # SC2317 (unreachable) is noise in the single file: the step functions are
  # called by name.
  [ -f "$bundle/system-optimize" ] && { shellcheck -e SC2317 "$bundle/system-optimize" || rc=1; }
else
  echo "shellcheck not installed; skipped" >&2
fi

[ "$rc" -eq 0 ] && echo "lint ok"
exit "$rc"
