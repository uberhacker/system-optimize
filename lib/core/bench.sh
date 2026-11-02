#!/usr/bin/env bash
# lib/core/bench.sh - --benchmark and --benchmark-only: a short measurement
# of CPU, memory and disk, kept in the history so that runs can be compared.
#
# Each test takes BENCH_SECONDS (default 5) and uses the first tool found:
#   cpu     sysbench cpu (events/s), else stress-ng --cpu (bogo ops/s)
#   memory  sysbench memory (MiB/s), else stress-ng --memrate (bogo ops/s)
#   disk    fio random 4 KiB reads, direct I/O, on a 128 MiB file (IOPS)
#   llm     llama-bench (llama.cpp), only when BENCH_LLM_MODEL names a GGUF
#           model: prompt processing (llm_pp) and generation (llm_tg) in
#           tokens/s, 128 prompt tokens and 32 generated, best of 2
# A test whose tool is missing is skipped (its score is null). Every score
# is "higher is better". "overall" is the geometric mean of cpu, memory and
# disk, so two benchmarks compare as the geometric mean of their ratios;
# the before/after verdict counts llm_pp and llm_tg too when both have them.
# When Performance Co-Pilot runs (pmcd) and pcp2json is there, each
# benchmark also records the machine's pressure, load and disk traffic
# while it ran, once a second, in the history directory as pcp/ID.json
# (BENCH_PCP=0 turns that off).
# The unit says which tool measured: scores are only compared when their
# units match. Nothing is installed: install sysbench and fio for all three.
# A benchmark never runs in a dry run.

BENCH_ID=""
declare -gA BENCH_SCORE=() BENCH_UNIT=()
BENCH_KEYS="cpu memory disk"
BENCH_LLM_KEYS="llm_pp llm_tg"
BENCH_LLM_MODEL_NAME=""

# _bench_nproc: online CPUs.
_bench_nproc() {
  local n
  n=$(getconf _NPROCESSORS_ONLN 2>/dev/null) || n=""
  [[ "$n" =~ ^[0-9]+$ ]] || n=$(nproc 2>/dev/null) || n=1
  printf '%s\n' "${n:-1}"
}

# _bench_stressng STRESSOR ARGS...: bogo ops/s (real time) of one stressor.
_bench_stressng() {
  local name="$1" secs; shift
  secs=$(cfg BENCH_SECONDS)
  run stress-ng "$@" --timeout "${secs}s" --metrics-brief 2>&1 |
    awk -v s="$name" '{ for (i = 1; i <= NF; i++) if ($i == s && $(i+1) ~ /^[0-9.]+$/) { print $(i+5); exit } }'
}

# bench_cpu / bench_memory / bench_disk: set BENCH_SCORE and BENCH_UNIT for
# one test, or return 1 when no tool is there.
bench_cpu() {
  local v secs
  secs=$(cfg BENCH_SECONDS)
  if has_cmd sysbench; then
    v=$(run sysbench cpu --threads="$(_bench_nproc)" --time="$secs" run 2>/dev/null |
        sed -n 's/^ *events per second: *\([0-9.]*\).*/\1/p' | head -n1)
    BENCH_UNIT[cpu]="events/s (sysbench cpu)"
  elif has_cmd stress-ng; then
    v=$(_bench_stressng cpu --cpu "$(_bench_nproc)")
    BENCH_UNIT[cpu]="bogo ops/s (stress-ng cpu)"
  else
    return 1
  fi
  BENCH_SCORE[cpu]="$v"
}

bench_memory() {
  local v secs
  secs=$(cfg BENCH_SECONDS)
  if has_cmd sysbench; then
    v=$(run sysbench memory --threads="$(_bench_nproc)" --memory-total-size=1T --time="$secs" run 2>/dev/null |
        sed -n 's/.*(\([0-9.]*\) MiB\/sec).*/\1/p' | head -n1)
    BENCH_UNIT[memory]="MiB/s (sysbench memory)"
  elif has_cmd stress-ng; then
    v=$(_bench_stressng memrate --memrate 1 --memrate-bytes 256M)
    BENCH_UNIT[memory]="bogo ops/s (stress-ng memrate)"
  else
    return 1
  fi
  BENCH_SCORE[memory]="$v"
}

# _bench_disk_dir: a directory on a real disk for the test file.
_bench_disk_dir() {
  if is_root; then
    so_path /var/tmp
  else
    printf '%s\n' "${XDG_CACHE_HOME:-$SO_HOME/.cache}"
  fi
}

bench_disk() {
  local v dir file secs
  has_cmd fio || return 1
  secs=$(cfg BENCH_SECONDS)
  dir=$(_bench_disk_dir)
  mkdir -p -- "$dir" 2>/dev/null || return 1
  file="$dir/system-optimize-bench.$$"
  # --minimal: semicolon-separated "terse" output; field 8 is the read IOPS.
  v=$(run fio --name=system-optimize --filename="$file" --size=128M --rw=randread --bs=4k \
        --direct=1 --ioengine=psync --time_based --runtime="$secs" --minimal 2>/dev/null |
      awk -F ';' 'NF > 8 { print $8; exit }')
  rm -f -- "$file"
  BENCH_UNIT[disk]="IOPS (fio 4k random read)"
  BENCH_SCORE[disk]="$v"
}

# _llama_bench_parse: "PP<TAB>TG" (tokens/s) from llama-bench -o json. Each
# result object has n_prompt, n_gen and avg_ts; a prompt test has n_gen 0.
_llama_bench_parse() {
  tr -d '\n' | sed 's/}/}\n/g' | awk '
    function num(k,   m) { if (match($0, "\"" k "\": *[0-9.eE+-]+")) { m = substr($0, RSTART, RLENGTH); sub(/^[^:]*: */, "", m); return m } return "" }
    { np = num("n_prompt"); ng = num("n_gen"); ts = num("avg_ts")
      if (ts == "") next
      if (np + 0 > 0 && ng + 0 == 0) pp = ts
      else if (ng + 0 > 0 && np + 0 == 0) tg = ts }
    END { printf "%s\t%s\n", pp, tg }'
}

# bench_llm: llm_pp and llm_tg from llama-bench, or return 1.
bench_llm() {
  local model out pp tg
  model=$(cfg BENCH_LLM_MODEL)
  [ -n "$model" ] || return 1
  has_cmd llama-bench || { log_detail "benchmark: BENCH_LLM_MODEL is set, but llama-bench is not installed"; return 1; }
  [ -r "$model" ] || { log_warn "benchmark: cannot read the model $model"; return 1; }
  out=$(run llama-bench -m "$model" -p 128 -n 32 -r 2 -o json 2>/dev/null | _llama_bench_parse) || out=""
  IFS=$'\t' read -r pp tg <<< "$out"
  [[ "$pp" =~ ^[0-9]+(\.[0-9]+)?$ ]] || pp=""
  [[ "$tg" =~ ^[0-9]+(\.[0-9]+)?$ ]] || tg=""
  [ -n "$pp$tg" ] || { log_warn "benchmark: llama-bench gave no result for $model"; return 1; }
  BENCH_SCORE[llm_pp]=$(printf '%.2f' "$pp" 2>/dev/null || printf '%s' "$pp")
  BENCH_SCORE[llm_tg]=$(printf '%.2f' "$tg" 2>/dev/null || printf '%s' "$tg")
  [ -n "$pp" ] || BENCH_SCORE[llm_pp]=""
  [ -n "$tg" ] || BENCH_SCORE[llm_tg]=""
  BENCH_UNIT[llm_pp]="tok/s"; BENCH_UNIT[llm_tg]="tok/s"
  BENCH_LLM_MODEL_NAME="${model##*/}"
}

# _bench_pcp_start ID SECONDS: record PCP metrics while the benchmark runs.
_bench_pcp_start() {
  local dir
  BENCH_PCP_PID=""
  cfg_bool BENCH_PCP && has_cmd pcp2json && pcp_running || return 0
  dir="$(hist_write_dir)/pcp"
  mkdir -p -- "$dir" 2>/dev/null || return 0
  pcp2json -t 1 -s "$2" kernel.all.load kernel.all.pressure.cpu.some.avg kernel.all.pressure.memory.some.avg \
    kernel.all.pressure.io.full.avg mem.util.available disk.all.read_bytes disk.all.write_bytes \
    > "$dir/$1.json" 2>/dev/null &
  BENCH_PCP_PID=$!
  BENCH_PCP_FILE="$dir/$1.json"
}

_bench_pcp_stop() {
  [ -n "${BENCH_PCP_PID:-}" ] || return 0
  kill "$BENCH_PCP_PID" 2>/dev/null
  wait "$BENCH_PCP_PID" 2>/dev/null
  chmod 0644 "$BENCH_PCP_FILE" 2>/dev/null
  log_detail "benchmark: PCP metrics in $BENCH_PCP_FILE"
  BENCH_PCP_PID=""
}

# _bench_words: the lines on stdin as "a", "a and b" or "a, b and c".
_bench_words() {
  awk '{ w[++n] = $0 } END {
    for (i = 1; i <= n; i++) printf "%s%s", w[i], (i == n ? "" : (i == n - 1 ? " and " : ", ")); print "" }'
}

# _bench_geomean VALUES...: the geometric mean of the positive numbers.
_bench_geomean() {
  printf '%s\n' "$@" | awk '$1 + 0 > 0 { s += log($1); n++ } END { if (n) printf "%.2f\n", exp(s / n) }'
}

# bench_run PHASE [SNAPSHOT]: measure (PHASE before, after, standalone or
# tune). bench_record then keeps it in the history. Returns 1 when no test
# could run.
bench_run() {
  local phase="$1" snap="${2:--}" k vals=() started id
  BENCH_SCORE=(); BENCH_UNIT=(); BENCH_LLM_MODEL_NAME=""
  started=$SECONDS
  id="$(printf '%(%Y%m%d-%H%M%S)T' -1)-$phase"
  log_info "benchmark ($phase): about $(( $(cfg BENCH_SECONDS) * 3 )) s"
  _bench_pcp_start "$id" "$(( $(cfg BENCH_SECONDS) * 3 + 2 ))"
  bench_cpu || log_detail "benchmark: no sysbench or stress-ng for the CPU test"
  bench_memory || log_detail "benchmark: no sysbench or stress-ng for the memory test"
  bench_disk || log_detail "benchmark: no fio for the disk test"
  _bench_pcp_stop
  bench_llm || true
  for k in $BENCH_LLM_KEYS; do
    [[ "${BENCH_SCORE[$k]-}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || BENCH_SCORE[$k]=""
  done
  for k in $BENCH_KEYS; do
    if [[ "${BENCH_SCORE[$k]-}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      vals+=("${BENCH_SCORE[$k]}")
    else
      BENCH_SCORE[$k]=""
    fi
  done
  if [ ${#vals[@]} -eq 0 ] && [ -z "${BENCH_SCORE[llm_pp]}${BENCH_SCORE[llm_tg]}" ]; then
    log_warn "benchmark: nothing to measure with; install sysbench (or stress-ng) and fio"
    BENCH_ID=""
    return 1
  fi
  BENCH_SCORE[overall]=""
  [ ${#vals[@]} -eq 0 ] || BENCH_SCORE[overall]=$(_bench_geomean "${vals[@]}")
  BENCH_UNIT[overall]="geometric mean of $(for k in $BENCH_KEYS; do [ -n "${BENCH_SCORE[$k]}" ] && printf '%s\n' "$k"; done | _bench_words)"
  BENCH_SECS=$((SECONDS - started))
  BENCH_ID="$id"
  BENCH_TIME=$(iso_now)
  BENCH_PHASE="$phase"
  BENCH_SNAPSHOT="$snap"
  for k in $BENCH_KEYS overall $BENCH_LLM_KEYS; do
    log_detail "benchmark $k: ${BENCH_SCORE[$k]:-skipped}${BENCH_SCORE[$k]:+ ${BENCH_UNIT[$k]}}"
  done
  BENCH_EPOCH=$(epoch_now)
  return 0
}

# bench_row [SNAPSHOT]: the current result as a history row.
bench_row() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$BENCH_ID" "$BENCH_EPOCH" "$BENCH_TIME" \
    "${1:-$BENCH_SNAPSHOT}" "$BENCH_PHASE" "${SO_PROFILE:--}" "${BENCH_SCORE[cpu]:--}" "${BENCH_SCORE[memory]:--}" \
    "${BENCH_SCORE[disk]:--}" "${BENCH_SCORE[overall]:--}" "${BENCH_UNIT[cpu]:--}" "${BENCH_UNIT[memory]:--}" \
    "${BENCH_UNIT[disk]:--}" "$BENCH_SECS" "${BENCH_SCORE[llm_pp]:--}" "${BENCH_SCORE[llm_tg]:--}" "${BENCH_LLM_MODEL_NAME:--}"
}

# bench_record [SNAPSHOT]: keep the current result in the history.
bench_record() {
  [ -n "$BENCH_ID" ] || return 0
  [ -z "${1:-}" ] || BENCH_SNAPSHOT="$1"
  hist_add benchmarks "$(bench_row)"
}

# bench_save NAME: keep the current result in BENCH_SAVED_NAME_*.
bench_save() {
  local k
  for k in $BENCH_KEYS overall $BENCH_LLM_KEYS; do
    printf -v "BENCH_SAVED_${1}_${k}" '%s' "${BENCH_SCORE[$k]-}"
    printf -v "BENCH_SAVED_${1}_${k}_unit" '%s' "${BENCH_UNIT[$k]-}"
  done
  printf -v "BENCH_SAVED_${1}_id" '%s' "$BENCH_ID"
}

# bench_change_pct SAVED: the change from a saved result to the current
# one, in percent, over the tests both measured with the same tool (the
# geometric mean of the ratios). Empty when they have none in common.
bench_change_pct() {
  local k b bu ratios=()
  for k in $BENCH_KEYS $BENCH_LLM_KEYS; do
    b="BENCH_SAVED_${1}_${k}"; bu="BENCH_SAVED_${1}_${k}_unit"
    if [ -z "${!b}" ] || [ -z "${BENCH_SCORE[$k]}" ] || [ "${!bu}" != "${BENCH_UNIT[$k]}" ]; then continue; fi
    ratios+=("$(awk -v a="${BENCH_SCORE[$k]}" -v b="${!b}" 'BEGIN { if (b > 0) printf "%.6f", a / b }')")
  done
  [ ${#ratios[@]} -gt 0 ] || return 0
  printf '%s\n' "${ratios[@]}" | awk '$1 > 0 { s += log($1); n++ } END { if (n) printf "%.1f\n", (exp(s / n) - 1) * 100 }'
}

# bench_verdict PCT: better, worse or same (within BENCH_THRESHOLD %).
bench_verdict() {
  local t
  t=$(cfg BENCH_THRESHOLD)
  [ -n "$1" ] || { echo unknown; return 0; }
  awk -v p="$1" -v t="$t" 'BEGIN { if (p > t) print "better"; else if (p < -t) print "worse"; else print "same" }'
}

# bench_print_compare SAVED: one line per test, before -> after.
bench_print_compare() {
  local k b pct
  for k in $BENCH_KEYS overall $BENCH_LLM_KEYS; do
    [ -n "${BENCH_SCORE[$k]-}" ] || [ "$k" = overall ] || [[ "$k" != llm_* ]] || continue
    b="BENCH_SAVED_${1}_${k}"
    log_kv "$k" "${!b:-skipped} -> ${BENCH_SCORE[$k]:-skipped}${BENCH_UNIT[$k]:+  ${BENCH_UNIT[$k]}}"
  done
  pct=$(bench_change_pct "$1")
  log_kv "change" "${pct:-n/a}${pct:+ % ($(bench_verdict "$pct"))}"
}

# bench_json: the current result as the benchmark object of docs/json.md.
# llm_pp, llm_tg and llm_model are there only when llama-bench ran.
bench_json() {
  local k sep="" keys="$BENCH_KEYS overall" llm=0
  [ -z "${BENCH_SCORE[llm_pp]-}${BENCH_SCORE[llm_tg]-}" ] || { keys+=" $BENCH_LLM_KEYS"; llm=1; }
  printf '{"id":%s,"time":%s,"snapshot":%s,"profile":%s,"phase":%s,"seconds":%s,"scores":{' \
    "$(json_str "$BENCH_ID")" "$(json_str "$BENCH_TIME")" "$(json_str_or_null "$BENCH_SNAPSHOT")" \
    "$(json_str_or_null "$SO_PROFILE")" "$(json_str "$BENCH_PHASE")" "$(json_num "${BENCH_SECS-}")"
  for k in $keys; do printf '%s"%s":%s' "$sep" "$k" "$(json_num "${BENCH_SCORE[$k]-}")"; sep=","; done
  printf '},"units":{'
  sep=""
  for k in $keys; do printf '%s"%s":%s' "$sep" "$k" "$(json_str_or_null "${BENCH_UNIT[$k]-}")"; sep=","; done
  printf '}'
  [ "$llm" = 0 ] || printf ',"llm_model":%s' "$(json_str_or_null "$BENCH_LLM_MODEL_NAME")"
  printf '}'
}

# bench_only_main: --benchmark-only (as any user).
bench_only_main() {
  local rc=0 k
  bench_run standalone || rc=1
  [ "$rc" != 0 ] || bench_record ""
  if [ "$SO_JSON" = 1 ]; then
    if [ "$rc" = 0 ]; then bench_json; printf '\n'; else printf '{"error":"no benchmark tool: install sysbench (or stress-ng) and fio"}\n'; fi
    return "$rc"
  fi
  [ "$rc" = 0 ] || return 1
  log_plain "${C_BOLD}Benchmark${C_RESET} $BENCH_ID"
  for k in $BENCH_KEYS overall; do
    log_kv "$k" "${BENCH_SCORE[$k]:-skipped}${BENCH_SCORE[$k]:+  ${BENCH_UNIT[$k]}}"
  done
  for k in $BENCH_LLM_KEYS; do
    [ -z "${BENCH_SCORE[$k]-}" ] || log_kv "$k" "${BENCH_SCORE[$k]}  ${BENCH_UNIT[$k]} ($BENCH_LLM_MODEL_NAME)"
  done
}
