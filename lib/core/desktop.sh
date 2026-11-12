#!/usr/bin/env bash
# lib/core/desktop.sh - the desktop user and session, for the steps that
# change a desktop setting (fonts, display, the file indexer).
#
# The desktop user is the one who ran sudo (SUDO_USER), else the owner of
# the active graphical session (loginctl), else nobody. Settings are changed
# as that user (so_as_user / do_as_user), never as root.
#   SO_DESKTOP_USER     overrides the user (for tests and odd setups)
#   SO_DESKTOP          overrides the desktop: gnome, kde, other or none
#   SO_SESSION_TYPE     overrides the session type: wayland, x11 or tty

# _desktop_session_ids: the active graphical sessions' ids.
_desktop_session_ids() {
  has_cmd loginctl || return 0
  run loginctl list-sessions --no-legend 2>/dev/null | awk '{ print $1 }'
}

# _desktop_session_prop ID PROP
_desktop_session_prop() {
  run loginctl show-session "$1" -p "$2" --value 2>/dev/null
}

# desktop_session: the id of the active graphical session, or nothing.
desktop_session() {
  local id
  [ -z "${SO_DESKTOP_SESSION_ID:-}" ] || { printf '%s\n' "$SO_DESKTOP_SESSION_ID"; return 0; }
  for id in $(_desktop_session_ids); do
    case "$(_desktop_session_prop "$id" Type)" in
      wayland|x11) ;;
      *) continue ;;
    esac
    [ "$(_desktop_session_prop "$id" Active)" = yes ] || continue
    SO_DESKTOP_SESSION_ID="$id"
    printf '%s\n' "$id"
    return 0
  done
  return 0
}

# desktop_user: the user whose desktop settings to change, or nothing.
desktop_user() {
  local id u
  if [ -n "${SO_DESKTOP_USER:-}" ]; then printf '%s\n' "$SO_DESKTOP_USER"; return 0; fi
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then printf '%s\n' "$SUDO_USER"; return 0; fi
  if ! is_root; then id -un 2>/dev/null; return 0; fi
  id=$(desktop_session)
  [ -n "$id" ] || return 0
  u=$(_desktop_session_prop "$id" Name)
  [ -z "$u" ] || [ "$u" = root ] || printf '%s\n' "$u"
}

# _desktop_user_session_desktop USER: the Desktop of USER's graphical
# session, active or not (a locked screen, a second seat), or nothing.
_desktop_user_session_desktop() {
  local id d
  [ -n "$1" ] || return 0
  for id in $(_desktop_session_ids); do
    case "$(_desktop_session_prop "$id" Type)" in wayland|x11) ;; *) continue ;; esac
    [ "$(_desktop_session_prop "$id" Name)" = "$1" ] || continue
    d=$(_desktop_session_prop "$id" Desktop)
    [ -n "$d" ] && { printf '%s\n' "$d"; return 0; }
  done
  return 0
}

# _desktop_from_shell USER: GNOME or KDE from USER's running shell process,
# else from the one shell that is installed; nothing when neither tells.
_desktop_from_shell() {
  local g=0 k=0
  if [ -n "$1" ] && has_cmd pgrep; then
    run pgrep -u "$1" -x gnome-shell >/dev/null 2>&1 && { echo gnome; return 0; }
    run pgrep -u "$1" -x plasmashell >/dev/null 2>&1 && { echo kde; return 0; }
  fi
  [ -x "$(so_path /usr/bin/gnome-shell)" ] && g=1
  [ -x "$(so_path /usr/bin/plasmashell)" ] && k=1
  if [ "$g" = 1 ] && [ "$k" = 0 ]; then echo gnome
  elif [ "$k" = 1 ] && [ "$g" = 0 ]; then echo kde
  fi
  return 0
}

# desktop_kind: gnome, kde, other or none. Under sudo XDG_CURRENT_DESKTOP is
# gone, so the desktop comes from the active graphical session, then the
# desktop user's own session, then their running (or the installed) shell.
desktop_kind() {
  local d="${SO_DESKTOP:-}" id
  if [ -z "$d" ]; then
    d="${XDG_CURRENT_DESKTOP:-}"
    if [ -z "$d" ] && id=$(desktop_session) && [ -n "$id" ]; then
      d=$(_desktop_session_prop "$id" Desktop)
    fi
    [ -n "$d" ] || d=$(_desktop_user_session_desktop "$(desktop_user)")
    [ -n "$d" ] || d=$(_desktop_from_shell "$(desktop_user)")
  fi
  d="${d,,}"
  case "$d" in
    none) echo none ;;
    *gnome*|*ubuntu*|*pop*) echo gnome ;;
    *kde*|*plasma*) echo kde ;;
    "") echo none ;;
    *) echo other ;;
  esac
}

# desktop_session_type: wayland, x11 or tty.
desktop_session_type() {
  local t="${SO_SESSION_TYPE:-}" id
  if [ -z "$t" ] && id=$(desktop_session) && [ -n "$id" ]; then
    t=$(_desktop_session_prop "$id" Type)
  fi
  [ -n "$t" ] || t="${XDG_SESSION_TYPE:-tty}"
  case "$t" in wayland|x11) echo "$t" ;; *) echo tty ;; esac
}

# gsettings_get USER SCHEMA KEY: the value as gsettings prints it.
gsettings_get() {
  has_cmd gsettings || return 1
  so_as_user "$1" gsettings get "$2" "$3" 2>/dev/null
}

# gsettings_set USER SCHEMA KEY VALUE: set it, recorded for --undo.
# Returns 3 when it already has the value.
gsettings_set() {
  local user="$1" schema="$2" key="$3" value="$4" prev
  prev=$(gsettings_get "$user" "$schema" "$key") || { log_warn "gsettings: no $schema $key"; return 1; }
  [ "$prev" = "$value" ] && return 3
  if [ "$SO_DRY_RUN" = 1 ]; then
    log_dry "would set $schema $key for $user: $prev -> $value"
    plan_note gsettings "$schema $key ($user)" "$prev" "$value"
    return 0
  fi
  snap_record gsettings "$user:$schema:$key" "$prev" "$value" || return 1
  do_as_user "$user" gsettings set "$schema" "$key" "$value"
}

# kconfig_get USER FILE GROUP KEY: a KDE setting (empty when unset).
kconfig_get() {
  local tool=kreadconfig6
  has_cmd "$tool" || tool=kreadconfig5
  has_cmd "$tool" || return 1
  so_as_user "$1" "$tool" --file "$2" --group "$3" --key "$4" 2>/dev/null
}

# kconfig_set USER FILE GROUP KEY VALUE: set it, recorded for --undo.
# Returns 3 when it already has the value.
kconfig_set() {
  local user="$1" file="$2" group="$3" key="$4" value="$5" prev
  has_cmd kwriteconfig6 || has_cmd kwriteconfig5 || { log_warn "no kwriteconfig"; return 1; }
  prev=$(kconfig_get "$user" "$file" "$group" "$key") || prev=""
  [ "$prev" = "$value" ] && return 3
  if [ "$SO_DRY_RUN" = 1 ]; then
    log_dry "would set $file [$group] $key for $user: ${prev:-(unset)} -> $value"
    plan_note kconfig "$file $group $key ($user)" "${prev:-unset}" "$value"
    return 0
  fi
  snap_record kconfig "$user:$file:$group:$key" "$prev" "$value" || return 1
  _kconfig_write "$user" "$file" "$group" "$key" "$value"
}

# on_ac_power: the machine runs on mains power (true without a battery).
on_ac_power() {
  local d t online=""
  for d in "$(so_path /sys/class/power_supply)"/*; do
    [ -r "$d/type" ] || continue
    t=$(read_line "$d/type") || continue
    case "$t" in
      Mains|USB)
        if [ "$(read_line "$d/online" 2>/dev/null)" = 1 ]; then return 0; fi
        online=0 ;;
    esac
  done
  [ "$online" != 0 ]
}
