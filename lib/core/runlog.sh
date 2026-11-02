#!/usr/bin/env bash
# lib/core/runlog.sh - the per-run log file.
#
# Every real or dry run of a command writes a log (unless LOGGING=0 /
# --no-log): a header describing the run, then every line the program
# prints, the verbose-only lines (commands, details), and the output, exit
# status and duration of every command run through the runners. Lines are
# timestamped and colour-free (log.sh's _log_file does the writing).
# SO_LOG_FILE is the open log's path; empty means no log.
#
# --help, --version and usage errors never open a log.
#
# Location: --log FILE, else LOG_DIR, else /var/log/system-optimize for
# root and ${XDG_STATE_HOME:-~/.local/state}/system-optimize for a user.
# Files are named YYYYmmdd-HHMMSS-<action>-PID.log, "latest.log" points at
# the newest, and only the newest LOG_KEEP (default 20, 0 = all) are kept.
# The directory is created 0700 and the files 0600: they show package
# lists, paths and the hostname.

# runlog_default_dir: where logs go when LOG_DIR is not set.
runlog_default_dir() {
  if is_root; then
    printf '%s/var/log/system-optimize\n' "$SO_ROOT"
  else
    printf '%s/system-optimize\n' "${XDG_STATE_HOME:-$SO_HOME/.local/state}"
  fi
}

# runlog_prune DIR KEEP: remove all but the newest KEEP logs in DIR. The
# names start with the timestamp, so the glob order is oldest first.
runlog_prune() {
  local dir="$1" keep="$2" n i
  local -a logs=()
  [ "$keep" -gt 0 ] 2>/dev/null || return 0
  for i in "$dir"/[0-9]*-*.log; do
    [ -f "$i" ] && logs+=("$i")
  done
  n=${#logs[@]}
  for ((i = 0; i < n - keep; i++)); do
    rm -f -- "${logs[i]}"
  done
}

# runlog_header ACTION ARGS...: what this run is (ACTION: apply, undo or
# self-update; ARGS: the command line).
runlog_header() {
  local action="$1"; shift
  [ -n "$SO_LOG_FILE" ] || return 0
  {
    printf '# %s\n' "$(version_string)"
    printf '# started  %(%Y-%m-%d %H:%M:%S %z)T\n' -1
    printf '# host     %s\n' "$(uname -n 2>/dev/null || echo unknown) ($(uname -sr 2>/dev/null) $(uname -m 2>/dev/null))"
    printf '# os       %s\n' "$(sysinfo_describe_os)"
    printf '# hardware %s\n' "$(sysinfo_describe_hw)"
    printf '# user     %s (uid %s)\n' "$SO_CUR_USER" "$SO_UID"
    printf '# command  system-optimize%s\n' "${*:+ $(so_quote "$@")}"
    printf '# action   %s\n' "$action"
    printf '# program  %s%s\n' "$SO_BIN" "$([ "$SO_BUNDLED" = 1 ] && printf ' (single file)')"
    printf '# mode     %s\n' "$([ "$SO_DRY_RUN" = 1 ] && printf 'dry run' || printf 'real run')"
    config_print_nondefault '# setting  '
    printf '\n'
  } >> "$SO_LOG_FILE"
}

# runlog_open ACTION ARGS...: open the run log (ACTION names the file).
# Never fatal: a log that cannot be written is a warning.
runlog_open() {
  local dir file
  if [ -n "$SO_LOG_PATH" ]; then
    file="$SO_LOG_PATH"
    dir=""
  else
    cfg_bool LOGGING || return 0
    dir=$(cfg LOG_DIR)
    [ -n "$dir" ] || dir=$(runlog_default_dir)
    if ! (umask 077; mkdir -p -- "$dir") 2>/dev/null; then
      log_warn "cannot create log directory $dir; this run is not logged (LOG_DIR or --no-log)"
      return 0
    fi
    file="$dir/$(printf '%(%Y%m%d-%H%M%S)T' -1)-${1:-run}-$$.log"
  fi
  if ! (umask 077; : >> "$file") 2>/dev/null; then
    log_warn "cannot write log file $file; this run is not logged"
    return 0
  fi
  SO_LOG_FILE="$file"
  runlog_header "$@"
  if [ -n "$dir" ]; then
    ln -sfn -- "${file##*/}" "$dir/latest.log" 2>/dev/null || true
    runlog_prune "$dir" "$(cfg LOG_KEEP)"
  fi
}

# runlog_close RC: final line with the exit status; no more is logged.
runlog_close() {
  [ -n "$SO_LOG_FILE" ] || return 0
  printf '\n# finished %(%Y-%m-%d %H:%M:%S %z)T, exit status %s, %ss\n' -1 "$1" "$SECONDS" >> "$SO_LOG_FILE"
  SO_LOG_FILE=""
}
