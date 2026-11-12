#!/usr/bin/env bash
# lib/core/report.sh - --list-steps, --describe, --history and
# --status --json: what the steps are and what they did, for people and
# for programs (the formats are in docs/json.md). All of it works as a
# normal user: it reads the history (0644), never the snapshots (0700).

SO_CAPABILITIES="undo enable revert-step profile benchmark history describe safe-apply tune check-drift export"

# step_doc STEP: the step's section of docs/steps.md (Markdown, without the
# heading). A single-file build carries the file as so_steps_doc.
step_doc() {
  local doc
  if declare -F so_steps_doc >/dev/null; then
    doc=$(so_steps_doc)
  else
    doc=$(cat -- "$SO_ROOT_DIR/docs/steps.md" 2>/dev/null) || doc=""
  fi
  printf '%s\n' "$doc" | awk -v s="## $1" '
    $0 == s { on = 1; next }
    on && /^## / { exit }
    on { print }' | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}'
}

# hist_snapshot_rows: "ID<TAB>CHANGES<TAB>OPEN<TAB>STEPS<TAB>PROFILE<TAB>TIME"
# per run in the history, oldest first.
hist_snapshot_rows() {
  local runs
  runs=$(hist_all runs)
  [ -n "$runs" ] || return 0
  {
    printf '%s\n' "$runs" | sed 's/^/R\t/'
    hist_all changes | sed 's/^/C\t/'
  } | awk -F '\t' '
    $1 == "R" { if (!($2 in seen)) { order[++n] = $2; seen[$2] = 1 }; steps[$2] = $7; prof[$2] = $6; t[$2] = $4; next }
    $1 == "C" { total[$2]++; if ($11 == "-") open[$2]++ }
    END { for (i = 1; i <= n; i++) { id = order[i]; printf "%s\t%d\t%d\t%s\t%s\t%s\n", id, total[id], open[id], steps[id], prof[id], t[id] } }'
}

# active_profile: the profile of the newest run whose changes are not all
# undone, or nothing.
active_profile() {
  hist_snapshot_rows | awk -F '\t' '$3 > 0 && $5 != "-" { p = $5 } END { if (p != "") print p }'
}

# status_json: --status --json.
status_json() {
  local s line result applied sep="" snaps="" prof id total open steps due
  printf '{"version":%s,"capabilities":%s,"steps":[' "$(json_str "$(version_string)")" \
    "$(json_word_array "$SO_CAPABILITIES")"
  for s in "${SO_STEPS[@]}"; do
    line=$(step_probe "$s" | head -n1)
    tsv_split "$line"
    result="${SO_F[1]-}"
    applied=$(probe_applied "$result" "${SO_STEP_FLAGS[$s]}")
    printf '%s{"name":%s,"kind":%s,"category":%s,"applied":%s,"title":%s,"summary":%s,"flags":%s,"state":%s,"note":%s}' \
      "$sep" "$(json_str "$s")" "$(json_str "${SO_STEP_KIND[$s]}")" "$(json_str "${SO_STEP_CATEGORY[$s]}")" "$applied" \
      "$(json_str "${SO_STEP_TITLE[$s]}")" "$(json_str "${SO_STEP_SUMMARY[$s]}")" \
      "$(json_word_array "${SO_STEP_FLAGS[$s]}")" "$(json_str "${result:-unknown}")" "$(json_str "${SO_F[2]-}")"
    sep=","
  done
  printf '],"profiles":%s,"profile_steps":{' "$(json_str_array "${SO_PROFILES[@]}")"
  sep=""
  for s in "${SO_PROFILES[@]}"; do
    printf '%s%s:%s' "$sep" "$(json_str "$s")" "$(json_word_array "${SO_PROFILE_STEPS[$s]}")"
    sep=","
  done
  prof=$(active_profile)
  printf '},"profile":%s,"snapshots":[' "$(json_str_or_null "$prof")"
  while IFS=$'\t' read -r id total open steps _ _; do
    due=$(safe_pending_due "$id") || due=""
    [ "$steps" != - ] || steps=""
    # newest first: each row goes in front of the ones collected so far
    snaps="{\"id\":$(json_str "$id"),\"summary\":$(json_str "$total change(s)${steps:+: $steps}"),\"undone\":$(json_bool "$([ "$open" = 0 ] && echo 1 || echo 0)"),\"open\":$open,\"rollback_due\":$(json_str_or_null "$due")}${snaps:+,$snaps}"
  done < <(hist_snapshot_rows)
  printf '%s],"categories":%s,"warnings":%s,"hardware":%s,"helpers_running":%s}\n' "$snaps" \
    "$(categories_json)" "$(warnings_json)" "$(hw_json)" "$(json_word_array "$(helpers_running)")"
}

# categories_json: [{"id","title"}] in display order.
categories_json() {
  local c sep=""
  printf '['
  for c in "${SO_CATEGORIES[@]}"; do
    printf '%s{"id":%s,"title":%s}' "$sep" "$(json_str "$c")" "$(json_str "${SO_CATEGORY_TITLE[$c]}")"
    sep=","
  done
  printf ']'
}

# warnings_json: [{"id","text"}] for the conflicts found.
warnings_json() {
  local id text sep=""
  printf '['
  while IFS=$'\t' read -r id text; do
    printf '%s{"id":%s,"text":%s}' "$sep" "$(json_str "$id")" "$(json_str "$text")"
    sep=","
  done < <(so_warnings)
  printf ']'
}

# hw_json: the read-only hardware facts as an object of strings.
hw_json() {
  local k v sep=""
  printf '{'
  while IFS=$'\t' read -r k v; do
    printf '%s%s:%s' "$sep" "$(json_str "$k")" "$(json_str "$v")"
    sep=","
  done < <(hw_facts)
  printf '}'
}

# list_steps_main: --list-steps [--json].
list_steps_main() {
  local s p
  if [ "$SO_JSON" = 1 ]; then
    local sep=""
    printf '{"steps":['
    for s in "${SO_STEPS[@]}"; do
      printf '%s{"name":%s,"kind":%s,"category":%s,"title":%s,"summary":%s,"flags":%s}' "$sep" "$(json_str "$s")" \
        "$(json_str "${SO_STEP_KIND[$s]}")" "$(json_str "${SO_STEP_CATEGORY[$s]}")" "$(json_str "${SO_STEP_TITLE[$s]}")" \
        "$(json_str "${SO_STEP_SUMMARY[$s]}")" "$(json_word_array "${SO_STEP_FLAGS[$s]}")"
      sep=","
    done
    printf '],"profiles":['
    sep=""
    for p in "${SO_PROFILES[@]}"; do
      printf '%s{"name":%s,"title":%s,"steps":%s}' "$sep" "$(json_str "$p")" \
        "$(json_str "${SO_PROFILE_TITLE[$p]}")" "$(json_word_array "${SO_PROFILE_STEPS[$p]}")"
      sep=","
    done
    printf ']}\n'
    return 0
  fi
  log_plain "${C_BOLD}Default steps${C_RESET} (run unless --skip)"
  for s in $(steps_of_kind default); do log_kv "$s" "${SO_STEP_TITLE[$s]}"; done
  log_plain ""
  log_plain "${C_BOLD}Opt-in steps${C_RESET} (--enable LIST, ENABLE=, a profile or --only)"
  for s in $(steps_of_kind opt-in); do
    log_kv "$s" "${SO_STEP_TITLE[$s]}$(step_has_flag "$s" reboot && printf ' (reboot)')$(step_has_flag "$s" report && printf ' (report only)')"
  done
  log_plain ""
  log_plain "${C_BOLD}Profiles${C_RESET} (--profile NAME)"
  for p in "${SO_PROFILES[@]}"; do
    log_kv "$p" "${SO_PROFILE_STEPS[$p]}"
    log_plain "      ${SO_PROFILE_TITLE[$p]}"
  done
}

# describe_main STEP: --describe STEP [--json].
describe_main() {
  local s="$1" line result="" note="" doc
  local -a plan=()
  while IFS= read -r line; do
    tsv_split "$line"
    if [ "${SO_F[0]}" = result ]; then result="${SO_F[1]}"; note="${SO_F[2]-}"
    else plan+=("${line#plan$'\t'}")
    fi
  done < <(step_probe "$s")
  doc=$(step_doc "$s")
  if [ "$SO_JSON" = 1 ]; then
    printf '{"name":%s,"kind":%s,"category":%s,"title":%s,"summary":%s,"flags":%s,"applied":%s,"state":%s,"note":%s,"doc":%s,"changes":%s}\n' \
      "$(json_str "$s")" "$(json_str "${SO_STEP_KIND[$s]}")" "$(json_str "${SO_STEP_CATEGORY[$s]}")" "$(json_str "${SO_STEP_TITLE[$s]}")" \
      "$(json_str "${SO_STEP_SUMMARY[$s]}")" "$(json_word_array "${SO_STEP_FLAGS[$s]}")" \
      "$(probe_applied "$result" "${SO_STEP_FLAGS[$s]}")" "$(json_str "$result")" "$(json_str "$note")" \
      "$(json_str "$doc")" "$(plan_json "${plan[@]+"${plan[@]}"}")"
    return 0
  fi
  log_plain "${C_BOLD}$s${C_RESET} (${SO_STEP_KIND[$s]}): ${SO_STEP_TITLE[$s]}"
  log_plain "  ${SO_STEP_SUMMARY[$s]}"
  log_plain ""
  log_kv "here" "$result${note:+: $note}"
  for line in "${plan[@]+"${plan[@]}"}"; do
    tsv_split "$line"
    log_kv "${SO_F[0]}" "${SO_F[1]}: ${SO_F[2]:-?} -> ${SO_F[3]:-?}"
  done
  if [ -n "$doc" ]; then
    log_plain ""
    printf '%s\n' "$doc" | sed 's/^/  /' >&"$SO_OUT"
  fi
}

# _hist_bench_json ROW: a benchmarks row as the benchmark object. llm_pp
# and llm_tg (llama-bench, tokens/s) are there only when they were measured.
_hist_bench_json() {
  tsv_split "$1"
  local f=("${SO_F[@]}") llm="" llmu="" model=""
  if [[ "${f[14]-}" =~ ^[0-9] ]] || [[ "${f[15]-}" =~ ^[0-9] ]]; then
    llm=",\"llm_pp\":$(json_num "${f[14]-}"),\"llm_tg\":$(json_num "${f[15]-}")"
    llmu=',"llm_pp":"tok/s","llm_tg":"tok/s"'
    model=",\"llm_model\":$(json_str_or_null "${f[16]-}")"
  fi
  printf '{"id":%s,"time":%s,"snapshot":%s,"profile":%s,"phase":%s,"seconds":%s,"scores":{"cpu":%s,"memory":%s,"disk":%s,"overall":%s%s},"units":{"cpu":%s,"memory":%s,"disk":%s,"overall":%s%s}%s}' \
    "$(json_str "${f[0]}")" "$(json_str "${f[2]}")" "$(json_str_or_null "${f[3]}")" "$(json_str_or_null "${f[5]}")" \
    "$(json_str "${f[4]}")" "$(json_num "${f[13]-}")" \
    "$(json_num "${f[6]}")" "$(json_num "${f[7]}")" "$(json_num "${f[8]}")" "$(json_num "${f[9]}")" "$llm" \
    "$(json_str_or_null "${f[10]}")" "$(json_str_or_null "${f[11]}")" "$(json_str_or_null "${f[12]}")" \
    "$(json_str "geometric mean of cpu, memory and disk")" "$llmu" "$model"
}

# history_main: --history [--step STEP] [--limit N] [--json].
history_main() {
  local step="$SO_ARG_STEP" limit="${SO_ARG_LIMIT:-0}" benches changes row sep="" first="" baseline="" refs=" "
  local -a f
  benches=$(hist_all benchmarks | sort -s -t $'\t' -k2,2n)
  changes=$(hist_all changes | sort -s -t $'\t' -k3,3n -k1,1 -k2,2n)
  if [ -n "$step" ]; then
    changes=$(printf '%s\n' "$changes" | awk -F '\t' -v s="$step" '$5 == s')
  fi
  if [ "$limit" -gt 0 ]; then
    changes=$(printf '%s\n' "$changes" | grep . | tail -n "$limit")
  fi
  # Benchmarks taken with each change's run (before and after).
  declare -A b_before=() b_after=()
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    tsv_split "$row"
    case "${SO_F[4]}" in
      before) b_before[${SO_F[3]}]="${SO_F[0]}" ;;
      after|tune) b_after[${SO_F[3]}]="${SO_F[0]}" ;;
    esac
  done <<< "$benches"
  if [ -n "$step" ]; then
    first=$(printf '%s\n' "$changes" | head -n1 | cut -f3)
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      tsv_split "$row"
      refs+="${b_before[${SO_F[0]}]-} ${b_after[${SO_F[0]}]-} "
    done <<< "$changes"
    # The baseline: the newest benchmark taken before the step's first change.
    if [ -n "$first" ]; then
      baseline=$(printf '%s\n' "$benches" | awk -F '\t' -v t="$first" '$2 + 0 < t + 0 { b = $1 } END { print b }')
    fi
    refs+="$baseline "
    benches=$(printf '%s\n' "$benches" | awk -F '\t' -v r="$refs" 'index(r, " " $1 " ")')
  elif [ "$limit" -gt 0 ]; then
    benches=$(printf '%s\n' "$benches" | grep . | tail -n "$limit")
  fi
  if [ "$SO_JSON" != 1 ]; then
    history_print "$benches" "$changes"
    return 0
  fi
  printf '{"benchmarks":['
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    printf '%s' "$sep"; _hist_bench_json "$row"; sep=","
  done <<< "$benches"
  printf '],"changes":['
  sep=""
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    tsv_split "$row"; f=("${SO_F[@]}")
    printf '%s{"time":%s,"snapshot":%s,"step":%s,"kind":%s,"target":%s,"old":%s,"new":%s,"undone":%s,"undone_time":%s,"benchmark_before":%s,"benchmark_after":%s}' \
      "$sep" "$(json_str "${f[3]}")" "$(json_str "${f[0]}")" "$(json_str_or_null "${f[4]}")" "$(json_str "${f[5]}")" \
      "$(json_str "${f[6]}")" "$(json_str_or_null "${f[7]}")" "$(json_str_or_null "${f[8]}")" \
      "$(json_bool "$([ "${f[9]}" = - ] && echo 0 || echo 1)")" "$(json_str_or_null "${f[10]}")" \
      "$(json_str_or_null "${b_before[${f[0]}]-}")" "$(json_str_or_null "${b_after[${f[0]}]-}")"
    sep=","
  done <<< "$changes"
  printf '],"baseline":%s}\n' "$(json_str_or_null "$baseline")"
}

# history_print BENCHES CHANGES: the human-readable --history.
history_print() {
  local row
  log_plain "${C_BOLD}Benchmarks${C_RESET} (cpu / memory / disk / overall; higher is better)"
  [ -n "$1" ] || log_plain "  (none: system-optimize --benchmark-only)"
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    tsv_split "$row"
    log_kv "${SO_F[2]}" "${SO_F[6]} / ${SO_F[7]} / ${SO_F[8]} / ${SO_F[9]}  (${SO_F[4]}${SO_F[3]:+, ${SO_F[3]}})"
  done <<< "$1"
  log_plain ""
  log_plain "${C_BOLD}Changes${C_RESET}"
  [ -n "$2" ] || log_plain "  (none)"
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    tsv_split "$row"
    log_kv "${SO_F[3]}" "${SO_F[4]}: ${SO_F[5]} ${SO_F[6]}: ${SO_F[7]} -> ${SO_F[8]}$([ "${SO_F[9]}" = - ] || printf ' (undone %s)' "${SO_F[10]}")"
  done <<< "$2"
}
