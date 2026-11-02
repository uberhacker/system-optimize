#!/usr/bin/env bash
# lib/tweaks/boot.sh - opt-in steps "journal", "flatpak", "waitonline" and
# "firmware".
#
# journal: caps the systemd journal at JOURNAL_MAX (default 500M) with
# /etc/systemd/journald.conf.d/99-system-optimize.conf ([Journal]
# SystemMaxUse=) and restarts systemd-journald. journald's own default is
# 10 % of the filesystem up to 4 GiB, which a busy machine fills with logs
# nobody reads. A cap already set at or below JOURNAL_MAX (journald.conf or
# another drop-in) is kept. systemd only: Alpine, Void and Gentoo with
# OpenRC log with syslog and are skipped. journald deletes the oldest logs
# over the cap; --undo removes the file but cannot bring them back.
#
# flatpak: removes the runtimes no installed application uses any more
# (old GNOME and KDE platform branches, their locales and GL extensions),
# from the system installation only (it needs root; a user's own
# installation is theirs). The list comes from flatpak itself: `flatpak
# uninstall --unused --system` is asked and answered "n", and its table is
# matched against `flatpak list --runtime` to get each full ref and the
# remote it came from. Each one is recorded (kind flatpak) before `flatpak
# uninstall --unused --system --noninteractive -y` removes them, so --undo
# can install them again from the same remote (the newest build of that
# branch, not the exact one removed). Pinned runtimes are never removed.
#
# waitonline: NetworkManager-wait-online.service holds the boot until the
# network is up (up to 60 seconds on a laptop away from its Wi-Fi), for the
# services that want network-online.target. On a desktop that mounts
# nothing over the network nothing needs it, so it is disabled. When
# /etc/fstab has a network filesystem (nfs, nfs4, cifs, smb3, sshfs,
# fuse.sshfs, glusterfs, ceph) or the _netdev option, or remote-fs.target
# wants a mount unit, the step warns and leaves it on: those mounts need the
# network at boot. systemd-networkd-wait-online.service (Debian and Ubuntu
# servers, Arch with networkd) is only reported. Undo enables it again.
#
# firmware: reports the firmware updates fwupd already knows about (from
# its cached metadata: get-updates with --no-metadata-check, --json where
# fwupdmgr has it, else the text). It never refreshes the metadata and
# never installs anything; it ends in a warning naming each device, its
# version and the offered one, with the command to install them. Skipped
# without fwupdmgr and in containers.

step_def journal opt-in journal_step '' \
  "Cap the systemd journal" \
  "Limits the journal to JOURNAL_MAX (default 500M); journald deletes the oldest logs over it." \
  boot

step_def flatpak opt-in flatpak_step '' \
  "Remove unused Flatpak runtimes" \
  "flatpak uninstall --unused for the system installation; --undo installs the removed runtimes again." \
  boot

step_def waitonline opt-in waitonline_step '' \
  "Faster boot: skip NetworkManager-wait-online" \
  "Disables NetworkManager-wait-online.service, unless something mounts over the network at boot." \
  boot

step_def firmware opt-in firmware_step 'report' \
  "Firmware updates offered by fwupd" \
  "Lists the firmware updates fwupd offers from its cached metadata. Never installs firmware." \
  boot

SO_JOURNAL_CONF=/etc/systemd/journald.conf.d/99-system-optimize.conf

# ---------------------------------------------------------------------------
# journal
# ---------------------------------------------------------------------------
# boot_size_bytes SIZE: a journald size (500M, 1G, 1048576) in bytes, or
# failure.
boot_size_bytes() {
  local s="${1^^}" n mult=1
  [[ "$s" =~ ^([0-9]+)([KMGTPE]?)B?$ ]] || return 1
  n="${BASH_REMATCH[1]}"
  case "${BASH_REMATCH[2]}" in
    K) mult=1024 ;;
    M) mult=$((1024 ** 2)) ;;
    G) mult=$((1024 ** 3)) ;;
    T) mult=$((1024 ** 4)) ;;
    P) mult=$((1024 ** 5)) ;;
    E) mult=$((1024 ** 6)) ;;
  esac
  printf '%s\n' "$((n * mult))"
}

# boot_journal_other_cap: "VALUE FILE" of the SystemMaxUse journald uses
# without our drop-in (the main file, then the drop-ins in name order, the
# last one winning), or failure when none sets it.
boot_journal_other_cap() {
  local f v cap_found="" files=() names
  files=("$(so_path /etc/systemd/journald.conf)")
  names=$(for f in "$(so_path /usr/lib/systemd/journald.conf.d)"/*.conf "$(so_path /etc/systemd/journald.conf.d)"/*.conf; do
    [ -f "$f" ] && printf '%s\n' "${f##*/}"
  done | LC_ALL=C sort -u)
  for f in $names; do
    [ "/etc/systemd/journald.conf.d/$f" = "$SO_JOURNAL_CONF" ] && continue
    if [ -f "$(so_path "/etc/systemd/journald.conf.d/$f")" ]; then
      files+=("$(so_path "/etc/systemd/journald.conf.d/$f")")
    else
      files+=("$(so_path "/usr/lib/systemd/journald.conf.d/$f")")
    fi
  done
  for f in "${files[@]}"; do
    [ -r "$f" ] || continue
    v=$(sed -n 's/^[[:space:]]*SystemMaxUse[[:space:]]*=[[:space:]]*\([^[:space:]#]*\).*/\1/p' "$f" | tail -n1)
    [ -n "$v" ] && cap_found="$v ${f#"${SO_ROOT:-}"}"
  done
  [ -n "$cap_found" ] || return 1
  printf '%s\n' "$cap_found"
}

journal_step() {
  local max want other ov of ob rc=0
  max=$(cfg JOURNAL_MAX); max="${max:-500M}"
  if [ "$SO_HAS_SYSTEMD" != 1 ]; then
    step_skip "no systemd journal (this system logs with $SO_INIT_SYSTEM's syslog)"
    return 0
  fi
  want=$(boot_size_bytes "$max") || { step_fail "JOURNAL_MAX=$max is not a size"; return 1; }
  if [ ! -e "$(so_path "$SO_JOURNAL_CONF")" ] && other=$(boot_journal_other_cap); then
    ov="${other%% *}"; of="${other#* }"
    if ob=$(boot_size_bytes "$ov") && [ "$ob" -le "$want" ]; then
      step_ok "the journal is already capped at $ov ($of)"
      return 0
    fi
  fi
  install_file "$SO_JOURNAL_CONF" 0644 < <(printf '%s\n' \
    "# Written by system-optimize ($(version_string)). Undo: system-optimize --undo" \
    '# Cap the persistent journal; journald deletes the oldest logs over it.' \
    '[Journal]' "SystemMaxUse=$max") || rc=$?
  case "$rc" in
    0) ;;
    3) step_ok "the journal is already capped at $max"; return 0 ;;
    *) step_fail "could not write $SO_JOURNAL_CONF"; return 1 ;;
  esac
  if ! do_run systemctl restart systemd-journald.service; then
    step_warn "wrote $SO_JOURNAL_CONF, but systemd-journald did not restart"
    return 0
  fi
  if [ "$SO_DRY_RUN" = 1 ]; then
    step_dry "would cap the journal at $max (logs over it are deleted)"
  else
    step_updated "journal capped at $max; older logs over it were deleted"
  fi
}

# ---------------------------------------------------------------------------
# flatpak
# ---------------------------------------------------------------------------
# boot_flatpak_unused: the unused runtimes of the system installation as
# "REF<TAB>ORIGIN" lines, from flatpak's own list (answered "n").
boot_flatpak_unused() {
  local table refs line id rest ref origin r o rid rbranch hit tmo
  refs=$(run flatpak list --system --runtime --columns=ref,origin 2>/dev/null) || return 1
  # `run` gives the command /dev/null for stdin; this one needs its "n".
  tmo=$(_timeout_cmd)
  log_cmd "flatpak uninstall --unused --system (answered n: only the list)"
  # shellcheck disable=SC2086  # the timeout words
  table=$(printf 'n\n' | _run_logged $tmo env LC_ALL=C flatpak uninstall --unused --system 2>/dev/null) || true
  while IFS= read -r line; do
    # Rows look like " 1.  org.gnome.Platform  45  r" (an Arch column too
    # when it differs from the machine's).
    [[ "$line" =~ ^[[:space:]]*[0-9]+\.[[:space:]]+([A-Za-z0-9._-]+)[[:space:]]*(.*)$ ]] || continue
    id="${BASH_REMATCH[1]}"; rest=" ${BASH_REMATCH[2]} "
    hit=""
    while IFS=$'\t' read -r r o; do
      [[ "$r" == runtime/* ]] || continue
      rid="${r#runtime/}"; rid="${rid%%/*}"
      rbranch="${r##*/}"
      [ "$rid" = "$id" ] || continue
      if [[ "$rest" == *" $rbranch "* ]] || [ -z "$hit" ]; then
        hit="$r"$'\t'"$o"
        [[ "$rest" == *" $rbranch "* ]] && break
      fi
    done <<< "$refs"
    [ -n "$hit" ] || { log_warn "flatpak: no installed runtime matches $id"; continue; }
    ref="${hit%%$'\t'*}"; origin="${hit#*$'\t'}"
    printf '%s\t%s\n' "$ref" "$origin"
  done <<< "$table"
}

flatpak_step() {
  local list ref origin n=0 names=""
  if ! has_cmd flatpak; then
    step_skip "flatpak is not installed"
    return 0
  fi
  list=$(boot_flatpak_unused) || { step_fail "flatpak list failed"; return 1; }
  while IFS=$'\t' read -r ref origin; do
    [ -n "$ref" ] || continue
    if ! [[ "$ref" =~ ^runtime/[A-Za-z0-9._-]+/[A-Za-z0-9_]+/[A-Za-z0-9._-]+$ ]] || ! [[ "$origin" =~ ^[A-Za-z0-9._-]+$ ]]; then
      step_fail "flatpak gave a ref --undo could not reinstall ($ref from $origin); nothing removed"
      return 1
    fi
    n=$((n + 1))
    names+="${names:+, }$(cut -d/ -f2 <<< "$ref")//${ref##*/}"
  done <<< "$list"
  if [ "$n" = 0 ]; then
    step_ok "no unused runtimes in the system installation"
    return 0
  fi
  if [ "$SO_DRY_RUN" = 1 ]; then
    while IFS=$'\t' read -r ref origin; do
      log_dry "would remove $ref (from $origin)"
      plan_note flatpak "$ref" "installed ($origin)" removed
    done <<< "$list"
    step_dry "would remove $n unused runtime(s): $names"
    return 0
  fi
  while IFS=$'\t' read -r ref origin; do
    snap_record flatpak "$ref" "$origin" removed || { step_fail "could not record $ref"; return 1; }
  done <<< "$list"
  if ! run flatpak uninstall --unused --system --noninteractive -y; then
    step_fail "flatpak uninstall --unused failed"
    return 1
  fi
  step_updated "removed $n unused runtime(s): $names"
}

# ---------------------------------------------------------------------------
# waitonline
# ---------------------------------------------------------------------------
SO_WAITONLINE_UNIT=NetworkManager-wait-online.service

# boot_network_mounts: what mounts over the network at boot, one per line
# (fstab mount points, and mount units remote-fs.target wants).
boot_network_mounts() {
  local spec mnt type opts _rest f
  f=$(so_path /etc/fstab)
  if [ -r "$f" ]; then
    while read -r spec mnt type opts _rest; do
      case "$spec" in ''|'#'*) continue ;; esac
      case "$type" in
        nfs|nfs4|cifs|smb3|smbfs|sshfs|fuse.sshfs|glusterfs|ceph|fuse.ceph|fuse.glusterfs)
          printf '%s\n' "$mnt"; continue ;;
      esac
      list_has "${opts:-}" _netdev && printf '%s\n' "$mnt"
    done < "$f"
  fi
  for f in "$(so_path /etc/systemd/system/remote-fs.target.wants)"/*.mount "$(so_path /etc/systemd/system/remote-fs.target.wants)"/*.automount; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    printf '%s\n' "${f##*/}"
  done
  return 0
}

waitonline_step() {
  local state mounts
  if [ "$SO_HAS_SYSTEMD" != 1 ]; then
    step_skip "no systemd (no wait-online service)"
    return 0
  fi
  state=$(unit_enabled_state "$SO_WAITONLINE_UNIT")
  case "$state" in
    enabled) ;;
    disabled|masked)
      step_ok "$SO_WAITONLINE_UNIT is already $state"
      return 0 ;;
    *)
      if [ "$(unit_enabled_state systemd-networkd-wait-online.service)" = enabled ]; then
        step_skip "this system uses systemd-networkd-wait-online.service (left alone; disable it yourself if nothing needs the network at boot)"
      else
        step_skip "no NetworkManager-wait-online.service"
      fi
      return 0 ;;
  esac
  mounts=$(boot_network_mounts | tr '\n' ' ')
  mounts="${mounts% }"
  if [ -n "$mounts" ]; then
    step_warn "left $SO_WAITONLINE_UNIT on: these mounts need the network at boot: $mounts"
    return 0
  fi
  unit_set "$SO_WAITONLINE_UNIT" disable || { step_fail "could not disable $SO_WAITONLINE_UNIT"; return 1; }
  if [ "$SO_DRY_RUN" = 1 ]; then
    step_dry "would disable $SO_WAITONLINE_UNIT (nothing mounts over the network)"
  else
    step_updated "disabled $SO_WAITONLINE_UNIT; turn it back on with: systemctl enable $SO_WAITONLINE_UNIT (or --undo --only waitonline)"
  fi
}

# ---------------------------------------------------------------------------
# firmware
# ---------------------------------------------------------------------------
# boot_fwupd_json: "NAME<TAB>CURRENT<TAB>NEW" per device from
# `fwupdmgr get-updates --json` (stdin). Devices are at depth 3, their
# releases at depth 5; the first release is the newest.
boot_fwupd_json() {
  awk '
    function val(l) { sub(/^[^:]*:[ \t]*"/, "", l); sub(/",?[ \t]*$/, "", l); return l }
    {
      line = $0
      if (depth == 3 && line ~ /^[ \t]*"Name"[ \t]*:/) name = val(line)
      if (depth == 3 && line ~ /^[ \t]*"Version"[ \t]*:/) cur = val(line)
      if (depth == 5 && line ~ /^[ \t]*"Version"[ \t]*:/ && new == "") new = val(line)
      s = line
      gsub(/\\./, "", s); gsub(/"[^"]*"/, "", s)
      o = gsub(/[[{]/, "", s); c = gsub(/[]}]/, "", s)
      before = depth; depth += o - c
      if (before >= 3 && depth < 3) {
        if (name != "" && new != "") printf "%s\t%s\t%s\n", name, cur, new
        name = ""; cur = ""; new = ""
      }
    }'
}

# boot_fwupd_text: the same from the text output (stdin): a device heading
# ("├─Name:"), its "Current version:" and the first "New version:".
boot_fwupd_text() {
  awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    /:[ \t]*$/ && $0 !~ /:[ \t]+[^ \t]/ {
      h = $0; sub(/:[ \t]*$/, "", h); gsub(/^[^A-Za-z0-9]+/, "", h); heading = h; next
    }
    /Current version:/ {
      if (name != "" && new != "") printf "%s\t%s\t%s\n", name, cur, new
      name = heading; cur = $0; sub(/.*Current version:/, "", cur); cur = trim(cur); new = ""; next
    }
    /New version:/ && name != "" && new == "" { new = $0; sub(/.*New version:/, "", new); new = trim(new) }
    END { if (name != "" && new != "") printf "%s\t%s\t%s\n", name, cur, new }'
}

firmware_step() {
  local out rc=0 fw_rows="" name cur new list="" n=0
  if [ "$SO_IN_CONTAINER" = 1 ]; then
    step_skip "container"
    return 0
  fi
  if ! has_cmd fwupdmgr; then
    step_skip "fwupdmgr is not installed"
    return 0
  fi
  out=$(run env LC_ALL=C fwupdmgr get-updates --json --no-metadata-check 2>/dev/null) || rc=$?
  if [ "$rc" = 2 ]; then
    step_ok "no firmware updates in fwupd's cached metadata"
    return 0
  fi
  if [ "$rc" = 0 ] && [[ "$out" == *'"Devices"'* ]]; then
    fw_rows=$(boot_fwupd_json <<< "$out")
  else
    # Older fwupd: no --json for get-updates (or no --no-metadata-check).
    rc=0
    out=$(run env LC_ALL=C fwupdmgr get-updates --no-metadata-check 2>&1) || rc=$?
    if [ "$rc" = 1 ] && [[ "$out" == *nknown\ option* ]]; then
      rc=0
      out=$(run env LC_ALL=C fwupdmgr get-updates 2>&1) || rc=$?
    fi
    case "$rc" in
      0) fw_rows=$(boot_fwupd_text <<< "$out") ;;
      2) step_ok "no firmware updates in fwupd's cached metadata"; return 0 ;;
      *) step_skip "fwupdmgr get-updates failed (exit code $rc); refresh its metadata with: fwupdmgr refresh"; return 0 ;;
    esac
  fi
  while IFS=$'\t' read -r name cur new; do
    [ -n "$name" ] || continue
    n=$((n + 1))
    list+="${list:+; }$name ${cur:-?} -> $new"
  done <<< "$fw_rows"
  if [ "$n" = 0 ]; then
    step_ok "no firmware updates in fwupd's cached metadata"
  else
    step_warn "$n firmware update(s): $list; install with: sudo fwupdmgr update"
  fi
}
