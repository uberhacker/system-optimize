#!/usr/bin/env bash
# tests/install-smoke.sh - install.sh end to end, then the program against
# the machine it runs on.
#
#   tests/install-smoke.sh
#
# CI runs this inside the stock containers system-update is tested on
# (Ubuntu, Debian, Fedora, Rocky, Arch, openSUSE Tumbleweed and Leap,
# Alpine); tests/containers.sh does the same locally with docker. It works
# on any Linux machine with bash 4.4, tar, curl and coreutils or BusyBox.
# SO_EXPECT_PKG=NAME also checks the package manager --status detects.
# install.sh writes only into a temporary prefix (SO_SUDO empty: it never
# escalates).
#
# What it checks:
#   1. install.sh --prefix DIR installs the single file and the bash
#      completion; it answers --help, --version and --completion.
#   2. --status and --dry-run read the real /proc, /sys and /etc of this
#      machine (no sandbox) and finish without errors. Inside a container a
#      real run is refused without --force.
#   3. As root inside a container (CI): a real run with --force and then
#      --undo. Only the container's own files can change (the kernel, disk
#      and CPU steps skip themselves in a container); the run must save a
#      snapshot and --undo must put every file back.
#   4. --self-update --dry-run of the single file against a local fake
#      release: up to date, and refusing a release without a checksum.
#   5. install.sh --tree, back to the single file, --uninstall.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
prefix="$tmp/prefix"
version=$(tr -d '[:space:]' < "$root/VERSION")
so="$prefix/bin/system-optimize"

fail() { echo "install-smoke: FAIL: $*" >&2; exit 1; }

install_sh() { SO_SUDO='' "$root/install.sh" "$@"; }

# expect PATTERN CMD...: CMD must succeed and print PATTERN.
expect() {
  local pat="$1" out rc=0; shift
  out=$("$@" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || { printf '%s\n' "$out"; fail "'$*' exited $rc"; }
  [[ "$out" == *"$pat"* ]] || { printf '%s\n' "$out"; fail "'$*' did not print: $pat"; }
  printf '%s\n' "$out" > "$tmp/last.out"
}

# expect_fail PATTERN CMD...: CMD must fail and print PATTERN.
expect_fail() {
  local pat="$1" out rc=0; shift
  out=$("$@" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || { printf '%s\n' "$out"; fail "'$*' should have failed"; }
  [[ "$out" == *"$pat"* ]] || { printf '%s\n' "$out"; fail "'$*' did not print: $pat"; }
}

# in_container: the same test the program makes without systemd-detect-virt.
in_container() {
  [ -e /.dockerenv ] || [ -e /run/.containerenv ] ||
    { command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt --container >/dev/null 2>&1; }
}

export NO_COLOR=1 LOG_DIR="$tmp/logs" SNAPSHOT_DIR="$tmp/snapshots"
export SO_SYSTEM_CONFIG="$tmp/system-optimize.conf" SO_HOME="$tmp/home"
mkdir -p "$SO_HOME"
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME

# ---- 1. the single file
echo "== install.sh --prefix $prefix"
expect "(single file) to $so" install_sh --prefix "$prefix"
grep -q '^SO_BUNDLED=1$' "$so" || fail "$so is not a single-file build"
[ -f "$prefix/share/bash-completion/completions/system-optimize" ] || fail "no bash completion installed"
expect "Usage: system-optimize" "$so" --help
expect "system-optimize $version (" "$so" --version
expect "single file" "$so" --version
expect "complete -F _system_optimize" "$so" --completion bash

# ---- 2. this machine, read only
echo "== --status and --dry-run on this machine"
expect "Kernel settings" "$so" --status
cat "$tmp/last.out"
if [ -n "${SO_EXPECT_PKG:-}" ]; then
  grep -Eq "package manager: +$SO_EXPECT_PKG( |\$)" "$tmp/last.out" ||
    fail "--status did not detect the package manager $SO_EXPECT_PKG"
fi
expect "Summary (dry run)" "$so" --dry-run --yes
cat "$tmp/last.out"
grep -q ' 0 failed' "$tmp/last.out" || fail "the dry run reported a failed step"
ls "$LOG_DIR"/*-apply-*.log >/dev/null || fail "no log in $LOG_DIR"
[ ! -e "$SNAPSHOT_DIR" ] || fail "a dry run saved a snapshot"
expect_fail "refusing to continue: stdin is not a terminal" "$so" --force </dev/null
if in_container; then
  expect_fail "running in a container" "$so" --yes
fi

# ---- 3. a real run and its undo, as root in a container only
if in_container && [ "$(id -u)" -eq 0 ]; then
  echo "== --force --yes, then --undo --yes (container, root)"
  (cd /etc && find . -xdev -type f -exec md5sum {} + 2>/dev/null | LC_ALL=C sort -k2) > "$tmp/etc.sum.before"
  expect "going ahead because of --force" "$so" --force --yes
  cat "$tmp/last.out"
  grep -q ' 0 failed' "$tmp/last.out" || fail "the real run reported a failed step"
  if grep -q 'snapshot: ' "$tmp/last.out"; then
    expect "restored " "$so" --undo --yes
    cat "$tmp/last.out"
    (cd /etc && find . -xdev -type f -exec md5sum {} + 2>/dev/null | LC_ALL=C sort -k2) > "$tmp/etc.sum.after"
    if [ "$(cat "$tmp/etc.sum.before")" != "$(cat "$tmp/etc.sum.after")" ]; then
      diff "$tmp/etc.sum.before" "$tmp/etc.sum.after" 2>/dev/null || true
      fail "--undo did not restore /etc"
    fi
  else
    echo "(nothing to change in this container)"
  fi
fi

# ---- 4. --self-update --dry-run against a local fake release
echo "== self-update dry run"
rel="$tmp/rel/releases/latest/download"
mkdir -p "$rel"
cp "$so" "$rel/system-optimize"
(cd "$rel" && sha256sum system-optimize > system-optimize.sha256)
export SYSTEM_OPTIMIZE_ALLOW_FILE_SOURCE=1 SELF_UPDATE_REPO="file://$tmp/rel"
expect "already up to date: system-optimize $version" "$so" --self-update --dry-run
rm "$rel/system-optimize.sha256"
expect_fail "refusing an unverified update" "$so" --self-update
[ "$(sha256sum < "$so")" = "$(sha256sum < "$rel/system-optimize")" ] || fail "the single file was changed"
unset SYSTEM_OPTIMIZE_ALLOW_FILE_SOURCE SELF_UPDATE_REPO

# ---- 5. the tree layout, back to the single file, uninstall
echo "== install.sh --tree, then the single file again, then --uninstall"
expect "(tree) to $prefix/share/system-optimize" install_sh --prefix "$prefix" --tree
[ -d "$prefix/share/system-optimize/lib/tweaks" ] || fail "the tree has no lib/tweaks"
[ "$(readlink "$so")" = "$prefix/share/system-optimize/bin/system-optimize" ] || fail "the command does not point into the tree"
expect "system-optimize $version" "$so" --version
case "$("$so" --version)" in *"single file"*) fail "still the single file after --tree" ;; esac
expect "Summary (dry run)" "$so" -ny
expect "removed the previous tree installation" install_sh --prefix "$prefix"
[ ! -e "$prefix/share/system-optimize" ] || fail "the tree was left behind"
expect "single file" "$so" --version
install_sh --prefix "$prefix" --uninstall
if [ -e "$so" ] || [ -L "$so" ]; then fail "$so was left behind"; fi
[ ! -e "$prefix/share/bash-completion/completions/system-optimize" ] || fail "the completion was left behind"
expect "nothing of system-optimize found" install_sh --prefix "$prefix" --uninstall

echo "install-smoke: ok"
