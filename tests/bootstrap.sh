#!/bin/sh
# tests/bootstrap.sh - install what tests/install-smoke.sh needs in a stock
# distribution container: bash, curl, tar, gzip, diff, find, md5sum and
# sha256sum. Only what is missing is installed; on Alpine BusyBox provides
# the rest, so the program is tested with BusyBox's tools as Alpine ships
# them. POSIX sh: it runs before bash exists. Used by CI and tests/containers.sh.
set -e
need=""
for c in bash curl tar gzip diff find md5sum sha256sum; do
  command -v "$c" >/dev/null 2>&1 || need="$need $c"
done
[ -n "$need" ] || exit 0
echo "bootstrap: installing for:$need"
if command -v apk >/dev/null 2>&1; then
  apk add --no-cache bash curl ca-certificates
elif command -v dnf >/dev/null 2>&1; then
  # Rocky ships curl-minimal, which provides curl; do not ask for curl there.
  pkgs="bash tar gzip diffutils findutils"
  command -v curl >/dev/null 2>&1 || pkgs="$pkgs curl"
  # shellcheck disable=SC2086 # a word list
  dnf install -y -q $pkgs
elif command -v apt-get >/dev/null 2>&1; then
  apt-get update -q && apt-get install -y -q --no-install-recommends bash curl ca-certificates diffutils tar gzip findutils
elif command -v pacman >/dev/null 2>&1; then
  # -Syu, not -Sy: Arch does not support partial upgrades, and a new curl
  # against the image's old openssl fails (the openssl 4 move, Nov 2026).
  pacman -Syu --noconfirm --needed bash diffutils findutils tar gzip curl
elif command -v zypper >/dev/null 2>&1; then
  zypper -n install bash diffutils findutils tar gzip curl
else
  echo "bootstrap: no known package manager" >&2
  exit 1
fi
