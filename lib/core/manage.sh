#!/usr/bin/env bash
# lib/core/manage.sh - looking at a step without running it (step_probe),
# --safe-apply and --confirm, --check-drift and --tune.

# step_probe STEP: run STEP as a quiet dry run in a subshell and print
# "result<TAB>RESULT<TAB>NOTE", then one "plan<TAB>KIND<TAB>TARGET<TAB>CURRENT<TAB>WANTED"
# line per change it would make. Nothing is changed or printed otherwise.
step_probe() {
  ( _step_probe_in_subshell "$1" )
}

# _step_probe_in_subshell STEP: step_probe's body; it changes the run's
# globals, so it is only ever called in a subshell.
_step_probe_in_subshell() {
  local name="$1" so_res p
  exec {so_res}>&1
  exec >/dev/null 2>&1
  exec {SO_OUT}>/dev/null
  SO_DRY_RUN=1 SO_PLAN_CAPTURE=1 SO_LOG_FILE="" SO_VERBOSE=0
  SO_PLAN=()
  STEP_RESULT=""; STEP_NOTE=""; SO_CURRENT_STEP="$name"
  "${SO_STEP_FUNC[$name]}"
  [ -n "$STEP_RESULT" ] || STEP_RESULT=ok
  printf 'result\t%s\t%s\n' "$STEP_RESULT" "${STEP_NOTE//[$'\t\n']/ }" >&"$so_res"
  for p in "${SO_PLAN[@]+"${SO_PLAN[@]}"}"; do printf 'plan\t%s\n' "$p" >&"$so_res"; done
}

# probe_applied RESULT FLAGS: is the step in place? true (nothing to do),
# false (it would change things), null (it does not apply here, or reports
# only).
probe_applied() {
  list_has "$2" report && { echo null; return; }
  case "$1" in
    ok) echo true ;;
    dry-run) echo false ;;
    *) echo null ;;
  esac
}

# ---------------------------------------------------------------------------
# --safe-apply
# ---------------------------------------------------------------------------
# The pending rollbacks are listed in the history directory (readable by the
# desktop user, unlike the snapshots): "ID<TAB>DUE (ISO 8601)<TAB>DUE (epoch)".
safe_pending_file() { printf '%s/pending.tsv\n' "$(hist_system_dir)"; }

# safe_pending_due ID: the time ID's rollback is due, if one is pending.
safe_pending_due() {
  awk -F '\t' -v id="$1" '$1 == id { print $2; found = 1 } END { exit !found }' "$(safe_pending_file)" 2>/dev/null
}

# safe_pending_newest: the newest pending ID.
safe_pending_newest() {
  awk -F '\t' 'NF { id = $1 } END { if (id != "") print id; else exit 1 }' "$(safe_pending_file)" 2>/dev/null
}

# _safe_pending_drop ID
_safe_pending_drop() {
  local f
  f=$(safe_pending_file)
  [ -f "$f" ] || return 0
  awk -F '\t' -v id="$1" '$1 != id' "$f" > "$f.new" && chmod 0644 "$f.new" && mv -f -- "$f.new" "$f"
  rm -f -- "$(snap_base)/$1/pending"
}

# safe_schedule ID: undo the snapshot ID after SAFE_APPLY_TIMEOUT seconds
# unless --confirm comes first. A transient systemd timer (or, without
# systemd, a detached sleep) runs `system-optimize --rollback ID`, which
# does nothing once the run was confirmed. Either survives the terminal
# closing.
safe_schedule() {
  local id="$1" secs due epoch dir
  secs=$(cfg SAFE_APPLY_TIMEOUT)
  epoch=$(( $(epoch_now) + secs ))
  due=$(printf '%(%Y-%m-%dT%H:%M:%S%z)T' "$epoch")
  due="${due:0:22}:${due:22}"
  dir=$(hist_system_dir)
  mkdir -p -- "$dir" && chmod 0755 "$dir"
  (umask 022; printf '%s\t%s\t%s\n' "$id" "$due" "$epoch" >> "$(safe_pending_file)")
  printf '%s\n' "$due" > "$(snap_base)/$id/pending"
  if [ "$SO_INIT_SYSTEM" = systemd ] && has_cmd systemd-run; then
    if ! run systemd-run --quiet --unit="system-optimize-rollback-$id" --on-active="${secs}s" \
         --timer-property=AccuracySec=1s "$SO_BIN" --rollback "$id" --yes --no-color; then
      log_warn "could not start the rollback timer; undoing now"
      return 1
    fi
  else
    # shellcheck disable=SC2016  # the positional parameters are sh's own
    setsid sh -c 'sleep "$1"; exec "$2" --rollback "$3" --yes --no-color' sh "$secs" "$SO_BIN" "$id" \
      </dev/null >/dev/null 2>&1 &
  fi
  log_warn "safe apply: these changes are undone at $due unless you keep them:"
  log_plain "    sudo system-optimize --confirm $id"
}

# safe_after_run: --safe-apply's part after the steps (SO_BENCH_PCT holds
# the benchmark's change, if any).
safe_after_run() {
  local id
  cfg_bool SAFE_APPLY || return 0
  [ "$SO_DRY_RUN" != 1 ] && [ -n "$SO_SNAP" ] || return 0
  id=$(snap_id)
  if [ -n "${SO_BENCH_PCT:-}" ] && [ "$(bench_verdict "$SO_BENCH_PCT")" = worse ]; then
    log_warn "safe apply: the benchmark is ${SO_BENCH_PCT#-} % slower; undoing the run"
    SO_SAFE_STATE=rolled-back-regression
    _safe_undo_now "$id"
    return
  fi
  if safe_schedule "$id"; then
    SO_SAFE_STATE=pending
  else
    SO_SAFE_STATE=rolled-back
    _safe_undo_now "$id"
  fi
}

# _safe_undo_now ID: undo ID within this run.
_safe_undo_now() {
  local total i dir
  dir="$(snap_base)/$1"
  total=$(grep -c '' "$dir/manifest") || total=0
  SO_UNDO_ITEMS=()
  for ((i = total; i >= 1; i--)); do
    snap_entry_undone "$dir" "$i" || SO_UNDO_ITEMS+=("$1:$i")
  done
  run_step undo undo_items_step
}

# confirm_main [ID]: --confirm: keep a --safe-apply run.
confirm_main() {
  local id="${1:-}"
  [ -n "$id" ] && [ "$id" != latest ] || id=$(safe_pending_newest) || {
    log_info "no safe-apply run is waiting for a confirmation"
    return 0
  }
  if ! safe_pending_due "$id" >/dev/null; then
    log_info "snapshot $id has no rollback pending"
    return 0
  fi
  if [ "$SO_DRY_RUN" = 1 ]; then
    log_dry "would keep snapshot $id and cancel its rollback"
    return 0
  fi
  if [ "$SO_INIT_SYSTEM" = systemd ] && has_cmd systemctl; then
    run systemctl stop "system-optimize-rollback-$id.timer" >/dev/null 2>&1 || true
  fi
  _safe_pending_drop "$id"
  log_ok "kept the changes of $id; the rollback is cancelled (system-optimize --undo $id still undoes them)"
}

# rollback_main ID: --rollback ID (the safe-apply timer): undo ID if it is
# still pending.
rollback_main() {
  local id="$1"
  if ! safe_pending_due "$id" >/dev/null; then
    log_info "snapshot $id was confirmed or already rolled back; nothing to do"
    return 0
  fi
  _safe_pending_drop "$id"
  log_warn "safe apply: $id was not confirmed in time; undoing it"
  SO_YES=1
  undo_main "$id"
}

# ---------------------------------------------------------------------------
# --check-drift
# ---------------------------------------------------------------------------
# drift_applied_steps: the steps with changes in the history that are not
# undone, in run order.
drift_applied_steps() {
  local applied s
  applied=$(hist_all changes | awk -F '\t' 'NF >= 10 && $10 == "-" && $5 != "-" { print $5 }' | sort -u | tr '\n' ' ')
  for s in "${SO_STEPS[@]}"; do
    list_has "$applied" "$s" && printf '%s\n' "$s"
  done
  return 0
}

# drift_main: --check-drift: run each applied step as a dry run and report
# the ones that would change something again (an update, another tool or a
# person changed it back). Changes nothing; records the result.
drift_main() {
  local s line result note drifted=() n=0 sep="" json=""
  local -a plan
  for s in $(drift_applied_steps); do
    step_has_flag "$s" report && continue
    n=$((n + 1))
    plan=()
    result=""; note=""
    while IFS= read -r line; do
      tsv_split "$line"
      if [ "${SO_F[0]}" = result ]; then result="${SO_F[1]}"; note="${SO_F[2]-}"
      else plan+=("${line#plan$'\t'}")
      fi
    done < <(step_probe "$s")
    if [ "$result" = dry-run ]; then
      drifted+=("$s")
      log_warn "$s: drifted: $note"
      json+="$sep{\"step\":$(json_str "$s"),\"note\":$(json_str "$note"),\"changes\":$(plan_json "${plan[@]+"${plan[@]}"}")}"
      sep=","
    else
      log_ok "$s: still in place"
    fi
  done
  if [ "$n" = 0 ]; then
    log_info "no applied steps in the history to check"
  elif [ ${#drifted[@]} -eq 0 ]; then
    log_ok "no drift: the $n applied step(s) are still in place"
  else
    log_warn "${#drifted[@]} step(s) drifted: ${drifted[*]}; run system-optimize --only $(join_by , "${drifted[@]}") to apply them again"
  fi
  hist_writable && is_root && hist_add drift "$(epoch_now)"$'\t'"$(iso_now)"$'\t'"${drifted[*]:--}"
  if [ "$SO_JSON" = 1 ]; then
    printf '{"time":%s,"checked":%s,"drifted":[%s]}\n' "$(json_str "$(iso_now)")" "$n" "$json"
  fi
  return 0
}

# plan_json LINES...: the "changes" array from plan lines.
plan_json() {
  local l sep=""
  printf '['
  for l in "$@"; do
    tsv_split "$l"
    printf '%s{"kind":%s,"target":%s,"current":%s,"wanted":%s}' "$sep" "$(json_str "${SO_F[0]}")" \
      "$(json_str "${SO_F[1]-}")" "$(json_str_or_null "${SO_F[2]-}")" "$(json_str_or_null "${SO_F[3]-}")"
    sep=","
  done
  printf ']'
}

# ---------------------------------------------------------------------------
# --tune
# ---------------------------------------------------------------------------
# tune_main: measure, then for each of TUNE_STEPS that would change
# something: apply it alone, measure again, keep it when it is faster by
# more than BENCH_THRESHOLD %, otherwise undo it at once. Everything kept is
# in this run's snapshot, so --undo still takes it all back.
tune_main() {
  local s cand=() before after pct verdict kept=() dropped=() i id line rows=() tune_id prev steps
  steps=$(cfg TUNE_STEPS)
  for s in ${steps//,/ }; do
    step_has_flag "$s" report && continue
    line=$(step_probe "$s" | head -n1)
    tsv_split "$line"
    [ "${SO_F[1]}" = dry-run ] && cand+=("$s")
  done
  if [ ${#cand[@]} -eq 0 ]; then
    log_ok "tune: nothing to try; every step in TUNE_STEPS ($steps) is in place or does not apply here"
    return 0
  fi
  if [ "$SO_DRY_RUN" = 1 ]; then
    log_dry "would try, one at a time with a benchmark after each: ${cand[*]}"
    return 0
  fi
  confirm "Try ${cand[*]} one at a time, keeping only what measures faster?" || return 1
  bench_run tune-baseline || { log_error "tune needs a benchmark tool: install sysbench (or stress-ng) and fio"; return 1; }
  bench_save base
  local base_row
  base_row=$(bench_row)
  tune_id=$(printf '%(%Y%m%d-%H%M%S)T' -1)
  for s in "${cand[@]}"; do
    before=0
    [ -n "$SO_SNAP" ] && before=$(grep -c '' "$SO_SNAP/manifest")
    SO_ONLY="$s" run_step "$s" "${SO_STEP_FUNC[$s]}"
    after=0
    [ -n "$SO_SNAP" ] && after=$(grep -c '' "$SO_SNAP/manifest")
    [ "$after" -gt "$before" ] || continue
    id=$(snap_id)
    bench_run tune "$id" || continue
    rows+=("$(bench_row)")
    pct=$(bench_change_pct base)
    verdict=$(bench_verdict "$pct")
    prev="${BENCH_SAVED_base_id:-}"
    if [ "$verdict" = better ]; then
      log_ok "tune: $s is ${pct} % faster; kept"
      kept+=("$s")
      bench_save base
    else
      log_info "tune: $s changed the benchmark by ${pct:-?} %; undoing it"
      dropped+=("$s")
      SO_UNDO_ITEMS=()
      for ((i = after; i > before; i--)); do SO_UNDO_ITEMS+=("$id:$i"); done
      run_step undo undo_items_step
    fi
    hist_add tune "$tune_id"$'\t'"$(epoch_now)"$'\t'"$(iso_now)"$'\t'"$s"$'\t'"$id"$'\t'"$prev"$'\t'"$BENCH_ID"$'\t'"${pct:--}"$'\t'"$([ "$verdict" = better ] && echo 1 || echo 0)"
  done
  hist_add benchmarks "$base_row" "${rows[@]+"${rows[@]}"}"
  log_plain "  tune: kept ${kept[*]:-nothing}; undid ${dropped[*]:-nothing}"
}
