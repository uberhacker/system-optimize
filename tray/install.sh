#!/usr/bin/env bash
# install.sh - install or remove the parts of system-optimize-tray from a checkout.
#
# Usage: install.sh [parts] [options]
# Parts (with none: --tray, plus --extension when GNOME Shell is installed):
#   --tray          the tray app, its dashboard, root helper and polkit policy
#   --extension     the GNOME Shell extension, enabled for you (log out and in)
#   --monitoring    Performance Co-Pilot, so the resource screens have long
#                   history (pcp-zeroconf and pcp-system-tools on Fedora), and
#                   its AMD GPU agent where there is an AMD GPU
#   --agent         the optional tuning agent, then its model and schedule for
#                   you (install-agent.sh; about 3 GB download, 3-3.5 GB RAM
#                   while it runs)
#   --all           all four
# Options:
#   --uninstall     remove the parts named instead. --monitoring removes only
#                   the packages this script installed; --agent keeps the model
#                   unless --remove-model is given
#   --model NAME, --schedule CRON, --no-pull, --install-ollama, --remove-model
#                   passed to install-agent.sh (see install-agent.sh --help)
#   --prefix DIR    install prefix (default /usr)
#   --dry-run       print what would run, change nothing
#   --yes           do not ask before installing packages or downloading the model
#   -h, --help      this text
#
# Run it as yourself: the system parts go through sudo, and the agent's
# schedule and the extension are per user. Every system part is a make target
# in this directory (install-tray, install-extension, install-agent and their
# uninstall-* twins), so packagers and other installers can call those.
# Exit codes: 0 done, 1 failed, 2 bad usage.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
UUID="system-optimize@bradvrudney.github.io"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/system-optimize-tray"
TRAY=0 EXT=0 MON=0 AGENT=0 UNINSTALL=0 DRY=0 YES=0
PREFIX=/usr
AGENT_ARGS=()

say() { printf '%s\n' "$*"; }
warn() { printf 'install: %s\n' "$*" >&2; }
die() { warn "$*"; exit 1; }
usage() { sed -n '2,/^set -euo/p' "$0" | sed -e '/^set -euo/d' -e 's/^# \{0,1\}//'; }

run() {
    if [ "$DRY" = 1 ]; then
        printf '+ %s\n' "$*"
    else
        "$@"
    fi
}

as_root() {
    if [ "$(id -u)" = 0 ]; then run "$@"; else run sudo "$@"; fi
}

confirm() {
    [ "$YES" = 1 ] || [ "$DRY" = 1 ] && return 0
    [ -t 0 ] || die "$1 Run again with --yes to go ahead without a terminal."
    local ans
    read -r -p "$1 [y/N] " ans
    case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

while [ $# -gt 0 ]; do
    case "$1" in
        --tray) TRAY=1 ;;
        --extension) EXT=1 ;;
        --monitoring) MON=1 ;;
        --agent) AGENT=1 ;;
        --all) TRAY=1 EXT=1 MON=1 AGENT=1 ;;
        --uninstall) UNINSTALL=1 ;;
        --dry-run) DRY=1; AGENT_ARGS+=(--dry-run) ;;
        --yes|-y) YES=1; AGENT_ARGS+=(--yes) ;;
        --prefix) [ $# -ge 2 ] || { warn "--prefix needs a directory"; exit 2; }; PREFIX="$2"; shift ;;
        --prefix=*) PREFIX="${1#*=}" ;;
        --model|--schedule)
            [ $# -ge 2 ] || { warn "$1 needs a value"; exit 2; }
            AGENT_ARGS+=("$1" "$2"); shift ;;
        --no-pull|--install-ollama|--remove-model) AGENT_ARGS+=("$1") ;;
        -h|--help) usage; exit 0 ;;
        *) warn "unknown option: $1 (see --help)"; exit 2 ;;
    esac
    shift
done
case "$PREFIX" in /*) ;; *) warn "--prefix must be an absolute path"; exit 2 ;; esac

if [ $((TRAY + EXT + MON + AGENT)) = 0 ]; then
    TRAY=1
    command -v gnome-shell >/dev/null 2>&1 && EXT=1
fi
MAKE=(make -C "$HERE" PREFIX="$PREFIX")

# -- monitoring: Performance Co-Pilot ---------------------------------------
amd_gpu() { grep -qs '^0x1002$' /sys/class/drm/card*/device/vendor; }

monitoring_packages() {
    if command -v dnf >/dev/null 2>&1; then
        printf '%s\n' pcp-zeroconf pcp-system-tools
        amd_gpu && printf '%s\n' pcp-pmda-amdgpu
    elif command -v apt-get >/dev/null 2>&1; then
        printf '%s\n' pcp python3-pcp
    elif command -v pacman >/dev/null 2>&1; then
        printf '%s\n' pcp
        amd_gpu && printf '%s\n' amdgpu_top
    elif command -v zypper >/dev/null 2>&1; then
        printf '%s\n' pcp
    fi
}

installed() {
    if command -v rpm >/dev/null 2>&1 && rpm -q "$1" >/dev/null 2>&1; then return 0; fi
    if command -v dpkg-query >/dev/null 2>&1 && dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'ok installed'; then
        return 0
    fi
    if command -v pacman >/dev/null 2>&1 && pacman -Q "$1" >/dev/null 2>&1; then return 0; fi
    return 1
}

pkg_install() {
    if command -v dnf >/dev/null 2>&1; then as_root dnf install -y "$@"
    elif command -v apt-get >/dev/null 2>&1; then as_root apt-get install -y "$@"
    elif command -v pacman >/dev/null 2>&1; then as_root pacman -S --needed --noconfirm "$@"
    else as_root zypper --non-interactive install "$@"
    fi
}

pkg_remove() {
    if command -v dnf >/dev/null 2>&1; then as_root dnf remove -y "$@"
    elif command -v apt-get >/dev/null 2>&1; then as_root apt-get remove -y "$@"
    elif command -v pacman >/dev/null 2>&1; then as_root pacman -R --noconfirm "$@"
    else as_root zypper --non-interactive remove "$@"
    fi
}

install_monitoring() {
    local pkgs=() new=() p
    mapfile -t pkgs < <(monitoring_packages)
    [ ${#pkgs[@]} -gt 0 ] || { warn "no supported package manager (dnf, apt, pacman, zypper): install pcp yourself"; return 1; }
    for p in "${pkgs[@]}"; do installed "$p" || new+=("$p"); done
    if [ ${#new[@]} -gt 0 ]; then
        confirm "Install ${new[*]} (Performance Co-Pilot keeps resource history)?" || return 1
        pkg_install "${new[@]}"
        if [ "$DRY" != 1 ]; then
            mkdir -p "$STATE"
            printf '%s\n' "${new[@]}" >> "$STATE/monitoring-packages"
        fi
    else
        say "Performance Co-Pilot is already installed."
    fi
    if command -v systemctl >/dev/null 2>&1; then
        as_root systemctl enable --now pmcd.service pmlogger.service
    fi
    if amd_gpu && ! command -v amdgpu_top >/dev/null 2>&1; then
        say "For per-process GPU memory, install amdgpu_top from https://github.com/Umio-Yasuno/amdgpu_top/releases"
    fi
}

uninstall_monitoring() {
    local list="$STATE/monitoring-packages" pkgs=()
    if [ ! -s "$list" ]; then
        say "This script installed no monitoring packages; nothing to remove."
        return 0
    fi
    mapfile -t pkgs < <(sort -u "$list")
    confirm "Remove ${pkgs[*]}?" || return 1
    pkg_remove "${pkgs[@]}"
    [ "$DRY" = 1 ] || rm -f "$list"
}

# -- the parts ----------------------------------------------------------------
if [ "$UNINSTALL" = 1 ]; then
    if [ "$AGENT" = 1 ]; then
        if command -v system-optimize-agent >/dev/null 2>&1 || [ -x "$HERE/bin/system-optimize-agent" ]; then
            if [ "$(id -u)" = 0 ]; then
                warn "run 'install-agent.sh --uninstall' as each user to remove their agent schedule"
            else
                run "$HERE/install-agent.sh" --uninstall "${AGENT_ARGS[@]}"
            fi
        fi
        as_root "${MAKE[@]}" uninstall-agent
    fi
    if [ "$EXT" = 1 ]; then
        if command -v gnome-extensions >/dev/null 2>&1 && [ "$(id -u)" != 0 ]; then
            run gnome-extensions disable "$UUID" || true
        fi
        as_root "${MAKE[@]}" uninstall-extension
    fi
    [ "$TRAY" = 1 ] && as_root "${MAKE[@]}" uninstall-tray
    [ "$MON" = 1 ] && uninstall_monitoring
    say "Removed. Your settings stay in ~/.config/system-optimize."
    exit 0
fi

[ "$TRAY" = 1 ] && as_root "${MAKE[@]}" install-tray
if [ "$EXT" = 1 ]; then
    as_root "${MAKE[@]}" install-extension
    if command -v gnome-extensions >/dev/null 2>&1 && [ "$(id -u)" != 0 ]; then
        run gnome-extensions enable "$UUID" || warn "enable it after logging in again: gnome-extensions enable $UUID"
    fi
    say "GNOME: log out and back in to load the extension."
fi
if [ "$MON" = 1 ]; then
    install_monitoring || warn "monitoring was not set up"
fi
if [ "$AGENT" = 1 ]; then
    as_root "${MAKE[@]}" install-agent
    if [ "$(id -u)" = 0 ]; then
        warn "the agent's model and schedule are per user: run $PREFIX/share/system-optimize-tray/install-agent.sh as yourself"
    elif [ "$DRY" = 1 ]; then
        say "+ $HERE/install-agent.sh ${AGENT_ARGS[*]}"
    else
        "$HERE/install-agent.sh" "${AGENT_ARGS[@]}"
    fi
fi
say "Done."
