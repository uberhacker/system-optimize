#!/usr/bin/env bash
# tests/sysvinit.sh - install.sh and the program on a machine that runs SysV
# init as PID 1 with systemd's tools installed beside it, as MX Linux does.
#
#   tests/sysvinit.sh            build the image, boot it, run the checks
#   tests/sysvinit.sh --inside   the checks themselves (run in the container)
#
# Needs docker. SO_SYSV_IMAGE picks the base image (default debian:12, which
# MX Linux 23 is built on; Ubuntu works too, with sysvinit-core from universe).
# The container boots /sbin/init from sysvinit-core, so /run/initctl and the
# /etc/init.d services are real; systemctl is installed and answers "System
# has not been booted with systemd as init system", which is what broke
# Debian's pcp package for Ed. Docker's Debian images ship a policy-rc.d
# that stops every service from starting; a booted machine has none, so the
# image removes it.
#
# What it checks:
#   1. --status names SysV init and says systemctl is there without systemd.
#   2. install.sh --full leaves out PCP and the other systemd-only parts,
#      installs no package, and leaves dpkg clean (dpkg --audit is empty).
#   3. tests/install-smoke.sh passes here too (real run with --force, then
#      --undo puts /etc back).
#   4. The tools step with --install-tools installs earlyoom with apt,
#      enables it with update-rc.d and starts it through its init script;
#      --undo stops it and removes the package (apt-get remove keeps the
#      init script and its links as conffiles, as Debian always does).
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

fail() { echo "sysvinit: FAIL: $*" >&2; exit 1; }

if [ "${1:-}" != --inside ]; then
  image="${SO_SYSV_IMAGE:-debian:12}"
  tag=system-optimize-sysvinit-test
  name="so-sysvinit-$$"
  build=$(mktemp -d)
  trap 'docker rm -f "$name" >/dev/null 2>&1 || true; rm -rf -- "$build"' EXIT
  cat > "$build/Dockerfile" <<EOF
FROM $image
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -q \\
 && apt-get install -y -q --no-install-recommends sysvinit-core systemd procps bash curl \\
      ca-certificates diffutils findutils tar gzip \\
 && sed -i '/getty/d' /etc/inittab \\
 && rm -f /usr/sbin/policy-rc.d
CMD ["/sbin/init"]
EOF
  echo "== building $tag from $image (SysV init with systemctl installed)"
  # Extra docker flags, split on spaces (for example a proxy build arg).
  read -r -a build_args <<<"${SO_SYSV_BUILD_ARGS:-}"
  read -r -a run_args <<<"${SO_SYSV_RUN_ARGS:-}"
  docker build -q -t "$tag" "${build_args[@]}" "$build" >/dev/null
  docker run -d --name "$name" "${run_args[@]}" "$tag" >/dev/null
  for _ in $(seq 1 30); do
    docker exec "$name" test -p /run/initctl 2>/dev/null && break
    sleep 1
  done
  docker exec "$name" test -p /run/initctl || fail "SysV init did not come up in the container"
  [ "$(docker exec "$name" cat /proc/1/comm)" = init ] || fail "PID 1 is not SysV init"
  docker exec "$name" mkdir -p /src
  tar -C "$root" --exclude=.git --exclude=tests/vendor -cf - . | docker exec -i "$name" tar -C /src -xf -
  docker exec "$name" bash /src/tests/sysvinit.sh --inside
  exit
fi

# ---- inside the container ---------------------------------------------------
cd "$root"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
prefix="$tmp/prefix"
so="$prefix/bin/system-optimize"
export NO_COLOR=1 LOG_DIR="$tmp/logs" SNAPSHOT_DIR="$tmp/snapshots"
export SO_SYSTEM_CONFIG="$tmp/system-optimize.conf" SO_HOME="$tmp/home"
export SO_INSTALL_MANIFEST="$tmp/installer.manifest"
mkdir -p "$SO_HOME"

[ -p /run/initctl ] || fail "not running under SysV init"
command -v systemctl >/dev/null || fail "systemctl should be installed, as on MX Linux"
[ ! -d /run/systemd/system ] || fail "systemd must not be running"

echo "== 2. install.sh --full --yes"
out=$(SO_SUDO='' ./install.sh --full --yes --prefix "$prefix" 2>&1) || { printf '%s\n' "$out"; fail "install.sh --full failed"; }
printf '%s\n' "$out"
[[ "$out" == *"pcp: needs systemd, and this system runs SysV init"* ]] || fail "--full did not say why PCP was left out"
dpkg-query -W -f='${Status}\n' pcp pcp-zeroconf 2>/dev/null | grep -q 'ok installed' && fail "PCP was installed"
[ -z "$(dpkg --audit)" ] || { dpkg --audit; fail "dpkg has packages left half set up"; }
! grep -q '^pkg' "$SO_INSTALL_MANIFEST" || fail "install.sh installed a package"

echo "== 1. status"
out=$("$so" status 2>&1)
[[ "$out" == *"sysvinit (systemctl is installed, but systemd is not running"* ]] || { printf '%s\n' "$out"; fail "status did not name SysV init"; }

echo "== 3. tests/install-smoke.sh"
SO_EXPECT_PKG=apt bash tests/install-smoke.sh

echo "== 4. the tools step: earlyoom through apt and update-rc.d, and --undo"
out=$("$so" apply tools --install-tools --force --yes 2>&1) || { printf '%s\n' "$out"; fail "tools --install-tools failed"; }
printf '%s\n' "$out"
dpkg-query -W -f='${Status}' earlyoom 2>/dev/null | grep -q 'ok installed' || fail "earlyoom was not installed"
compgen -G '/etc/rc2.d/S[0-9][0-9]earlyoom' >/dev/null || fail "earlyoom has no start link in /etc/rc2.d"
service earlyoom status >/dev/null 2>&1 || fail "earlyoom is not running"
out=$("$so" undo --yes 2>&1) || { printf '%s\n' "$out"; fail "undo failed"; }
printf '%s\n' "$out"
! service earlyoom status >/dev/null 2>&1 || fail "earlyoom still runs"
! dpkg-query -W -f='${Status}' earlyoom 2>/dev/null | grep -q 'ok installed' || fail "earlyoom is still installed"
[ -z "$(dpkg --audit)" ] || { dpkg --audit; fail "dpkg has packages left half set up"; }

echo "sysvinit: all checks passed"
