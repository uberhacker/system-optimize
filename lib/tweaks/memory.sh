#!/usr/bin/env bash
# lib/tweaks/memory.sh - opt-in steps "mglru" and "thp": page reclaim and
# transparent huge pages (new in 2.1).
#
# mglru  The multi-generation LRU (MGLRU) is the kernel's page reclaim on
#        Fedora, Arch and most current kernels (/sys/kernel/mm/lru_gen).
#        Its min_ttl_ms keeps the pages used in the last N milliseconds
#        from being evicted; when that cannot be done, the OOM killer acts
#        instead of the desktop thrashing. The kernel's documentation says
#        1000 ms removes most of the jank and 3000 ms risks early OOM
#        kills. MGLRU_TTL_MS sets it (default 1000). Works alongside
#        systemd-oomd and earlyoom, which act earlier on pressure.
# thp    Transparent huge pages: "enabled" goes to THP_MODE (madvise by
#        default: huge pages for the programs that ask for them, such as
#        llama.cpp and databases; Phoronix measured madvise faster than
#        always in 8 of 9 llama.cpp tests on 6.18), and "defrag" to
#        defer+madvise (no direct-compaction stalls, as CachyOS ships it).
#        THP_MODE=keep leaves "enabled" as it is. Programs that are
#        already running keep what they have; the change applies to
#        programs started afterwards.
#
# Both write sysfs now (write_sysfs records the value before) and keep it
# across reboots:
#   systemd            /etc/tmpfiles.d/system-optimize-{mglru,thp}.conf
#                      ("w" lines, applied by systemd-tmpfiles at boot)
#   OpenRC + local.d   /etc/local.d/system-optimize-{mglru,thp}.start
#                      (Alpine, Gentoo; the "local" service runs it)
#   anything else      until the next reboot only (Void's runit, minimal
#                      systems); the result says so
# Containers are skipped (the host's kernel owns these), and so are kernels
# without MGLRU or THP. Undo: the sysfs values go back to what they were and
# the persistence file is removed (or its old copy restored).

step_def mglru opt-in mglru_step 'bench' \
  "Memory reclaim protects the working set" \
  "Sets MGLRU min_ttl_ms (default 1000 ms) so the desktop keeps its working set instead of thrashing." \
  memory

step_def thp opt-in thp_step 'bench' \
  "Transparent huge pages: madvise, deferred defrag" \
  "THP for programs that ask for it (llama.cpp, databases) with defer+madvise defrag, which avoids compaction stalls." \
  memory

SO_MGLRU_DIR=/sys/kernel/mm/lru_gen
SO_THP_DIR=/sys/kernel/mm/transparent_hugepage

# memory_persist_file NAME: where NAME's settings are kept across reboots
# (a tmpfiles.d entry or an OpenRC local.d script), or failure when
# nothing here would apply one at boot.
memory_persist_file() {
  if [ "$SO_INIT_SYSTEM" = systemd ]; then
    printf '/etc/tmpfiles.d/system-optimize-%s.conf\n' "$1"
  elif [ "$SO_INIT_SYSTEM" = openrc ] && [ -d "$(so_path /etc/local.d)" ]; then
    printf '/etc/local.d/system-optimize-%s.start\n' "$1"
  else
    return 1
  fi
}

# memory_persist_content FILE PATH=VALUE...: the file's content for those
# sysfs values (tmpfiles.d "w" lines, or a shell script for local.d).
memory_persist_content() {
  local file="$1" pv; shift
  case "$file" in
    *.start)
      printf '%s\n' '#!/bin/sh' \
        "# Written by system-optimize ($(version_string)). Undo: system-optimize --undo"
      for pv in "$@"; do
        printf 'echo %s > %s 2>/dev/null\n' "${pv#*=}" "${pv%%=*}"
      done
      printf 'exit 0\n' ;;
    *)
      printf '%s\n' "# Written by system-optimize ($(version_string)). Undo: system-optimize --undo"
      for pv in "$@"; do
        printf 'w %s - - - - %s\n' "${pv%%=*}" "${pv#*=}"
      done ;;
  esac
}

# memory_persist NAME PATH=VALUE...: write NAME's persistence file. Sets
# SO_MEMORY_KEPT to where it is kept (empty: until the next reboot).
# Returns install_file's code (0 written, 3 unchanged, 1 failed); 0 when
# there is nowhere to keep it.
memory_persist() {
  local name="$1" file mode=0644 rc=0; shift
  SO_MEMORY_KEPT=""
  file=$(memory_persist_file "$name") || return 0
  [[ "$file" == *.start ]] && mode=0755
  install_file "$file" "$mode" < <(memory_persist_content "$file" "$@") || rc=$?
  SO_MEMORY_KEPT="$file"
  return "$rc"
}

# memory_choices FILE: the words of a sysfs choice list, brackets removed.
memory_choices() {
  local v
  v=$(read_line "$(so_path "$1")" 2>/dev/null) || return 1
  v="${v//[/}"
  printf '%s\n' "${v//]/}"
}

# memory_result CHANGED KEPT_RC WHAT [AFTER]: report the step's result.
#   CHANGED  sysfs values written (or that would be)
#   KEPT_RC  memory_persist's return code
#   WHAT     what was set, for the note
#   AFTER    added to the note when something changed
memory_result() {
  local changed="$1" rc="$2" what="$3" after="${4:-}" where
  if [ -n "$SO_MEMORY_KEPT" ]; then where="kept in $SO_MEMORY_KEPT"; else where="until the next reboot (nothing here applies it at boot)"; fi
  if [ "$changed" = 0 ] && { [ "$rc" = 3 ] || [ -z "$SO_MEMORY_KEPT" ]; }; then
    step_ok "$what already set${SO_MEMORY_KEPT:+; kept in $SO_MEMORY_KEPT}"
  elif [ "$SO_DRY_RUN" = 1 ]; then
    step_dry "would set $what, $where$after"
  else
    step_updated "set $what, $where$after"
  fi
}

# ---------------------------------------------------------------------------
# mglru
# ---------------------------------------------------------------------------
# mglru_on: MGLRU is built in and enabled (a non-zero mask, or y).
mglru_on() {
  local v
  v=$(read_line "$(so_path "$SO_MGLRU_DIR/enabled")" 2>/dev/null) || return 1
  case "$v" in
    y|Y) return 0 ;;
    n|N) return 1 ;;
  esac
  [[ "$v" =~ ^(0[xX][0-9a-fA-F]+|[0-9]+)$ ]] || return 1
  [ $((v)) -ne 0 ]
}

mglru_step() {
  local want cur rc=0 changed=0 file="$SO_MGLRU_DIR/min_ttl_ms"
  if [ "$SO_IN_CONTAINER" = 1 ]; then
    step_skip "container: the host's kernel owns page reclaim"
    return 0
  fi
  if [ ! -e "$(so_path "$SO_MGLRU_DIR/enabled")" ] || [ ! -e "$(so_path "$file")" ]; then
    step_skip "this kernel has no multi-generation LRU (MGLRU)"
    return 0
  fi
  if ! mglru_on; then
    step_skip "MGLRU is built in but switched off ($SO_MGLRU_DIR/enabled)"
    return 0
  fi
  want=$(cfg MGLRU_TTL_MS)
  [[ "$want" =~ ^[0-9]+$ ]] || want=1000
  if [ "$want" -gt 3000 ]; then
    log_warn "MGLRU_TTL_MS=$want: the kernel documentation says values of 3000 and above risk early OOM kills"
  fi
  cur=$(read_line "$(so_path "$file")") || cur=""
  log_info "MGLRU min_ttl_ms: ${cur:-unknown} (wanted $want)"
  if [ "$cur" != "$want" ]; then
    write_sysfs "$file" "$want" "$cur" || { step_fail "could not set $file to $want"; return 1; }
    changed=1
  fi
  memory_persist mglru "$file=$want" || rc=$?
  [ "$rc" = 0 ] || [ "$rc" = 3 ] || { step_fail "could not write $SO_MEMORY_KEPT"; return 1; }
  memory_result "$changed" "$rc" "MGLRU min_ttl_ms=$want"
}

# ---------------------------------------------------------------------------
# thp
# ---------------------------------------------------------------------------
thp_step() {
  local mode en_cur df_cur en_choices df_choices rc=0 changed=0 what=""
  local -a keep=()
  if [ "$SO_IN_CONTAINER" = 1 ]; then
    step_skip "container: the host's kernel owns transparent huge pages"
    return 0
  fi
  if [ ! -e "$(so_path "$SO_THP_DIR/enabled")" ]; then
    step_skip "this kernel has no transparent huge pages"
    return 0
  fi
  mode=$(cfg THP_MODE)
  en_cur=$(_sysfs_value "$SO_THP_DIR/enabled") || en_cur=""
  df_cur=$(_sysfs_value "$SO_THP_DIR/defrag") || df_cur=""
  en_choices=$(memory_choices "$SO_THP_DIR/enabled") || en_choices=""
  df_choices=$(memory_choices "$SO_THP_DIR/defrag") || df_choices=""
  log_info "transparent huge pages: enabled ${en_cur:-unknown}, defrag ${df_cur:-unknown}"

  if [ "$mode" != keep ]; then
    if [ "$en_cur" = "$mode" ]; then
      keep+=("$SO_THP_DIR/enabled=$mode")
      what+="enabled=$mode"
    elif list_has "$en_choices" "$mode"; then
      write_sysfs "$SO_THP_DIR/enabled" "$mode" "$en_cur" || { step_fail "could not set THP to $mode"; return 1; }
      changed=$((changed + 1))
      keep+=("$SO_THP_DIR/enabled=$mode")
      what+="enabled=$mode"
    else
      log_warn "THP_MODE=$mode is not offered by this kernel ($en_choices); THP mode left at $en_cur"
    fi
  fi
  if [ -e "$(so_path "$SO_THP_DIR/defrag")" ]; then
    if [ "$df_cur" = defer+madvise ]; then
      keep+=("$SO_THP_DIR/defrag=defer+madvise")
      what+="${what:+, }defrag=defer+madvise"
    elif list_has "$df_choices" defer+madvise; then
      write_sysfs "$SO_THP_DIR/defrag" defer+madvise "$df_cur" || { step_fail "could not set THP defrag to defer+madvise"; return 1; }
      changed=$((changed + 1))
      keep+=("$SO_THP_DIR/defrag=defer+madvise")
      what+="${what:+, }defrag=defer+madvise"
    else
      log_detail "THP defrag: this kernel offers no defer+madvise ($df_choices)"
    fi
  fi
  if [ ${#keep[@]} -eq 0 ]; then
    step_skip "nothing to set (THP_MODE=$mode, and no defer+madvise defrag here)"
    return 0
  fi
  memory_persist thp "${keep[@]}" || rc=$?
  [ "$rc" = 0 ] || [ "$rc" = 3 ] || { step_fail "could not write $SO_MEMORY_KEPT"; return 1; }
  if [ "$changed" -gt 0 ]; then
    log_info "THP changes apply to programs started from now on; running ones keep what they have"
  fi
  memory_result "$changed" "$rc" "THP $what" " (applies to programs started from now on)"
}
