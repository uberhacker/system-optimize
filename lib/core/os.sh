#!/usr/bin/env bash
# lib/core/os.sh - the distribution, its package manager and its init
# system, and the read-only helpers for packages and services (new in 2.0).
#
# Distribution: /etc/os-release (or /usr/lib/os-release) is parsed line by
# line, never sourced. ID and ID_LIKE map to a package manager the same way
# system-update does:
#   apt         Debian, Ubuntu, Mint, Pop!_OS, ...
#   dnf         Fedora, RHEL, Rocky, Alma, CentOS Stream, Oracle, Amazon
#   zypper      openSUSE Tumbleweed and Leap, SLES
#   pacman      Arch, Manjaro, EndeavourOS, CachyOS, ...
#   apk         Alpine, postmarketOS
#   xbps        Void
#   emerge      Gentoo
#   nix         NixOS
#   rpm-ostree  Fedora Atomic (Silverblue, Kinoite, ...), Bazzite, Bluefin,
#               detected before dnf so that dnf never runs on them
# An unknown ID falls back to the first package manager found on PATH.
# --install-tools installs with apt, dnf, zypper, pacman, apk and xbps; on
# emerge, nix and rpm-ostree systems it says what to install by hand (a
# Gentoo atom, a NixOS option, an rpm-ostree layer and a reboot are the
# owner's decision).
#
# Init system: systemd, openrc (Alpine, Gentoo, Artix), runit (Void) or
# none (most containers). The svc_* helpers take a service's base name
# (earlyoom) and answer for whichever init runs; svc_set in snapshot.sh
# changes one and records it for --undo.
#
# Overrides (tests and odd machines): SO_PKG (a manager name or none),
# SO_INIT (systemd, openrc, runit or none).
#
# Changes from 1.x: 1.x did not look at the distribution at all. 2.0.0
# knew dnf, apt, pacman and zypper from the commands on PATH; this module
# replaces that with system-update's detection.

SO_OS_ID=""
SO_OS_ID_LIKE=""
SO_OS_NAME=""
SO_OS_VERSION_ID=""
SO_OS_VARIANT_ID=""
SO_PKG_MANAGER="none"
SO_INIT_SYSTEM="none"
SO_HAS_SYSTEMD=0

# Managers --install-tools can install with.
SO_PKG_INSTALLERS="apt dnf zypper pacman apk xbps"

# os_read_release FILE: set SO_OS_* from FILE without sourcing it.
os_read_release() {
  local file="$1" line key value
  [ -r "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*([A-Z0-9_]+)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then
      value="${BASH_REMATCH[1]}"
    fi
    value="${value//[^[:print:]]/}"
    case "$key" in
      ID) SO_OS_ID="${value,,}" ;;
      ID_LIKE) SO_OS_ID_LIKE="${value,,}" ;;
      PRETTY_NAME) SO_OS_NAME="$value" ;;
      NAME) [ -n "$SO_OS_NAME" ] || SO_OS_NAME="$value" ;;
      VERSION_ID) SO_OS_VERSION_ID="$value" ;;
      VARIANT_ID) SO_OS_VARIANT_ID="${value,,}" ;;
    esac
  done < "$file"
  return 0
}

# os_value KEY: one os-release value (for callers outside this module).
os_value() {
  case "$1" in
    ID) [ -n "$SO_OS_ID" ] && printf '%s\n' "$SO_OS_ID" ;;
    ID_LIKE) [ -n "$SO_OS_ID_LIKE" ] && printf '%s\n' "$SO_OS_ID_LIKE" ;;
    PRETTY_NAME) [ -n "$SO_OS_NAME" ] && printf '%s\n' "$SO_OS_NAME" ;;
    VERSION_ID) [ -n "$SO_OS_VERSION_ID" ] && printf '%s\n' "$SO_OS_VERSION_ID" ;;
    *) return 1 ;;
  esac
}

# os_is_ostree: booted from an rpm-ostree or bootc deployment?
os_is_ostree() {
  [ -e "$(so_path /run/ostree-booted)" ] && return 0
  case "$SO_OS_VARIANT_ID" in
    silverblue|kinoite|sericea|onyx|sway-atomic|budgie-atomic|cosmic-atomic|coreos|iot) return 0 ;;
  esac
  case "$SO_OS_ID" in
    bazzite|bluefin|aurora|ucore) return 0 ;;
  esac
  return 1
}

# os_pkg_from_ids ID ID_LIKE: the package manager for these ids.
os_pkg_from_ids() {
  local candidate
  for candidate in "${1,,}" ${2,,}; do
    case "$candidate" in
      debian|ubuntu|linuxmint|pop|elementary|kali|raspbian|neon|zorin|devuan|mx|deepin|tuxedo|parrot)
        echo apt; return 0 ;;
      fedora|rhel|centos|rocky|almalinux|ol|amzn|nobara|scientific|eurolinux|circle)
        echo dnf; return 0 ;;
      opensuse*|sles|sled|suse|sle-micro)
        echo zypper; return 0 ;;
      arch|archarm|manjaro|endeavouros|garuda|artix|cachyos|arcolinux)
        echo pacman; return 0 ;;
      alpine|postmarketos)
        echo apk; return 0 ;;
      void)
        echo xbps; return 0 ;;
      gentoo|funtoo)
        echo emerge; return 0 ;;
      nixos)
        echo nix; return 0 ;;
    esac
  done
  echo none
  return 1
}

# os_pkg_from_commands: last resort, the first manager found on PATH.
os_pkg_from_commands() {
  if has_cmd apt-get && has_cmd dpkg; then echo apt
  elif has_cmd dnf || has_cmd dnf5 || has_cmd yum; then echo dnf
  elif has_cmd zypper; then echo zypper
  elif has_cmd pacman; then echo pacman
  elif has_cmd apk; then echo apk
  elif has_cmd xbps-install; then echo xbps
  elif has_cmd emerge; then echo emerge
  elif has_cmd nix-env || has_cmd nixos-rebuild; then echo nix
  else echo none; return 1
  fi
}

# os_is_like NAME...: ID or ID_LIKE names one of NAME.
os_is_like() {
  local id want
  for id in $SO_OS_ID $SO_OS_ID_LIKE; do
    for want in "$@"; do [ "$id" = "$want" ] && return 0; done
  done
  return 1
}

# init_scan: which init system runs (SO_INIT_SYSTEM, SO_HAS_SYSTEMD).
init_scan() {
  if [ -n "${SO_INIT:-}" ]; then
    SO_INIT_SYSTEM="$SO_INIT"
  elif [ -d "$(so_path /run/systemd/system)" ]; then
    SO_INIT_SYSTEM=systemd
  elif [ -d "$(so_path /run/openrc)" ] || { has_cmd rc-service && [ -e "$(so_path /run/openrc/softlevel)" ]; }; then
    SO_INIT_SYSTEM=openrc
  elif [ -d "$(so_path /run/runit)" ] || { has_cmd sv && [ -d "$(so_path /etc/runit/runsvdir)" ]; }; then
    SO_INIT_SYSTEM=runit
  else
    SO_INIT_SYSTEM=none
  fi
  case "$SO_INIT_SYSTEM" in systemd|openrc|runit|none) ;; *) SO_INIT_SYSTEM=none ;; esac
  if [ "$SO_INIT_SYSTEM" = systemd ]; then SO_HAS_SYSTEMD=1; else SO_HAS_SYSTEMD=0; fi
}

# os_detect: SO_OS_*, SO_PKG_MANAGER and SO_INIT_SYSTEM.
os_detect() {
  local file
  SO_OS_ID="" SO_OS_ID_LIKE="" SO_OS_NAME="" SO_OS_VERSION_ID="" SO_OS_VARIANT_ID=""
  file=$(so_path /etc/os-release)
  [ -r "$file" ] || file=$(so_path /usr/lib/os-release)
  os_read_release "$file" || true
  if [ -n "${SO_PKG:-}" ]; then
    SO_PKG_MANAGER="$SO_PKG"
  elif os_is_ostree; then
    SO_PKG_MANAGER=rpm-ostree
  else
    SO_PKG_MANAGER=$(os_pkg_from_ids "$SO_OS_ID" "$SO_OS_ID_LIKE") ||
      SO_PKG_MANAGER=$(os_pkg_from_commands) || SO_PKG_MANAGER=none
  fi
  init_scan
}

# os_describe: "Name [id=x like=y]" for --status.
os_describe() {
  printf '%s [id=%s%s]\n' "${SO_OS_NAME:-unknown Linux}" "${SO_OS_ID:-?}" "${SO_OS_ID_LIKE:+ like=$SO_OS_ID_LIKE}"
}

# ---------------------------------------------------------------------------
# Services, by base name, for whichever init runs
# ---------------------------------------------------------------------------
# svc_runit_dir: where enabled runit services are linked.
svc_runit_dir() {
  if [ -d "$(so_path /var/service)" ]; then echo /var/service
  else echo /etc/runit/runsvdir/default
  fi
}

# svc_exists NAME: the service is installed.
svc_exists() {
  case "$SO_INIT_SYSTEM" in
    systemd) unit_exists "$1.service" ;;
    openrc) [ -x "$(so_path "/etc/init.d/$1")" ] ;;
    runit) [ -d "$(so_path "/etc/sv/$1")" ] ;;
    *) return 1 ;;
  esac
}

# svc_active NAME: the service is running.
svc_active() {
  case "$SO_INIT_SYSTEM" in
    systemd) unit_active "$1.service" ;;
    openrc) svc_exists "$1" && has_cmd rc-service && run rc-service "$1" status >/dev/null 2>&1 ;;
    runit)
      svc_exists "$1" && has_cmd sv || return 1
      local out
      out=$(run sv status "$1" 2>/dev/null) || return 1
      [[ "$out" == run:* ]] ;;
    *) return 1 ;;
  esac
}

# svc_enabled_state NAME: enabled, disabled, masked, ... or absent.
svc_enabled_state() {
  local lvl
  case "$SO_INIT_SYSTEM" in
    systemd) unit_enabled_state "$1.service" ;;
    openrc)
      svc_exists "$1" || { echo absent; return 0; }
      for lvl in sysinit boot default; do
        if [ -e "$(so_path "/etc/runlevels/$lvl/$1")" ]; then echo enabled; return 0; fi
      done
      echo disabled ;;
    runit)
      svc_exists "$1" || { echo absent; return 0; }
      if [ -e "$(so_path "$(svc_runit_dir)/$1")" ] || [ -L "$(so_path "$(svc_runit_dir)/$1")" ]; then
        echo enabled
      else
        echo disabled
      fi ;;
    *) echo absent ;;
  esac
}

# ---------------------------------------------------------------------------
# Packages (for --install-tools and --undo)
# ---------------------------------------------------------------------------
# pkg_can_install: --install-tools can install packages here.
pkg_can_install() { list_has "$SO_PKG_INSTALLERS" "$SO_PKG_MANAGER"; }

# pkg_hand_hint NAME: how to install NAME by hand where we do not.
pkg_hand_hint() {
  case "$SO_PKG_MANAGER" in
    rpm-ostree) echo "rpm-ostree install $1, then reboot" ;;
    emerge) echo "emerge --ask $1 (with its category, e.g. sys-process/$1)" ;;
    nix) echo "enable it in configuration.nix (services.$1.enable = true) and nixos-rebuild switch" ;;
    *) echo "install the package $1 with your package manager" ;;
  esac
}

# _dnf_cmd: dnf, or yum on old systems.
_dnf_cmd() { if has_cmd dnf; then echo dnf; elif has_cmd dnf5; then echo dnf5; else echo yum; fi; }

# pkg_installed NAME
pkg_installed() {
  case "$SO_PKG_MANAGER" in
    dnf|zypper|rpm-ostree) run rpm -q --quiet "$1" >/dev/null 2>&1 ;;
    apt) [ "$(run dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" = "install ok installed" ] ;;
    pacman) run pacman -Q "$1" >/dev/null 2>&1 ;;
    apk) run apk info -e "$1" >/dev/null 2>&1 ;;
    xbps) run xbps-query "$1" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# pkg_install NAME / pkg_remove NAME: through the package manager, with the
# package timeout. They change the system: callers check SO_DRY_RUN first.
pkg_install() {
  local -a cmd
  case "$SO_PKG_MANAGER" in
    dnf) cmd=("$(_dnf_cmd)" install -y "$1") ;;
    apt) cmd=(env DEBIAN_FRONTEND=noninteractive apt-get install -y "$1") ;;
    pacman) cmd=(pacman -S --noconfirm --needed "$1") ;;
    zypper) cmd=(zypper --non-interactive install "$1") ;;
    apk) cmd=(apk add "$1") ;;
    xbps) cmd=(xbps-install -y "$1") ;;
    *) log_error "$1: $(pkg_hand_hint "$1")"; return 1 ;;
  esac
  SO_RUN_TIMEOUT="$SO_PKG_TIMEOUT" run "${cmd[@]}"
}

pkg_remove() {
  local -a cmd
  case "$SO_PKG_MANAGER" in
    dnf) cmd=("$(_dnf_cmd)" remove -y "$1") ;;
    apt) cmd=(env DEBIAN_FRONTEND=noninteractive apt-get remove -y "$1") ;;
    pacman) cmd=(pacman -R --noconfirm "$1") ;;
    zypper) cmd=(zypper --non-interactive remove "$1") ;;
    apk) cmd=(apk del "$1") ;;
    xbps) cmd=(xbps-remove -y "$1") ;;
    *) log_error "cannot remove $1 with $SO_PKG_MANAGER; remove it by hand"; return 1 ;;
  esac
  SO_RUN_TIMEOUT="$SO_PKG_TIMEOUT" run "${cmd[@]}"
}

# pkg_name TOOL: the package that provides TOOL on this distribution.
pkg_name() {
  case "$1:$SO_PKG_MANAGER" in
    zram-generator:apt) echo systemd-zram-generator ;;
    *) echo "$1" ;;
  esac
}

# pkg_needs_repo TOOL: print the extra repository TOOL needs here and
# succeed, or fail when the distribution's own repositories have it.
# earlyoom is in Fedora but only in EPEL on RHEL, Rocky, Alma and Oracle.
pkg_needs_repo() {
  case "$1" in
    earlyoom)
      # ID, not ID_LIKE: Rocky and Alma say "like fedora" too.
      if [ "$SO_PKG_MANAGER" = dnf ] && list_has "rhel centos rocky almalinux ol eurolinux circle scientific" "$SO_OS_ID" &&
         ! pkg_installed epel-release; then
        echo "EPEL (dnf install epel-release)"
        return 0
      fi ;;
  esac
  return 1
}
