#!/usr/bin/env bash
# lib/tweaks/storage.sh - opt-in steps "noatime", "btrfs", "plocate",
# "indexer" and "psd": fewer disk writes, Btrfs compression and scrubbing,
# fast file search, a desktop indexer that leaves build output alone, and
# browser profiles in RAM (new in 2.1).
#
# noatime  Adds ATIME (noatime, or lazytime) to the local ext4, XFS, Btrfs
#          and F2FS entries of /etc/fstab, replacing relatime, strictatime
#          or atime; an entry that already says noatime is left alone.
#          Network, tmpfs, swap and bind entries, noauto entries, anything
#          under /media or /run/media and partitions on removable disks are
#          never touched. The edited copy is checked with `findmnt --verify`
#          before it replaces /etc/fstab (nothing is written when it does
#          not verify), then each changed mount point that is mounted is
#          remounted at once. Containers are skipped.
# btrfs    Adds compress=zstd:1 to the local Btrfs entries that have no
#          compress or compress-force option (and no nodatacow/nodatasum,
#          which compression would switch off). It applies to data written
#          from now on: nothing is recompressed or defragmented, autodefrag
#          is never added (and one the owner set is kept). Same fstab,
#          verify and remount approach as noatime. Then a monthly scrub, by
#          whichever owner is there, in this order:
#            1. a scrub timer that is already on (btrfsd, btrfsmaintenance,
#               btrfs-progs' btrfs-scrub@, ours): left as it is
#            2. btrfsd installed: its timer is enabled (it checks the error
#               counters hourly and scrubs about monthly, never on battery)
#            3. btrfsd in the official repositories (Fedora 43+, Debian 13+,
#               Ubuntu 24.04+): installed and enabled
#            4. btrfsmaintenance's btrfs-scrub.timer (openSUSE): enabled
#            5. btrfs-progs' btrfs-scrub@-.timer (Arch) for /: enabled
#            6. our own monthly system-optimize-btrfs-scrub.timer and
#               .service (ConditionACPower=true, `btrfs scrub start -B`)
#          Without systemd: a monthly cron script that skips on battery.
#          Containers and machines without Btrfs are skipped.
# plocate  Installs plocate. An enabled mlocate updatedb timer is disabled,
#          not removed (undo cannot reinstall a removed package); where the
#          package manager would remove mlocate to install plocate (Arch,
#          Fedora) the step stops and says so. plocate's own daily timer
#          (plocate-updatedb.timer upstream, Fedora, Arch, Debian) is
#          enabled, and the first index is built when there is none.
#          Without systemd the package's daily cron job does the indexing.
# indexer  For the desktop user: GNOME's LocalSearch/Tracker
#          (org.freedesktop.Tracker3.Miner.Files ignored-directories, which
#          takes folder names) and KDE's Baloo (baloofilerc [General]
#          "exclude filters") leave build output, caches, virtual
#          environments and VM folders alone. The user's own entries are
#          kept; ours are added after them. Other desktops are skipped.
# psd      Installs profile-sync-daemon from the official repositories
#          (Fedora, Debian/Ubuntu, Arch, openSUSE) and enables its user
#          unit psd.service for every user (systemctl --global). It starts
#          at the next login; browsers must be closed when it first starts.
#          systemd only.
#
# Undo: /etc/fstab and every file written here are restored from the
# snapshot (or removed); the remounted mount points get their previous
# option back live (kind mount); units, user units, packages, gsettings and
# kconfig values go back through their own kinds.

step_def noatime opt-in noatime_step 'bench' \
  "Fewer disk writes on reads (noatime)" \
  "Adds noatime (or lazytime, ATIME) to the local ext4, XFS, Btrfs and F2FS mounts in fstab and remounts them." \
  storage

step_def btrfs opt-in btrfs_step 'bench' \
  "Btrfs: zstd compression and monthly scrub" \
  "compress=zstd:1 for new writes on Btrfs mounts, and a monthly scrub through btrfsd or a timer. Never defragments or recompresses." \
  storage

step_def plocate opt-in plocate_step '' \
  "Fast file search (plocate)" \
  "Installs plocate and turns on its daily index timer; mlocate's timer is turned off, not removed." \
  storage

step_def indexer opt-in indexer_step 'desktop' \
  "Leave build and cache folders out of desktop search" \
  "Keeps GNOME LocalSearch/Tracker and KDE Baloo out of node_modules, build output, caches and VM folders." \
  storage

step_def psd opt-in psd_step 'desktop' \
  "Browser profiles in RAM (profile-sync-daemon)" \
  "Installs profile-sync-daemon and turns it on for every user from the next login." \
  storage

SO_STORAGE_FSTAB=/etc/fstab
SO_STORAGE_LOCAL_FS="ext4 xfs btrfs f2fs"
SO_BTRFS_COMPRESS="compress=zstd:1"
SO_BTRFS_UNIT=system-optimize-btrfs-scrub
SO_BTRFS_CRON_NAME=system-optimize-btrfs-scrub

# ---------------------------------------------------------------------------
# fstab and the live mounts
# ---------------------------------------------------------------------------
STORAGE_EDITS=()     # the mount points storage_fstab_edit changed
STORAGE_MPS=()       # the mount points of the entries it looked at
STORAGE_HAS_ROOT=0   # one of those is /

# storage_opt_has OPTS NAME: the comma-separated OPTS hold NAME (or NAME=...).
storage_opt_has() {
  local o
  local IFS=,
  for o in $1; do
    [ "$o" = "$2" ] || [[ "$o" == "$2="* ]] && return 0
  done
  return 1
}

# storage_live MP: "TYPE OPTIONS" of the mount at MP now (the last entry of
# /proc/mounts for it), or failure when nothing is mounted there.
storage_live() {
  local f _dev mp type opts _rest live_now=""
  f=$(so_path /proc/mounts)
  [ -r "$f" ] || return 1
  while read -r _dev mp type opts _rest; do
    [ "$mp" = "$1" ] && live_now="$type $opts"
  done < "$f"
  [ -n "$live_now" ] || return 1
  printf '%s\n' "$live_now"
}

# storage_source_removable SOURCE: the fstab SOURCE (UUID=, LABEL=, a /dev
# path, ...) is a partition of a removable disk.
storage_source_removable() {
  local src="$1" link real name disk
  case "$src" in
    UUID=*) link="/dev/disk/by-uuid/${src#UUID=}" ;;
    LABEL=*) link="/dev/disk/by-label/${src#LABEL=}" ;;
    PARTUUID=*) link="/dev/disk/by-partuuid/${src#PARTUUID=}" ;;
    PARTLABEL=*) link="/dev/disk/by-partlabel/${src#PARTLABEL=}" ;;
    /dev/*) link="$src" ;;
    *) return 1 ;;
  esac
  real=$(readlink -f -- "$(so_path "$link")" 2>/dev/null) || return 1
  name="${real##*/}"
  case "$name" in
    nvme*|mmcblk*) disk="${name%p[0-9]*}" ;;
    *) disk="${name%%[0-9]*}" ;;
  esac
  [ -n "$disk" ] || return 1
  [ "$(read_line "$(so_path "/sys/block/$disk/removable")" 2>/dev/null)" = 1 ]
}

# storage_entry_ok SOURCE MP TYPE OPTS: an fstab entry these steps may
# change: a local filesystem we know, at a plain mount point, not a bind
# mount, not noauto, not on removable media.
storage_entry_ok() {
  local src="$1" mp="$2" type="$3" opts="$4"
  list_has "$SO_STORAGE_LOCAL_FS" "$type" || return 1
  [[ "$mp" =~ ^/[A-Za-z0-9_./-]*$ ]] && [[ "$mp" != *..* ]] || return 1
  case "$mp" in /media|/media/*|/run/media/*) return 1 ;; esac
  storage_opt_has "$opts" bind && return 1
  storage_opt_has "$opts" rbind && return 1
  storage_opt_has "$opts" noauto && return 1
  storage_source_removable "$src" && return 1
  return 0
}

# storage_opts_atime OPTS WANT: OPTS with WANT as the atime option, or
# failure when OPTS need no change.
storage_opts_atime() {
  local opts="$1" want="$2" o out=""
  storage_opt_has "$opts" "$want" && return 1
  # noatime already writes less than lazytime would.
  [ "$want" = lazytime ] && storage_opt_has "$opts" noatime && return 1
  local IFS=,
  for o in $opts; do
    case "$o" in relatime|strictatime|atime) continue ;; esac
    out+="${out:+,}$o"
  done
  printf '%s\n' "${out:+$out,}$want"
}

# storage_opts_compress OPTS: OPTS with zstd:1 compression, or failure when
# they need no change (a compress option is there) or must not get one.
storage_opts_compress() {
  local opts="$1"
  storage_opt_has "$opts" compress && return 1
  storage_opt_has "$opts" compress-force && return 1
  storage_opt_has "$opts" nodatacow && return 1
  storage_opt_has "$opts" nodatasum && return 1
  printf '%s,%s\n' "$opts" "$SO_BTRFS_COMPRESS"
}

# storage_fstab_edit MODE OUT [WANT]: write /etc/fstab to OUT with the
# entries changed for MODE (atime: WANT as the atime option on every local
# entry; compress: zstd:1 on the Btrfs entries). Lines that do not change
# are copied byte for byte. Sets STORAGE_EDITS, STORAGE_MPS and
# STORAGE_HAS_ROOT.
storage_fstab_edit() {
  local mode="$1" out="$2" want="${3:-}" src line nl re new live
  STORAGE_EDITS=(); STORAGE_MPS=(); STORAGE_HAS_ROOT=0
  src=$(so_path "$SO_STORAGE_FSTAB")
  : > "$out" || return 1
  re='^([[:space:]]*)([^#[:space:]][^[:space:]]*)([[:space:]]+)([^[:space:]]+)([[:space:]]+)([^[:space:]]+)([[:space:]]+)([^[:space:]]+)(.*)$'
  while true; do
    line=""
    if IFS= read -r line; then nl=$'\n'
    elif [ -n "$line" ]; then nl=""
    else break
    fi
    new="$line"
    if [[ "$line" =~ $re ]]; then
      # Kept now: the checks below run regular expressions of their own.
      local -a m=("${BASH_REMATCH[@]}")
      local f_src="${m[2]}" f_mp="${m[4]}" f_type="${m[6]}" f_opts="${m[8]}" opts=""
      if storage_entry_ok "$f_src" "$f_mp" "$f_type" "$f_opts" &&
         { [ "$mode" = atime ] || [ "$f_type" = btrfs ]; }; then
        STORAGE_MPS+=("$f_mp")
        [ "$f_mp" = / ] && STORAGE_HAS_ROOT=1
        if [ "$mode" = atime ]; then
          opts=$(storage_opts_atime "$f_opts" "$want") || opts=""
        else
          opts=$(storage_opts_compress "$f_opts") || opts=""
          # A compress option given elsewhere (rootflags=) is the owner's.
          if [ -n "$opts" ] && live=$(storage_live "$f_mp") && storage_opt_has "${live#* }" compress; then
            log_detail "$f_mp is mounted with compression already; left alone"
            opts=""
          fi
        fi
        if [ -n "$opts" ]; then
          new="${m[1]}$f_src${m[3]}$f_mp${m[5]}$f_type${m[7]}$opts${m[9]}"
          STORAGE_EDITS+=("$f_mp")
        fi
      fi
    fi
    printf '%s%s' "$new" "$nl" >> "$out"
    [ -n "$nl" ] || break
  done < "$src"
}

# storage_fstab_verify FILE: findmnt --verify accepts the edited FILE. On
# failure the step's result is set: skipped when /etc/fstab itself does not
# verify (its problems are the owner's to fix first), failed otherwise.
storage_fstab_verify() {
  local out
  if ! has_cmd findmnt; then
    log_detail "findmnt not found; /etc/fstab is not verified"
    return 0
  fi
  out=$(run findmnt --verify --tab-file "$1" 2>&1) && return 0
  if ! run findmnt --verify --tab-file "$(so_path "$SO_STORAGE_FSTAB")" >/dev/null 2>&1; then
    step_skip "findmnt --verify reports problems in /etc/fstab already; fix them first"
    return 1
  fi
  log_warn "findmnt --verify did not accept the changed /etc/fstab:"
  log_detail "$out"
  step_fail "the changed /etc/fstab did not verify; /etc/fstab was left as it was"
  return 1
}

# storage_apply FILE OPTION: write /etc/fstab from FILE and remount the
# mount points in STORAGE_REMOUNT with OPTION, recording the option that
# puts each back (STORAGE_PREV) for --undo. Sets STORAGE_FAILED (remounts
# that failed). Returns 1 when /etc/fstab could not be written.
STORAGE_REMOUNT=()
STORAGE_PREV=()
STORAGE_FAILED=0
storage_apply() {
  local file="$1" opt="$2" i rc=0
  STORAGE_FAILED=0
  if [ "$SO_DRY_RUN" = 1 ]; then
    install_file "$SO_STORAGE_FSTAB" 0644 < "$file" || rc=$?
    for i in "${!STORAGE_REMOUNT[@]}"; do
      log_dry "would run: mount -o remount,$opt ${STORAGE_REMOUNT[i]}"
      plan_note mount "${STORAGE_REMOUNT[i]}" "${STORAGE_PREV[i]}" "$opt"
    done
    [ "$rc" = 0 ] || [ "$rc" = 3 ]
    return
  fi
  # The mount lines go in first, so that --undo (newest first) restores
  # /etc/fstab before it remounts with the previous option.
  for i in "${!STORAGE_REMOUNT[@]}"; do
    snap_record mount "${STORAGE_REMOUNT[i]}" "${STORAGE_PREV[i]}" "$opt" || return 1
  done
  install_file "$SO_STORAGE_FSTAB" 0644 < "$file" || rc=$?
  [ "$rc" = 0 ] || [ "$rc" = 3 ] || return 1
  for i in "${!STORAGE_REMOUNT[@]}"; do
    do_run mount -o "remount,$opt" "$(so_path "${STORAGE_REMOUNT[i]}")" || STORAGE_FAILED=$((STORAGE_FAILED + 1))
  done
  return 0
}

# storage_atime_prev WANT LIVEOPTS: the option that puts a live mount back
# (for --undo), or failure when it already has WANT.
storage_atime_prev() {
  local want="$1" live="$2"
  storage_opt_has "$live" "$want" && return 1
  if [ "$want" = noatime ]; then
    if storage_opt_has "$live" relatime; then echo relatime; else echo strictatime; fi
  else
    # /proc/mounts shows neither relatime nor noatime for strictatime.
    if storage_opt_has "$live" relatime || storage_opt_has "$live" noatime; then echo nolazytime; else echo strictatime; fi
  fi
}

# storage_result OPT: the step's result after storage_apply.
storage_result() {
  local opt="$1" list n
  list=$(join_by ' ' "${STORAGE_EDITS[@]}")
  n=${#STORAGE_REMOUNT[@]}
  if [ "$SO_DRY_RUN" = 1 ]; then
    step_dry "would add $opt to $list in /etc/fstab and remount $n mount point(s)"
  elif [ "$STORAGE_FAILED" -gt 0 ]; then
    step_warn "$opt in /etc/fstab for $list; $STORAGE_FAILED mount point(s) could not be remounted now and get it at the next boot"
  else
    step_updated "$opt in /etc/fstab for $list; remounted $n mount point(s)"
  fi
}

# ---------------------------------------------------------------------------
# noatime
# ---------------------------------------------------------------------------
noatime_step() {
  local want tmp mp live prev
  want=$(cfg ATIME)
  case "$want" in noatime|lazytime) ;; *) want=noatime ;; esac
  if [ "$SO_IN_CONTAINER" = 1 ]; then
    step_skip "container: the host owns the mounts"
    return 0
  fi
  if [ ! -f "$(so_path "$SO_STORAGE_FSTAB")" ]; then
    step_skip "no /etc/fstab"
    return 0
  fi
  tmp=$(tmp_file) || { step_fail "could not create a temporary file"; return 1; }
  storage_fstab_edit atime "$tmp" "$want" || { step_fail "could not read /etc/fstab"; return 1; }
  if [ ${#STORAGE_MPS[@]} = 0 ]; then
    step_skip "no local ext4, XFS, Btrfs or F2FS entries in /etc/fstab"
    return 0
  fi
  if [ ${#STORAGE_EDITS[@]} = 0 ]; then
    step_ok "$([ "$want" = noatime ] && echo noatime || echo "lazytime or noatime") already on ${#STORAGE_MPS[@]} local mount(s) in /etc/fstab"
    return 0
  fi
  if ! storage_fstab_verify "$tmp"; then
    [ "$STEP_RESULT" = failed ] && return 1
    return 0
  fi
  STORAGE_REMOUNT=(); STORAGE_PREV=()
  for mp in "${STORAGE_EDITS[@]}"; do
    if ! live=$(storage_live "$mp"); then
      log_detail "$mp is not mounted now; it gets $want when it is mounted"
      continue
    fi
    prev=$(storage_atime_prev "$want" "${live#* }") || continue
    STORAGE_REMOUNT+=("$mp"); STORAGE_PREV+=("$prev")
  done
  storage_apply "$tmp" "$want" || { step_fail "could not write /etc/fstab"; return 1; }
  storage_result "$want"
}

# ---------------------------------------------------------------------------
# btrfs
# ---------------------------------------------------------------------------
BTRFS_NOTE=""     # what the scrub part did, for the result
BTRFS_STATE=""    # ok | changed | dry | warn | fail | none

# btrfs_btrfsd_in_repos: the official repositories have btrfsd.
btrfs_btrfsd_in_repos() {
  local v="${SO_OS_VERSION_ID%%.*}" minor="${SO_OS_VERSION_ID#*.}"
  [[ "$v" =~ ^[0-9]+$ ]] || return 1
  [ "$minor" != "$SO_OS_VERSION_ID" ] && [[ "$minor" =~ ^[0-9]+$ ]] || minor=0
  case "$SO_PKG_MANAGER:$SO_OS_ID" in
    dnf:fedora) [ "$v" -ge 43 ] ;;
    apt:debian) [ "$v" -ge 13 ] ;;
    apt:ubuntu) [ "$v" -gt 24 ] || { [ "$v" -eq 24 ] && [ "$((10#$minor))" -ge 4 ]; } ;;
    *) return 1 ;;
  esac
}

# btrfs_unit_on UNIT WHO: enable UNIT; sets BTRFS_STATE/BTRFS_NOTE.
btrfs_unit_on() {
  local unit="$1" who="$2" state
  state=$(unit_enabled_state "$unit")
  case "$state" in
    enabled) BTRFS_STATE=ok; BTRFS_NOTE="$who scrubs ($unit already on)"; return 0 ;;
    masked) BTRFS_STATE=warn; BTRFS_NOTE="$unit is masked; no scrub set up"; return 0 ;;
  esac
  if ! unit_set "$unit" enable; then
    BTRFS_STATE=fail; BTRFS_NOTE="could not enable $unit"
    return 1
  fi
  if [ "$SO_DRY_RUN" = 1 ]; then BTRFS_STATE=dry; BTRFS_NOTE="would enable $unit ($who scrubs)"
  else BTRFS_STATE=changed; BTRFS_NOTE="enabled $unit ($who scrubs)"
  fi
}

btrfs_service_content() {
  cat <<EOF
# Written by system-optimize ($(version_string)). Undo: system-optimize --undo
[Unit]
Description=Monthly Btrfs scrub of $1 (system-optimize)
Documentation=man:btrfs-scrub(8)
ConditionACPower=true
ConditionVirtualization=!container

[Service]
Type=oneshot
ExecStart=btrfs scrub start -B $1
Nice=19
IOSchedulingClass=idle
CPUSchedulingPolicy=idle
EOF
}

btrfs_timer_content() {
  cat <<EOF
# Written by system-optimize ($(version_string)). Undo: system-optimize --undo
[Unit]
Description=Monthly Btrfs scrub of $1 (system-optimize)

[Timer]
OnCalendar=monthly
RandomizedDelaySec=6h
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

btrfs_cron_content() {
  cat <<EOF
#!/bin/sh
# Written by system-optimize ($(version_string)). Undo: system-optimize --undo
# Monthly Btrfs scrub of $1; skipped on battery.
ac=""
for s in /sys/class/power_supply/*; do
  case "\$(cat "\$s/type" 2>/dev/null)" in
    Mains|USB)
      if [ "\$(cat "\$s/online" 2>/dev/null)" = 1 ]; then ac=1; break; fi
      ac=0 ;;
  esac
done
[ "\$ac" = 0 ] && exit 0
exec btrfs scrub start -B $1
EOF
}

# btrfs_own_timer MP: our monthly service and timer.
btrfs_own_timer() {
  local mp="$1" svc="/etc/systemd/system/$SO_BTRFS_UNIT.service" tmr="/etc/systemd/system/$SO_BTRFS_UNIT.timer"
  local rc1=0 rc2=0
  if ! has_cmd btrfs; then
    BTRFS_STATE=warn; BTRFS_NOTE="no btrfs command (btrfs-progs) to scrub with"
    return 0
  fi
  install_file "$svc" 0644 < <(btrfs_service_content "$mp") || rc1=$?
  install_file "$tmr" 0644 < <(btrfs_timer_content "$mp") || rc2=$?
  if { [ "$rc1" != 0 ] && [ "$rc1" != 3 ]; } || { [ "$rc2" != 0 ] && [ "$rc2" != 3 ]; }; then
    BTRFS_STATE=fail; BTRFS_NOTE="could not write $tmr"
    return 1
  fi
  if [ "$rc1" = 0 ] || [ "$rc2" = 0 ]; then
    do_run systemctl daemon-reload || true
  fi
  btrfs_unit_on "$SO_BTRFS_UNIT.timer" "a monthly timer"
  if [ "$BTRFS_STATE" = ok ] && { [ "$rc1" = 0 ] || [ "$rc2" = 0 ]; }; then
    BTRFS_STATE=changed; BTRFS_NOTE="updated $SO_BTRFS_UNIT.timer"
  fi
}

# btrfs_cron MP: a monthly cron script, without systemd.
btrfs_cron() {
  local mp="$1" d f="" rc=0
  for d in /etc/periodic/monthly /etc/cron.monthly; do
    if [ -d "$(so_path "$d")" ]; then f="$d/$SO_BTRFS_CRON_NAME"; break; fi
  done
  if [ -z "$f" ]; then
    BTRFS_STATE=none; BTRFS_NOTE="no systemd and no monthly cron directory for a scrub"
    return 0
  fi
  if ! has_cmd btrfs; then
    BTRFS_STATE=warn; BTRFS_NOTE="no btrfs command (btrfs-progs) to scrub with"
    return 0
  fi
  install_file "$f" 0755 < <(btrfs_cron_content "$mp") || rc=$?
  case "$rc" in
    0) if [ "$SO_DRY_RUN" = 1 ]; then BTRFS_STATE=dry; BTRFS_NOTE="would add a monthly scrub in $f"
       else BTRFS_STATE=changed; BTRFS_NOTE="monthly scrub in $f"
       fi ;;
    3) BTRFS_STATE=ok; BTRFS_NOTE="monthly scrub already in $f" ;;
    *) BTRFS_STATE=fail; BTRFS_NOTE="could not write $f"; return 1 ;;
  esac
}

# btrfs_scrub MP: a monthly scrub through whichever owner is there.
btrfs_scrub() {
  local mp="$1" u
  BTRFS_STATE=none; BTRFS_NOTE=""
  if [ "$SO_INIT_SYSTEM" != systemd ]; then
    btrfs_cron "$mp"
    return
  fi
  # Something scrubs already: leave it be.
  for u in btrfsd.timer btrfs-scrub.timer btrfs-scrub@-.timer "$SO_BTRFS_UNIT.timer"; do
    if [ "$(unit_enabled_state "$u")" = enabled ]; then
      [ "$u" = "$SO_BTRFS_UNIT.timer" ] && { btrfs_own_timer "$mp"; return; }
      BTRFS_STATE=ok; BTRFS_NOTE="$u already scrubs"
      return 0
    fi
  done
  if unit_exists btrfsd.timer; then
    btrfs_unit_on btrfsd.timer btrfsd
  elif btrfs_btrfsd_in_repos; then
    if ! pkg_add btrfsd; then
      BTRFS_STATE=fail; BTRFS_NOTE="could not install btrfsd"
      return 1
    fi
    btrfs_unit_on btrfsd.timer btrfsd
  elif unit_exists btrfs-scrub.timer; then
    btrfs_unit_on btrfs-scrub.timer btrfsmaintenance
  elif [ "$mp" = / ] && unit_exists btrfs-scrub@.timer; then
    btrfs_unit_on btrfs-scrub@-.timer btrfs-progs
  else
    btrfs_own_timer "$mp"
  fi
}

btrfs_step() {
  local tmp mp live scrub_mp="" c_state=none c_note="" note rc=0
  if [ "$SO_IN_CONTAINER" = 1 ]; then
    step_skip "container: the host owns the filesystems"
    return 0
  fi
  STORAGE_EDITS=(); STORAGE_MPS=(); STORAGE_HAS_ROOT=0
  tmp=$(tmp_file) || { step_fail "could not create a temporary file"; return 1; }
  if [ -f "$(so_path "$SO_STORAGE_FSTAB")" ]; then
    storage_fstab_edit compress "$tmp" || { step_fail "could not read /etc/fstab"; return 1; }
  fi
  live=$(storage_live /) || live=""
  if [ "$STORAGE_HAS_ROOT" = 1 ] || [ "${live%% *}" = btrfs ]; then
    scrub_mp=/
  elif [ ${#STORAGE_MPS[@]} -gt 0 ]; then
    scrub_mp="${STORAGE_MPS[0]}"
  else
    step_skip "no Btrfs filesystems"
    return 0
  fi

  # Compression for new writes.
  if [ ${#STORAGE_EDITS[@]} -gt 0 ]; then
    if ! storage_fstab_verify "$tmp"; then
      [ "$STEP_RESULT" = failed ] && return 1
      return 0
    fi
    STORAGE_REMOUNT=(); STORAGE_PREV=()
    for mp in "${STORAGE_EDITS[@]}"; do
      if live=$(storage_live "$mp") && [ "${live%% *}" = btrfs ]; then
        STORAGE_REMOUNT+=("$mp"); STORAGE_PREV+=("compress=no")
      fi
    done
    storage_apply "$tmp" "$SO_BTRFS_COMPRESS" || { step_fail "could not write /etc/fstab"; return 1; }
    note="$SO_BTRFS_COMPRESS for $(join_by ' ' "${STORAGE_EDITS[@]}")"
    if [ "$SO_DRY_RUN" = 1 ]; then c_state=dry; c_note="would add $note"
    elif [ "$STORAGE_FAILED" -gt 0 ]; then c_state=warn; c_note="$note in /etc/fstab ($STORAGE_FAILED mount point(s) get it at the next boot)"
    else c_state=changed; c_note="$note"
    fi
  elif [ ${#STORAGE_MPS[@]} -gt 0 ]; then
    c_state=ok; c_note="compression already set"
  fi

  btrfs_scrub "$scrub_mp" || rc=1
  note="${c_note:+$c_note; }$BTRFS_NOTE"
  if [ "$c_state" = fail ] || [ "$BTRFS_STATE" = fail ] || [ "$rc" != 0 ]; then
    step_fail "$note"; return 1
  elif [ "$SO_DRY_RUN" = 1 ] && { [ "$c_state" = dry ] || [ "$BTRFS_STATE" = dry ]; }; then
    step_dry "$note"
  elif [ "$c_state" = warn ] || [ "$BTRFS_STATE" = warn ]; then
    step_warn "$note"
  elif [ "$c_state" = changed ] || [ "$BTRFS_STATE" = changed ]; then
    step_updated "$note"
  else
    step_ok "$note"
  fi
}

# storage_pkg_present PKG CMD: PKG is installed (asked of the package
# manager where it can answer, else CMD on PATH).
storage_pkg_present() {
  pkg_installed "$1" && return 0
  case "$SO_PKG_MANAGER" in
    dnf|zypper|rpm-ostree|apt|pacman|apk|xbps) return 1 ;;
  esac
  has_cmd "$2"
}

# ---------------------------------------------------------------------------
# plocate
# ---------------------------------------------------------------------------
# plocate_first_unit UNIT...: the first of UNIT that is installed.
plocate_first_unit() {
  local u
  for u in "$@"; do
    unit_exists "$u" && { printf '%s\n' "$u"; return 0; }
  done
  return 1
}

plocate_step() {
  local have=0 u timer state changed=0 notes=() f
  storage_pkg_present plocate plocate && have=1
  if [ "$have" = 0 ]; then
    if ! pkg_can_install; then
      step_skip "cannot install packages with $SO_PKG_MANAGER here; $(pkg_hand_hint plocate)"
      return 0
    fi
    # pacman and dnf replace mlocate with plocate; undo could not bring it back.
    if { [ "$SO_PKG_MANAGER" = pacman ] || [ "$SO_PKG_MANAGER" = dnf ]; } && pkg_installed mlocate; then
      step_skip "installing plocate would remove mlocate here, which undo cannot put back; remove mlocate first if you want plocate"
      return 0
    fi
    pkg_add plocate || { step_fail "could not install plocate"; return 1; }
    changed=1
    notes+=("$([ "$SO_DRY_RUN" = 1 ] && echo "would install plocate" || echo "installed plocate")")
  fi

  if [ "$SO_INIT_SYSTEM" != systemd ]; then
    f=""
    for u in /etc/cron.daily/plocate /etc/periodic/daily/plocate; do
      [ -e "$(so_path "$u")" ] && f="$u"
    done
    if [ -n "$f" ]; then notes+=("its daily cron job $f keeps the index")
    else notes+=("no systemd: the package's daily cron job, if it has one, keeps the index (or run updatedb)")
    fi
    if [ "$changed" = 0 ]; then step_ok "plocate already installed; ${notes[*]}"
    elif [ "$SO_DRY_RUN" = 1 ]; then step_dry "$(join_by '; ' "${notes[@]}")"
    else step_updated "$(join_by '; ' "${notes[@]}")"
    fi
    return 0
  fi

  # mlocate's daily timer: off, so the two do not both index.
  for u in mlocate-updatedb.timer updatedb.timer mlocate.timer; do
    unit_exists "$u" || continue
    [ "$(unit_enabled_state "$u")" = enabled ] || continue
    unit_set "$u" disable || { step_fail "could not disable $u"; return 1; }
    changed=1
    notes+=("$([ "$SO_DRY_RUN" = 1 ] && echo "would turn off" || echo "turned off") mlocate's $u")
  done

  if ! timer=$(plocate_first_unit plocate-updatedb.timer plocate.timer); then
    if [ "$SO_DRY_RUN" = 1 ] && [ "$have" = 0 ]; then
      timer=plocate-updatedb.timer
    else
      step_warn "$(join_by '; ' "${notes[@]}" "no plocate updatedb timer found; run updatedb yourself")"
      return 0
    fi
  fi
  state=$(unit_enabled_state "$timer")
  case "$state" in
    enabled) ;;
    masked) notes+=("$timer is masked; left alone") ;;
    *)
      unit_set "$timer" enable || { step_fail "could not enable $timer"; return 1; }
      changed=1
      notes+=("$([ "$SO_DRY_RUN" = 1 ] && echo "would enable" || echo "enabled") $timer")
      # The first index, so that locate works today.
      if [ ! -e "$(so_path /var/lib/plocate/plocate.db)" ]; then
        do_run systemctl start --no-block "${timer%.timer}.service" || true
      fi ;;
  esac
  if [ "$changed" = 0 ]; then
    step_ok "plocate installed and $timer on"
  elif [ "$SO_DRY_RUN" = 1 ]; then
    step_dry "$(join_by '; ' "${notes[@]}")"
  else
    step_updated "$(join_by '; ' "${notes[@]}")"
  fi
}

# ---------------------------------------------------------------------------
# indexer
# ---------------------------------------------------------------------------
# The folders desktop search leaves alone: build output, caches, virtual
# environments, package caches and VM folders.
SO_INDEXER_NAMES=(node_modules .cache target build dist .venv venv __pycache__ .gradle .m2 "VirtualBox VMs")
SO_TRACKER_SCHEMA=org.freedesktop.Tracker3.Miner.Files
SO_TRACKER_KEY=ignored-directories

# indexer_gvariant_list TEXT: the strings of a GVariant string array, one
# per line (['a', 'b'] or @as []).
indexer_gvariant_list() {
  local s="$1" re="^[^'\"]*('([^']*)'|\"([^\"]*)\")"
  while [[ "$s" =~ $re ]]; do
    if [ -n "${BASH_REMATCH[2]}" ] || [[ "${BASH_REMATCH[1]}" == "''" ]]; then
      printf '%s\n' "${BASH_REMATCH[2]}"
    else
      printf '%s\n' "${BASH_REMATCH[3]}"
    fi
    s="${s:${#BASH_REMATCH[0]}}"
  done
}

# indexer_gvariant ITEMS...: a GVariant string array.
indexer_gvariant() {
  local out="" x
  for x in "$@"; do out+="${out:+, }'${x//\'/\\\'}'"; done
  printf '[%s]\n' "$out"
}

indexer_gnome() {
  local user="$1" cur name rc=0 added=0
  local -a items=()
  if ! cur=$(gsettings_get "$user" "$SO_TRACKER_SCHEMA" "$SO_TRACKER_KEY"); then
    step_skip "GNOME LocalSearch/Tracker is not installed ($SO_TRACKER_SCHEMA not found)"
    return 0
  fi
  mapfile -t items < <(indexer_gvariant_list "$cur")
  for name in "${SO_INDEXER_NAMES[@]}"; do
    local x seen=0
    for x in "${items[@]+"${items[@]}"}"; do [ "$x" = "$name" ] && { seen=1; break; }; done
    [ "$seen" = 1 ] && continue
    items+=("$name"); added=$((added + 1))
  done
  if [ "$added" = 0 ]; then
    step_ok "LocalSearch/Tracker already leaves these folders alone for $user"
    return 0
  fi
  gsettings_set "$user" "$SO_TRACKER_SCHEMA" "$SO_TRACKER_KEY" "$(indexer_gvariant "${items[@]}")" || rc=$?
  case "$rc" in
    0) if [ "$SO_DRY_RUN" = 1 ]; then step_dry "would add $added folder name(s) to LocalSearch/Tracker's ignored folders for $user"
       else step_updated "LocalSearch/Tracker leaves $added more folder name(s) alone for $user"
       fi ;;
    3) step_ok "LocalSearch/Tracker already leaves these folders alone for $user" ;;
    *) step_fail "could not change $SO_TRACKER_SCHEMA $SO_TRACKER_KEY"; return 1 ;;
  esac
}

indexer_kde() {
  local user="$1" cur ver name rc=0 added=0 out
  local -a items=()
  if ! has_cmd kreadconfig6 && ! has_cmd kreadconfig5; then
    step_skip "no kreadconfig to read Baloo's settings with"
    return 0
  fi
  cur=$(kconfig_get "$user" baloofilerc General "exclude filters") || cur=""
  if [ -z "$cur" ]; then
    # Unset: Baloo uses its built-in list, and merges it into ours at its
    # next start only while "exclude filters version" is below its own.
    ver=$(kconfig_get "$user" baloofilerc General "exclude filters version") || ver=""
    if [ -n "$ver" ] && [ "$ver" != 0 ]; then
      step_skip "Baloo's exclude filters are its built-in list with a version set; writing ours would drop the built-in ones"
      return 0
    fi
  fi
  IFS=, read -r -a items <<< "$cur"
  for name in "${SO_INDEXER_NAMES[@]}"; do
    local x seen=0
    for x in "${items[@]+"${items[@]}"}"; do [ "$x" = "$name" ] && { seen=1; break; }; done
    [ "$seen" = 1 ] && continue
    items+=("$name"); added=$((added + 1))
  done
  if [ "$added" = 0 ]; then
    step_ok "Baloo already leaves these folders alone for $user"
    return 0
  fi
  out=$(join_by , "${items[@]}")
  kconfig_set "$user" baloofilerc General "exclude filters" "$out" || rc=$?
  case "$rc" in
    0) if [ "$SO_DRY_RUN" = 1 ]; then step_dry "would add $added folder name(s) to Baloo's exclude filters for $user"
       else step_updated "Baloo leaves $added more folder name(s) alone for $user (from its next start)"
       fi ;;
    3) step_ok "Baloo already leaves these folders alone for $user" ;;
    *) step_fail "could not change Baloo's exclude filters"; return 1 ;;
  esac
}

indexer_step() {
  local user kind
  user=$(desktop_user)
  if [ -z "$user" ]; then
    step_skip "no desktop user"
    return 0
  fi
  kind=$(desktop_kind)
  case "$kind" in
    gnome) indexer_gnome "$user" ;;
    kde) indexer_kde "$user" ;;
    *) step_skip "not GNOME or KDE (desktop: $kind)" ;;
  esac
}

# ---------------------------------------------------------------------------
# psd
# ---------------------------------------------------------------------------
# psd_in_repos: the official repositories have profile-sync-daemon.
psd_in_repos() {
  case "$SO_PKG_MANAGER" in
    apt|pacman|zypper) return 0 ;;
    dnf) [ "$SO_OS_ID" = fedora ] ;;
    *) return 1 ;;
  esac
}

psd_step() {
  local prev changed=0 notes=()
  if [ "$SO_INIT_SYSTEM" != systemd ]; then
    step_skip "profile-sync-daemon needs systemd user units"
    return 0
  fi
  if [ "$SO_IN_CONTAINER" = 1 ]; then
    step_skip "container"
    return 0
  fi
  if ! storage_pkg_present profile-sync-daemon profile-sync-daemon; then
    if ! psd_in_repos; then
      step_skip "profile-sync-daemon is not in this distribution's own repositories"
      return 0
    fi
    pkg_add profile-sync-daemon || { step_fail "could not install profile-sync-daemon"; return 1; }
    changed=1
    notes+=("$([ "$SO_DRY_RUN" = 1 ] && echo "would install" || echo "installed") profile-sync-daemon")
  fi
  prev=$(run systemctl --global is-enabled psd.service 2>/dev/null) || prev=disabled
  if [ "${prev//[^a-z-]/}" != enabled ]; then
    gunit_set psd.service enable || { step_fail "could not enable psd.service for every user"; return 1; }
    changed=1
    notes+=("$([ "$SO_DRY_RUN" = 1 ] && echo "would enable" || echo "enabled") psd.service for every user")
  fi
  if [ "$changed" = 0 ]; then
    step_ok "psd.service already on for every user"
  elif [ "$SO_DRY_RUN" = 1 ]; then
    step_dry "$(join_by '; ' "${notes[@]}")"
  else
    step_updated "$(join_by '; ' "${notes[@]}"); it starts at the next login (close the browsers first)"
  fi
}
