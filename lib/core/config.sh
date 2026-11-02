#!/usr/bin/env bash
# lib/core/config.sh - settings from config files, environment and flags.
#
# Precedence (lowest to highest):
#   built-in default < /etc/system-optimize.conf < user config < environment < flags
#
# Config files are simple KEY=value lines. They are parsed line by line and
# never sourced or eval'd, so a hostile value cannot run code. Unknown keys
# and malformed values are reported and ignored. See config.example.

SO_DEFAULT_REPO="https://github.com/uberhacker/system-optimize"

# Allowed keys with their default values and a validation class.
#   bool     1/0/yes/no/true/false/on/off
#   int      non-negative integer
#   url      https:// URL (file:// only when SYSTEM_OPTIMIZE_ALLOW_FILE_SOURCE=1)
#   color    auto|always|never
#   name     a git ref name
#   path     an absolute path (no "..", no spaces or shell metacharacters)
#   list     comma separated step names
#   enum:A|B one of the words A, B, ... (an empty word allows an empty value)
#   size     a size with an optional K, M or G suffix
declare -gA SO_CFG_DEFAULT=(
  [SELF_UPDATE_REPO]="$SO_DEFAULT_REPO"
  [SELF_UPDATE_BRANCH]=""
  [TIMEOUT]="300"
  [PKG_TIMEOUT]="1800"
  [DOWNLOAD_TIMEOUT]="300"
  [ONLY]=""
  [SKIP]=""
  [INSTALL_TOOLS]="0"
  [FORCE]="0"
  [SNAPSHOT_DIR]=""
  [COLOR]="auto"
  [LOGGING]="1"
  [LOG_DIR]=""
  [LOG_KEEP]="20"
  [ENABLE]=""
  [PROFILE]=""
  [BACKEND]="auto"
  [BENCHMARK]="0"
  [BENCH_SECONDS]="5"
  [BENCH_THRESHOLD]="3"
  [SAFE_APPLY]="0"
  [SAFE_APPLY_TIMEOUT]="300"
  [HISTORY]="1"
  [HISTORY_DIR]=""
  [HISTORY_KEEP_DAYS]="180"
  [TUNE_STEPS]="sysctl,io,cpu,noatime,btrfs,thp,mglru,scheduler"
  [ATIME]="noatime"
  [JOURNAL_MAX]="500M"
  [CHARGE_LIMIT]="80"
  [GPU_MEM_GIB]="0"
  [FONT_HINTING]="slight"
  [FONT_SUBPIXEL]="rgb"
  [PARALLEL_DOWNLOADS]="10"
  [SCHEDULER]="auto"
  [MGLRU_TTL_MS]="1000"
  [THP_MODE]="madvise"
  [BENCH_LLM_MODEL]=""
  [BENCH_PCP]="1"
)
declare -gA SO_CFG_TYPE=(
  [SELF_UPDATE_REPO]=url
  [SELF_UPDATE_BRANCH]=name
  [TIMEOUT]=int
  [PKG_TIMEOUT]=int
  [DOWNLOAD_TIMEOUT]=int
  [ONLY]=list
  [SKIP]=list
  [INSTALL_TOOLS]=bool
  [FORCE]=bool
  [SNAPSHOT_DIR]=path
  [COLOR]=color
  [LOGGING]=bool
  [LOG_DIR]=path
  [LOG_KEEP]=int
  [ENABLE]=list
  [PROFILE]="enum:|dev|gaming|battery|llm"
  [BACKEND]="enum:auto|files|tuned"
  [BENCHMARK]=bool
  [BENCH_SECONDS]=int
  [BENCH_THRESHOLD]=int
  [SAFE_APPLY]=bool
  [SAFE_APPLY_TIMEOUT]=int
  [HISTORY]=bool
  [HISTORY_DIR]=path
  [HISTORY_KEEP_DAYS]=int
  [TUNE_STEPS]=list
  [ATIME]="enum:noatime|lazytime"
  [JOURNAL_MAX]=size
  [CHARGE_LIMIT]=int
  [GPU_MEM_GIB]=int
  [FONT_HINTING]="enum:none|slight|medium|full"
  [FONT_SUBPIXEL]="enum:none|rgb|bgr|vrgb|vbgr"
  [PARALLEL_DOWNLOADS]=int
  [SCHEDULER]="enum:auto|bpfland|lavd|flash|cosmos|rusty"
  [MGLRU_TTL_MS]=int
  [THP_MODE]="enum:madvise|always|never|keep"
  [BENCH_LLM_MODEL]=path
  [BENCH_PCP]=bool
)
# No older names yet: Ed's 1.x script had no configuration.
declare -gA SO_CFG_ALIAS=()
declare -gA SO_CFG=()        # effective values
declare -gA SO_CFG_SOURCE=() # where each value came from (for --list and the log)

config_user_file() {
  printf '%s/system-optimize/config\n' "${XDG_CONFIG_HOME:-${SO_HOME:-$HOME}/.config}"
}

config_system_file() {
  printf '%s\n' "${SO_SYSTEM_CONFIG:-${SO_ROOT:-}/etc/system-optimize.conf}"
}

# config_valid TYPE VALUE: validation per class.
config_valid() {
  local type="$1" value="$2"
  # No control characters anywhere.
  [[ "$value" =~ [[:cntrl:]] ]] && return 1
  case "$type" in
    bool) [[ "${value,,}" =~ ^(1|0|yes|no|true|false|on|off|y|n)$ ]] ;;
    int) [[ "$value" =~ ^[0-9]{1,9}$ ]] ;;
    url)
      if [[ "$value" =~ ^https://[A-Za-z0-9._~:/?#@!$\&\'()*+,\;=%-]+$ ]]; then
        return 0
      fi
      if [ "${SYSTEM_OPTIMIZE_ALLOW_FILE_SOURCE:-0}" = 1 ] && [[ "$value" =~ ^file:///[A-Za-z0-9._/-]+$ ]]; then
        return 0
      fi
      return 1 ;;
    color) [[ "$value" =~ ^(auto|always|never)$ ]] ;;
    name) [[ "$value" =~ ^[A-Za-z0-9_./-]*$ ]] && [[ "$value" != *..* ]] && [[ "$value" != -* ]] ;;
    path) [ -z "$value" ] || { [[ "$value" =~ ^/[A-Za-z0-9_.@+/-]*$ ]] && [[ "$value" != *..* ]]; } ;;
    list) [[ "$value" =~ ^[a-z0-9,-]*$ ]] ;;
    enum:*) [[ "|${type#enum:}|" == *"|$value|"* ]] ;;
    size) [[ "$value" =~ ^[0-9]{1,6}[KMG]?$ ]] ;;
    *) return 1 ;;
  esac
}

# config_normalize TYPE VALUE: canonical form (bools become 1/0).
config_normalize() {
  local type="$1" value="$2"
  case "$type" in
    bool) if bool "$value"; then echo 1; else echo 0; fi ;;
    url) printf '%s\n' "${value%/}" ;;
    *) printf '%s\n' "$value" ;;
  esac
}

# config_set KEY VALUE SOURCE: validate and store.
config_set() {
  local key="$1" value="$2" src="$3" type
  type="${SO_CFG_TYPE[$key]:-}"
  if [ -z "$type" ]; then
    log_warn "config: unknown key '$key' ($src) ignored"
    return 1
  fi
  if ! config_valid "$type" "$value"; then
    log_warn "config: invalid value for $key ($src) ignored"
    return 1
  fi
  SO_CFG[$key]=$(config_normalize "$type" "$value")
  SO_CFG_SOURCE[$key]="$src"
  return 0
}

# config_parse_file FILE: read KEY=value lines.
config_parse_file() {
  local file="$1" line key value lineno=0
  [ -r "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    # Trim surrounding whitespace.
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue
    [[ "$line" == \#* ]] && continue
    if ! [[ "$line" =~ ^([A-Z][A-Z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      log_warn "config: $file:$lineno: not a KEY=value line, ignored"
      continue
    fi
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    # Strip one layer of matching quotes.
    if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then
      value="${BASH_REMATCH[1]}"
    fi
    config_set "$key" "$value" "$file:$lineno" || true
  done < "$file"
}

# config_load: defaults, system file, user file (or --config FILE),
# environment (older SO_* names included), in that order.
config_load() {
  local key alias
  for key in "${!SO_CFG_DEFAULT[@]}"; do
    SO_CFG[$key]="${SO_CFG_DEFAULT[$key]}"
    SO_CFG_SOURCE[$key]="default"
  done
  config_parse_file "$(config_system_file)"
  if [ -n "${SO_CONFIG_FILE:-}" ]; then
    if [ -r "$SO_CONFIG_FILE" ]; then
      config_parse_file "$SO_CONFIG_FILE"
    else
      log_warn "config file not readable: $SO_CONFIG_FILE"
    fi
  else
    config_parse_file "$(config_user_file)"
  fi
  # Older environment names first, so that the current names win.
  for alias in "${!SO_CFG_ALIAS[@]}"; do
    key="${SO_CFG_ALIAS[$alias]}"
    if config_in_env "$alias" && ! config_in_env "$key"; then
      config_set "$key" "${!alias}" "env $alias" || true
    fi
  done
  for key in "${!SO_CFG_DEFAULT[@]}"; do
    if config_in_env "$key"; then
      config_set "$key" "${!key}" "env" || true
    fi
  done
}

# config_in_env NAME: NAME came from the environment (exported) and is not
# empty. The program's own defaults (SO_TIMEOUT, ...) are plain shell
# variables and do not count.
config_in_env() {
  local d
  d=$(declare -p "$1" 2>/dev/null) || return 1
  [[ "$d" == "declare -x"* ]] && [ -n "${!1:-}" ]
}

# cfg KEY: print the effective value.
cfg() { printf '%s\n' "${SO_CFG[$1]-}"; }

# cfg_bool KEY: true when the effective value is on.
cfg_bool() { bool "${SO_CFG[$1]-0}"; }

# config_print_nondefault PREFIX: one "PREFIX KEY=value (source)" line per
# setting that is not at its default (for the log header and --list).
config_print_nondefault() {
  local prefix="$1" key
  for key in $(printf '%s\n' "${!SO_CFG[@]}" | sort); do
    [ "${SO_CFG_SOURCE[$key]}" = default ] && continue
    printf '%s%s=%s (%s)\n' "$prefix" "$key" "${SO_CFG[$key]}" "${SO_CFG_SOURCE[$key]}"
  done
}
