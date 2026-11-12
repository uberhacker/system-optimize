#!/usr/bin/env bash
# lib/tweaks/scheduler.sh - opt-in steps "scheduler" and "responsive" (new
# in 2.1).
#
# scheduler: runs a sched_ext CPU scheduler (BPF, loaded at run time)
# through scx_loader, a small D-Bus service that starts one at boot from
# /etc/scx_loader/config.toml. The step writes that file with the two keys
# scx_loader documents at the top level, default_sched and default_mode:
#   SCHEDULER=auto   scx_lavd on a battery-powered machine (it has a power
#                    saving side), scx_bpfland otherwise (interactive work,
#                    games)
#   SCHEDULER=NAME   scx_NAME (bpfland, lavd, flash, cosmos, rusty)
#   default_mode     "Gaming" with the gaming profile, "Auto" otherwise
# then enables and starts scx_loader.service. If the scheduler stops or
# crashes, the kernel falls back to its own scheduler (EEVDF) by itself.
# It needs systemd and a kernel built with sched_ext (Linux 6.12 or later
# with CONFIG_SCHED_CLASS_EXT; Fedora, Arch, Ubuntu 25.04+ and CachyOS
# kernels have it).
# Packages:
#   Arch (and CachyOS, Manjaro, ...)  scx-scheds and scx-tools (scx_loader)
#                                     from the official repositories
#   Fedora                            only from the COPR
#                                     bieszczaders/kernel-cachyos-addons
#                                     (scx-scheds, scx-tools; scx-scheds may
#                                     pull in scx-tools-git instead, which
#                                     is used as it is), and only with
#                                     INSTALL_TOOLS on. The step writes the
#                                     repository file itself under a name
#                                     --undo accepts, rather than through
#                                     `dnf copr enable`, whose file name
#                                     has colons in it
#   elsewhere                         scx-scheds and scx-tools when the
#                                     distribution's repositories have them;
#                                     otherwise the step says what to install
# Conflict: ananicy-cpp can stall sched_ext schedulers (CachyOS sched-ext
# guide). sched_ext is the default here: when ananicy-cpp runs, the step
# warns and says how to stop it, and leaves it running.
# Undo: the config file is restored (or removed), scx_loader.service goes
# back to its state before (disabling it stops the scheduler), and the
# packages and the repository file this run added are removed.
#
# responsive: three helpers that keep a desktop responsive under load.
#   uresourced    gives the active graphical user's session more CPU, memory
#                 and I/O weight (Fedora; systemd only); uresourced.service
#                 is enabled and started
#   GameMode      a user D-Bus service games ask for better scheduling and
#                 power settings while they run (gamemoderun); installed only,
#                 it starts on demand
#   ananicy-cpp   renices processes by rules; offered only when no sched_ext
#                 scheduler runs and the scheduler step is not part of this
#                 run (see the conflict above); ananicy-cpp.service is
#                 enabled and started
# Each part installs from the distribution's own repositories and skips on
# its own when they do not have the package. On OpenRC and runit a service
# is enabled with svc_set where the package ships one.
# Undo: the services go back to their state before; the packages this run
# installed are removed.

step_def scheduler opt-in scheduler_step 'bench' \
  "sched_ext CPU scheduler (scx_loader)" \
  "Runs a sched_ext scheduler through scx_loader: bpfland on desktops, lavd on laptops. The kernel scheduler takes over if it stops." \
  power

SO_SCX_CONFIG=/etc/scx_loader/config.toml
SO_SCX_UNIT=scx_loader.service
SO_SCX_COPR=bieszczaders/kernel-cachyos-addons
SO_SCX_COPR_REPO=/etc/yum.repos.d/system-optimize-kernel-cachyos-addons.repo
SO_SCX_PACKAGES="scx-scheds scx-tools"

# scheduler_pkg_available NAME: see pkg_available.
scheduler_pkg_available() { pkg_available "$1"; }

# scheduler_name: the scx_* binary to run.
scheduler_name() {
  local want
  want=$(cfg SCHEDULER)
  case "${want:-auto}" in
    auto) if [ "$SO_IS_PORTABLE" = 1 ]; then echo scx_lavd; else echo scx_bpfland; fi ;;
    *) printf 'scx_%s\n' "$want" ;;
  esac
}

# scheduler_mode: scx_loader's default_mode.
scheduler_mode() {
  if [ "${SO_PROFILE:-}" = gaming ]; then echo Gaming; else echo Auto; fi
}

scheduler_config_content() {
  cat <<EOF
# Written by system-optimize ($(version_string)). Undo: system-optimize --undo
# The sched_ext scheduler scx_loader starts at boot, and its mode (Auto,
# Gaming, LowLatency, PowerSave or Server). Switch for this boot only with
# scxctl switch --sched NAME --mode MODE; stop it with scxctl stop.
default_sched = "$1"
default_mode = "$2"
EOF
}

# _scheduler_is_fedora: Fedora itself (or a spin), not the RHEL family,
# whose COPR chroots are EPEL ones.
_scheduler_is_fedora() {
  [ "$SO_PKG_MANAGER" = dnf ] || return 1
  list_has "rhel centos rocky almalinux ol eurolinux circle scientific amzn" "$SO_OS_ID" && return 1
  os_is_like fedora
}

# _scheduler_copr_present: a repository file already points at the COPR.
_scheduler_copr_present() {
  local d
  d=$(so_path /etc/yum.repos.d)
  [ -d "$d" ] || return 1
  grep -lqs 'kernel-cachyos-addons' "$d"/*.repo 2>/dev/null
}

scheduler_copr_content() {
  local owner="${SO_SCX_COPR%%/*}" project="${SO_SCX_COPR#*/}"
  cat <<EOF
# Written by system-optimize ($(version_string)) for the scheduler step.
# Undo: system-optimize --undo (removes this repository)
[copr:copr.fedorainfracloud.org:$owner:$project]
name=Copr repo for $project owned by $owner
baseurl=https://download.copr.fedorainfracloud.org/results/$owner/$project/fedora-\$releasever-\$basearch/
type=rpm-md
skip_if_unavailable=True
gpgcheck=1
gpgkey=https://download.copr.fedorainfracloud.org/results/$owner/$project/pubkey.gpg
repo_gpgcheck=0
enabled=1
enabled_metadata=1
EOF
}

# _scheduler_install: install scx_loader and the schedulers. Sets
# SCHED_NOTE; returns 0 when installed (or would be), 2 when the step
# should skip (SCHED_NOTE says why), 1 on failure.
_scheduler_install() {
  local p rc=0 avail=""
  SCHED_NOTE=""
  if ! pkg_can_install; then
    SCHED_NOTE="scx_loader is not installed: $(pkg_hand_hint scx-scheds) (with scx_loader)"
    return 2
  fi
  if _scheduler_is_fedora; then
    if ! _scheduler_copr_present; then
      if ! cfg_bool INSTALL_TOOLS; then
        SCHED_NOTE="scx_loader comes from the COPR $SO_SCX_COPR on Fedora; run with --install-tools to add it, or install scx-scheds and scx-tools yourself"
        return 2
      fi
      install_file "$SO_SCX_COPR_REPO" 0644 < <(scheduler_copr_content) || rc=$?
      if [ "$rc" != 0 ] && [ "$rc" != 3 ]; then
        SCHED_NOTE="could not add the COPR repository $SO_SCX_COPR_REPO"
        return 1
      fi
      SCHED_NOTE="added the COPR $SO_SCX_COPR"
    fi
    avail="$SO_SCX_PACKAGES"
  else
    for p in $SO_SCX_PACKAGES; do
      scheduler_pkg_available "$p" && avail+="${avail:+ }$p"
    done
    if ! list_has "$avail" scx-tools; then
      SCHED_NOTE="scx_loader is not in this distribution's repositories (packages scx-scheds and scx-tools); install it from the sched_ext project to use this step"
      return 2
    fi
  fi
  for p in $avail; do
    _scheduler_pkg_satisfied "$p" && continue
    pkg_add "$p" || { SCHED_NOTE="could not install $p"; return 1; }
  done
  return 0
}

# _scheduler_pkg_satisfied NAME: NAME, or a package that stands in for it,
# is installed. The COPR's scx-scheds pulls in scx-tools-git, which
# conflicts with scx-tools and gives the same scx_loader, so installing
# scx-tools after it fails.
_scheduler_pkg_satisfied() {
  pkg_installed "$1" && return 0
  case "$1" in
    scx-tools)
      pkg_installed scx-tools-git || has_cmd scx_loader ;;
    *) return 1 ;;
  esac
}

# _scheduler_ananicy_warning: the warning when ananicy-cpp runs too.
_scheduler_ananicy_warning() {
  if [ "$SO_INIT_SYSTEM" = systemd ]; then
    printf 'ananicy-cpp runs and can stall sched_ext schedulers; stop it with: sudo systemctl disable --now ananicy-cpp'
  else
    printf 'ananicy-cpp runs and can stall sched_ext schedulers; stop and disable its service'
  fi
}

scheduler_step() {
  local sched mode state rc=0 installed=0 changed=0 enabled note=""
  if [ "$SO_IN_CONTAINER" = 1 ]; then
    step_skip "container: the host's kernel schedules the CPUs"
    return 0
  fi
  if [ "$SO_INIT_SYSTEM" != systemd ]; then
    step_skip "scx_loader needs systemd; $(init_no_systemd_note)"
    return 0
  fi
  state=$(scx_state)
  if [ "$state" = absent ]; then
    step_skip "this kernel has no sched_ext (it needs Linux 6.12 or later built with CONFIG_SCHED_CLASS_EXT)"
    return 0
  fi
  if [ "$(unit_enabled_state scx.service)" = enabled ]; then
    step_skip "scx.service (the older sched_ext service) is enabled; disable it first, since it and scx_loader must not both run"
    return 0
  fi
  sched=$(scheduler_name)
  mode=$(scheduler_mode)

  if ! unit_exists "$SO_SCX_UNIT"; then
    _scheduler_install || rc=$?
    case "$rc" in
      0) installed=1; note="$SCHED_NOTE" ;;
      2) step_skip "$SCHED_NOTE"; return 0 ;;
      *) step_fail "$SCHED_NOTE"; return 1 ;;
    esac
    rc=0
  fi
  if [ "$SO_DRY_RUN" != 1 ] && ! has_cmd "$sched"; then
    step_fail "$sched is not installed (scx_loader has no such scheduler here); choose another with --scheduler"
    return 1
  fi

  install_file "$SO_SCX_CONFIG" 0644 < <(scheduler_config_content "$sched" "$mode") || rc=$?
  case "$rc" in
    0) changed=1 ;;
    3) ;;
    *) step_fail "could not write $SO_SCX_CONFIG"; return 1 ;;
  esac

  enabled=$(unit_enabled_state "$SO_SCX_UNIT")
  if [ "$enabled" != enabled ]; then
    unit_set "$SO_SCX_UNIT" enable || { step_fail "could not enable $SO_SCX_UNIT"; return 1; }
    changed=1
  elif [ "$changed" = 1 ]; then
    # Already running: it reads its configuration when it starts.
    do_run systemctl restart "$SO_SCX_UNIT" || { step_fail "could not restart $SO_SCX_UNIT"; return 1; }
  fi

  if ananicy_running; then
    if [ "$SO_DRY_RUN" = 1 ] && [ "$changed" = 1 ]; then
      step_dry "would run $sched in $mode mode through scx_loader; $(_scheduler_ananicy_warning)"
    else
      step_warn "$sched in $mode mode through scx_loader; $(_scheduler_ananicy_warning)"
    fi
    return 0
  fi
  if [ "$changed" = 0 ] && [ "$installed" = 0 ]; then
    step_ok "$sched already runs in $mode mode through scx_loader"
  elif [ "$SO_DRY_RUN" = 1 ]; then
    step_dry "would run $sched in $mode mode through scx_loader${note:+ ($note)}"
  else
    step_updated "$sched in $mode mode through scx_loader${note:+ ($note)}; the kernel scheduler takes over if it stops"
  fi
}

step_def responsive opt-in responsive_step '' \
  "Responsiveness helpers: uresourced, GameMode, ananicy-cpp" \
  "Turns on uresourced and GameMode where packaged; ananicy-cpp only when no sched_ext scheduler runs or is set up in this run." \
  power

# responsive_ananicy_allowed: the owner's rule: ananicy-cpp only when no
# sched_ext scheduler runs and the scheduler step is not in this run.
responsive_ananicy_allowed() {
  scx_running && return 1
  # The scheduler step sets up sched_ext only where systemd runs (scx_loader).
  step_enabled scheduler && [ "$SO_INIT_SYSTEM" = systemd ] && return 1
  return 0
}

# _responsive_enable NAME HAD: enable and start the service NAME (HAD: its
# package was installed before this run). Returns 0 when it was changed (or
# would be), 3 when it already was, 1 on failure, 2 when the package ships
# no service for this init system.
_responsive_enable() {
  local name="$1" had="$2" state
  if ! svc_exists "$name"; then
    if [ "$SO_DRY_RUN" = 1 ] && [ "$had" = 0 ]; then
      log_dry "would enable and start $name once it is installed"
      plan_note unit "$name" absent enabled
      return 0
    fi
    return 2
  fi
  state=$(svc_enabled_state "$name")
  [ "$state" = enabled ] && return 3
  svc_set "$name" enable || return 1
  return 0
}

# _responsive_part PKG SERVICE: install PKG and enable SERVICE (none: no
# service). Appends to RESP_DONE, RESP_OK, RESP_SKIPPED or RESP_FAILED.
_responsive_part() {
  local pkg="$1" svc="$2" rc=0 had=0
  pkg_installed "$pkg" && had=1
  if [ "$had" = 0 ]; then
    if ! scheduler_pkg_available "$pkg"; then
      RESP_SKIPPED+=("$pkg (not in this distribution's repositories)")
      return 0
    fi
    if ! pkg_can_install; then
      RESP_SKIPPED+=("$pkg ($(pkg_hand_hint "$pkg"))")
      return 0
    fi
    if ! pkg_add "$pkg"; then
      RESP_FAILED+=("$pkg (install failed)")
      return 0
    fi
  fi
  if [ "$svc" = none ]; then
    if [ "$had" = 1 ]; then RESP_OK+=("$pkg"); else RESP_DONE+=("$pkg"); fi
    return 0
  fi
  _responsive_enable "$svc" "$had" || rc=$?
  case "$rc" in
    0) RESP_DONE+=("$pkg") ;;
    3) if [ "$had" = 1 ]; then RESP_OK+=("$pkg"); else RESP_DONE+=("$pkg"); fi ;;
    2) if [ "$had" = 1 ]; then RESP_SKIPPED+=("$pkg (no $(init_label) service)"); else RESP_DONE+=("$pkg (no $(init_label) service to enable)"); fi ;;
    *) RESP_FAILED+=("$svc (could not enable)") ;;
  esac
}

responsive_step() {
  local note="" warn=""
  RESP_DONE=() RESP_OK=() RESP_SKIPPED=() RESP_FAILED=()
  if [ "$SO_IN_CONTAINER" = 1 ]; then
    step_skip "container: nothing to tune for a desktop here"
    return 0
  fi
  if [ "$SO_INIT_SYSTEM" = systemd ]; then
    _responsive_part uresourced uresourced
  else
    RESP_SKIPPED+=("uresourced (needs systemd)")
  fi
  _responsive_part gamemode none
  if responsive_ananicy_allowed; then
    _responsive_part ananicy-cpp ananicy-cpp
  elif scx_running; then
    RESP_SKIPPED+=("ananicy-cpp (a sched_ext scheduler runs)")
  else
    RESP_SKIPPED+=("ananicy-cpp (the scheduler step sets up sched_ext in this run)")
  fi
  if scx_running && ananicy_running; then
    warn="ananicy-cpp and the sched_ext scheduler $(scx_ops) both run; ananicy-cpp can stall it, so stop one (sudo systemctl disable --now ananicy-cpp)"
  fi

  [ ${#RESP_DONE[@]} -eq 0 ] || note+="$([ "$SO_DRY_RUN" = 1 ] && echo "would set up" || echo "set up"): $(join_by ', ' "${RESP_DONE[@]}")"
  [ ${#RESP_OK[@]} -eq 0 ] || note+="${note:+; }already on: $(join_by ', ' "${RESP_OK[@]}")"
  [ ${#RESP_FAILED[@]} -eq 0 ] || note+="${note:+; }failed: $(join_by ', ' "${RESP_FAILED[@]}")"
  [ ${#RESP_SKIPPED[@]} -eq 0 ] || note+="${note:+; }left out: $(join_by ', ' "${RESP_SKIPPED[@]}")"

  if [ ${#RESP_FAILED[@]} -gt 0 ]; then
    step_fail "$note"
    return 1
  fi
  if [ -n "$warn" ]; then
    step_warn "$warn; $note"
  elif [ ${#RESP_DONE[@]} -eq 0 ] && [ ${#RESP_OK[@]} -eq 0 ]; then
    step_skip "$note"
  elif [ ${#RESP_DONE[@]} -eq 0 ]; then
    step_ok "$note"
  elif [ "$SO_DRY_RUN" = 1 ]; then
    step_dry "$note"
  else
    step_updated "$note"
  fi
}
