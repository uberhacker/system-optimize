#!/usr/bin/env bash
# lib/install/installer.sh - the component installer behind install.sh:
# Full or Custom, each part's readme, a summary before anything changes, and
# a manifest so that --uninstall takes back exactly what it did.
#
# Sourced by install.sh after its options are read; it uses install.sh's
# SRC, MODE, PREFIX, BIN_DIR, BUNDLE, SO_SUDO, SO_HOME, priv and die. It is
# not part of the single-file program.
#
# Components (the names --custom takes):
#   cli           the program and its bash completion (always installed)
#   STEP          one opt-in step, turned on in the config file (ENABLE=)
#   CATEGORY      every opt-in step of a category: power, memory, storage,
#                 network, display, boot, gpu, helpers
#   tray          the tray app, dashboard, root helper and polkit policy
#   extension     the GNOME Shell extension (GNOME only)
#   monitoring    Performance Co-Pilot for the tray's resource screens
#   agent         the local tuning agent, its model and its schedule
#   scx           sched_ext schedulers through scx_loader (the scheduler
#                 step with --install-tools; a COPR on Fedora)
#   pcp           Performance Co-Pilot, for the benchmark's metric windows
#   bpftune       BPF network auto-tuning (shown how to get it)
#   lact          LACT, the AMD GPU control daemon (shown how to get it)
# The tray, extension, monitoring and agent parts are installed by the tray
# app's own tray/install.sh, offered only when this checkout has it.
#
# The manifest (one "KIND<TAB>..." line per change, in the order made):
#   file PATH                   a file this installer copied
#   dir PATH                    a directory it created
#   config FILE KEY OLD         a KEY=value it set (OLD is "-" when unset)
#   userconf USER FILE KEY OLD  the same in a user's file
#   pkg MANAGER NAME            a package it installed
#   tray USER SCRIPT PARTS      tray/install.sh parts installed for USER
#   applied STEP,...            opt-in steps it applied with the program

INST_CATEGORIES=(power memory storage network display boot gpu helpers)
declare -gA INST_CAT_TITLE=(
  [power]="Power and CPU" [memory]="Memory" [storage]="Storage" [network]="Network"
  [display]="Display and fonts" [boot]="Boot and cleanup" [gpu]="GPU and AI" [helpers]="Tools"
)
INST_TRAY_PARTS=(tray extension monitoring agent)
INST_HELPER_PARTS=(scx pcp bpftune lact)
INST_AGENT_MODEL="${INST_AGENT_MODEL:-qwen3:4b}"
INST_AGENT_SCHEDULE="${INST_AGENT_SCHEDULE:-@daily}"
INST_AGENT_RAM_KB=$((6 * 1024 * 1024))      # the agent installer warns below 6 GB
INST_AGENT_DISK_KB=$((3584 * 1024))         # and below 3.5 GB free

INST_STEPS=()
declare -gA INST_KIND=() INST_CAT=() INST_TITLE=() INST_SUMMARY=() INST_FLAGS=()
declare -gA INST_PICK=()     # component -> 1
INST_EXCLUDED=()             # "name<TAB>why", left out of a full install
INST_APPLY="${INST_APPLY:-ask}"
INST_C_B="" INST_C_DIM="" INST_C_OK="" INST_C_WARN="" INST_C_HEAD="" INST_C_OFF=""

# --- output ------------------------------------------------------------------

inst_colors() {
  local want="${INST_COLOR:-auto}"
  # NO_COLOR turns off the automatic choice; --color=always still wins.
  [ -z "${NO_COLOR:-}" ] || [ "$want" != auto ] || want=never
  if [ "$want" = always ] || { [ "$want" = auto ] && [ -t 1 ] && [ "${TERM:-dumb}" != dumb ]; }; then
    INST_C_B=$'\e[1m' INST_C_DIM=$'\e[2m' INST_C_OK=$'\e[32m' INST_C_WARN=$'\e[33m'
    INST_C_HEAD=$'\e[1;36m' INST_C_OFF=$'\e[0m'
  fi
}

inst_head() { printf '\n%s%s%s\n' "$INST_C_HEAD" "$*" "$INST_C_OFF"; }
inst_ok() { printf '%s✓%s %s\n' "$INST_C_OK" "$INST_C_OFF" "$*"; }
inst_warn() { printf '%s!%s %s\n' "$INST_C_WARN" "$INST_C_OFF" "$*"; }
inst_dim() { printf '%s%s%s\n' "$INST_C_DIM" "$*" "$INST_C_OFF"; }
inst_dry() { printf '%swould%s %s\n' "$INST_C_WARN" "$INST_C_OFF" "$*"; }

# inst_wrap TEXT: the text wrapped to the terminal, indented two spaces.
inst_wrap() {
  local width="${COLUMNS:-80}"
  [ "$width" -ge 40 ] 2>/dev/null || width=80
  [ "$width" -le 100 ] || width=100
  printf '%s\n' "$1" | fold -s -w $((width - 4)) | sed 's/^/  /; s/ *$//'
}

# inst_ask PROMPT DEFAULT: y or n from the answer (DEFAULT on empty). "?"
# returns 2 so the caller can show more. End of input counts as DEFAULT.
inst_ask() {
  local prompt="$1" def="$2" ans hint="[y/N]"
  [ "$def" = y ] && hint="[Y/n]"
  while :; do
    printf '%s%s%s %s ' "$INST_C_B" "$prompt" "$INST_C_OFF" "$hint"
    if ! IFS= read -r ans; then echo; ans=""; fi
    case "${ans,,}" in
      "") [ "$def" = y ]; return ;;
      y|yes) return 0 ;;
      n|no) return 1 ;;
      "?"|more) return 2 ;;
      *) echo "  answer y or n (or ? for the full readme)" ;;
    esac
  done
}

# inst_read PROMPT DEFAULT: a line of text (DEFAULT on empty).
inst_read() {
  local ans
  printf '%s%s%s [%s] ' "$INST_C_B" "$1" "$INST_C_OFF" "$2"
  IFS= read -r ans || ans=""
  printf '%s\n' "${ans:-$2}"
}

# --- facts about the machine -------------------------------------------------

inst_os_name() {
  local f="${SO_INSTALL_OSRELEASE:-/etc/os-release}" n=""
  [ -r "$f" ] && n=$(sed -n 's/^PRETTY_NAME=//p' "$f" | head -n1 | tr -d '"')
  printf '%s\n' "${n:-Linux}"
}

inst_os_id() {
  local f="${SO_INSTALL_OSRELEASE:-/etc/os-release}" id="" like=""
  [ -r "$f" ] && { id=$(sed -n 's/^ID=//p' "$f" | tr -d '"'); like=$(sed -n 's/^ID_LIKE=//p' "$f" | tr -d '"'); }
  printf '%s %s\n' "$id" "$like"
}

inst_user() {
  if [ -n "${SO_DESKTOP_USER:-}" ]; then printf '%s\n' "$SO_DESKTOP_USER"
  elif [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then printf '%s\n' "$SUDO_USER"
  else id -un; fi
}

inst_user_home() {
  local u="$1" h
  if [ "$u" = "$(id -un)" ]; then printf '%s\n' "$SO_HOME"; return; fi
  h=$(getent passwd "$u" 2>/dev/null | cut -d: -f6)
  printf '%s\n' "${h:-/home/$u}"
}

inst_desktop() {
  local d="${SO_DESKTOP:-${XDG_CURRENT_DESKTOP:-}}"
  d="${d,,}"
  case "$d" in
    *gnome*|*ubuntu*|*pop*) echo gnome ;;
    *kde*|*plasma*) echo kde ;;
    ""|none) echo none ;;
    *) echo other ;;
  esac
}

inst_ram_kb() {
  local f="${SO_INSTALL_MEMINFO:-/proc/meminfo}"
  awk '/^MemTotal:/ { print $2; exit }' "$f" 2>/dev/null || echo 0
}

# inst_disk_kb: free space where the agent's model goes (the user's home).
inst_disk_kb() {
  [ -z "${SO_INSTALL_DISK_KB:-}" ] || { echo "$SO_INSTALL_DISK_KB"; return; }
  df -Pk "$(inst_user_home "$(inst_user)")" 2>/dev/null | awk 'NR == 2 { print $4 }'
}

inst_gib() { awk -v k="${1:-0}" 'BEGIN { printf "%.1f GiB", k / 1048576 }'; }

inst_pkg_manager() {
  local m
  for m in dnf apt-get zypper pacman; do
    command -v "$m" >/dev/null 2>&1 && { echo "$m"; return; }
  done
  echo none
}

# --- the step list and the readmes -------------------------------------------

# _json_field OBJ KEY: a string field of a flat JSON object, unescaped.
_json_field() {
  local re="\"$2\":\"((\\\\.|[^\"\\\\])*)\"" v
  [[ "$1" =~ $re ]] || return 1
  v="${BASH_REMATCH[1]}"
  v=${v//\\\"/\"}; v=${v//\\n/ }; v=${v//\\t/ }; v=${v//\\\\/\\}
  printf '%s\n' "$v"
}

# inst_load_steps: the steps from "system-optimize steps --json".
inst_load_steps() {
  local json obj name re='\{"name":[^{}]*\}' flags
  json=$(bash "$SRC/bin/system-optimize" steps --json 2>/dev/null) || die "could not read the step list from $SRC/bin/system-optimize"
  while [[ "$json" =~ $re ]]; do
    obj="${BASH_REMATCH[0]}"
    json="${json#*"$obj"}"
    name=$(_json_field "$obj" name) || continue
    INST_KIND[$name]=$(_json_field "$obj" kind) || continue   # a profile
    INST_STEPS+=("$name")
    INST_CAT[$name]=$(_json_field "$obj" category)
    INST_TITLE[$name]=$(_json_field "$obj" title)
    INST_SUMMARY[$name]=$(_json_field "$obj" summary)
    flags="${obj#*\"flags\":[}"; flags="${flags%%]*}"; flags="${flags//\"/}"
    INST_FLAGS[$name]="$flags"
  done
  [ ${#INST_STEPS[@]} -gt 0 ] || die "the step list from $SRC/bin/system-optimize is empty"
}

# inst_optin_in CATEGORY: the opt-in steps of a category, in run order.
inst_optin_in() {
  local s
  for s in "${INST_STEPS[@]}"; do
    [ "${INST_KIND[$s]}" = opt-in ] && [ "${INST_CAT[$s]}" = "$1" ] && printf '%s\n' "$s"
  done
  return 0
}

# md_section FILE HEADING [full]: the first paragraph under "## HEADING" or
# "### HEADING" (with "full", the whole section), markdown marks removed.
md_section() {
  local file="$1" head="$2" mode="${3:-first}"
  [ -r "$file" ] || return 1
  awk -v h="$head" -v mode="$mode" '
    $0 ~ /^###? / { t = $0; sub(/^#+ /, "", t)
      if (on) exit
      if (t == h) { on = 1; next } }
    on && mode == "first" && /^$/ && got { exit }
    on && /^$/ && !got { next }
    on { got = 1; print }
  ' "$file" | sed -e 's/\*\*//g' -e 's/`//g' -e 's/\[\([^]]*\)\]([^)]*)/\1/g'
}

# inst_readme NAME [full]: what a component does, from the docs.
inst_readme() {
  local n="$1" mode="${2:-first}" text="" readme="$SRC/tray/README.md"
  case "$n" in
    tray) text=$(awk 'NR > 1 && /^$/ && got { exit } NR > 1 && /^[^#|!]/ { got = 1; print }' "$readme" 2>/dev/null) ;;
    extension) text=$(grep -m1 '^| GNOME 4' "$readme" 2>/dev/null | awk -F'|' '{ print $3 }' | sed 's/\*\*//g; s/^ *//') ;;
    monitoring) text="" ;;   # the fallback says what tray/install.sh --monitoring does
    agent) text=$(md_section "$readme" "The tuning agent (optional)" "$mode") ;;
    scx) text=$(md_section "$SRC/docs/tools.md" "sched-ext/scx" "$mode") ;;
    pcp) text=$(md_section "$SRC/docs/tools.md" "Performance Co-Pilot (PCP)" "$mode") ;;
    bpftune) text=$(md_section "$SRC/docs/tools.md" "bpftune" "$mode") ;;
    lact) text=$(md_section "$SRC/docs/tools.md" "LACT" "$mode") ;;
    *) text=$(md_section "$SRC/docs/steps.md" "$n" "$mode") ;;
  esac
  [ -n "$text" ] || text=$(inst_fallback "$n")
  printf '%s\n' "$text"
}

inst_fallback() {
  case "$1" in
    tray) echo "A tray icon and dashboard: live CPU, memory, temperature and disk readings, a switch per step, and the benchmark against your baseline. Changes go through system-optimize behind a password prompt." ;;
    extension) echo "GNOME has no tray: this panel menu shows live readings, a switch per step, Apply all, Undo and profiles." ;;
    monitoring) echo "Performance Co-Pilot for the tray's resource screens: long history of CPU, memory, temperature and disk, and the AMD GPU where there is one. The tray's own minute averages need nothing installed." ;;
    agent) echo "A small local model (qwen3:4b through Ollama) looks at the status and benchmark history once a day and may suggest one change. It never applies anything itself." ;;
    scx) echo "sched_ext loads a CPU scheduler written in BPF (scx_bpfland, scx_lavd) through scx_loader. The scheduler step picks one; this installs the packages (a COPR on Fedora)." ;;
    pcp) echo "Performance Co-Pilot records system metrics. With it, --benchmark keeps a metrics window from before and after each run." ;;
    bpftune) echo "bpftune tunes network buffers from live traffic with BPF. When it runs, the sysctl step leaves the buffer keys to it." ;;
    lact) echo "LACT controls AMD GPU power, clocks and fans. When it runs, system-optimize leaves the GPU's power settings to it." ;;
    *) [ -n "${INST_SUMMARY[$1]:-}" ] && printf '%s\n' "${INST_SUMMARY[$1]}" ;;
  esac
}

inst_title() {
  case "$1" in
    tray) echo "Tray app and dashboard" ;;
    extension) echo "GNOME Shell extension" ;;
    monitoring) echo "Resource monitoring (Performance Co-Pilot)" ;;
    agent) echo "Local tuning agent ($INST_AGENT_MODEL)" ;;
    scx) echo "sched_ext schedulers (scx_loader)" ;;
    pcp) echo "Performance Co-Pilot" ;;
    bpftune) echo "bpftune network auto-tuning" ;;
    lact) echo "LACT, AMD GPU control" ;;
    *) printf '%s\n' "${INST_TITLE[$1]:-$1}" ;;
  esac
}

# inst_notes NAME: what to know before choosing it (reboot, repository, ...).
inst_notes() {
  local n="$1" f="${INST_FLAGS[$1]:-}" out=()
  [[ ",$f," == *,reboot,* ]] && out+=("needs a reboot")
  [[ ",$f," == *,desktop,* ]] && out+=("changes a desktop setting for $(inst_user)")
  case "$n" in
    scx) inst_is_fedora && out+=("adds a COPR repository") ;;
    lact|bpftune) out+=("shows how to get it; nothing is installed") ;;
    agent) out+=("downloads about 3 GB; needs about 3.5 GB of RAM while it runs") ;;
  esac
  [ ${#out[@]} -eq 0 ] && return 0
  local first="${out[0]}" o
  for o in "${out[@]:1}"; do first+="; $o"; done
  printf '%s\n' "$first"
}

inst_is_fedora() { [[ " $(inst_os_id) " == *" fedora "* ]]; }

# inst_full_why NAME: why a full install leaves NAME to you, or nothing.
inst_full_why() {
  local f="${INST_FLAGS[$1]:-}"
  [[ ",$f," == *,reboot,* ]] && { echo "needs a reboot"; return; }
  case "$1" in
    scx) inst_is_fedora && echo "adds a COPR repository" ;;
    agent)
      if [ "$(inst_ram_kb)" -lt "$INST_AGENT_RAM_KB" ]; then echo "this machine has $(inst_gib "$(inst_ram_kb)") of RAM (6 GB recommended)"
      elif [ "$(inst_disk_kb)" -lt "$INST_AGENT_DISK_KB" ]; then echo "only $(inst_gib "$(inst_disk_kb)") free for the model (3.5 GB needed)"
      fi ;;
  esac
  return 0
}

# inst_unavailable NAME: why NAME can't be installed here, or nothing.
inst_unavailable() {
  case "$1" in
    tray|extension|monitoring|agent)
      [ -f "$(inst_tray_script)" ] || { echo "this checkout has no tray directory yet; the tray app's pull request adds it"; return; } ;;
  esac
  case "$1" in
    extension) [ "$(inst_desktop)" = gnome ] || echo "for GNOME only (this desktop: $(inst_desktop))" ;;
  esac
  return 0
}

# --- choosing ----------------------------------------------------------------

# inst_all_names: every name --custom takes.
inst_all_names() {
  local s
  printf '%s\n' cli "${INST_CATEGORIES[@]}" "${INST_TRAY_PARTS[@]}" "${INST_HELPER_PARTS[@]}"
  for s in "${INST_STEPS[@]}"; do [ "${INST_KIND[$s]}" = opt-in ] && printf '%s\n' "$s"; done
  return 0
}

# inst_pick_list LIST: --custom LIST.
inst_pick_list() {
  local item s why bad=()
  local -a items
  IFS=', ' read -r -a items <<< "$1"
  for item in "${items[@]}"; do
    [ -n "$item" ] || continue
    if [ "$item" = cli ]; then continue
    elif [[ " ${INST_CATEGORIES[*]} " == *" $item "* ]]; then
      for s in $(inst_optin_in "$item"); do INST_PICK[$s]=1; done
    elif [ "${INST_KIND[$item]:-}" = opt-in ]; then INST_PICK[$item]=1
    elif [ -n "${INST_KIND[$item]:-}" ]; then die "$item is a default step: it always runs (system-optimize skip $item to leave it out)"
    elif [[ " ${INST_TRAY_PARTS[*]} ${INST_HELPER_PARTS[*]} " == *" $item "* ]]; then
      why=$(inst_unavailable "$item")
      [ -z "$why" ] || die "can't install $item: $why"
      INST_PICK[$item]=1
    else bad+=("$item"); fi
  done
  [ ${#bad[@]} -eq 0 ] || die "unknown component: ${bad[*]} (install.sh --list shows them)"
  # The tray's parts need the tray.
  if [ -n "${INST_PICK[monitoring]:-}${INST_PICK[agent]:-}${INST_PICK[extension]:-}" ] && [ -z "${INST_PICK[tray]:-}" ]; then
    INST_PICK[tray]=1
  fi
}

# inst_pick_full: everything that needs no reboot and no extra repository;
# the rest goes to INST_EXCLUDED.
inst_pick_full() {
  local n why
  for n in $(inst_all_names); do
    [ "$n" = cli ] && continue
    [[ " ${INST_CATEGORIES[*]} " == *" $n "* ]] && continue
    [ -z "$(inst_unavailable "$n")" ] || continue
    case "$n" in bpftune|lact) continue ;; esac   # nothing to install
    why=$(inst_full_why "$n")
    if [ -n "$why" ]; then INST_EXCLUDED+=("$n"$'\t'"$why"); continue; fi
    INST_PICK[$n]=1
  done
}

# inst_offer NAME: show NAME's readme and ask (Custom). 0 = chosen.
inst_offer() {
  local n="$1" notes rc
  printf '\n  %s%s%s %s(%s)%s\n' "$INST_C_B" "$(inst_title "$n")" "$INST_C_OFF" "$INST_C_DIM" "$n" "$INST_C_OFF"
  inst_wrap "$(inst_readme "$n")"
  notes=$(inst_notes "$n")
  [ -z "$notes" ] || printf '  %s%s%s\n' "$INST_C_WARN" "$notes" "$INST_C_OFF"
  local verb=Install
  [ -n "${INST_KIND[$n]:-}" ] && verb="Turn on"
  case "$n" in bpftune|lact) verb="Show how to get" ;; esac
  while :; do
    inst_ask "  $verb $n? (? for the full readme)" n; rc=$?
    [ "$rc" = 2 ] || return "$rc"
    inst_wrap "$(inst_readme "$n" full)"
  done
}

inst_custom_walk() {
  local c s n why steps
  inst_head "Tuning steps"
  inst_dim "Default steps always run. These are opt-in; each is turned on in the config file and undone with system-optimize disable STEP."
  for c in "${INST_CATEGORIES[@]}"; do
    steps=$(inst_optin_in "$c" | tr '\n' ' ')
    [ -n "$steps" ] || continue
    printf '\n%s%s%s: %s\n' "$INST_C_HEAD" "${INST_CAT_TITLE[$c]}" "$INST_C_OFF" "${steps% }"
    inst_ask "Go through $c?" y || continue
    for s in $steps; do inst_offer "$s" && INST_PICK[$s]=1; done
  done
  inst_head "Tray, monitoring and the agent"
  for n in "${INST_TRAY_PARTS[@]}"; do
    why=$(inst_unavailable "$n")
    if [ -n "$why" ]; then inst_dim "  $(inst_title "$n"): not offered, $why"; continue; fi
    if [ "$n" != tray ] && [ -z "${INST_PICK[tray]:-}" ]; then inst_dim "  $(inst_title "$n"): needs the tray"; continue; fi
    inst_offer "$n" && INST_PICK[$n]=1
  done
  if [ -n "${INST_PICK[agent]:-}" ]; then
    INST_AGENT_MODEL=$(inst_read "  Model for the agent" "$INST_AGENT_MODEL")
    INST_AGENT_SCHEDULE=$(inst_read "  When it runs (cron, @daily, off)" "$INST_AGENT_SCHEDULE")
  fi
  inst_head "Helper tools"
  for n in "${INST_HELPER_PARTS[@]}"; do inst_offer "$n" && INST_PICK[$n]=1; done
  return 0
}

inst_menu() {
  local ans n why
  inst_head "system-optimize installer"
  inst_dim "$(inst_os_name), desktop: $(inst_desktop), $(inst_gib "$(inst_ram_kb)") RAM, $(inst_gib "$(inst_disk_kb)") free in your home"
  printf '\n  %s1%s  Full    everything that needs no reboot or extra repository (you review the list first)\n' "$INST_C_B" "$INST_C_OFF"
  printf '  %s2%s  Custom  go through each part, read what it does, and choose\n' "$INST_C_B" "$INST_C_OFF"
  printf '  %sq%s  Quit\n\n' "$INST_C_B" "$INST_C_OFF"
  while :; do
    printf '%sChoice%s [1] ' "$INST_C_B" "$INST_C_OFF"
    IFS= read -r ans || ans=q
    case "${ans,,}" in
      ""|1|full) INST_SELECT=full; break ;;
      2|custom) INST_SELECT=custom; break ;;
      q|quit) echo "nothing installed"; exit 0 ;;
      *) echo "  1, 2 or q" ;;
    esac
  done
  if [ "$INST_SELECT" = full ]; then
    inst_pick_full
    if [ ${#INST_EXCLUDED[@]} -gt 0 ]; then
      inst_head "Left out of a full install"
      for n in "${INST_EXCLUDED[@]}"; do printf '  %s: %s\n' "${n%%$'\t'*}" "${n#*$'\t'}"; done
      for n in "${INST_EXCLUDED[@]}"; do
        inst_offer "${n%%$'\t'*}" && INST_PICK[${n%%$'\t'*}]=1
      done
    fi
  else
    inst_custom_walk
  fi
  return 0
}

# --- the plan ----------------------------------------------------------------

inst_picked_steps() {
  local s
  for s in "${INST_STEPS[@]}"; do [ -n "${INST_PICK[$s]:-}" ] && printf '%s\n' "$s"; done
  return 0
}

inst_summary() {
  local steps n
  steps=$(inst_picked_steps | paste -sd' ' -)
  inst_head "Summary"
  printf '  %-12s %s\n' "System:" "$(inst_os_name), desktop $(inst_desktop), $(inst_gib "$(inst_ram_kb)") RAM"
  printf '  %-12s %s\n' "Program:" "$BUNDLE (and bash completion)"
  printf '  %-12s %s\n' "Steps on:" "${steps:-none beyond the defaults}"
  [ -z "$steps" ] || printf '  %-12s %s\n' "" "ENABLE= in $(inst_config_file)"
  for n in "${INST_TRAY_PARTS[@]}" "${INST_HELPER_PARTS[@]}"; do
    [ -n "${INST_PICK[$n]:-}" ] || continue
    case "$n" in
      agent) printf '  %-12s %s\n' "agent:" "$INST_AGENT_MODEL, schedule $INST_AGENT_SCHEDULE, for $(inst_user)" ;;
      *) printf '  %-12s %s\n' "$n:" "$(inst_title "$n")" ;;
    esac
  done
  if [ "${INST_APPLY}" = 1 ] || { [ "$INST_APPLY" = ask ] && [ -n "$steps${INST_PICK[scx]:-}" ]; }; then
    printf '  %-12s %s\n' "Then:" "$( [ "$INST_APPLY" = 1 ] && echo "apply" || echo "ask whether to apply") the steps with system-optimize (undo: system-optimize undo)"
  fi
  printf '  %-12s %s\n' "Remove:" "./install.sh --uninstall takes all of this back"
  [ "${INST_DRY_RUN:-0}" != 1 ] || inst_dim "  (dry run: nothing will change)"
}

# --- recording ---------------------------------------------------------------

inst_manifest() {
  if [ -n "${SO_INSTALL_MANIFEST:-}" ]; then printf '%s\n' "$SO_INSTALL_MANIFEST"
  elif [ "$MODE" = user ]; then printf '%s\n' "${XDG_STATE_HOME:-$SO_HOME/.local/state}/system-optimize/installer.manifest"
  elif [ "$MODE" = prefix ]; then printf '%s\n' "$PREFIX/var/lib/system-optimize/installer.manifest"
  else printf '%s\n' /var/lib/system-optimize/installer.manifest; fi
}

inst_config_file() {
  if [ "$MODE" = user ]; then printf '%s\n' "${SO_CONFIG_FILE:-${XDG_CONFIG_HOME:-$SO_HOME/.config}/system-optimize/config}"
  else printf '%s\n' "${SO_SYSTEM_CONFIG:-/etc/system-optimize.conf}"; fi
}

inst_record() {
  local m; m=$(inst_manifest)
  [ "${INST_DRY_RUN:-0}" = 1 ] && return 0
  priv "$m" mkdir -p "$(dirname "$m")"
  printf '%s\n' "$(IFS=$'\t'; echo "$*")" | priv "$m" tee -a "$m" >/dev/null
}

# _conf_get FILE KEY: the value (exit 1 when unset).
_conf_get() {
  [ -r "$1" ] || return 1
  local line
  line=$(grep -E "^[[:space:]]*$2[[:space:]]*=" "$1" | tail -n1) || return 1
  line="${line#*=}"; line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
  [[ "$line" =~ ^\"(.*)\"$ ]] && line="${BASH_REMATCH[1]}"
  printf '%s\n' "$line"
}

# _conf_put FILE KEY VALUE [RUNAS]: set KEY=VALUE (VALUE "-" removes it).
_conf_put() {
  local file="$1" key="$2" value="$3" runas="${4:-}" tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/so-conf.XXXXXX")
  if [ -r "$file" ]; then grep -vE "^[[:space:]]*$key[[:space:]]*=" "$file" > "$tmp" || true; fi
  [ "$value" = - ] || printf '%s=%s\n' "$key" "$value" >> "$tmp"
  if [ -n "$runas" ] && [ "$runas" != "$(id -un)" ]; then
    inst_as_user "$runas" mkdir -p "$(dirname "$file")"
    inst_as_user "$runas" tee "$file" < "$tmp" >/dev/null
  else
    priv "$file" mkdir -p "$(dirname "$file")"
    priv "$file" cp "$tmp" "$file"
    priv "$file" chmod 0644 "$file"
  fi
  rm -f "$tmp"
}

# inst_set_config FILE KEY VALUE [USER]: set and record.
inst_set_config() {
  local file="$1" key="$2" value="$3" user="${4:-}" old
  old=$(_conf_get "$file" "$key") || old=-
  [ "$old" = "$value" ] && return 0
  if [ "${INST_DRY_RUN:-0}" = 1 ]; then inst_dry "set $key=$value in $file"; return 0; fi
  if [ -n "$user" ]; then inst_record userconf "$user" "$file" "$key" "${old:--}"
  else inst_record config "$file" "$key" "${old:--}"; fi
  _conf_put "$file" "$key" "$value" "$user"
  inst_ok "$key=$value in $file"
}

inst_as_user() {
  local u="$1"; shift
  if [ "$u" = "$(id -un)" ]; then "$@"
  elif [ "$(id -u)" -eq 0 ] && command -v runuser >/dev/null 2>&1; then runuser -u "$u" -- "$@"
  elif [ -n "$SO_SUDO" ]; then $SO_SUDO -u "$u" -- "$@"
  else die "can't run as $u"; fi
}

# --- doing -------------------------------------------------------------------

inst_do_steps() {
  local steps cur merged s file
  steps=$(inst_picked_steps | paste -sd, -)
  [ -n "$steps" ] || return 0
  file=$(inst_config_file)
  cur=$(_conf_get "$file" ENABLE) || cur=""
  merged="$cur"
  for s in ${steps//,/ }; do [[ ",$merged," == *",$s,"* ]] || merged="${merged:+$merged,}$s"; done
  inst_set_config "$file" ENABLE "$merged"
}

# inst_tray_script: the tray app's own installer in this checkout.
inst_tray_script() { printf '%s\n' "$SRC/tray/install.sh"; }

# inst_do_tray: the tray's parts, through tray/install.sh run as the desktop
# user (it uses sudo for the system parts; the extension, the agent's model
# and its schedule are per user). Choosing a part is the consent, so it runs
# with --yes; the summary showed what comes.
inst_do_tray() {
  local u script n parts=() args=()
  for n in "${INST_TRAY_PARTS[@]}"; do [ -n "${INST_PICK[$n]:-}" ] && parts+=("--$n"); done
  [ ${#parts[@]} -gt 0 ] || return 0
  u=$(inst_user)
  script=$(inst_tray_script)
  args=("${parts[@]}" --yes)
  [ -z "${INST_PICK[agent]:-}" ] || args+=(--model "$INST_AGENT_MODEL" --schedule "$INST_AGENT_SCHEDULE")
  if [ "${INST_DRY_RUN:-0}" = 1 ]; then
    inst_dry "run as $u: tray/install.sh ${args[*]}"
    return 0
  fi
  inst_record tray "$u" "$script" "$(IFS=,; echo "${parts[*]}")"
  if inst_as_user "$u" bash "$script" "${args[@]}"; then
    inst_ok "tray parts installed for $u: ${parts[*]//--/}"
  else
    inst_warn "the tray's installer did not finish; run it again: $script ${args[*]}"
  fi
  return 0
}

_pkg_installed() {
  case "$1" in
    dnf|zypper) rpm -q "$2" >/dev/null 2>&1 ;;
    apt-get) dpkg -s "$2" 2>/dev/null | grep -q '^Status: install ok installed' ;;
    pacman) pacman -Q "$2" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

inst_do_helpers() {
  local mgr pkg
  if [ -n "${INST_PICK[pcp]:-}" ] && [ -n "${INST_PICK[monitoring]:-}" ]; then
    inst_ok "pcp: installed with the tray's monitoring part"
  elif [ -n "${INST_PICK[pcp]:-}" ]; then
    mgr=$(inst_pkg_manager)
    case "$mgr" in dnf|apt-get) pkg=pcp-zeroconf ;; *) pkg="" ;; esac
    if [ -z "$pkg" ]; then
      inst_warn "pcp: install Performance Co-Pilot from your distribution's packages and enable pmcd (https://pcp.io)"
    elif _pkg_installed "$mgr" "$pkg"; then
      inst_ok "pcp: $pkg is already installed"
    elif [ "${INST_DRY_RUN:-0}" = 1 ]; then
      inst_dry "install $pkg with $mgr"
    else
      inst_record pkg "$mgr" "$pkg"
      case "$mgr" in
        dnf) priv "${SO_ROOT:-}/etc" dnf install -y "$pkg" ;;
        apt-get) priv "${SO_ROOT:-}/etc" env DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" ;;
      esac && inst_ok "pcp: installed $pkg (pmcd and pmlogger start with it)"
    fi
  fi
  [ -z "${INST_PICK[bpftune]:-}" ] || inst_dim "  bpftune: install it from your distribution or build it from https://github.com/oracle/bpftune, then: sudo systemctl enable --now bpftune"
  [ -z "${INST_PICK[lact]:-}" ] || inst_dim "  LACT: packages for each distribution are listed at https://github.com/ilya-zlobintsev/LACT; then: sudo systemctl enable --now lactd"
  return 0
}

# inst_program ARGS...: run the installed program as root.
inst_program() {
  local prog="${SO_INSTALL_PROGRAM:-$BUNDLE}"
  if [ "${INST_DRY_RUN:-0}" = 1 ]; then inst_dry "run: system-optimize $*"; return 0; fi
  priv "${SO_ROOT:-}/etc" "$prog" "$@"
}

inst_do_apply() {
  local steps go="$INST_APPLY"
  steps=$(inst_picked_steps | paste -sd, -)
  [ -n "$steps${INST_PICK[scx]:-}" ] || return 0
  if [ "$go" = ask ]; then
    if [ "${INST_INTERACTIVE:-0}" = 1 ]; then
      inst_ask "Apply the steps now? (the default steps too; undo with system-optimize undo)" y && go=1 || go=0
    else
      go=0
    fi
  fi
  if [ "$go" != 1 ]; then
    inst_dim "The steps run the next time you run: sudo system-optimize apply"
    return 0
  fi
  inst_head "Applying"
  if [ -n "$steps" ]; then
    inst_program apply --yes && inst_record applied "$steps"
  fi
  if [ -n "${INST_PICK[scx]:-}" ]; then
    inst_program apply scheduler --install-tools --yes && inst_record applied scheduler
  fi
  return 0
}

# inst_run: install.sh's "install" with components.
inst_run() {
  inst_colors
  inst_load_steps
  case "${INST_SELECT:-}" in
    full) inst_pick_full ;;
    custom) inst_pick_list "$INST_LIST" ;;
    menu) inst_menu ;;
  esac
  [ -z "${INST_PICK[scx]:-}" ] || INST_PICK[scheduler]=1
  inst_summary
  if [ "${INST_SELECT}" = full ] && [ ${#INST_EXCLUDED[@]} -gt 0 ] && [ "${INST_INTERACTIVE:-0}" != 1 ]; then
    local n
    inst_dim "  Left out (add them with --custom):"
    for n in "${INST_EXCLUDED[@]}"; do inst_dim "    ${n%%$'\t'*}: ${n#*$'\t'}"; done
  fi
  if [ "${INST_INTERACTIVE:-0}" = 1 ] && [ "${INST_YES:-0}" != 1 ]; then
    echo
    inst_ask "Go ahead?" y || { echo "nothing installed"; exit 0; }
  fi
  inst_head "Installing"
  if [ "${INST_DRY_RUN:-0}" = 1 ]; then
    inst_dry "install $BUNDLE and its completion"
  elif [ "$LAYOUT" = tree ]; then install_tree; else install_single; fi
  inst_do_steps
  inst_do_tray
  inst_do_helpers
  inst_do_apply
  echo
  if [ "${INST_DRY_RUN:-0}" = 1 ]; then inst_ok "dry run done: nothing changed"
  else inst_ok "done. See what runs: system-optimize status. Remove it all: ./install.sh --uninstall"; fi
}

# inst_list: --list.
inst_list() {
  local c s n why
  inst_colors
  inst_load_steps
  inst_head "Opt-in steps by category (--custom CATEGORY or STEP)"
  for c in "${INST_CATEGORIES[@]}"; do
    printf '  %s%-9s%s' "$INST_C_B" "$c" "$INST_C_OFF"
    inst_optin_in "$c" | paste -sd' ' -
    [ -n "$(inst_optin_in "$c")" ] || echo "(none)"
  done
  inst_head "Other parts"
  for n in "${INST_TRAY_PARTS[@]}" "${INST_HELPER_PARTS[@]}"; do
    why=$(inst_unavailable "$n")
    printf '  %s%-11s%s %s%s\n' "$INST_C_B" "$n" "$INST_C_OFF" "$(inst_title "$n")" "${why:+ (not here: $why)}"
  done
  echo
  echo "Full leaves out what needs a reboot or a COPR: $(for s in "${INST_STEPS[@]}"; do [[ ",${INST_FLAGS[$s]}," == *,reboot,* ]] && [ "${INST_KIND[$s]}" = opt-in ] && printf '%s ' "$s"; done)scx (on Fedora)"
}

# inst_uninstall: take back what the manifest lists, newest first.
inst_uninstall() {
  local m kind a b c d i
  local -a lines=() f
  inst_colors
  m=$(inst_manifest)
  [ -r "$m" ] || return 0
  mapfile -t lines < "$m"
  inst_head "Taking back what the installer did"
  for ((i = ${#lines[@]} - 1; i >= 0; i--)); do
    IFS=$'\t' read -r -a f <<< "${lines[i]}"
    kind="${f[0]-}"; a="${f[1]-}"; b="${f[2]-}"; c="${f[3]-}"; d="${f[4]-}"
    case "$kind" in
      applied)
        if [ -x "${SO_INSTALL_PROGRAM:-$BUNDLE}" ] || [ "${INST_DRY_RUN:-0}" = 1 ]; then
          # shellcheck disable=SC2086  # a list of step names
          inst_program disable ${a//,/ } --yes || inst_warn "system-optimize disable $a did not finish"
        fi ;;
      pkg)
        if [ "${INST_DRY_RUN:-0}" = 1 ]; then inst_dry "remove the package $b"; continue; fi
        case "$a" in
          dnf) priv "${SO_ROOT:-}/etc" dnf remove -y "$b" ;;
          apt-get) priv "${SO_ROOT:-}/etc" apt-get remove -y "$b" ;;
        esac && inst_ok "removed the package $b" ;;
      tray)
        # shellcheck disable=SC2086  # the parts, one word each
        if [ "${INST_DRY_RUN:-0}" = 1 ]; then inst_dry "run as $a: tray/install.sh --uninstall ${c//,/ } --yes"
        elif [ -f "$b" ]; then
          inst_as_user "$a" bash "$b" --uninstall ${c//,/ } --yes || inst_warn "the tray's parts were not all removed; run: $b --uninstall ${c//,/ }"
        else
          inst_warn "$b is gone, so the tray's parts stay; from a checkout run: tray/install.sh --uninstall ${c//,/ }"
        fi ;;
      file)
        if [ "${INST_DRY_RUN:-0}" = 1 ]; then inst_dry "remove $a"; continue; fi
        priv "${SO_ROOT:-}$a" rm -f -- "${SO_ROOT:-}$a" ;;
      dir)
        [ "${INST_DRY_RUN:-0}" = 1 ] && continue
        priv "${SO_ROOT:-}$a" rmdir -- "${SO_ROOT:-}$a" 2>/dev/null || true ;;
      config)
        if [ "${INST_DRY_RUN:-0}" = 1 ]; then inst_dry "put $b back in $a"; continue; fi
        _conf_put "$a" "$b" "$c" && inst_ok "put $b back in $a" ;;
      userconf)
        if [ "${INST_DRY_RUN:-0}" = 1 ]; then inst_dry "put $c back in $b"; continue; fi
        _conf_put "$b" "$c" "$d" "$a" && inst_ok "put $c back in $b" ;;
    esac
  done
  [ "${INST_DRY_RUN:-0}" = 1 ] || { priv "$m" rm -f -- "$m"; inst_ok "the tray, settings and tools the installer added are gone"; }
}
