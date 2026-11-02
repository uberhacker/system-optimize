#!/usr/bin/env bash
# lib/core/steps.sh - the step registry, the opt-in steps and the profiles.
#
# Every step module registers itself when it is loaded:
#
#   step_def NAME KIND FUNC FLAGS TITLE SUMMARY CATEGORY
#
#   KIND     default   runs on every run unless --skip leaves it out
#            opt-in    runs only when chosen: --enable, ENABLE=, a profile
#                      (--profile, PROFILE=) or --only
#   FLAGS    comma separated, may be empty:
#            reboot    takes full effect only after a reboot
#            report    reports only; changes nothing
#            bench     its effect shows in --benchmark (--tune tries it)
#            desktop   changes the desktop user's settings
#   CATEGORY one of SO_CATEGORIES, for grouping (--list-steps, the tray)
#
# The modules are loaded in run order, so SO_STEPS is the run order. A
# profile is a named set of opt-in steps for one kind of use.

declare -gA SO_STEP_KIND=() SO_STEP_FUNC=() SO_STEP_FLAGS=() SO_STEP_TITLE=() SO_STEP_SUMMARY=()
declare -gA SO_STEP_CATEGORY=()
SO_STEPS=()

# The categories, in display order, and their titles.
SO_CATEGORIES=(power memory storage network display boot gpu helpers)
declare -gA SO_CATEGORY_TITLE=(
  [power]="Power and CPU"
  [memory]="Memory"
  [storage]="Storage"
  [network]="Network"
  [display]="Display and fonts"
  [boot]="Boot and cleanup"
  [gpu]="GPU and AI"
  [helpers]="Tools"
)

# The profiles: their opt-in steps and a title.
SO_PROFILES=(dev gaming battery llm)
declare -gA SO_PROFILE_STEPS=(
  [dev]="pkgmgr ccache plocate indexer noatime journal dns mglru"
  [gaming]="scheduler responsive display wifi mglru"
  [battery]="charge powerswitch wifi journal noatime"
  [llm]="gpu-memory thp mglru rocm"
)
declare -gA SO_PROFILE_TITLE=(
  [dev]="Developer workstation: faster package downloads, compiler cache, quicker search, fewer disk writes"
  [gaming]="Gaming: a sched_ext scheduler, GameMode, variable and high refresh, no Wi-Fi power saving on mains"
  [battery]="Laptop on battery: an 80 % charge limit, power profile by power source, fewer disk writes"
  [llm]="Local LLMs: more GPU-addressable memory on AMD APUs, THP for model weights, ROCm (needs a reboot)"
)

SO_ENABLE=""    # the opt-in steps chosen for this run (ENABLE, --enable, the profile)
SO_PROFILE=""   # the profile chosen for this run

# step_def NAME KIND FUNC FLAGS TITLE SUMMARY CATEGORY: register a step.
step_def() {
  SO_STEP_CATEGORY[$1]="${7:-helpers}"
  SO_STEPS+=("$1")
  SO_STEP_KIND[$1]="$2"
  SO_STEP_FUNC[$1]="$3"
  SO_STEP_FLAGS[$1]="$4"
  SO_STEP_TITLE[$1]="$5"
  SO_STEP_SUMMARY[$1]="$6"
}

# step_exists NAME
step_exists() { [ -n "${SO_STEP_KIND[$1]-}" ]; }

# step_has_flag NAME FLAG
step_has_flag() { list_has "${SO_STEP_FLAGS[$1]-}" "$2"; }

# steps_of_kind KIND: the names, in run order.
steps_of_kind() {
  local s
  for s in "${SO_STEPS[@]}"; do
    [ "${SO_STEP_KIND[$s]}" = "$1" ] && printf '%s\n' "$s"
  done
  return 0
}

# profile_exists NAME
profile_exists() { [ -n "${SO_PROFILE_STEPS[$1]-}" ]; }

# steps_resolve_enable: SO_ENABLE from ENABLE, --enable and the profile.
steps_resolve_enable() {
  local list s out=""
  SO_PROFILE=$(cfg PROFILE)
  list="$(cfg ENABLE) ${SO_ARG_ENABLE:-}"
  [ -z "$SO_PROFILE" ] || list+=" ${SO_PROFILE_STEPS[$SO_PROFILE]}"
  for s in ${list//,/ }; do
    list_has "$out" "$s" || out+="${out:+ }$s"
  done
  SO_ENABLE="$out"
}

# step_enabled NAME: does this run include NAME? --skip always wins; --only
# runs exactly the steps it names (opt-in ones too); otherwise the default
# steps run and the opt-in steps run when chosen. Anything that is not a
# step (undo, the benchmark) always runs.
step_enabled() {
  local name="$1"
  step_exists "$name" || return 0
  if [ -n "$SO_SKIP" ] && list_has "$SO_SKIP" "$name"; then
    return 1
  fi
  if [ -n "$SO_ONLY" ]; then
    list_has "$SO_ONLY" "$name"
    return
  fi
  [ "${SO_STEP_KIND[$name]}" = default ] && return 0
  list_has "$SO_ENABLE" "$name"
}

# steps_selected: the steps of this run, space separated, in run order.
steps_selected() {
  local s out=""
  for s in "${SO_STEPS[@]}"; do
    step_enabled "$s" && out+="${out:+ }$s"
  done
  printf '%s\n' "$out"
}

# steps_check_list LIST: every name in LIST is a step.
steps_check_list() {
  local name
  for name in ${1//,/ }; do
    if ! step_exists "$name"; then
      log_error "unknown step: $name (steps: $(join_by ', ' "${SO_STEPS[@]}"))"
      return 1
    fi
  done
}
