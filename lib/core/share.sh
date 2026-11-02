#!/usr/bin/env bash
# lib/core/share.sh - shareable settings: --export FILE, --import FILE and
# --diff-config FILE.
#
# An exported file is an ordinary config file (KEY=value) with the
# settings that make sense on another machine: which steps run (ENABLE,
# PROFILE, SKIP; ENABLE also lists the opt-in steps applied here), and the
# steps' own settings. It has no host name, user, path, snapshot or
# self-update source: SELF_UPDATE_*, SNAPSHOT_DIR, LOG_DIR and HISTORY_DIR
# are never exported, and never imported either.

SO_SHARE_KEYS="ENABLE PROFILE SKIP BACKEND INSTALL_TOOLS ATIME JOURNAL_MAX CHARGE_LIMIT GPU_MEM_GIB
  FONT_HINTING FONT_SUBPIXEL PARALLEL_DOWNLOADS TUNE_STEPS BENCHMARK BENCH_SECONDS BENCH_THRESHOLD
  SAFE_APPLY SAFE_APPLY_TIMEOUT HISTORY_KEEP_DAYS TIMEOUT PKG_TIMEOUT SCHEDULER MGLRU_TTL_MS THP_MODE BENCH_PCP"

# share_enable: ENABLE plus the opt-in steps applied here.
share_enable() {
  local out s
  out=$(cfg ENABLE)
  for s in $(drift_applied_steps); do
    [ "${SO_STEP_KIND[$s]}" = opt-in ] || continue
    list_has "$out" "$s" || out+="${out:+,}$s"
  done
  printf '%s\n' "$out"
}

# share_content: the exported file.
share_content() {
  local key value
  printf '# system-optimize settings, exported %s by %s.\n' "$(printf '%(%Y-%m-%d)T' -1)" "$(version_string)"
  printf '# Use them on another machine: system-optimize --import FILE, or --config FILE.\n'
  for key in $SO_SHARE_KEYS; do
    if [ "$key" = ENABLE ]; then value=$(share_enable); else value=$(cfg "$key"); fi
    printf '%s=%s\n' "$key" "$value"
  done
}

# export_main FILE
export_main() {
  local file="$1"
  if [ -e "$file" ] && [ "$SO_DRY_RUN" != 1 ]; then
    confirm "Replace $file?" || return 1
  fi
  if [ "$SO_DRY_RUN" = 1 ]; then
    log_dry "would write $file:"
    share_content | sed 's/^/      | /' >&"$SO_OUT"
    return 0
  fi
  share_content > "$file" || { log_error "cannot write $file"; return 1; }
  log_ok "settings written to $file"
}

# share_read FILE: SO_SHARE[KEY]=value for the shareable keys in FILE
# (checked like any config file); other keys are reported and ignored.
share_read() {
  local file="$1" key
  local -A saved=() saved_src=()
  declare -gA SO_SHARE=()
  [ -r "$file" ] || { log_error "cannot read $file"; return 1; }
  for key in "${!SO_CFG[@]}"; do saved[$key]="${SO_CFG[$key]}"; saved_src[$key]="${SO_CFG_SOURCE[$key]}"; done
  for key in "${!SO_CFG[@]}"; do SO_CFG_SOURCE[$key]="unset"; done
  config_parse_file "$file"
  for key in "${!SO_CFG[@]}"; do
    if [ "${SO_CFG_SOURCE[$key]}" != unset ]; then
      if list_has "$SO_SHARE_KEYS" "$key"; then
        SO_SHARE[$key]="${SO_CFG[$key]}"
      else
        log_warn "$file: $key is not a shareable setting; ignored"
      fi
    fi
    SO_CFG[$key]="${saved[$key]}"
    SO_CFG_SOURCE[$key]="${saved_src[$key]}"
  done
  steps_check_list "${SO_SHARE[ENABLE]-} ${SO_SHARE[SKIP]-} ${SO_SHARE[TUNE_STEPS]-}" || return 1
}

# diff_main FILE: --diff-config.
diff_main() {
  local key here n=0
  share_read "$1" || return 1
  for key in $SO_SHARE_KEYS; do
    [ -n "${SO_SHARE[$key]+x}" ] || continue
    if [ "$key" = ENABLE ]; then here=$(share_enable); else here=$(cfg "$key"); fi
    [ "$here" = "${SO_SHARE[$key]}" ] && continue
    n=$((n + 1))
    log_kv "$key" "here: ${here:-(empty)}   $1: ${SO_SHARE[$key]:-(empty)}"
  done
  [ "$n" -gt 0 ] || log_ok "$1 matches the settings in effect"
  return 0
}

# import_content FILE: the system config with FILE's shareable settings.
import_content() {
  local sys key
  sys=$(config_system_file)
  printf '# system-optimize settings. Imported from %s on %s.\n' "${1##*/}" "$(printf '%(%Y-%m-%d)T' -1)"
  if [ -r "$sys" ]; then
    # Keep the lines for keys the import does not set.
    while IFS= read -r line || [ -n "$line" ]; do
      [[ "$line" == '# system-optimize settings. Imported'* ]] && continue
      key=""
      [[ "$line" =~ ^[[:space:]]*([A-Z][A-Z0-9_]*)[[:space:]]*= ]] && key="${BASH_REMATCH[1]}"
      [ -n "$key" ] && [ -n "${SO_SHARE[$key]+x}" ] && continue
      printf '%s\n' "$line"
    done < "$sys"
  fi
  for key in $SO_SHARE_KEYS; do
    [ -n "${SO_SHARE[$key]+x}" ] && printf '%s=%s\n' "$key" "${SO_SHARE[$key]}"
  done
}

# import_step: write the imported settings to /etc/system-optimize.conf.
import_step() {
  local tmp rc=0
  tmp=$(tmp_file) || return 1
  import_content "$SO_ARG_FILE" > "$tmp"
  install_file /etc/system-optimize.conf 0644 < "$tmp" || rc=$?
  case "$rc" in
    0) if [ "$SO_DRY_RUN" = 1 ]; then step_dry "would write /etc/system-optimize.conf"
       else step_updated "settings imported into /etc/system-optimize.conf; run system-optimize to apply them"; fi ;;
    3) step_ok "/etc/system-optimize.conf already has these settings" ;;
    *) step_fail "could not write /etc/system-optimize.conf"; return 1 ;;
  esac
}

# import_main FILE
import_main() {
  share_read "$1" || return 1
  [ ${#SO_SHARE[@]} -gt 0 ] || { log_error "$1 has no settings to import"; return 1; }
  diff_main "$1"
  if [ "$SO_DRY_RUN" != 1 ]; then
    confirm "Import these settings into /etc/system-optimize.conf?" || return 1
  fi
  run_step import import_step
}
