#!/usr/bin/env bash
# lib/core/json.sh - writing JSON from bash, for --json (see docs/json.md).
# Strings are escaped here; numbers are checked before they are written
# bare, so nothing read from the system can break the document.

# json_str TEXT: TEXT as a JSON string.
json_str() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\t'/\\t}
  s=${s//$'\r'/\\r}
  s=${s//[$'\001'-$'\037']/}
  printf '"%s"' "$s"
}

# json_str_or_null TEXT: a string, or null when TEXT is empty or "-".
json_str_or_null() {
  if [ -z "$1" ] || [ "$1" = - ]; then printf 'null'; else json_str "$1"; fi
}

# json_num TEXT: TEXT when it is a number, else null.
json_num() {
  if [[ "$1" =~ ^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then printf '%s' "$1"; else printf 'null'; fi
}

# json_bool VALUE: true for 1/true, false for 0/false, null otherwise.
json_bool() {
  case "$1" in
    1|true) printf 'true' ;;
    0|false) printf 'false' ;;
    *) printf 'null' ;;
  esac
}

# json_str_array WORDS...: ["a","b"].
json_str_array() {
  local w sep=""
  printf '['
  for w in "$@"; do printf '%s%s' "$sep" "$(json_str "$w")"; sep=","; done
  printf ']'
}

# json_word_array WORDS: an array of the words in WORDS (split on spaces,
# commas and newlines).
json_word_array() {
  local -a w=()
  local IFS=$', \t\n'
  read -r -d '' -a w <<< "$1" || true
  json_str_array "${w[@]+"${w[@]}"}"
}

# json_join ITEMS...: already-encoded values joined with commas.
json_join() {
  local IFS=,
  printf '%s' "$*"
}
