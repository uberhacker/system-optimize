#!/usr/bin/env bash
# lib/tweaks/gpu.sh - opt-in steps "gpu-memory" and "rocm": GPU memory and
# compute for local LLMs on AMD (new in 2.1).
#
# gpu-memory  An AMD APU (Ryzen AI, Strix Point, Strix Halo, ...) has a
#             small VRAM carve-out set in the firmware and maps the rest of
#             the GPU's memory from RAM through TTM (GTT). The kernel caps
#             that at about half of RAM (ttm pages_limit, in 4 KiB pages).
#             AMD's Strix Halo guidance: keep the carve-out small and raise
#             the TTM limit instead. The step first reports the TTM limit,
#             the GTT size, the carve-out, the kernel against AMD's 6.18.4
#             minimum for Strix Halo and the rocminfo gfx target, then sets
#             the limit to GPU_MEM_GIB (--gpu-memory GIB), or to 75 % of
#             RAM when that is 0. It never goes above 85 % of RAM nor above
#             RAM less 8 GiB (Jeff Geerling: 108 of 128 GiB stable, 110
#             crashed), and only raises. With AMD's amd-ttm (amd-debug-tools)
#             installed it runs `amd-ttm --set GIB`; otherwise it writes the
#             same line itself: /etc/modprobe.d/ttm.conf, "options ttm
#             pages_limit=PAGES". ttm loads from the initramfs, so that is
#             rebuilt (dracut, update-initramfs, mkinitcpio or mkinitfs).
#             Needs a reboot. Only on an AMD APU: an amdgpu card with at
#             most 4 GiB of VRAM and an AMD CPU; a discrete GPU has its own
#             memory. Skipped in VMs and containers, and on image-based
#             systems (rpm-ostree), where the hint gives the kernel argument
#             instead. Never touches amdgpu power or clock files: LACT owns
#             those.
# rocm        Installs the ROCm runtime that the distribution itself
#             packages: Fedora 42 and later "rocm" (or rocm-hip, rocminfo
#             and rocm-smi), Arch rocm-hip-runtime and rocminfo,
#             Debian/Ubuntu rocminfo and rocm-smi where the release has
#             them. Elsewhere (RHEL and clones, openSUSE, Alpine, Void,
#             Gentoo) it installs nothing and says where ROCm comes from.
#             It adds the desktop user to the render and video groups,
#             which ROCm needs to open /dev/kfd and /dev/dri (gpasswd, else
#             usermod, else Alpine's addgroup); new groups take effect at
#             the next login. Only with an amdgpu GPU; skipped in
#             containers.
#
# Undo: gpu-memory restores /etc/modprobe.d/ttm.conf (or removes it) and
# rebuilds the initramfs again; the old limit is back after a reboot. rocm
# removes the packages it installed and takes the user out of the groups it
# added them to.

step_def gpu-memory opt-in gpu_memory_step 'reboot,bench' \
  "More GPU memory for AMD APUs (TTM limit)" \
  "Raises the TTM pages limit so an AMD APU can map more RAM as GPU memory (amd-ttm or modprobe.d). Needs a reboot." \
  gpu

step_def rocm opt-in rocm_step 'reboot' \
  "ROCm for AMD GPUs" \
  "Installs ROCm where the distribution packages it and adds the desktop user to render and video." \
  gpu

SO_GPU_TTM_CONF=/etc/modprobe.d/ttm.conf
SO_GPU_PAGES_PER_GIB=262144          # 4 KiB pages in a GiB
SO_GPU_APU_VRAM_MAX=4294967296       # a carve-out of at most 4 GiB: an APU
SO_GPU_STRIX_HALO_KERNEL=6.18.4      # AMD's minimum for Strix Halo compute

# gpu_amdgpu_cards: the /sys/class/drm/cardN/device directories (system
# paths) whose driver is amdgpu, one per line.
gpu_amdgpu_cards() {
  local d name drv
  for d in "$(so_path /sys/class/drm)"/card*; do
    name="${d##*/}"
    [[ "$name" =~ ^card[0-9]+$ ]] || continue
    drv=$(readlink "$d/device/driver" 2>/dev/null) || continue
    [ "${drv##*/}" = amdgpu ] && printf '/sys/class/drm/%s/device\n' "$name"
  done
  return 0
}

# gpu_apu_card: the amdgpu card with a small VRAM carve-out (an APU).
gpu_apu_card() {
  local c vram
  while IFS= read -r c; do
    vram=$(read_line "$(so_path "$c/mem_info_vram_total")" 2>/dev/null) || continue
    [[ "$vram" =~ ^[0-9]+$ ]] || continue
    if [ "$vram" -le "$SO_GPU_APU_VRAM_MAX" ]; then
      printf '%s\n' "$c"
      return 0
    fi
  done < <(gpu_amdgpu_cards)
  return 1
}

# gpu_gib BYTES: BYTES in GiB with one decimal.
gpu_gib() {
  awk -v b="$1" 'BEGIN { printf "%.1f", b / 1073741824 }'
}

# gpu_kernel_older A B: kernel release A is older than version B (x.y.z).
gpu_kernel_older() {
  local a1 a2 a3 b1 b2 b3
  [[ "$1" =~ ^([0-9]+)\.([0-9]+)(\.([0-9]+))? ]] || return 1
  a1=${BASH_REMATCH[1]}; a2=${BASH_REMATCH[2]}; a3=${BASH_REMATCH[4]:-0}
  IFS=. read -r b1 b2 b3 <<< "$2"
  [ "$a1" -ne "$b1" ] && { [ "$a1" -lt "$b1" ]; return; }
  [ "$a2" -ne "$b2" ] && { [ "$a2" -lt "$b2" ]; return; }
  [ "$a3" -lt "${b3:-0}" ]
}

# gpu_gfx_target: the first gfx target rocminfo lists, when it is installed.
gpu_gfx_target() {
  local out
  has_cmd rocminfo || return 1
  out=$(SO_RUN_TIMEOUT=30 run rocminfo 2>/dev/null) || return 1
  out=$(grep -o -m1 'gfx[0-9a-f]\{3,5\}' <<< "$out" | head -n1)
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# gpu_conf_pages FILE: the ttm pages_limit an /etc/modprobe.d file sets.
gpu_conf_pages() {
  local f
  f=$(so_path "$1")
  [ -r "$f" ] || return 1
  sed -n 's/^[[:space:]]*options[[:space:]]\{1,\}ttm[[:space:]].*pages_limit=\([0-9]\{1,\}\).*/\1/p' "$f" | tail -n1 | grep .
}

# gpu_other_ttm_conf: another /etc/modprobe.d file that sets ttm's
# pages_limit (or amdgpu.gttsize), which ours would fight with.
gpu_other_ttm_conf() {
  local f
  for f in "$(so_path /etc/modprobe.d)"/*.conf; do
    [ -f "$f" ] || continue
    [ "${f##*/}" = "${SO_GPU_TTM_CONF##*/}" ] && continue
    if grep -qE '^[[:space:]]*options[[:space:]]+(ttm[[:space:]].*pages_limit=|amdgpu[[:space:]].*gttsize=)' "$f"; then
      printf '/etc/modprobe.d/%s\n' "${f##*/}"
      return 0
    fi
  done
  return 1
}

# gpu_report CARD: what the GPU memory looks like now (log_info).
gpu_report() {
  local card="$1" v gfx
  v=$(ttm_pages_limit) && [[ "$v" =~ ^[0-9]+$ ]] &&
    log_info "TTM pages limit: $v pages ($(gpu_gib $((v * 4096))) GiB)"
  v=$(read_line "$(so_path "$card/mem_info_gtt_total")" 2>/dev/null) && [[ "$v" =~ ^[0-9]+$ ]] &&
    log_info "GTT size (RAM the GPU can map now): $(gpu_gib "$v") GiB"
  v=$(read_line "$(so_path "$card/mem_info_vram_total")" 2>/dev/null) && [[ "$v" =~ ^[0-9]+$ ]] &&
    log_info "VRAM carve-out (set in the firmware): $(gpu_gib "$v") GiB"
  if gpu_kernel_older "$SO_KERNEL_RELEASE" "$SO_GPU_STRIX_HALO_KERNEL"; then
    log_warn "kernel $SO_KERNEL_RELEASE is older than $SO_GPU_STRIX_HALO_KERNEL, which AMD names as the minimum for GPU compute on Strix Halo; update the kernel if this is one"
  else
    log_info "kernel $SO_KERNEL_RELEASE (AMD's minimum for Strix Halo: $SO_GPU_STRIX_HALO_KERNEL)"
  fi
  if gfx=$(gpu_gfx_target); then
    log_info "ROCm gfx target: $gfx"
  fi
  return 0
}

# gpu_target_gib: the TTM limit to set, in GiB, from GPU_MEM_GIB and RAM;
# fails when RAM is too small for any. Caps a GPU_MEM_GIB that is too high
# (with a warning).
gpu_target_gib() {
  local ram="$SO_MEM_GB" want cap
  want=$(cfg GPU_MEM_GIB)
  [[ "$want" =~ ^[0-9]+$ ]] || want=0
  cap=$((ram * 85 / 100))
  [ $((ram - 8)) -lt "$cap" ] && cap=$((ram - 8))
  [ "$cap" -gt 0 ] || return 1
  if [ "$want" -eq 0 ]; then
    want=$((ram * 75 / 100))
  fi
  if [ "$want" -gt "$cap" ]; then
    [ "$(cfg GPU_MEM_GIB)" = 0 ] ||
      log_warn "GPU_MEM_GIB=$want is more than this ${ram} GiB machine can spare; capped at $cap GiB (85 % of RAM and at least 8 GiB left for the system)"
    want=$cap
  fi
  printf '%s\n' "$want"
}

# _gpu_amd_ttm GIB: amd-ttm --set GIB, answering no to its reboot question.
_gpu_amd_ttm() {
  printf 'n\n' | amd-ttm --set "$1"
}

# gpu_write_conf GIB PAGES: put "options ttm pages_limit=PAGES" in
# /etc/modprobe.d/ttm.conf, through amd-ttm when it is installed. Returns
# 0 written, 3 unchanged, 1 failed.
gpu_write_conf() {
  local gib="$1" pages="$2" rc=0 content
  content="options ttm pages_limit=$pages"
  if [ "$(gpu_conf_pages "$SO_GPU_TTM_CONF" 2>/dev/null)" = "$pages" ]; then
    log_detail "$SO_GPU_TTM_CONF already sets pages_limit=$pages"
    return 3
  fi
  if has_cmd amd-ttm; then
    if [ "$SO_DRY_RUN" = 1 ]; then
      log_dry "would run: amd-ttm --set $gib (it writes $SO_GPU_TTM_CONF)"
      plan_note file "$SO_GPU_TTM_CONF" "$(gpu_conf_pages "$SO_GPU_TTM_CONF" 2>/dev/null || echo absent)" "pages_limit=$pages"
      return 0
    fi
    snap_file "$SO_GPU_TTM_CONF" written || return 1
    do_pipe "amd-ttm --set $gib" _gpu_amd_ttm "$gib" || rc=$?
    if [ "$rc" = 0 ] && [ "$(gpu_conf_pages "$SO_GPU_TTM_CONF" 2>/dev/null)" = "$pages" ]; then
      return 0
    fi
    log_warn "amd-ttm --set $gib did not write pages_limit=$pages (exit $rc); writing $SO_GPU_TTM_CONF directly"
  fi
  install_file "$SO_GPU_TTM_CONF" 0644 < <(
    printf '%s\n' "# Written by system-optimize ($(version_string)). Undo: system-optimize --undo" \
      "# Lets the integrated GPU map up to $gib GiB of RAM (4 KiB pages). Needs a reboot." \
      "$content")
}

gpu_memory_step() {
  local card cur conf gib pages other rc=0 cur_gib
  if [ "$SO_IS_VM" = 1 ] || [ "$SO_IN_CONTAINER" = 1 ]; then
    step_skip "virtual machine or container: the host owns the GPU"
    return 0
  fi
  if [ -z "$(gpu_amdgpu_cards)" ]; then
    step_skip "no AMD GPU (amdgpu driver)"
    return 0
  fi
  if [ "$SO_CPU_VENDOR" != AuthenticAMD ]; then
    step_skip "not an AMD APU: the CPU is not AMD's"
    return 0
  fi
  if ! card=$(gpu_apu_card); then
    step_skip "not an AMD APU: the AMD GPU has more than 4 GiB of its own VRAM"
    return 0
  fi
  gpu_report "$card"
  cur=$(ttm_pages_limit) || cur=""
  if ! [[ "$cur" =~ ^[0-9]+$ ]]; then
    step_skip "no TTM pages limit in /sys/module/ttm/parameters (ttm not loaded)"
    return 0
  fi
  if ! gib=$(gpu_target_gib); then
    step_skip "$SO_MEM_GB GiB of RAM is too little to give the GPU more"
    return 0
  fi
  pages=$((gib * SO_GPU_PAGES_PER_GIB))
  if other=$(gpu_other_ttm_conf); then
    step_skip "$other already sets the GPU memory limit; left alone"
    return 0
  fi
  conf=$(gpu_conf_pages "$SO_GPU_TTM_CONF" 2>/dev/null) || conf=""
  if [ "$conf" = "$pages" ]; then
    if [ "$cur" = "$pages" ]; then
      step_ok "GPU memory limit already $gib GiB"
    else
      step_ok "GPU memory limit of $gib GiB already in $SO_GPU_TTM_CONF; reboot to apply it"
    fi
    return 0
  fi
  cur_gib=$((cur / SO_GPU_PAGES_PER_GIB))
  if [ "$cur" -ge "$pages" ] || { [ -n "$conf" ] && [ "$conf" -gt "$pages" ]; }; then
    [ -n "$conf" ] && [ "$conf" -gt "$cur" ] && cur_gib=$((conf / SO_GPU_PAGES_PER_GIB))
    step_skip "the GPU can already map $cur_gib GiB, not less than $gib GiB; this step only raises the limit"
    return 0
  fi
  if [ "$SO_PKG_MANAGER" = rpm-ostree ]; then
    step_skip "image-based system: set it with rpm-ostree kargs --append=ttm.pages_limit=$pages and reboot"
    return 0
  fi
  log_info "raising the GPU memory limit from $cur_gib GiB to $gib GiB of ${SO_MEM_GB} GiB RAM"
  gpu_write_conf "$gib" "$pages" || rc=$?
  [ "$rc" = 0 ] || [ "$rc" = 3 ] || { step_fail "could not write $SO_GPU_TTM_CONF"; return 1; }
  if [ "$SO_DRY_RUN" = 1 ]; then
    initramfs_rebuild || true
    step_dry "would set the GPU memory limit to $gib GiB ($SO_GPU_TTM_CONF) and rebuild the initramfs; needs a reboot"
    return 0
  fi
  snap_record initramfs - - rebuilt || return 1
  if ! initramfs_rebuild; then
    step_warn "set $gib GiB in $SO_GPU_TTM_CONF, but the initramfs could not be rebuilt; rebuild it, then reboot"
    return 0
  fi
  step_updated "GPU memory limit $cur_gib -> $gib GiB in $SO_GPU_TTM_CONF; reboot to apply it"
}

# ---------------------------------------------------------------------------
# rocm
# ---------------------------------------------------------------------------
# rocm_pkg_offered NAME: the distribution's repositories have NAME (or it
# is installed).
rocm_pkg_offered() {
  pkg_installed "$1" && return 0
  case "$SO_PKG_MANAGER" in
    dnf) SO_RUN_TIMEOUT="$SO_PKG_TIMEOUT" run "$(_dnf_cmd)" -q list "$1" >/dev/null 2>&1 ;;
    pacman) run pacman -Si "$1" >/dev/null 2>&1 ;;
    apt) run env DEBIAN_FRONTEND=noninteractive apt-get -s -q install "$1" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# rocm_plan: SO_ROCM_PKGS (the packages to have) and SO_ROCM_HINT (why
# there are none, and where ROCm comes from then).
rocm_plan() {
  local p ver
  SO_ROCM_PKGS=()
  SO_ROCM_HINT=""
  case "$SO_PKG_MANAGER" in
    dnf)
      if [ "$SO_OS_ID" != fedora ]; then
        SO_ROCM_HINT="$SO_OS_NAME does not package ROCm; AMD's repository (repo.radeon.com) has it"
        return 0
      fi
      ver="${SO_OS_VERSION_ID%%.*}"
      if [[ "$ver" =~ ^[0-9]+$ ]] && [ "$ver" -lt 42 ]; then
        SO_ROCM_HINT="Fedora $ver is too old for Fedora's own ROCm builds; upgrade to Fedora 42 or later"
        return 0
      fi
      if rocm_pkg_offered rocm; then
        SO_ROCM_PKGS=(rocm)
      else
        for p in rocm-hip rocminfo rocm-smi; do
          rocm_pkg_offered "$p" && SO_ROCM_PKGS+=("$p")
        done
      fi ;;
    pacman)
      for p in rocm-hip-runtime rocminfo; do
        rocm_pkg_offered "$p" && SO_ROCM_PKGS+=("$p")
      done ;;
    apt)
      for p in rocminfo rocm-smi; do
        rocm_pkg_offered "$p" && SO_ROCM_PKGS+=("$p")
      done ;;
    rpm-ostree)
      SO_ROCM_HINT="image-based system: rpm-ostree install rocm, then reboot (or use a toolbox)" ;;
    *)
      SO_ROCM_HINT="${SO_OS_NAME:-this distribution} has no ROCm packages this step knows; AMD's ROCm documentation lists the supported ways"
      return 0 ;;
  esac
  if [ ${#SO_ROCM_PKGS[@]} -eq 0 ] && [ -z "$SO_ROCM_HINT" ]; then
    SO_ROCM_HINT="${SO_OS_NAME:-this release}'s repositories offer no ROCm runtime packages"
  fi
}

# rocm_group_exists GROUP
rocm_group_exists() {
  grep -q "^$1:" "$(so_path /etc/group)" 2>/dev/null
}

# rocm_in_group USER GROUP: USER is a listed member of GROUP.
rocm_in_group() {
  local members
  members=$(awk -F: -v g="$2" '$1 == g { print $4 }' "$(so_path /etc/group)" 2>/dev/null)
  list_has "${members//,/ }" "$1"
}

# rocm_add_group USER GROUP: add USER to GROUP, recorded for --undo.
rocm_add_group() {
  local user="$1" group="$2"
  if [ "$SO_DRY_RUN" = 1 ]; then
    log_dry "would add $user to the group $group"
    plan_note group "$user:$group" absent member
    return 0
  fi
  snap_record group "$user:$group" absent member || return 1
  if has_cmd gpasswd; then do_run gpasswd -a "$user" "$group" >/dev/null
  elif has_cmd usermod; then do_run usermod -aG "$group" "$user"
  elif has_cmd addgroup; then do_run addgroup "$user" "$group"
  else
    log_warn "no gpasswd, usermod or addgroup to add $user to $group"
    return 1
  fi
}

rocm_step() {
  local p user g gfx installed=0 added="" failed=0 note="" who=""
  if [ "$SO_IN_CONTAINER" = 1 ]; then
    step_skip "container: ROCm needs the host's GPU driver and groups"
    return 0
  fi
  if [ -z "$(gpu_amdgpu_cards)" ]; then
    step_skip "no AMD GPU (amdgpu driver)"
    return 0
  fi
  rocm_plan
  for p in "${SO_ROCM_PKGS[@]}"; do
    pkg_installed "$p" && continue
    if pkg_add "$p"; then
      installed=$((installed + 1))
    else
      log_warn "could not install $p"
      failed=$((failed + 1))
    fi
  done
  [ -z "$SO_ROCM_HINT" ] || log_info "ROCm: $SO_ROCM_HINT"

  user=$(desktop_user)
  if [ -z "$user" ] || [ "$user" = root ]; then
    log_warn "no desktop user found; add yourself to the render and video groups to use ROCm"
  else
    who="$user"
    for g in render video; do
      if ! rocm_group_exists "$g"; then
        log_detail "no group $g on this system"
        continue
      fi
      rocm_in_group "$user" "$g" && continue
      if rocm_add_group "$user" "$g"; then
        added+="${added:+, }$g"
      else
        failed=$((failed + 1))
      fi
    done
  fi
  if [ "$SO_DRY_RUN" != 1 ] && gfx=$(gpu_gfx_target); then
    log_info "ROCm sees the GPU as $gfx"
  fi

  [ "$installed" = 0 ] || note="$( [ "$SO_DRY_RUN" = 1 ] && echo "would install" || echo installed) $installed ROCm package(s)"
  [ -z "$added" ] || note+="${note:+; }$( [ "$SO_DRY_RUN" = 1 ] && echo "would add" || echo added) $user to $added (takes effect at the next login)"
  if [ "$failed" -gt 0 ]; then
    step_fail "${note:+$note; }$failed change(s) failed"
    return 1
  fi
  if [ -z "$note" ]; then
    if [ ${#SO_ROCM_PKGS[@]} -eq 0 ]; then
      step_skip "$SO_ROCM_HINT"
    else
      step_ok "ROCm ($(join_by ' ' "${SO_ROCM_PKGS[@]}")) installed${who:+; $who is in render and video}"
    fi
    return 0
  fi
  [ ${#SO_ROCM_PKGS[@]} -gt 0 ] || note+="; $SO_ROCM_HINT"
  if [ "$SO_DRY_RUN" = 1 ]; then
    step_dry "$note"
  else
    step_updated "$note"
  fi
}
