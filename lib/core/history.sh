#!/usr/bin/env bash
# lib/core/history.sh - the history: every run's changes, every benchmark,
# drift checks and --tune trials, kept so that results can be compared over
# time and read without root (the tray app reads it as the desktop user).
#
# Where: HISTORY_DIR, else /var/lib/system-optimize/history for root and
# ${XDG_STATE_HOME:-~/.local/state}/system-optimize/history for a user
# (whose own --benchmark-only results go there). The system directory is
# 0755 and its files 0644, unlike the 0700 snapshots: the history holds the
# changes (kind, target, value before and after) but never a file's
# contents. Readers merge the system history with their own.
#
# Store: SQLite (history.db) when sqlite3 is installed, else one
# tab-separated file per table (TABLE.tsv, with a header line). A store
# keeps the format it was created with. The schema is in docs/json.md.
# --undo never removes history; it marks changes undone. Rows older than
# HISTORY_KEEP_DAYS (default 180) are pruned after each write, except
# changes not undone yet and the runs that made them.

declare -gA SO_HIST_COLS=(
  [runs]="id epoch time mode profile steps command exit"
  [changes]="snapshot line epoch time step kind target old new undone_epoch undone_time"
  [benchmarks]="id epoch time snapshot phase profile cpu memory disk overall cpu_unit memory_unit disk_unit seconds llm_pp llm_tg llm_model"
  [drift]="epoch time steps"
  [tune]="id epoch time step snapshot before after change kept"
)
SO_HIST_TABLES="runs changes benchmarks drift tune"
SO_HIST_SCHEMA_VERSION=1

# hist_system_dir / hist_user_dir / hist_write_dir
hist_system_dir() {
  local d
  d=$(cfg HISTORY_DIR)
  if [ -n "$d" ]; then printf '%s\n' "$d"; else so_path /var/lib/system-optimize/history; fi
}
hist_user_dir() { printf '%s/system-optimize/history\n' "${XDG_STATE_HOME:-$SO_HOME/.local/state}"; }
hist_write_dir() { if is_root || [ -n "$(cfg HISTORY_DIR)" ]; then hist_system_dir; else hist_user_dir; fi; }

# hist_read_dirs: the stores a reader merges (the system one first).
hist_read_dirs() {
  local s u
  s=$(hist_system_dir); u=$(hist_user_dir)
  printf '%s\n' "$s"
  [ "$u" = "$s" ] || printf '%s\n' "$u"
}

# hist_backend DIR: sqlite, text, or none (no store there yet).
hist_backend() {
  local dir="$1"
  if [ -f "$dir/history.db" ]; then echo sqlite
  elif [ -f "$dir/runs.tsv" ] || [ -f "$dir/benchmarks.tsv" ]; then echo text
  else echo none
  fi
}

# _hist_new_backend: the format for a new store.
_hist_new_backend() {
  case "${SO_HISTORY_BACKEND:-}" in
    sqlite|text) echo "$SO_HISTORY_BACKEND"; return ;;
  esac
  if has_cmd sqlite3; then echo sqlite; else echo text; fi
}

# _hist_sql DIR [-readonly] SQL...: run SQL on DIR's database.
_hist_sql() {
  local db="$1/history.db"; shift
  local ro=()
  [ "${1:-}" = -readonly ] && { ro=(-readonly); shift; }
  sqlite3 -batch "${ro[@]}" -separator $'\t' -noheader "$db" "$@" 2>/dev/null
}

# _hist_q VALUE: a quoted SQL string ('-' for empty).
_hist_q() {
  local v="${1:--}"
  v="${v//[$'\t\n\r']/ }"
  printf "'%s'" "${v//\'/\'\'}"
}

# hist_init DIR: create the store (0755 directory, 0644 files).
hist_init() {
  local dir="$1" t backend cols sql=""
  backend=$(hist_backend "$dir")
  [ "$backend" = none ] || return 0
  mkdir -p -- "$dir" && chmod 0755 "$dir" || return 1
  backend=$(_hist_new_backend)
  if [ "$backend" = sqlite ]; then
    for t in $SO_HIST_TABLES; do
      cols=${SO_HIST_COLS[$t]}
      sql+="CREATE TABLE IF NOT EXISTS $t (${cols// / TEXT, } TEXT);"
    done
    sql+="CREATE INDEX IF NOT EXISTS changes_snapshot ON changes (snapshot, line);"
    sql+="PRAGMA user_version = $SO_HIST_SCHEMA_VERSION;"
    (umask 022; _hist_sql "$dir" "$sql") || return 1
    chmod 0644 "$dir/history.db"
  else
    for t in $SO_HIST_TABLES; do
      (umask 022; printf '%s\n' "${SO_HIST_COLS[$t]// /$'\t'}" > "$dir/$t.tsv") || return 1
    done
  fi
}

# hist_insert DIR TABLE ROW...: add rows (each a tab-separated line in the
# table's column order; '-' for an empty value).
hist_insert() {
  local dir="$1" table="$2" row f sql="BEGIN;" vals
  local -a fields
  shift 2
  [ $# -gt 0 ] || return 0
  case "$(hist_backend "$dir")" in
    sqlite)
      for row in "$@"; do
        tsv_split "$row"; fields=("${SO_F[@]}")
        vals=""
        for f in "${fields[@]}"; do vals+="${vals:+,}$(_hist_q "$f")"; done
        sql+="INSERT INTO $table VALUES ($vals);"
      done
      _hist_sql "$dir" "PRAGMA busy_timeout=5000;${sql}COMMIT;" >/dev/null ;;
    text)
      for row in "$@"; do
        tsv_split "$row"
        local out="" x
        for x in "${SO_F[@]}"; do
          x="${x:--}"
          out+="${out:+$'\t'}${x//[$'\t\n\r']/ }"
        done
        printf '%s\n' "$out" >> "$dir/$table.tsv"
      done ;;
    *) return 1 ;;
  esac
}

# hist_rows DIR TABLE: every row, tab-separated, in insertion order.
hist_rows() {
  local dir="$1" table="$2" cols
  cols=${SO_HIST_COLS[$table]}
  case "$(hist_backend "$dir")" in
    sqlite) _hist_sql "$dir" -readonly "SELECT ${cols// /, } FROM $table ORDER BY rowid;" ;;
    text) [ -r "$dir/$table.tsv" ] && tail -n +2 "$dir/$table.tsv" ;;
  esac
  return 0
}

# hist_all TABLE: the rows of every store a reader sees.
hist_all() {
  local d
  while IFS= read -r d; do hist_rows "$d" "$1"; done < <(hist_read_dirs)
}

# hist_writable: may this run write the history?
hist_writable() {
  [ "$SO_DRY_RUN" != 1 ] && cfg_bool HISTORY
}

# hist_add TABLE ROW...: insert into this user's store (created if needed),
# then prune it.
hist_add() {
  local dir
  hist_writable || return 0
  dir=$(hist_write_dir)
  hist_init "$dir" || { log_warn "cannot write the history in $dir"; return 0; }
  hist_insert "$dir" "$@" || log_warn "cannot write the history in $dir"
  hist_prune "$dir" "$(cfg HISTORY_KEEP_DAYS)"
}

# hist_prune DIR DAYS: drop rows older than DAYS (0 keeps everything);
# changes not undone, and their runs, stay.
hist_prune() {
  local dir="$1" days="$2" cut t
  [ "$days" -gt 0 ] 2>/dev/null || return 0
  cut=$(( $(epoch_now) - days * 86400 ))
  case "$(hist_backend "$dir")" in
    sqlite)
      _hist_sql "$dir" "PRAGMA busy_timeout=5000; BEGIN;
        DELETE FROM benchmarks WHERE CAST(epoch AS INTEGER) < $cut;
        DELETE FROM drift WHERE CAST(epoch AS INTEGER) < $cut;
        DELETE FROM tune WHERE CAST(epoch AS INTEGER) < $cut;
        DELETE FROM changes WHERE CAST(epoch AS INTEGER) < $cut AND undone_epoch != '-';
        DELETE FROM runs WHERE CAST(epoch AS INTEGER) < $cut AND id NOT IN (SELECT snapshot FROM changes);
        COMMIT;" >/dev/null ;;
    text)
      for t in benchmarks drift tune; do
        _hist_text_filter "$dir/$t.tsv" "\$$(_hist_col "$t" epoch) >= $cut"
      done
      _hist_text_filter "$dir/changes.tsv" "\$3 >= $cut || \$10 == \"-\""
      awk -F '\t' 'NR == FNR { if (FNR > 1) keep[$1] = 1; next } FNR == 1 || $2 >= cut || ($1 in keep)' cut="$cut" \
        "$dir/changes.tsv" "$dir/runs.tsv" > "$dir/runs.tsv.new" && _hist_replace "$dir/runs.tsv" ;;
  esac
}

# _hist_col TABLE COLUMN: the column's 1-based number.
_hist_col() {
  local i=0 c
  for c in ${SO_HIST_COLS[$1]}; do i=$((i + 1)); [ "$c" = "$2" ] && { echo "$i"; return 0; }; done
  return 1
}

# _hist_text_filter FILE AWK-CONDITION: keep the header and matching rows.
_hist_text_filter() {
  [ -f "$1" ] || return 0
  awk -F '\t' "FNR == 1 || ($2)" "$1" > "$1.new" && _hist_replace "$1"
}

_hist_replace() { chmod 0644 "$1.new" && mv -f -- "$1.new" "$1"; }

# hist_clear: --history-clear: delete this user's store.
hist_clear() {
  local dir t
  dir=$(hist_write_dir)
  if [ "$(hist_backend "$dir")" = none ]; then
    log_info "no history in $dir"
    return 0
  fi
  confirm "Delete the whole history in $dir (benchmarks and the record of changes; snapshots stay)?" || return 1
  rm -f -- "$dir/history.db" "$dir/history.db-journal"
  for t in $SO_HIST_TABLES; do rm -f -- "$dir/$t.tsv"; done
  log_ok "history deleted"
}

# hist_prune_main DAYS: --history-prune DAYS.
hist_prune_main() {
  local dir
  dir=$(hist_write_dir)
  [ "$(hist_backend "$dir")" != none ] || { log_info "no history in $dir"; return 0; }
  hist_prune "$dir" "$1"
  log_ok "history older than $1 day(s) pruned in $dir"
}

# ---------------------------------------------------------------------------
# What is recorded
# ---------------------------------------------------------------------------
# history_record_run MODE: after a real run that saved a snapshot, the run
# and its changes.
history_record_run() {
  local mode="$1" id epoch now line n=0 old
  local -a rows=()
  [ -n "$SO_SNAP" ] || return 0
  id=$(snap_id); epoch=$(epoch_now); now=$(iso_now)
  while IFS= read -r line; do
    n=$((n + 1))
    tsv_split "$line"
    old="${SO_F[2]}"
    case "${SO_F[0]}" in
      file) [ "$old" = absent ] || old=present ;;
      pkg) old=absent ;;
    esac
    rows+=("$id"$'\t'"$n"$'\t'"$epoch"$'\t'"${SO_F[5]:-$now}"$'\t'"${SO_F[3]:--}"$'\t'"${SO_F[0]}"$'\t'"${SO_F[1]}"$'\t'"${old:--}"$'\t'"${SO_F[4]:--}"$'\t-\t-')
  done < "$SO_SNAP/manifest"
  hist_add runs "$id"$'\t'"$epoch"$'\t'"$now"$'\t'"$mode"$'\t'"${SO_PROFILE:--}"$'\t'"$(snap_steps "$SO_SNAP")"$'\t'"${SO_COMMAND_LINE:-system-optimize}"$'\t'"${SO_RUN_RC:-0}"
  hist_add changes "${rows[@]}"
}

# history_record_undo: mark the changes SO_UNDO_DONE undid.
history_record_undo() {
  local item id n when epoch dir sql="" awkset=""
  [ ${#SO_UNDO_DONE[@]} -gt 0 ] || return 0
  hist_writable || return 0
  dir=$(hist_write_dir)
  [ "$(hist_backend "$dir")" != none ] || return 0
  epoch=$(epoch_now)
  for item in "${SO_UNDO_DONE[@]}"; do
    id="${item%%:*}"; item="${item#*:}"; n="${item%%:*}"; when="${item#*:}"
    sql+="UPDATE changes SET undone_epoch = '$epoch', undone_time = $(_hist_q "$when") WHERE snapshot = $(_hist_q "$id") AND line = '$n';"
    awkset+="$id:$n=$when "
  done
  case "$(hist_backend "$dir")" in
    sqlite) _hist_sql "$dir" "PRAGMA busy_timeout=5000; BEGIN;${sql}COMMIT;" >/dev/null ;;
    text)
      awk -F '\t' -v OFS='\t' -v set="$awkset" -v epoch="$epoch" '
        BEGIN { n = split(set, a, " "); for (i = 1; i <= n; i++) { k = a[i]; sub(/=.*/, "", k); v = a[i]; sub(/^[^=]*=/, "", v); u[k] = v } }
        FNR > 1 && (($1 ":" $2) in u) { $10 = epoch; $11 = u[$1 ":" $2] }
        { print }' "$dir/changes.tsv" > "$dir/changes.tsv.new" && _hist_replace "$dir/changes.tsv" ;;
  esac
}
