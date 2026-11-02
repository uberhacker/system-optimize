#!/usr/bin/env bash
# tests/containers.sh - tests/install-smoke.sh inside stock distribution
# containers with docker, as CI does (see .github/workflows/ci.yml).
#
# Usage: tests/containers.sh [--restricted] [IMAGE...]
#   --restricted  for sandboxes that reach the network only through the
#                 host's HTTPS proxy: --network host, https_proxy passed in,
#                 and the proxy CA (CONTAINER_CA, default
#                 /root/.ccr/ca-bundle.crt) trusted inside the container.
#   IMAGE...      default: the CI matrix.
# Logs go to tests/containers.out/<image>.log. Exit status 1 when any failed.
set -uo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/tests/containers.out"
restricted=0
images=()
default=(ubuntu:24.04:apt debian:stable:apt fedora:latest:dnf rockylinux:9:dnf archlinux:latest:pacman
         opensuse/tumbleweed:zypper opensuse/leap:zypper alpine:latest:apk)

while [ $# -gt 0 ]; do
  case "$1" in
    --restricted) restricted=1 ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) images+=("$1") ;;
  esac
  shift
done
[ ${#images[@]} -gt 0 ] || images=("${default[@]}")
command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 2; }
mkdir -p "$out"

net=()
pre=":"
if [ "$restricted" = 1 ]; then
  proxy="${HTTPS_PROXY:-${https_proxy:-}}"
  [ -n "$proxy" ] || { echo "--restricted needs HTTPS_PROXY" >&2; exit 2; }
  ca="${CONTAINER_CA:-/root/.ccr/ca-bundle.crt}"
  net=(--network host -e "https_proxy=$proxy" -e "HTTPS_PROXY=$proxy" -e "http_proxy=$proxy" -e "HTTP_PROXY=$proxy")
  if [ -r "$ca" ]; then
    net+=(-v "$ca:/ca.crt:ro")
    # Trust the proxy CA wherever this image keeps its bundle.
    # shellcheck disable=SC2016 # expanded inside the container
    pre='for f in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/ca-bundle.pem; do [ -f "$f" ] && cat /ca.crt >> "$f"; done; [ -d /etc/pki/ca-trust/source/anchors ] && cp /ca.crt /etc/pki/ca-trust/source/anchors/proxy.crt; [ -d /usr/local/share/ca-certificates ] && cp /ca.crt /usr/local/share/ca-certificates/proxy.crt; export SSL_CERT_FILE=/ca.crt CURL_CA_BUNDLE=/ca.crt'
  fi
fi

rc=0
summary=()
for spec in "${images[@]}"; do
  case "$spec" in
    *:apt|*:dnf|*:pacman|*:zypper|*:apk|*:xbps) image="${spec%:*}"; pkg="${spec##*:}" ;;
    *) image="$spec"; pkg="" ;;
  esac
  log="$out/${image//[^A-Za-z0-9._-]/_}.log"
  echo "=== $image"
  if docker run --rm "${net[@]}" -v "$root:/src:ro" -e SO_EXPECT_PKG="$pkg" "$image" \
      sh -c "$pre; cp -r /src /tmp/so && cd /tmp/so && sh tests/bootstrap.sh && bash tests/install-smoke.sh" > "$log" 2>&1; then
    summary+=("$image: ok")
  else
    summary+=("$image: FAILED (see $log)")
    tail -n 25 "$log" | sed 's/^/    | /'
    rc=1
  fi
done
echo
printf '%s\n' "${summary[@]}"
exit "$rc"
