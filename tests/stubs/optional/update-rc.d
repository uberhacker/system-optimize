#!/usr/bin/env bash
# update-rc.d stub (SysV init): "NAME defaults" links S01NAME into
# $SO_ROOT/etc/rc{2,3,4,5}.d; "-f NAME remove" removes every link of NAME.
printf 'update-rc.d %s\n' "$*" >> "${STUB_LOG:-/dev/null}"
[ "${1:-}" = -f ] && shift
name="${1:-}" action="${2:-}"
case "$action" in
  defaults)
    for l in 2 3 4 5; do
      mkdir -p "${SO_ROOT:-}/etc/rc$l.d"
      ln -sfn "../init.d/$name" "${SO_ROOT:-}/etc/rc$l.d/S01$name"
    done ;;
  remove) rm -f "${SO_ROOT:-}"/etc/rc[0-6S].d/[SK][0-9][0-9]"$name" ;;
esac
exit "${STUB_EXIT_update_rc_d:-0}"
