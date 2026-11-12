#!/usr/bin/env bash
# lib/core/snapshot.sh - every change goes through here, so that --undo can
# put it back.
#
# A snapshot is a directory under SNAPSHOT_DIR (default
# /var/lib/system-optimize/snapshots) named after the time of the run,
# YYYYmmdd-HHMMSS. It holds:
#   info       what made it (version, time, host, command line, profile)
#   manifest   one tab-separated line per thing that was changed, in order:
#                KIND  TARGET  BEFORE  STEP  AFTER  TIME
#              STEP is the step that made the change, AFTER the new value
#              (for the history) and TIME when (ISO 8601). Snapshots made by
#              2.0 have only the first three fields. The kinds:
#                file      PATH          absent | saved:N  (files/N is the old copy)
#                sysctl    KEY           the value before
#                sysfs     PATH          the value before
#                unit      UNIT          enabled | disabled | ...  (systemd)
#                gunit     UNIT          enabled | disabled  (a user unit, for every user)
#                svc       INIT:NAME     enabled | disabled  (OpenRC or runit)
#                ppd       -             the power-profiles-daemon profile before
#                tuned     -             the tuned profile(s) before
#                pkg       NAME          installed  (installed by this run)
#                gsettings USER:SCHEMA:KEY  the value before (GVariant text)
#                kconfig   USER:FILE:GROUP:KEY  the value before ("" = unset)
#                kscreen   USER:OUTPUT:SETTING  the value before
#                mount     MOUNTPOINT    the option that puts it back (relatime, compress=no)
#                group     USER:GROUP    absent  (USER was added to GROUP)
#                flatpak   REF           the remote it came from (removed by this run)
#                initramfs -             -   (the initramfs was rebuilt)
#   files/     copies of the files that were replaced or removed
#   undone-entries  "LINE<TAB>TIME" for each line undone by --undo --only
#   undone     written by --undo once every line has been restored
#   pending    written by --safe-apply: the time the rollback is due
# Paths in the manifest are the real system paths (without SO_ROOT). The
# directory is 0700 and created on the first change of a real run; a dry
# run never creates one. What a user may read of it (the changes, without
# file contents) is copied into the history (lib/core/history.sh).

SO_SNAP=""          # the current run's snapshot directory, once created
SO_SNAP_COUNT=0     # entries recorded by this run
SO_PLAN=()          # with SO_PLAN_CAPTURE=1: "KIND<TAB>TARGET<TAB>CURRENT<TAB>WANTED"
SO_PLAN_CAPTURE=0

# tsv_split LINE: SO_F=(the tab-separated fields of LINE). Unlike `read`
# with IFS=tab, empty fields are kept.
tsv_split() {
  local l="$1"
  SO_F=()
  while [[ "$l" == *$'\t'* ]]; do
    SO_F+=("${l%%$'\t'*}")
    l="${l#*$'\t'}"
  done
  SO_F+=("$l")
}

# iso_now: the time now, ISO 8601 with the offset (2026-11-01T16:20:05+01:00).
iso_now() {
  local t
  printf -v t '%(%Y-%m-%dT%H:%M:%S%z)T' -1
  printf '%s:%s\n' "${t:0:22}" "${t:22}"
}

# epoch_now: seconds since 1970.
epoch_now() { printf '%(%s)T\n' -1; }

# snap_base: where snapshots live.
snap_base() {
  local d
  d=$(cfg SNAPSHOT_DIR)
  if [ -n "$d" ]; then
    printf '%s\n' "$d"
  else
    so_path /var/lib/system-optimize/snapshots
  fi
}

# snap_begin: create this run's snapshot (once).
snap_begin() {
  local base name dir
  [ -n "$SO_SNAP" ] && return 0
  [ "$SO_DRY_RUN" = 1 ] && return 1
  base=$(snap_base)
  # The parents keep the usual 0755 (the tray reads the history beside
  # them); only the snapshot directory itself is private.
  { mkdir -p -- "${base%/*}" && (umask 077; mkdir -p -- "$base"); } || { log_error "cannot create the snapshot directory $base"; return 1; }
  name=$(printf '%(%Y%m%d-%H%M%S)T' -1)
  dir="$base/$name"
  [ -e "$dir" ] && dir="$base/$name-$$"
  (umask 077; mkdir -p -- "$dir/files") || { log_error "cannot create the snapshot $dir"; return 1; }
  : > "$dir/manifest"
  {
    printf 'version  %s\n' "$(version_string)"
    printf 'created  %s\n' "$(iso_now)"
    printf 'host     %s\n' "$(uname -n 2>/dev/null || echo unknown)"
    printf 'command  %s\n' "${SO_COMMAND_LINE:-system-optimize}"
    printf 'profile  %s\n' "${SO_PROFILE:--}"
  } > "$dir/info"
  SO_SNAP="$dir"
  log_detail "snapshot: $dir"
}

# snap_id: the current snapshot's name, or empty.
snap_id() { [ -z "$SO_SNAP" ] || printf '%s\n' "${SO_SNAP##*/}"; }

# snap_has KIND TARGET: already recorded by the step running now (its first
# record of a target holds the state before the step, so later ones are
# dropped). Two steps that change the same target (noatime and btrfs both
# edit /etc/fstab) each keep their own record: undoing the run goes newest
# first and ends at the state before the run, and undoing one step puts
# back the state before that step.
snap_has() {
  [ -n "$SO_SNAP" ] || return 1
  awk -F '\t' -v k="$1" -v t="$2" -v s="${SO_CURRENT_STEP:--}" \
    '$1 == k && $2 == t && $4 == s { found = 1; exit } END { exit !found }' "$SO_SNAP/manifest"
}

# snap_record KIND TARGET BEFORE [AFTER]: add a manifest line for the step
# running now.
snap_record() {
  local kind="$1" target="$2" value="$3" after="${4:--}"
  snap_begin || return 1
  snap_has "$kind" "$target" && return 0
  value="${value//[$'\t\n']/ }"
  after="${after//[$'\t\n']/ }"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$kind" "$target" "$value" "${SO_CURRENT_STEP:--}" "$after" "$(iso_now)" \
    >> "$SO_SNAP/manifest"
  SO_SNAP_COUNT=$((SO_SNAP_COUNT + 1))
}

# plan_note KIND TARGET CURRENT WANTED: in a dry run, what would change
# (collected for --describe and --check-drift).
plan_note() {
  [ "$SO_PLAN_CAPTURE" = 1 ] || return 0
  SO_PLAN+=("$1"$'\t'"$2"$'\t'"${3//[$'\t\n']/ }"$'\t'"${4//[$'\t\n']/ }")
}

# snap_file PATH AFTER: save PATH (a system path) before it is replaced or
# removed (AFTER: written or removed).
snap_file() {
  local path="$1" after="${2:-written}" real n
  real=$(so_path "$path")
  snap_begin || return 1
  snap_has file "$path" && return 0
  if [ -e "$real" ] || [ -L "$real" ]; then
    n=$((SO_SNAP_COUNT + 1))
    cp -a -- "$real" "$SO_SNAP/files/$n" || { log_error "could not back up $path"; return 1; }
    snap_record file "$path" "saved:$n" "$after"
  else
    snap_record file "$path" absent "$after"
  fi
}

# ---------------------------------------------------------------------------
# Changing things (each records first, then changes; a dry run only reports)
# ---------------------------------------------------------------------------
# file_differs PATH NEWFILE: is the installed PATH missing or different?
# The "Written by system-optimize (VERSION)" header line does not count: a
# file an older build wrote holds the same settings, and rewriting it after
# every upgrade would make a snapshot for a comment and show every step as
# off (the tray's switches) until it was applied again.
file_differs() {
  local real
  real=$(so_path "$1")
  [ -f "$real" ] || return 0
  [ "$(_file_body "$real")" != "$(_file_body "$2")" ]
}

_file_body() { grep -v 'Written by system-optimize' -- "$1" || true; }

# install_file PATH MODE < CONTENT: put CONTENT at PATH (a system path).
# Never call it at the end of a pipeline (`cmd | install_file`): it would
# run in a subshell and the snapshot it starts would be lost to the run.
# Feed it with < FILE or < <(cmd).
# Returns 0 when it was written (or would be), 3 when PATH already holds
# exactly that, 1 on failure.
install_file() {
  local path="$1" mode="${2:-0644}" real tmp staged
  real=$(so_path "$path")
  tmp=$(tmp_file) || return 1
  cat > "$tmp"
  if ! file_differs "$path" "$tmp"; then
    log_detail "$path is already up to date"
    return 3
  fi
  if [ "$SO_DRY_RUN" = 1 ]; then
    if [ -e "$real" ]; then
      log_dry "would replace $path"
      plan_note file "$path" present written
    else
      log_dry "would create $path"
      plan_note file "$path" absent written
    fi
    _log_verbose "$(sed 's/^/      | /' "$tmp")"
    return 0
  fi
  snap_file "$path" written || return 1
  mkdir -p -- "$(dirname "$real")" || return 1
  staged="$(dirname "$real")/.system-optimize.$$.tmp"
  { cp -- "$tmp" "$staged" && chmod "$mode" "$staged" && mv -f -- "$staged" "$real"; } || {
    rm -f -- "$staged"
    log_error "could not write $path"
    return 1
  }
  log_cmd "wrote $path"
  return 0
}

# remove_file PATH: remove a system file (backed up first).
remove_file() {
  local path="$1" real
  real=$(so_path "$path")
  [ -e "$real" ] || [ -L "$real" ] || return 0
  if [ "$SO_DRY_RUN" = 1 ]; then
    log_dry "would remove $path"
    plan_note file "$path" present removed
    return 0
  fi
  snap_file "$path" removed || return 1
  rm -f -- "$real" || { log_error "could not remove $path"; return 1; }
  log_cmd "removed $path"
}

# write_sysfs PATH VALUE PREVIOUS: write VALUE to a /sys file (a system
# path), recording PREVIOUS for --undo.
write_sysfs() {
  local path="$1" value="$2" prev="$3"
  if [ "$SO_DRY_RUN" = 1 ]; then
    log_dry "would set $path: $prev -> $value"
    plan_note sysfs "$path" "$prev" "$value"
    return 0
  fi
  snap_record sysfs "$path" "$prev" "$value" || return 1
  log_cmd "echo $value > $path"
  if ! printf '%s\n' "$value" > "$(so_path "$path")" 2>/dev/null; then
    log_warn "could not write $value to $path"
    return 1
  fi
}

# unit_set UNIT enable|disable: enable --now or disable --now a systemd
# unit, recording its state before.
unit_set() {
  local unit="$1" action="$2" prev
  prev=$(unit_enabled_state "$unit")
  if [ "$SO_DRY_RUN" = 1 ]; then
    log_dry "would run: systemctl $action --now $unit"
    plan_note unit "$unit" "$prev" "${action}d"
    return 0
  fi
  snap_record unit "$unit" "$prev" "${action}d" || return 1
  run systemctl "$action" --now "$unit"
}

# gunit_set UNIT enable|disable: a user unit for every user (systemctl
# --global), recording its state before. Takes effect at the next login.
gunit_set() {
  local unit="$1" action="$2" prev
  prev=$(run systemctl --global is-enabled "$unit" 2>/dev/null) || prev=disabled
  prev="${prev//[^a-z-]/}"
  if [ "$SO_DRY_RUN" = 1 ]; then
    log_dry "would run: systemctl --global $action $unit"
    plan_note unit "$unit (every user)" "$prev" "${action}d"
    return 0
  fi
  snap_record gunit "$unit" "$prev" "${action}d" || return 1
  run systemctl --global "$action" "$unit"
}

# svc_set NAME enable|disable: enable and start, or stop and disable, a
# service by its base name with whichever init runs, recording its state
# before. systemd goes through unit_set; OpenRC uses rc-update and
# rc-service (default runlevel); runit links /etc/sv/NAME into the service
# directory, which runsvdir starts within seconds; SysV init uses
# update-rc.d (or chkconfig) and the service's /etc/init.d script.
svc_set() {
  local name="$1" action="$2" prev
  case "$SO_INIT_SYSTEM" in
    systemd) unit_set "$name.service" "$action"; return ;;
    openrc|runit|sysvinit) ;;
    *) log_warn "$name: no init system to $action it with"; return 1 ;;
  esac
  prev=$(svc_enabled_state "$name")
  if [ "$prev" = absent ]; then
    log_warn "$name: no $(init_label) service of that name"
    return 1
  fi
  if [ "$SO_DRY_RUN" = 1 ]; then
    log_dry "would $action the $(init_label) service $name"
    plan_note unit "$name" "$prev" "${action}d"
    return 0
  fi
  snap_record svc "$SO_INIT_SYSTEM:$name" "$prev" "${action}d" || return 1
  _svc_apply "$SO_INIT_SYSTEM" "$name" "$action"
}

# _svc_apply INIT NAME enable|disable: the change itself (also for --undo).
_svc_apply() {
  local init="$1" name="$2" action="$3" dir
  case "$init:$action" in
    openrc:enable)
      do_run rc-update add "$name" default || return 1
      do_run rc-service "$name" start ;;
    openrc:disable)
      do_run rc-service "$name" stop || true
      do_run rc-update del "$name" default ;;
    runit:enable)
      dir=$(svc_runit_dir)
      [ -e "$(so_path "$dir/$name")" ] && return 0
      do_run ln -s "/etc/sv/$name" "$(so_path "$dir/$name")" ;;
    runit:disable)
      dir=$(svc_runit_dir)
      [ -L "$(so_path "$dir/$name")" ] || return 0
      has_cmd sv && { do_run sv down "$name" || true; }
      do_run rm -f -- "$(so_path "$dir/$name")" ;;
    sysvinit:enable)
      if has_cmd update-rc.d; then do_run update-rc.d "$name" defaults || return 1
      elif has_cmd chkconfig; then do_run chkconfig "$name" on || return 1
      else log_warn "$name: neither update-rc.d nor chkconfig is here to enable it"; return 1
      fi
      _sysv_service "$name" start ;;
    sysvinit:disable)
      _sysv_service "$name" stop || true
      if has_cmd update-rc.d; then do_run update-rc.d -f "$name" remove
      elif has_cmd chkconfig; then do_run chkconfig "$name" off
      else return 1
      fi ;;
    *) return 1 ;;
  esac
}

# _sysv_service NAME start|stop: through invoke-rc.d or service when there,
# else the init script itself.
_sysv_service() {
  if has_cmd invoke-rc.d; then do_run invoke-rc.d "$1" "$2"
  elif has_cmd service; then do_run service "$1" "$2"
  else do_run "$(so_path "/etc/init.d/$1")" "$2"
  fi
}

# pkg_add NAME: install a package, recording it for --undo (which removes
# it). A package already installed is left alone and not recorded.
pkg_add() {
  local name="$1"
  pkg_installed "$name" && return 0
  if [ "$SO_DRY_RUN" = 1 ]; then
    log_dry "would install $name"
    plan_note pkg "$name" absent installed
    return 0
  fi
  pkg_install "$name" || return 1
  snap_record pkg "$name" installed installed
}

# ---------------------------------------------------------------------------
# Listing and restoring
# ---------------------------------------------------------------------------
# snap_ids: every snapshot name, oldest first.
snap_ids() {
  local d base
  base=$(snap_base)
  for d in "$base"/[0-9]*; do
    [ -f "$d/manifest" ] && printf '%s\n' "${d##*/}"
  done
  return 0
}

# snap_entry_undone DIR N: line N of the snapshot DIR was undone.
snap_entry_undone() {
  [ -e "$1/undone" ] && return 0
  grep -q "^$2"$'\t' "$1/undone-entries" 2>/dev/null
}

# snap_open_count DIR: lines not undone yet.
snap_open_count() {
  local dir="$1" n=0 i total
  [ -e "$dir/undone" ] && { echo 0; return 0; }
  total=$(grep -c '' "$dir/manifest" 2>/dev/null) || total=0
  for ((i = 1; i <= total; i++)); do
    snap_entry_undone "$dir" "$i" || n=$((n + 1))
  done
  echo "$n"
}

# snap_latest: the newest snapshot not yet (wholly) undone.
snap_latest() {
  local id last="" base
  base=$(snap_base)
  while IFS= read -r id; do
    [ -e "$base/$id/undone" ] || last="$id"
  done < <(snap_ids)
  [ -n "$last" ] || return 1
  printf '%s\n' "$last"
}

# snap_steps DIR: the steps that made the snapshot's changes.
snap_steps() {
  awk -F '\t' 'NF >= 4 && $4 != "-" && !seen[$4]++ { printf "%s%s", (n++ ? " " : ""), $4 } END { print "" }' "$1/manifest"
}

# snap_summary ID: "N change(s) (steps)" and the undone mark.
snap_summary() {
  local dir n open steps
  dir="$(snap_base)/$1"
  n=$(grep -c . "$dir/manifest" 2>/dev/null) || n=0
  steps=$(snap_steps "$dir")
  printf '%s change(s)' "$n"
  [ -z "$steps" ] || printf ' (%s)' "$steps"
  if [ -e "$dir/undone" ]; then
    printf ', undone %s' "$(read_line "$dir/undone")"
  else
    open=$(snap_open_count "$dir")
    [ "$open" = "$n" ] || printf ', %s undone' "$((n - open))"
  fi
  [ -e "$dir/pending" ] && printf ', rollback due %s unless confirmed' "$(read_line "$dir/pending")"
  printf '\n'
}

# list_snapshots_main: --list-snapshots.
list_snapshots_main() {
  local id n=0 base
  base=$(snap_base)
  log_plain "Snapshots in $base:"
  while IFS= read -r id; do
    n=$((n + 1))
    log_kv "$id" "$(snap_summary "$id")"
  done < <(snap_ids)
  [ "$n" -gt 0 ] || log_plain "  (none)"
  return 0
}

# _undo_valid KIND TARGET VALUE STEP: a manifest line we are willing to act
# on. The manifest is root's, in a 0700 directory, but it is still checked:
# files only under /etc, values only to /sys, names only of a safe shape.
_undo_valid() {
  local kind="$1" target="$2" value="$3" step="${4:--}"
  [[ "$step" =~ ^[a-z0-9-]+$ ]] || return 1
  case "$kind" in
    file)
      [[ "$target" =~ ^/etc/[A-Za-z0-9_.@+/-]+$ ]] && [[ "$target" != *..* ]] &&
        [[ "$value" =~ ^(absent|saved:[0-9]+)$ ]] ;;
    sysctl) [[ "$target" =~ ^[a-z0-9_.-]+$ ]] && [[ "$value" =~ ^[A-Za-z0-9\ _.-]*$ ]] ;;
    sysfs)
      [[ "$target" =~ ^/sys/[A-Za-z0-9_./:-]+$ ]] && [[ "$target" != *..* ]] &&
        [[ "$value" =~ ^[A-Za-z0-9_.+-]*$ ]] ;;
    unit|gunit) [[ "$target" =~ ^[A-Za-z0-9@._-]+$ ]] && [[ "$value" =~ ^[a-z-]+$ ]] ;;
    svc) [[ "$target" =~ ^(openrc|runit|sysvinit):[A-Za-z0-9@._-]+$ ]] && [[ "$value" =~ ^(enabled|disabled)$ ]] ;;
    ppd) [[ "$value" =~ ^[A-Za-z0-9_.-]*$ ]] ;;
    tuned) [[ "$value" =~ ^[A-Za-z0-9_.\ -]*$ ]] ;;
    pkg) [[ "$target" =~ ^[A-Za-z0-9+._-]+$ ]] ;;
    gsettings)
      [[ "$target" =~ ^[a-z_][a-z0-9_-]*:[A-Za-z0-9.-]+:[a-z0-9-]+$ ]] && [[ "$value" =~ ^[[:print:]]*$ ]] ;;
    kconfig)
      [[ "$target" =~ ^[a-z_][a-z0-9_-]*:[A-Za-z0-9._-]+:[A-Za-z0-9\ ._-]+:[A-Za-z0-9\ ._-]+$ ]] &&
        [[ "$value" =~ ^[[:print:]]*$ ]] ;;
    kscreen)
      [[ "$target" =~ ^[a-z_][a-z0-9_-]*:[A-Za-z0-9._-]+:(vrrpolicy|mode)$ ]] && [[ "$value" =~ ^[A-Za-z0-9@x._-]+$ ]] ;;
    mount) [[ "$target" =~ ^/[A-Za-z0-9_./-]*$ ]] && [[ "$target" != *..* ]] && [[ "$value" =~ ^[a-z0-9=:_-]+$ ]] ;;
    group) [[ "$target" =~ ^[a-z_][a-z0-9_-]*:[a-z_][a-z0-9_-]*$ ]] ;;
    flatpak) [[ "$target" =~ ^(runtime|app)/[A-Za-z0-9._-]+/[A-Za-z0-9_]+/[A-Za-z0-9._-]+$ ]] && [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]] ;;
    initramfs) true ;;
    *) return 1 ;;
  esac
}

# so_as_user USER CMD...: run CMD as the desktop USER, with their session bus.
so_as_user() {
  local user="$1" uid; shift
  uid=$(id -u "$user" 2>/dev/null) || return 1
  if [ "$(id -un 2>/dev/null)" = "$user" ]; then
    run env DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$uid/bus}" "$@"
  elif has_cmd runuser; then
    run runuser -u "$user" -- env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" XDG_RUNTIME_DIR="/run/user/$uid" "$@"
  else
    run su -s /bin/sh "$user" -c 'exec "$@"' sh env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" XDG_RUNTIME_DIR="/run/user/$uid" "$@"
  fi
}

# do_as_user USER CMD...: so_as_user, or "would run" in a dry run.
do_as_user() {
  local user="$1"; shift
  if [ "$SO_DRY_RUN" = 1 ]; then
    log_dry "would run as $user: $(so_quote "$@")"
    return 0
  fi
  log_cmd "as $user: $(so_quote "$@")"
  so_as_user "$user" "$@"
}

# initramfs_rebuild: regenerate the initramfs with the distribution's tool.
initramfs_rebuild() {
  if has_cmd dracut; then do_run dracut --force --quiet
  elif has_cmd update-initramfs; then do_run update-initramfs -u
  elif has_cmd mkinitcpio; then do_run mkinitcpio -P
  elif has_cmd mkinitfs; then do_run mkinitfs
  else
    log_warn "no initramfs tool (dracut, update-initramfs, mkinitcpio, mkinitfs) found"
    return 1
  fi
}

# _tuned_without NAME LIST: LIST of tuned profiles without NAME.
_tuned_without() {
  local p out=""
  for p in $2; do [ "$p" = "$1" ] || out+="${out:+ }$p"; done
  printf '%s\n' "$out"
}

# _undo_restart_for PATH: what to restart (or daemon-reload) after PATH is
# restored, for services that read their configuration only at start.
_undo_restart_for() {
  [ "$SO_HAS_SYSTEMD" = 1 ] || return 0
  case "$1" in
    /etc/systemd/system/*) echo daemon-reload ;;
    /etc/tuned/ppd.conf) echo tuned-ppd.service ;;
    /etc/tuned/*) echo tuned.service ;;
    /etc/systemd/resolved.conf.d/*) echo systemd-resolved.service ;;
    /etc/systemd/journald.conf.d/*) echo systemd-journald.service ;;
    /etc/NetworkManager/conf.d/*) echo NetworkManager.service ;;
    /etc/scx_loader/*) echo scx_loader.service ;;
  esac
}

# _undo_entry SNAPDIR KIND TARGET VALUE: put one thing back.
_undo_entry() {
  local dir="$1" kind="$2" target="$3" value="$4" real user rest cur
  case "$kind" in
    file)
      real=$(so_path "$target")
      if [ "$value" = absent ]; then
        [ -e "$real" ] || [ -L "$real" ] || return 0
        do_run rm -f -- "$real" || return 1
        [ "$SO_DRY_RUN" = 1 ] || log_info "removed $target"
      else
        if [ "$SO_DRY_RUN" = 1 ]; then log_dry "would restore $target"; return 0; fi
        if ! { mkdir -p -- "$(dirname "$real")" &&
               cp -a -- "$dir/files/${value#saved:}" "$real.system-optimize-undo" &&
               mv -f -- "$real.system-optimize-undo" "$real"; }; then
          log_error "could not restore $target"
          return 1
        fi
        log_info "restored $target"
      fi ;;
    sysctl)
      # A dirty_*bytes or dirty_*ratio of 0 means "the other one is in
      # use"; writing it would fail. Its partner restores both.
      if [ "$value" = 0 ] && [[ "$target" =~ ^vm\.dirty_(background_)?(bytes|ratio)$ ]]; then
        return 0
      fi
      [ -n "$value" ] || return 0
      do_run sysctl -w "$target=$value" >/dev/null || return 1 ;;
    sysfs)
      [ -n "$value" ] || return 0
      if [ "$SO_DRY_RUN" = 1 ]; then log_dry "would set $target to $value"; return 0; fi
      log_cmd "echo $value > $target"
      printf '%s\n' "$value" > "$(so_path "$target")" 2>/dev/null || { log_warn "could not write $value to $target"; return 1; }
      ;;
    unit)
      case "$value" in
        enabled) do_run systemctl enable --now "$target" ;;
        disabled|absent) do_run systemctl disable --now "$target" ;;
        masked) do_run systemctl mask --now "$target" ;;
        *) log_detail "$target was $value before; left as it is" ;;
      esac ;;
    gunit)
      case "$value" in
        enabled) do_run systemctl --global enable "$target" ;;
        *) do_run systemctl --global disable "$target" ;;
      esac ;;
    svc)
      if [ "$value" = enabled ]; then
        _svc_apply "${target%%:*}" "${target#*:}" enable
      else
        _svc_apply "${target%%:*}" "${target#*:}" disable
      fi ;;
    ppd) [ -n "$value" ] && do_run powerprofilesctl set "$value" ;;
    tuned)
      # system-optimize's own profile, when another record added it, stays
      # on top; the record that added it (AFTER has it) takes it away.
      cur=$(tuned_active_profile 2>/dev/null) || cur=""
      rest=""
      if [[ " $cur " == *" system-optimize "* ]] && [[ " $value " != *" system-optimize "* ]] \
        && [[ " ${SO_UNDO_AFTER-} " != *" system-optimize "* ]]; then
        rest=" system-optimize"
      fi
      if [ -z "$value" ] || [ "$value" = none ]; then
        if [ -n "$rest" ]; then do_run tuned-adm profile system-optimize; else do_run tuned-adm off; fi
      else
        # shellcheck disable=SC2086  # a list of profile names
        do_run tuned-adm profile $value$rest
      fi ;;
    pkg)
      if [ "$SO_DRY_RUN" = 1 ]; then log_dry "would remove the package $target"; return 0; fi
      pkg_remove "$target" ;;
    gsettings)
      user="${target%%:*}"; rest="${target#*:}"
      do_as_user "$user" gsettings set "${rest%%:*}" "${rest#*:}" "$value" ;;
    kconfig)
      user="${target%%:*}"; rest="${target#*:}"
      _kconfig_write "$user" "${rest%%:*}" "$(cut -d: -f2 <<< "$rest")" "${rest##*:}" "$value" ;;
    kscreen)
      user="${target%%:*}"; rest="${target#*:}"
      do_as_user "$user" kscreen-doctor "output.${rest%%:*}.${rest#*:}.$value" ;;
    mount)
      do_run mount -o "remount,$value" "$(so_path "$target")" ;;
    group)
      user="${target%%:*}"
      if has_cmd gpasswd; then do_run gpasswd -d "$user" "${target#*:}" >/dev/null
      else do_run deluser "$user" "${target#*:}"
      fi ;;
    flatpak)
      do_run flatpak install --system --noninteractive -y "$value" "$target" ;;
    initramfs)
      SO_UNDO_INITRAMFS=1 ;;
  esac
}

# _kconfig_write USER FILE GROUP KEY VALUE: a KDE setting ("" deletes it).
_kconfig_write() {
  local user="$1" file="$2" group="$3" key="$4" value="$5" tool=kwriteconfig6
  has_cmd "$tool" || tool=kwriteconfig5
  if [ -z "$value" ]; then
    do_as_user "$user" "$tool" --file "$file" --group "$group" --key "$key" --delete
  else
    do_as_user "$user" "$tool" --file "$file" --group "$group" --key "$key" "$value"
  fi
}

SO_UNDO_ITEMS=()   # "ID:LINE" pairs, in the order to undo them
SO_UNDO_DONE=()    # "ID:LINE:TIME" pairs undone by this run (for the history)
SO_UNDO_INITRAMFS=0
SO_UNDO_AFTER=""      # the record being undone: its AFTER value

# undo_items_step: undo SO_UNDO_ITEMS (set by undo_main or undo_steps_main).
undo_items_step() {
  local item id n dir kind target value step failed=0 count=0 udev=0 now id_seen=" " restarts=" " u
  local -a lines=()
  for item in "${SO_UNDO_ITEMS[@]}"; do
    id="${item%%:*}"; n="${item##*:}"
    dir="$(snap_base)/$id"
    mapfile -t lines < "$dir/manifest"
    tsv_split "${lines[n - 1]}"
    kind="${SO_F[0]}"; target="${SO_F[1]-}"; value="${SO_F[2]-}"; step="${SO_F[3]:--}"
    SO_UNDO_AFTER="${SO_F[4]-}"
    [ -n "$kind" ] || continue
    count=$((count + 1))
    if ! _undo_valid "$kind" "$target" "$value" "${step:--}"; then
      log_warn "skipping a manifest line that does not look right: ${lines[n - 1]}"
      failed=$((failed + 1))
      continue
    fi
    [ "$kind" = file ] && [[ "$target" == /etc/udev/* ]] && udev=1
    if [ "$kind" = file ]; then
      u=$(_undo_restart_for "$target")
      [ -z "$u" ] || [[ "$restarts" == *" $u "* ]] || restarts+="$u "
    fi
    if _undo_entry "$dir" "$kind" "$target" "$value"; then
      if [ "$SO_DRY_RUN" != 1 ]; then
        now=$(iso_now)
        printf '%s\t%s\n' "$n" "$now" >> "$dir/undone-entries"
        SO_UNDO_DONE+=("$id:$n:$now")
      fi
    else
      failed=$((failed + 1))
    fi
    [[ "$id_seen" == *" $id "* ]] || id_seen+="$id "
  done
  # Services that read a restored file only when they start.
  for u in $restarts; do
    if [ "$u" = daemon-reload ]; then do_run systemctl daemon-reload || true
    elif unit_active "$u"; then do_run systemctl try-restart "$u" || true
    fi
  done
  if [ "$udev" = 1 ] && has_cmd udevadm; then
    do_run udevadm control --reload-rules || true
  fi
  if [ "$SO_UNDO_INITRAMFS" = 1 ]; then
    initramfs_rebuild || failed=$((failed + 1))
  fi
  # A snapshot with every line undone is undone as a whole.
  if [ "$SO_DRY_RUN" != 1 ]; then
    for id in $id_seen; do
      dir="$(snap_base)/$id"
      [ "$(snap_open_count "$dir")" = 0 ] && iso_now > "$dir/undone"
      rm -f -- "$dir/pending"
    done
  fi
  history_record_undo
  if [ "$failed" -gt 0 ]; then
    step_fail "$failed of $count change(s) could not be restored; the snapshot is kept for another try"
    return 1
  fi
  if [ "$count" = 0 ]; then
    step_ok "nothing to restore"
  elif [ "$SO_DRY_RUN" = 1 ]; then
    step_dry "would restore $count change(s)"
  else
    step_updated "restored $count change(s)"
  fi
}

# undo_main ID: --undo [ID]: every line of a snapshot not undone yet,
# newest first (all of them again for a snapshot already undone as a whole).
undo_main() {
  local id="${1:-}" dir i total
  # --undo [ID] --only LIST (the flag, not ONLY= in a config file).
  if [ -n "${SO_ARG_ONLY:-}" ]; then
    undo_steps_main "$SO_ARG_ONLY" "$id"
    return
  fi
  if [ -z "$id" ] || [ "$id" = latest ]; then
    id=$(snap_latest) || {
      log_error "no snapshot to undo in $(snap_base)"
      return 1
    }
  fi
  dir="$(snap_base)/$id"
  [ -f "$dir/manifest" ] || { log_error "no snapshot $id in $(snap_base)"; return 1; }
  if [ -e "$dir/undone" ]; then
    log_warn "snapshot $id was already undone on $(read_line "$dir/undone"); restoring it again"
    rm -f -- "$dir/undone" "$dir/undone-entries"
  fi
  log_info "snapshot $id: $(snap_summary "$id")"
  if [ "$SO_DRY_RUN" != 1 ]; then
    confirm "Restore the system settings saved in snapshot $id?" || return 1
  fi
  total=$(grep -c '' "$dir/manifest") || total=0
  SO_UNDO_ITEMS=()
  for ((i = total; i >= 1; i--)); do
    snap_entry_undone "$dir" "$i" || SO_UNDO_ITEMS+=("$id:$i")
  done
  run_step undo undo_items_step
}

# undo_steps_main LIST [ID]: --undo [ID] --only LIST: the changes those
# steps made that are not undone yet, in every snapshot (or in ID), newest
# first.
undo_steps_main() {
  local list="$1" id dir i total step ids
  local -a lines=()
  SO_UNDO_ITEMS=()
  if [ -n "${2:-}" ] && [ "$2" != latest ]; then
    [ -f "$(snap_base)/$2/manifest" ] || { log_error "no snapshot $2 in $(snap_base)"; return 1; }
    ids="$2"
  else
    ids=$(snap_ids | sort -r)
  fi
  for id in $ids; do
    dir="$(snap_base)/$id"
    [ -e "$dir/undone" ] && continue
    mapfile -t lines < "$dir/manifest"
    total=${#lines[@]}
    for ((i = total; i >= 1; i--)); do
      tsv_split "${lines[i - 1]}"
      step="${SO_F[3]:--}"
      list_has "$list" "$step" || continue
      snap_entry_undone "$dir" "$i" || SO_UNDO_ITEMS+=("$id:$i")
    done
  done
  if [ ${#SO_UNDO_ITEMS[@]} -eq 0 ]; then
    log_info "no changes by $list to undo"
    run_step undo undo_items_step
    return
  fi
  log_info "undoing ${#SO_UNDO_ITEMS[@]} change(s) made by $list"
  if [ "$SO_DRY_RUN" != 1 ]; then
    confirm "Restore what $list changed?" || return 1
  fi
  run_step undo undo_items_step
}
