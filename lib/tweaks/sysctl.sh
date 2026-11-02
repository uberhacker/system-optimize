#!/usr/bin/env bash
# lib/tweaks/sysctl.sh - step "sysctl": kernel settings sized to the
# machine, in /etc/sysctl.d/99-system-optimize.conf.
#
# What changed from 1.x and why:
#   * Limits (file-max, inotify, socket backlogs) are only ever raised. 1.x
#     wrote fs.file-max = 2097152, which on current systemd machines is a
#     big step down from the default (2^63-1).
#   * vm.swappiness follows the kind of swap. With zram (Fedora's default
#     since 33) swapping is cheap, so the value is high (180, as the kernel
#     documentation, ArchWiki and Pop!_OS suggest for in-memory swap) with
#     page-cluster 0; 1.x set 10 there, which makes zram nearly useless.
#     With disk swap the RAM tiers of 1.x stay; without swap it is left
#     alone.
#   * Writeback on machines with 16 GiB or more uses fixed sizes
#     (dirty_background_bytes 256 MiB, dirty_bytes 1 GiB): a percentage of
#     64 or 128 GiB lets gigabytes of dirty pages pile up and then stall.
#   * RAM tiers use the size rounded up: a 32 GiB machine reports ~31.3
#     GiB, which 1.x put in the 8-31 GiB tier.
#   * BBR is used when the kernel has it; the kernel loads tcp_bbr itself
#     when sysctl asks for it.
#   * Only this file is loaded (sysctl -e -p FILE), not every file on the
#     system, and an unknown key does not abort the run.
#   * Network buffers (net.core.rmem_max/wmem_max) are raised to 16 MiB,
#     except when bpftune runs: it tunes them from live traffic and stops
#     the moment an admin writes one, so the net.core and TCP buffer keys
#     are left to it (BBR and fq stay here; bpftune does not set them).
#
# Back ends (BACKEND, --backend):
#   files  /etc/sysctl.d/99-system-optimize.conf, loaded with sysctl -p.
#   tuned  a tuned profile carries the settings, so tuned is their one
#          owner. Plain tuned: a profile "system-optimize" with only a
#          [sysctl] section, stacked on the active profile ("balanced
#          system-optimize"). tuned-ppd (Fedora 41+), which switches tuned
#          profiles when the power profile changes: an overlay profile
#          "system-optimize-BASE" (include=BASE plus [sysctl]) for every
#          profile /etc/tuned/ppd.conf maps to, and ppd.conf points at the
#          overlays. The sysctl.d file is removed. Needs tuned running.
#   auto   (default) tuned when tuned runs and is set not to re-apply
#          /etc/sysctl.d after its profiles (reapply_sysctl = 0 in
#          /etc/tuned/tuned-main.conf), since then a tuned profile would win
#          over the file; files otherwise (tuned's default re-applies
#          sysctl.d last, so the file already wins).
# --undo restores ppd.conf, removes the profiles and switches tuned back.
step_def sysctl default tweak_sysctl 'bench' \
  "Kernel settings sized to RAM and swap" \
  "Swap, writeback, cache, network and file-watch settings for this machine, in /etc/sysctl.d or a tuned profile." \
  memory

SO_SYSCTL_CONF=/etc/sysctl.d/99-system-optimize.conf

# _sysctl_bbr_available: does this kernel offer BBR?
_sysctl_bbr_available() {
  local avail
  avail=$(sysctl_get net.ipv4.tcp_available_congestion_control 2>/dev/null) || avail=""
  [[ " $avail " == *" bbr "* ]] && return 0
  has_cmd modinfo && run modinfo -n tcp_bbr >/dev/null 2>&1
}

# sysctl_plan: the settings for this machine, one "KEY<TAB>VALUE<TAB>MODE<TAB>WHY"
# line each. MODE is "raise" (only when the current value is lower) or "set".
sysctl_plan() {
  local gb="$SO_MEM_GB"
  _p() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"; }
  _p fs.inotify.max_user_watches 524288 raise "file watchers (IDEs, sync tools)"
  _p fs.inotify.max_user_instances 1024 raise "file watchers (IDEs, sync tools)"
  _p fs.file-max 2097152 raise "system-wide open files"
  _p net.core.somaxconn 4096 raise "listen backlog"
  _p net.core.netdev_max_backlog 16384 raise "packets queued per CPU"
  _p net.ipv4.tcp_max_syn_backlog 8192 raise "half-open connections"
  _p net.ipv4.tcp_slow_start_after_idle 0 set "keep the congestion window on idle connections"
  _p net.ipv4.tcp_fin_timeout 15 set "release closed connections sooner"
  _p net.ipv4.tcp_tw_reuse 1 set "reuse TIME-WAIT sockets for new outgoing connections"
  _p net.core.rmem_max 16777216 raise "largest socket receive buffer (16 MiB)"
  _p net.core.wmem_max 16777216 raise "largest socket send buffer (16 MiB)"
  if _sysctl_bbr_available; then
    _p net.core.default_qdisc fq set "fair queueing, paced for BBR"
    _p net.ipv4.tcp_congestion_control bbr set "BBR congestion control"
  fi
  case "$SO_SWAP_KIND" in
    zram)
      _p vm.swappiness 180 set "zram swap: swapping to compressed RAM is cheap"
      _p vm.page-cluster 0 set "zram swap: no read-ahead from swap" ;;
    disk)
      if [ "$gb" -ge 32 ]; then _p vm.swappiness 10 set "disk swap, ${gb} GiB RAM"
      elif [ "$gb" -ge 8 ]; then _p vm.swappiness 20 set "disk swap, ${gb} GiB RAM"
      else _p vm.swappiness 60 set "disk swap, ${gb} GiB RAM"
      fi ;;
  esac
  if [ "$gb" -ge 32 ]; then _p vm.vfs_cache_pressure 50 set "keep directory and inode caches (${gb} GiB RAM)"
  elif [ "$gb" -ge 8 ]; then _p vm.vfs_cache_pressure 75 set "keep directory and inode caches (${gb} GiB RAM)"
  fi
  if [ "$gb" -ge 16 ]; then
    _p vm.dirty_background_bytes 268435456 set "start writeback at 256 MiB of dirty pages"
    _p vm.dirty_bytes 1073741824 set "block writers at 1 GiB of dirty pages"
  elif [ "$gb" -ge 8 ]; then
    _p vm.dirty_background_ratio 5 set "writeback (${gb} GiB RAM)"
    _p vm.dirty_ratio 15 set "writeback (${gb} GiB RAM)"
  else
    _p vm.dirty_background_ratio 10 set "writeback (${gb} GiB RAM)"
    _p vm.dirty_ratio 20 set "writeback (${gb} GiB RAM)"
  fi
  unset -f _p
}

# sysctl_our_keys: the keys our file or our tuned profiles set now.
sysctl_our_keys() {
  local f
  sed -n 's/^\([a-z0-9_.-]*\) = .*/\1/p' "$(so_path "$SO_SYSCTL_CONF")" 2>/dev/null
  for f in "$(so_path /etc/tuned/profiles)"/system-optimize*/tuned.conf "$(so_path /etc/tuned)"/system-optimize*/tuned.conf; do
    [ -f "$f" ] && sed -n 's/^\([a-z0-9_.-]*\)=.*/\1/p' "$f"
  done
  return 0
}

# sysctl_wanted: the plan filtered for this kernel: keys it does not have
# are dropped, and "raise" keys whose current value is already as high
# (unless 1.x's file is about to be removed, or our own file is what set
# it: either may be what raised them). Same format, with the current value
# added as a fifth field.
sysctl_wanted() {
  local key value mode why cur legacy=0 ours
  legacy_sysctl_present && legacy=1
  ours=$(sysctl_our_keys | tr '\n' ' ')
  local bpftune=0
  bpftune_running && bpftune=1
  while IFS=$'\t' read -r key value mode why; do
    if [ "$bpftune" = 1 ] && bpftune_key "$key"; then
      log_detail "sysctl $key: left to bpftune, which tunes it from live traffic"
      continue
    fi
    cur=$(sysctl_get "$key") || { log_detail "sysctl $key: not in this kernel"; continue; }
    if [ "$mode" = raise ] && [ "$legacy" = 0 ] && [[ " $ours " != *" $key "* ]] &&
       [[ "$cur" =~ ^[0-9]+$ ]] && [ "${#cur}" -ge "${#value}" ] &&
       { [ "${#cur}" -gt "${#value}" ] || [ "$cur" -ge "$value" ]; }; then
      log_detail "sysctl $key: $cur is already at least $value"
      continue
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$value" "$mode" "$why" "$cur"
  done < <(sysctl_plan)
}

# sysctl_conf_content: the file, from sysctl_wanted's lines on stdin.
sysctl_conf_content() {
  local key value _mode why _cur
  printf '# Written by system-optimize (%s). Undo: system-optimize --undo\n' "$(version_string)"
  printf '# Sized for: %s\n' "$(sysinfo_describe_hw)"
  while IFS=$'\t' read -r key value _mode why _cur; do
    printf '\n# %s\n%s = %s\n' "$why" "$key" "$value"
  done
}

SO_SYSCTL_BACKEND_WHY=""

# sysctl_backend: print files or tuned (sysctl_backend_resolve sets it).
sysctl_backend() { sysctl_backend_resolve; printf '%s\n' "$SO_SYSCTL_BACKEND"; }

# sysctl_backend_resolve: SO_SYSCTL_BACKEND (files or tuned) from BACKEND
# and the machine; SO_SYSCTL_BACKEND_WHY says why.
sysctl_backend_resolve() {
  SO_SYSCTL_BACKEND=$(_sysctl_backend_pick)
  SO_SYSCTL_BACKEND_WHY=$(_sysctl_backend_pick why)
}

# _sysctl_backend_pick [why]: the back end, or with "why" the reason.
_sysctl_backend_pick() {
  local SO_SYSCTL_BACKEND_WHY=""
  _sysctl_backend_choose > /dev/null
  if [ "${1:-}" = why ]; then printf '%s\n' "$SO_SYSCTL_BACKEND_WHY"; else _sysctl_backend_choose; fi
}

_sysctl_backend_choose() {
  local want main re
  want=$(cfg BACKEND)
  SO_SYSCTL_BACKEND_WHY=""
  if ! has_cmd tuned-adm || ! unit_active tuned.service; then
    [ "$want" != tuned ] || SO_SYSCTL_BACKEND_WHY="BACKEND=tuned, but tuned does not run; using $SO_SYSCTL_CONF"
    echo files
    return 0
  fi
  case "$want" in
    files) echo files; return 0 ;;
    tuned) SO_SYSCTL_BACKEND_WHY="BACKEND=tuned"; echo tuned; return 0 ;;
  esac
  main=$(so_path /etc/tuned/tuned-main.conf)
  re=$(sed -n 's/^[[:space:]]*reapply_sysctl[[:space:]]*=[[:space:]]*\([01]\).*/\1/p' "$main" 2>/dev/null | tail -n1)
  if [ "$re" = 0 ]; then
    SO_SYSCTL_BACKEND_WHY="tuned runs with reapply_sysctl = 0, so a tuned profile would override $SO_SYSCTL_CONF"
    echo tuned
  else
    echo files
  fi
}

# tuned_profiles_dir: where custom tuned profiles go (tuned 2.23 moved them).
tuned_profiles_dir() {
  if [ -d "$(so_path /usr/lib/tuned/profiles)" ] || [ -d "$(so_path /etc/tuned/profiles)" ]; then
    echo /etc/tuned/profiles
  else
    echo /etc/tuned
  fi
}

# tuned_ppd_conf: /etc/tuned/ppd.conf when tuned-ppd runs, else failure.
tuned_ppd_conf() {
  unit_active tuned-ppd.service && [ -f "$(so_path /etc/tuned/ppd.conf)" ] && echo /etc/tuned/ppd.conf
}

# _tuned_ppd_bases: the base profiles ppd.conf maps to ([profiles] and
# [battery]), our overlays mapped back to their base.
_tuned_ppd_bases() {
  awk -F= '/^\[/ { sec = $0; next }
    (sec == "[profiles]" || sec == "[battery]") && NF >= 2 {
      v = $2; gsub(/[[:space:]]/, "", v); sub(/^system-optimize-/, "", v); if (v != "") print v }' \
    "$(so_path /etc/tuned/ppd.conf)" | sort -u
}

# _tuned_ppd_content: ppd.conf with every mapping pointed at our overlay.
_tuned_ppd_content() {
  awk '/^\[/ { sec = $0; print; next }
    (sec == "[profiles]" || sec == "[battery]") && index($0, "=") {
      k = substr($0, 1, index($0, "=") - 1); v = substr($0, index($0, "=") + 1)
      gsub(/[[:space:]]/, "", v)
      if (v != "" && v !~ /^system-optimize-/) v = "system-optimize-" v
      print k "=" v; next }
    { print }' "$(so_path /etc/tuned/ppd.conf)"
}

# _tuned_profile_content [BASE]: a profile with the settings (from
# sysctl_wanted lines on stdin), including BASE when given.
_tuned_profile_content() {
  local key value _mode why _cur
  printf '# Written by system-optimize (%s). Undo: system-optimize --undo\n' "$(version_string)"
  printf '[main]\nsummary=system-optimize kernel settings%s\n' "${1:+ on top of $1}"
  [ -z "${1:-}" ] || printf 'include=%s\n' "$1"
  printf '\n[sysctl]\n'
  while IFS=$'\t' read -r key value _mode why _cur; do
    printf '# %s\n%s=%s\n' "$why" "$key" "$value"
  done
}

# _sysctl_drop_conf: with tuned as the owner, the sysctl.d file goes.
_sysctl_drop_conf() {
  SO_REMOVED_SYSCTL_CONF=0
  [ -e "$(so_path "$SO_SYSCTL_CONF")" ] || return 0
  remove_file "$SO_SYSCTL_CONF" || return 1
  SO_REMOVED_SYSCTL_CONF=1
}

# _sysctl_tuned LINE...: the tuned back end. Sets SO_SYSCTL_TUNED_NOTE.
# Returns 0 when something changed (or would), 1 when all was in place, 2
# on an error.
_sysctl_tuned() {
  local dir ppd cur want base tmp rc wrote=0 names=() n
  dir=$(tuned_profiles_dir)
  cur=$(tuned_active_profile) || cur=""
  tmp=$(tmp_file) || return 2
  if ppd=$(tuned_ppd_conf); then
    for base in $(_tuned_ppd_bases); do
      printf '%s\n' "$@" | _tuned_profile_content "$base" > "$tmp"
      rc=0; install_file "$dir/system-optimize-$base/tuned.conf" 0644 < "$tmp" || rc=$?
      case "$rc" in 0) wrote=1 ;; 3) ;; *) return 2 ;; esac
      names+=("system-optimize-$base")
    done
    [ ${#names[@]} -gt 0 ] || { log_warn "tuned-ppd: $ppd maps no profiles"; return 1; }
    _tuned_ppd_content > "$tmp"
    rc=0; install_file "$ppd" 0644 < "$tmp" || rc=$?
    case "$rc" in 0) wrote=1 ;; 3) ;; *) return 2 ;; esac
    want=""
    for n in $cur; do
      if list_has "${names[*]}" "system-optimize-$n"; then want+="${want:+ }system-optimize-$n"
      else want+="${want:+ }$n"
      fi
    done
    SO_SYSCTL_TUNED_NOTE="tuned-ppd overlays ${names[*]}"
    if [ "$SO_DRY_RUN" = 1 ]; then
      [ "$want" = "$cur" ] || plan_note tuned profile "$cur" "$want"
      _sysctl_drop_conf || return 2
      [ "$wrote" = 1 ] || [ "$want" != "$cur" ] || [ "$SO_REMOVED_SYSCTL_CONF" = 1 ]
      return
    fi
    if [ "$want" != "$cur" ]; then
      snap_record tuned - "$cur" "$want" || return 2
    fi
    if [ "$wrote" = 1 ]; then run systemctl restart tuned-ppd.service || log_warn "could not restart tuned-ppd"; fi
    if [ "$(tuned_active_profile)" != "$want" ]; then
      # shellcheck disable=SC2086  # a list of profile names
      run tuned-adm profile $want || return 2
    fi
  else
    printf '%s\n' "$@" | _tuned_profile_content > "$tmp"
    rc=0; install_file "$dir/system-optimize/tuned.conf" 0644 < "$tmp" || rc=$?
    case "$rc" in 0) wrote=1 ;; 3) ;; *) return 2 ;; esac
    if [[ " $cur " == *" system-optimize "* ]]; then want="$cur"
    elif [ -z "$cur" ] || [ "$cur" = none ]; then want=system-optimize
    else want="$cur system-optimize"
    fi
    SO_SYSCTL_TUNED_NOTE="tuned profile system-optimize, stacked: $want"
    if [ "$SO_DRY_RUN" = 1 ]; then
      [ "$want" = "$cur" ] || plan_note tuned profile "$cur" "$want"
      _sysctl_drop_conf || return 2
      [ "$wrote" = 1 ] || [ "$want" != "$cur" ] || [ "$SO_REMOVED_SYSCTL_CONF" = 1 ]
      return
    fi
    if [ "$want" != "$cur" ]; then
      snap_record tuned - "$cur" "$want" || return 2
      # shellcheck disable=SC2086  # a list of profile names
      run tuned-adm profile $want || return 2
    elif [ "$wrote" = 1 ]; then
      # shellcheck disable=SC2086  # reload the changed profile
      run tuned-adm profile $want || return 2
    fi
  fi
  _sysctl_drop_conf || return 2
  [ "$wrote" = 1 ] || [ "$want" != "$cur" ] || [ "$SO_REMOVED_SYSCTL_CONF" = 1 ]
}

tweak_sysctl() {
  local tmp key value mode why cur changed=0 rc=0
  local -a lines=()
  if [ "$SO_IN_CONTAINER" = 1 ]; then
    step_skip "in a container: kernel settings belong to the host"
    return 0
  fi
  mapfile -t lines < <(sysctl_wanted)
  if [ ${#lines[@]} -eq 0 ]; then
    step_skip "nothing to set on this kernel"
    return 0
  fi
  for key in "${lines[@]}"; do
    IFS=$'\t' read -r key value mode why cur <<< "$key"
    if [ "$cur" != "$value" ]; then
      changed=$((changed + 1))
      log_info "$key: $cur -> $value  ($why)"
    else
      log_detail "$key: already $value"
    fi
  done
  sysctl_backend_resolve
  if [ "$SO_SYSCTL_BACKEND" = tuned ]; then
    _sysctl_tuned_step "$changed" "${lines[@]}"
    return
  fi
  [ -z "$SO_SYSCTL_BACKEND_WHY" ] || log_warn "$SO_SYSCTL_BACKEND_WHY"
  tmp=$(tmp_file) || return 1
  printf '%s\n' "${lines[@]}" | sysctl_conf_content > "$tmp"
  install_file "$SO_SYSCTL_CONF" 0644 < "$tmp" || rc=$?
  [ "$rc" = 0 ] || [ "$rc" = 3 ] || { step_fail "could not write $SO_SYSCTL_CONF"; return 1; }

  if [ "$changed" = 0 ]; then
    if [ "$rc" = 3 ]; then step_ok "${#lines[@]} settings already in place"
    elif [ "$SO_DRY_RUN" = 1 ]; then step_dry "values already in place; would write $SO_SYSCTL_CONF to keep them"
    else step_updated "values already in place; wrote $SO_SYSCTL_CONF to keep them"
    fi
    return 0
  fi
  if [ "$SO_DRY_RUN" = 1 ]; then
    step_dry "would change $changed setting(s) and load $SO_SYSCTL_CONF"
    return 0
  fi
  # The values before, for --undo. The four writeback keys go together:
  # setting a *_bytes key zeroes its *_ratio partner and the other way round.
  for key in "${lines[@]}"; do
    IFS=$'\t' read -r key value mode why cur <<< "$key"
    snap_record sysctl "$key" "$cur" "$value" || return 1
  done
  for key in vm.dirty_background_ratio vm.dirty_ratio vm.dirty_background_bytes vm.dirty_bytes; do
    cur=$(sysctl_get "$key") && snap_record sysctl "$key" "$cur" "$cur"
  done
  if ! run sysctl -e -p "$(so_path "$SO_SYSCTL_CONF")" >/dev/null; then
    step_warn "wrote $SO_SYSCTL_CONF but the kernel refused some values (see the log); they apply after a reboot if at all"
    return 0
  fi
  step_updated "changed $changed setting(s); saved in $SO_SYSCTL_CONF"
}

# _sysctl_tuned_step CHANGED LINE...: the step's tuned branch.
_sysctl_tuned_step() {
  local changed="$1" key value mode why cur rc=0
  shift
  log_detail "back end: tuned ($SO_SYSCTL_BACKEND_WHY)"
  if [ "$SO_DRY_RUN" != 1 ] && [ "$changed" -gt 0 ]; then
    for key in "$@"; do
      IFS=$'\t' read -r key value mode why cur <<< "$key"
      snap_record sysctl "$key" "$cur" "$value" || return 1
    done
    for key in vm.dirty_background_ratio vm.dirty_ratio vm.dirty_background_bytes vm.dirty_bytes; do
      cur=$(sysctl_get "$key") && snap_record sysctl "$key" "$cur" "$cur"
    done
  fi
  SO_SYSCTL_TUNED_NOTE=""
  _sysctl_tuned "$@" || rc=$?
  case "$rc" in
    0)
      if [ "$SO_DRY_RUN" = 1 ]; then step_dry "would put $# setting(s) in tuned ($SO_SYSCTL_TUNED_NOTE)"
      else step_updated "changed $changed setting(s) through tuned ($SO_SYSCTL_TUNED_NOTE)"
      fi ;;
    1)
      if [ "$changed" = 0 ]; then step_ok "$# settings already in tuned ($SO_SYSCTL_TUNED_NOTE)"
      elif [ "$SO_DRY_RUN" = 1 ]; then step_dry "would re-apply the tuned profile: $changed value(s) differ now"
      else
        cur=$(tuned_active_profile) || cur=""
        # shellcheck disable=SC2086  # a list of profile names
        if [ -n "$cur" ] && run tuned-adm profile $cur; then
          step_updated "re-applied the tuned profile $cur: $changed value(s) differed"
        else
          step_warn "tuned has the settings, but $changed value(s) differ now; tuned applies them at its next profile switch"
        fi
      fi ;;
    *) step_fail "could not put the settings in tuned"; return 1 ;;
  esac
}
