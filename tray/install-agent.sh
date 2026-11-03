#!/usr/bin/env bash
# install-agent.sh - set up the optional local tuning agent for the current user.
#
# The agent asks a small local model (default qwen3:4b through Ollama) to look
# at system-optimize's status and benchmark history once a day and suggest one
# change. It never applies anything by itself: you approve each suggestion in
# the tray (or with `system-optimize-agent approve`), and the change then goes
# through the same polkit prompt as any other.
#
# Usage: install-agent.sh [options]
#   --model NAME        model to pull and use (default qwen3:4b)
#   --schedule CRON     when the agent runs (default @daily; "off" for never)
#   --install-ollama    install Ollama from your distribution's packages (dnf,
#                       pacman or zypper, through sudo) if it is missing
#   --no-pull           do not download the model now
#   --uninstall         remove the schedule; keeps your config and the model
#   --remove-model      with --uninstall: also delete the model from Ollama
#   --dry-run           print what would run, change nothing
#   --yes               do not ask before downloading or installing
#   -h, --help          this text
#
# Needs: about 3-3.5 GB of free RAM while the 4B model runs (it is unloaded
# again after each scheduled run) and about 3 GB of disk for the model.
# It refuses to run as root (INSTALL_AGENT_ALLOW_ROOT=1 overrides, for containers
# and tests only).
set -euo pipefail

MODEL=""
SCHEDULE="@daily"
INSTALL_OLLAMA=0
PULL=1
UNINSTALL=0
REMOVE_MODEL=0
DRY=0
YES=0
MIN_RAM_MB=6144     # total RAM below this: warn, the model will crowd the desktop
MIN_DISK_MB=3500

say() { printf '%s\n' "$*"; }
warn() { printf 'install-agent: %s\n' "$*" >&2; }
die() { warn "$*"; exit 1; }

usage() { sed -n '2,/^set -euo/p' "$0" | sed -e '/^set -euo/d' -e 's/^# \{0,1\}//'; }

run() {
    if [ "$DRY" = 1 ]; then
        printf '+ %s\n' "$*"
    else
        "$@"
    fi
}

confirm() {
    [ "$YES" = 1 ] && return 0
    [ "$DRY" = 1 ] && return 0
    [ -t 0 ] || die "$1 Run again with --yes to go ahead without a terminal."
    local ans
    read -r -p "$1 [y/N] " ans
    case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

while [ $# -gt 0 ]; do
    case "$1" in
        --model) [ $# -ge 2 ] || die "--model needs a name"; MODEL="$2"; shift 2 ;;
        --model=*) MODEL="${1#*=}"; shift ;;
        --schedule) [ $# -ge 2 ] || die "--schedule needs a cron expression"; SCHEDULE="$2"; shift 2 ;;
        --schedule=*) SCHEDULE="${1#*=}"; shift ;;
        --install-ollama) INSTALL_OLLAMA=1; shift ;;
        --no-pull) PULL=0; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        --remove-model) REMOVE_MODEL=1; shift ;;
        --dry-run) DRY=1; shift ;;
        --yes|-y) YES=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
done

[ "$(id -u)" != 0 ] || [ "${INSTALL_AGENT_ALLOW_ROOT:-}" = 1 ] || die "run this as yourself, not root: the agent and its schedule are per user."

# Model names as Ollama writes them: name[:tag], with / for namespaces.
if [ -n "$MODEL" ] && ! printf '%s' "$MODEL" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._/-]{0,79}(:[A-Za-z0-9._-]{1,40})?$'; then
    die "not a model name: $MODEL"
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
if command -v system-optimize-agent >/dev/null 2>&1; then
    AGENT=(system-optimize-agent)
elif [ -x "$HERE/bin/system-optimize-agent" ]; then
    AGENT=("$HERE/bin/system-optimize-agent")
else
    die "system-optimize-agent is not installed (install the system-optimize-agent package, or run make install-agent)"
fi

if [ "$UNINSTALL" = 1 ]; then
    run "${AGENT[@]}" schedule off
    if [ "$REMOVE_MODEL" = 1 ]; then
        model="${MODEL:-$("${AGENT[@]}" model)}"
        if command -v ollama >/dev/null 2>&1; then
            run ollama rm "$model" || warn "could not remove $model from Ollama"
        fi
    fi
    say "The agent's schedule is removed. Your settings stay in ~/.config/system-optimize/agent.conf."
    exit 0
fi

# Memory and disk.
ram_mb=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
avail_mb=$(awk '/^MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo)
if [ "$ram_mb" -lt "$MIN_RAM_MB" ]; then
    warn "this machine has $((ram_mb / 1024)) GB of RAM; a 4B model needs about 3-3.5 GB while it runs."
    confirm "Set up the agent anyway?" || exit 1
fi
say "RAM: $((ram_mb / 1024)) GB total, $((avail_mb / 1024)) GB available now (the 4B model uses about 3-3.5 GB while it runs)."

# Ollama.
if ! command -v ollama >/dev/null 2>&1; then
    if [ "$INSTALL_OLLAMA" != 1 ]; then
        die "Ollama is not installed. Install it from your distribution (Fedora: sudo dnf install ollama), or run again with --install-ollama."
    fi
    if command -v dnf >/dev/null 2>&1; then
        pkg=(sudo dnf install -y ollama)
    elif command -v pacman >/dev/null 2>&1; then
        pkg=(sudo pacman -S --needed --noconfirm ollama)
    elif command -v zypper >/dev/null 2>&1; then
        pkg=(sudo zypper --non-interactive install ollama)
    else
        die "no supported package manager (dnf, pacman, zypper). Install Ollama yourself, then run this again."
    fi
    confirm "Install Ollama with: ${pkg[*]}?" || exit 1
    run "${pkg[@]}"
    if [ -d /run/systemd/system ] && systemctl cat ollama.service >/dev/null 2>&1; then
        run sudo systemctl enable --now ollama.service
    fi
fi

if [ "$DRY" != 1 ] && ! ollama list >/dev/null 2>&1; then
    if [ -d /run/systemd/system ]; then
        die "Ollama is installed but not running. Start it (sudo systemctl enable --now ollama) and run this again."
    fi
    die "Ollama is installed but not running. Start it (ollama serve, or your init system's ollama service) and run this again."
fi

# Settings first, so check and the tray show the right model.
if [ -n "$MODEL" ]; then
    run "${AGENT[@]}" model "$MODEL"
fi
model="${MODEL:-$("${AGENT[@]}" model)}"

if [ "$PULL" = 1 ]; then
    store="${OLLAMA_MODELS:-}"
    for d in "$store" /var/lib/ollama /usr/share/ollama/.ollama "$HOME/.ollama"; do
        [ -n "$d" ] && [ -d "$d" ] && { store="$d"; break; }
    done
    free_mb=$(df -Pm "${store:-$HOME}" | awk 'NR==2 {print $4}')
    if [ "$free_mb" -lt "$MIN_DISK_MB" ]; then
        warn "only $free_mb MB free for models in ${store:-$HOME}; $model needs about 3 GB."
        confirm "Try the download anyway?" || exit 1
    fi
    confirm "Download $model (about 2.5-3 GB for a 4B model)?" || exit 1
    run ollama pull "$model"
fi

run "${AGENT[@]}" schedule "$SCHEDULE"
if [ "$DRY" != 1 ]; then
    "${AGENT[@]}" check || warn "the check above found a problem; the schedule is set but runs will fail until it is fixed."
fi
say "Done. The agent suggests changes; you approve each one in the tray or with: system-optimize-agent approve"
