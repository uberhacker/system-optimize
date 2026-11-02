#!/usr/bin/env bash
# make-tarball.sh OUTDIR - the source tarball the RPM and deb builds use:
# system-optimize-tray-VERSION.tar.gz holding tray/, gnome-extension/,
# packaging/ and LICENSE under system-optimize-tray-VERSION/.
set -euo pipefail
out="${1:-dist}"
top="$(cd "$(dirname "$0")/.." && pwd)"
version="$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import so_tray; print(so_tray.VERSION)' "$top/tray")"
name="system-optimize-tray-$version"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
tar -C "$top" --exclude=__pycache__ --exclude='*.pyc' --exclude=dist --exclude=screenshots-out \
    --transform "s,^,$name/," -czf "$out/$name.tar.gz" LICENSE tray gnome-extension packaging
echo "$out/$name.tar.gz"
