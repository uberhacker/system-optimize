#!/usr/bin/env bash
# install.sh - install, update or remove system-optimize.
#
#   ./install.sh               system install: the single file
#                              /usr/local/bin/system-optimize (uses sudo when
#                              needed)
#   ./install.sh --user        the same under ~/.local/bin (no sudo)
#   ./install.sh --prefix DIR  the same under DIR/bin
#   ./install.sh --tree        install the whole checkout (with .git when present)
#                              to PREFIX/share/system-optimize and symlink the
#                              commands into PREFIX/bin; --self-update then follows
#                              a branch instead of the GitHub releases
#   ./install.sh --update      download the configured branch and reinstall from it
#                              (SELF_UPDATE_REPO and SELF_UPDATE_BRANCH from the
#                              environment or the config files)
#   ./install.sh --uninstall   remove the installation and everything the
#                              installer added (add --user or --prefix DIR as it
#                              was installed)
#
# Components: run from a terminal with no options, it asks Full or Custom.
#   --full                     the program, every opt-in step, the tray, its
#                              resource history and agent (when tray/ is here)
#                              and Performance Co-Pilot; what needs a reboot or
#                              a COPR is listed and left out
#   --custom LIST              the program plus LIST: categories (power, memory,
#                              storage, network, display, boot, gpu, helpers),
#                              opt-in steps, tray, extension, monitoring, agent,
#                              scx, pcp, bpftune, lact
#   --list                     the components and what is offered here
#   --apply                    run the chosen steps right after installing
#   --model NAME, --schedule CRON   the agent's model and schedule
#   -y, --yes                  don't ask; -n, --dry-run: show, change nothing
#   --no-color                 plain output (NO_COLOR works too)
#
# The single file is made by build.sh from this checkout; it is plain bash,
# nothing is compiled. An installation made as root, or into a directory only
# root can write, belongs to root and is updated with sudo. A tree
# installation at PREFIX/share/system-optimize is removed when the single
# file is installed over it. A copy of 1.x at PREFIX/bin/system-optimize
# (the curl | sudo tee install) is replaced. Bash completion goes
# to PREFIX/share/bash-completion/completions (or the user's XDG data dir)
# and needs the bash-completion package.
#
# Environment: SO_SUDO (default sudo; empty: never escalate), SO_HOME
# (default $HOME), PREFIX (as --prefix); for --update also SO_TARBALL_URL
# and DOWNLOAD_TIMEOUT (default 300 seconds).

set -euo pipefail

NAME=system-optimize
COMMANDS=()   # extra command names (symlinks); none yet
SRC=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SO_SUDO="${SO_SUDO-sudo}"
SO_HOME="${SO_HOME:-${HOME:-/root}}"
DEFAULT_REPO="https://github.com/uberhacker/system-optimize"
COMP_MARK='# bash completion for system-optimize'
TMP_DIR=""

MODE=system
ACTION=install
LAYOUT=""
INST_SELECT=""
INST_LIST=""
INST_YES=0
INST_DRY_RUN=0
INST_INTERACTIVE=0
INST_APPLY=ask
INST_COLOR=auto
PREFIX="${PREFIX:-}"
[ -z "$PREFIX" ] || MODE=prefix

usage() { sed -n '2,/^# The single file/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --user) MODE=user ;;
    --prefix) [ -n "${2:-}" ] || die "--prefix needs a directory"; PREFIX="$2"; MODE=prefix; shift ;;
    --prefix=*) PREFIX="${1#*=}"; MODE=prefix ;;
    --tree) LAYOUT=tree ;;
    --single|--single-file) LAYOUT=single ;;
    --uninstall|--remove) ACTION=uninstall ;;
    --update) ACTION=update ;;
    --full) INST_SELECT=full ;;
    --custom) [ -n "${2:-}" ] || die "--custom needs a list (install.sh --list shows them)"; INST_SELECT=custom; INST_LIST="$2"; shift ;;
    --custom=*) INST_SELECT=custom; INST_LIST="${1#*=}" ;;
    --list) ACTION=list ;;
    --apply) INST_APPLY=1 ;;
    --no-apply) INST_APPLY=0 ;;
    --model) [ -n "${2:-}" ] || die "--model needs a name"; INST_AGENT_MODEL="$2"; shift ;;
    --schedule) [ -n "${2:-}" ] || die "--schedule needs a cron expression"; INST_AGENT_SCHEDULE="$2"; shift ;;
    -y|--yes) INST_YES=1 ;;
    -n|--dry-run) INST_DRY_RUN=1 ;;
    --interactive) INST_INTERACTIVE=1 ;;
    --no-color) INST_COLOR=never ;;
    --color=*) INST_COLOR="${1#*=}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "install.sh: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [ "$MODE" = user ]; then
  BIN_DIR="$SO_HOME/.local/bin"
  DATA_DIR="${XDG_DATA_HOME:-$SO_HOME/.local/share}"
  SHARE_DIR="$DATA_DIR/$NAME"
  COMP_DIR="$DATA_DIR/bash-completion/completions"
else
  [ "$MODE" = prefix ] || PREFIX=/usr/local
  PREFIX="${PREFIX%/}"
  [ -n "$PREFIX" ] || die "--prefix needs a directory"
  BIN_DIR="$PREFIX/bin"
  SHARE_DIR="$PREFIX/share/$NAME"
  COMP_DIR="$PREFIX/share/bash-completion/completions"
fi
BUNDLE="$BIN_DIR/$NAME"
COMP_FILE="$COMP_DIR/$NAME"

cleanup() { [ -n "$TMP_DIR" ] && rm -rf -- "$TMP_DIR"; return 0; }
trap cleanup EXIT

# priv PATH CMD...: run CMD as root when PATH (or its nearest existing
# parent) is not writable by us.
priv() {
  local probe="$1"; shift
  while [ ! -e "$probe" ]; do probe=$(dirname "$probe"); done
  if [ -w "$probe" ] || [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif [ -n "$SO_SUDO" ] && command -v "${SO_SUDO%% *}" >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    $SO_SUDO "$@"
  else
    die "need root to write to $probe and ${SO_SUDO:-sudo} is not available"
  fi
}

# system_owned: does this installation belong to root (see the header)?
system_owned() {
  [ "$(id -u)" -eq 0 ] && return 0
  local dir="$BIN_DIR"
  while [ ! -e "$dir" ]; do dir=$(dirname "$dir"); done
  [ ! -w "$dir" ]
}

# is_bundle FILE: a single-file build of ours.
is_bundle() {
  [ -f "$1" ] && [ ! -L "$1" ] && grep -q '^SO_BUNDLED=1$' "$1" 2>/dev/null
}

# is_legacy FILE: a copy of system-optimize 1.x (one script, installed with
# curl | sudo tee).
is_legacy() {
  [ -f "$1" ] && [ ! -L "$1" ] && grep -q '^# Linux Hardware-Aware Performance Optimizer' "$1" 2>/dev/null
}

# ours_tree DIR: a tree installation of ours.
ours_tree() {
  [ -d "$1/bin" ] && [ -d "$1/lib" ] && [ -f "$1/bin/$NAME" ]
}

# ours_completion FILE: the completion file we installed (a symlink into
# our tree, or a copy of our completion script).
ours_completion() {
  if [ -L "$1" ]; then
    [[ "$(readlink "$1")" == "$SHARE_DIR/"* ]]
  elif [ -f "$1" ]; then
    [[ "$(head -n1 "$1" 2>/dev/null)" == "$COMP_MARK"* ]]
  else
    return 1
  fi
}

# ours_link LINK: a command symlink pointing at our single file or into
# our tree.
ours_link() {
  local t
  [ -L "$1" ] || return 1
  t=$(readlink "$1")
  case "$t" in
    "$NAME"|"$BUNDLE"|"$SHARE_DIR"/*|"../share/$NAME"/*) return 0 ;;
  esac
  t=$(readlink -f -- "$1" 2>/dev/null) || return 1
  case "$t" in
    "$(readlink -f -- "$BUNDLE" 2>/dev/null || echo "$BUNDLE")") return 0 ;;
    "$(readlink -f -- "$SHARE_DIR" 2>/dev/null || echo "$SHARE_DIR")"/*) return 0 ;;
  esac
  return 1
}

path_note() {
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "note: $BIN_DIR is not on your PATH" ;;
  esac
}

# link_commands TARGET: the command symlinks in BIN_DIR, pointing at TARGET.
# A regular file of the same name is somebody else's and stays.
link_commands() {
  local target="$1" cmd link
  for cmd in "${COMMANDS[@]+"${COMMANDS[@]}"}"; do
    link="$BIN_DIR/$cmd"
    if [ -e "$link" ] && [ ! -L "$link" ]; then
      echo "note: $link exists and is not a symlink; left alone (use: $NAME ${cmd#cbs-} ...)"
      continue
    fi
    priv "$BIN_DIR" ln -sfn "$target" "$link"
  done
}

# install_completion copy|link
install_completion() {
  local src="$SRC/completions/$NAME.bash"
  [ -f "$src" ] || return 0
  if [ -e "$COMP_FILE" ] && ! ours_completion "$COMP_FILE"; then
    echo "note: $COMP_FILE exists and is not ours; bash completion not installed"
    return 0
  fi
  priv "$COMP_DIR" mkdir -p "$COMP_DIR"
  if [ "$1" = link ]; then
    priv "$COMP_FILE" ln -sfn "$SHARE_DIR/completions/$NAME.bash" "$COMP_FILE"
  else
    priv "$COMP_FILE" rm -f -- "$COMP_FILE"
    priv "$COMP_FILE" cp "$src" "$COMP_FILE"
    priv "$COMP_FILE" chmod 0644 "$COMP_FILE"
  fi
  echo "completion: $COMP_FILE (new shells; needs the bash-completion package)"
}

# remove_tree: a previous tree installation at SHARE_DIR, when the single
# file replaces it.
remove_tree() {
  [ -d "$SHARE_DIR" ] || return 0
  if [ "$(readlink -f -- "$SRC")" = "$(readlink -f -- "$SHARE_DIR")" ]; then
    echo "note: $SHARE_DIR left in place (install.sh is running from it)"
    return 0
  fi
  if ours_tree "$SHARE_DIR"; then
    priv "$SHARE_DIR" rm -rf "$SHARE_DIR"
    echo "removed the previous tree installation $SHARE_DIR"
  else
    echo "note: $SHARE_DIR does not look like a $NAME installation; left alone"
  fi
}

install_single() {
  local staged ver legacy=0
  { [ -f "$SRC/bin/$NAME" ] && [ -f "$SRC/build.sh" ]; } ||
    die "run install.sh from a $NAME checkout (no bin/$NAME and build.sh in $SRC)"
  if is_legacy "$BUNDLE"; then
    legacy=1
  elif [ -f "$BUNDLE" ] && [ ! -L "$BUNDLE" ] && ! is_bundle "$BUNDLE"; then
    die "$BUNDLE exists and is not $NAME; move it away first"
  fi
  TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/$NAME.install.XXXXXX")
  bash "$SRC/build.sh" "$TMP_DIR/$NAME" >/dev/null || die "build.sh failed"
  priv "$BIN_DIR" mkdir -p "$BIN_DIR"
  # Stage next to the target so the final step is one rename.
  staged="$BIN_DIR/.$NAME.new.$$"
  priv "$BIN_DIR" cp "$TMP_DIR/$NAME" "$staged"
  priv "$BIN_DIR" chmod 0755 "$staged"
  if ! priv "$BIN_DIR" mv -f -- "$staged" "$BUNDLE"; then
    priv "$BIN_DIR" rm -f -- "$staged"
    die "could not install $BUNDLE"
  fi
  link_commands "$NAME"
  remove_tree
  install_completion copy
  ver=$(sed -n "s/^SO_BUNDLE_VERSION='\(.*\)'\$/\1/p" "$BUNDLE" | head -n1)
  [ "$legacy" = 0 ] || echo "replaced $NAME 1.x at $BUNDLE (its settings files are cleaned up by the next run)"
  echo "installed $NAME ${ver:-?} (single file) to $BUNDLE"
  [ ${#COMMANDS[@]} -eq 0 ] || echo "commands:  ${COMMANDS[*]} (in $BIN_DIR)"
  path_note
}

install_tree() {
  local staging old item f
  { [ -f "$SRC/bin/$NAME" ] && [ -d "$SRC/lib" ]; } ||
    die "run install.sh from a $NAME checkout (no bin/$NAME and lib/ in $SRC)"
  if [ -f "$BUNDLE" ] && [ ! -L "$BUNDLE" ] && ! is_bundle "$BUNDLE" && ! is_legacy "$BUNDLE"; then
    die "$BUNDLE exists and is not $NAME; move it away first"
  fi
  staging="$(dirname "$SHARE_DIR")/.$NAME.install.$$"
  old="$(dirname "$SHARE_DIR")/.$NAME.old.$$"
  priv "$SHARE_DIR" mkdir -p "$(dirname "$SHARE_DIR")"
  priv "$BIN_DIR" mkdir -p "$BIN_DIR"
  priv "$SHARE_DIR" rm -rf "$staging"
  priv "$SHARE_DIR" mkdir -p "$staging"
  # Everything but test vendoring and builds; .git is kept for --self-update.
  for item in bin lib completions docs VERSION LICENSE README.md CONTRIBUTING.md \
              config.example install.sh build.sh .git; do
    [ -e "$SRC/$item" ] || continue
    priv "$SHARE_DIR" cp -a "$SRC/$item" "$staging/"
  done
  if system_owned; then
    priv "$SHARE_DIR" chown -R 0:0 "$staging"
  fi
  if [ -e "$SHARE_DIR" ]; then
    priv "$SHARE_DIR" rm -rf "$old"
    priv "$SHARE_DIR" mv "$SHARE_DIR" "$old"
  fi
  priv "$SHARE_DIR" mv "$staging" "$SHARE_DIR"
  priv "$SHARE_DIR" rm -rf "$old"
  for f in "bin/$NAME" install.sh build.sh; do
    [ -f "$SHARE_DIR/$f" ] && priv "$SHARE_DIR" chmod 0755 "$SHARE_DIR/$f"
  done
  if is_bundle "$BUNDLE"; then
    priv "$BIN_DIR" rm -f -- "$BUNDLE"
    echo "removed the previous single file $BUNDLE"
  elif is_legacy "$BUNDLE"; then
    priv "$BIN_DIR" rm -f -- "$BUNDLE"
    echo "replaced $NAME 1.x at $BUNDLE (its settings files are cleaned up by the next run)"
  fi
  priv "$BIN_DIR" ln -sfn "$SHARE_DIR/bin/$NAME" "$BUNDLE"
  link_commands "$SHARE_DIR/bin/$NAME"
  install_completion link
  echo "installed $NAME $(tr -d '[:space:]' < "$SHARE_DIR/VERSION") (tree) to $SHARE_DIR"
  echo "command:   $BIN_DIR/$NAME"
  path_note
}

uninstall() {
  local cmd link removed=0
  if [ -e "$COMP_FILE" ] || [ -L "$COMP_FILE" ]; then
    if ours_completion "$COMP_FILE"; then
      priv "$COMP_FILE" rm -f -- "$COMP_FILE"
      echo "removed $COMP_FILE"
      removed=1
    else
      echo "note: $COMP_FILE is not ours; left alone"
    fi
  fi
  for cmd in "${COMMANDS[@]+"${COMMANDS[@]}"}"; do
    link="$BIN_DIR/$cmd"
    if [ -L "$link" ]; then
      if ours_link "$link"; then
        priv "$link" rm -f -- "$link"
        echo "removed $link"
        removed=1
      else
        echo "note: $link does not point at $NAME; left alone"
      fi
    elif [ -e "$link" ]; then
      echo "note: $link is not a symlink; left alone"
    fi
  done
  if [ -L "$BUNDLE" ]; then
    if ours_link "$BUNDLE"; then
      priv "$BUNDLE" rm -f -- "$BUNDLE"
      echo "removed $BUNDLE"
      removed=1
    else
      echo "note: $BUNDLE does not point at $NAME; left alone"
    fi
  elif is_bundle "$BUNDLE"; then
    priv "$BUNDLE" rm -f -- "$BUNDLE"
    echo "removed $BUNDLE"
    removed=1
  elif [ -e "$BUNDLE" ]; then
    echo "note: $BUNDLE is not a single-file build of $NAME; left alone"
  fi
  if [ -d "$SHARE_DIR" ]; then
    if ours_tree "$SHARE_DIR"; then
      priv "$SHARE_DIR" rm -rf "$SHARE_DIR"
      echo "removed $SHARE_DIR"
      removed=1
    else
      echo "note: $SHARE_DIR does not look like a $NAME installation; left alone"
    fi
  fi
  [ "$removed" = 1 ] || echo "nothing of $NAME found under $BIN_DIR"
}

# read_config FILE: SELF_UPDATE_REPO, SELF_UPDATE_BRANCH and DOWNLOAD_TIMEOUT
# from a KEY=value file into CFG_REPO, CFG_BRANCH and CFG_TIMEOUT. The file
# is parsed, never sourced; values that do not look right are ignored.
read_config() {
  local line key value
  [ -r "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ "$line" =~ ^(SELF_UPDATE_REPO|SELF_UPDATE_BRANCH|DOWNLOAD_TIMEOUT)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then
      value="${BASH_REMATCH[1]}"
    fi
    case "$key" in
      SELF_UPDATE_REPO)
        if [[ "$value" =~ ^(https://|file:///)[A-Za-z0-9._~:/?#@!$\&\'()*+,\;=%-]+$ ]]; then CFG_REPO="$value"; fi ;;
      SELF_UPDATE_BRANCH)
        if [[ "$value" =~ ^[A-Za-z0-9_./-]*$ ]] && [[ "$value" != *..* ]]; then CFG_BRANCH="$value"; fi ;;
      DOWNLOAD_TIMEOUT)
        if [[ "$value" =~ ^[0-9]{1,9}$ ]]; then CFG_TIMEOUT="$value"; fi ;;
    esac
  done < "$1"
}

# remote_default_branch URL: the remote's HEAD branch, through git.
remote_default_branch() {
  local out tmo=""
  command -v git >/dev/null 2>&1 || return 1
  command -v timeout >/dev/null 2>&1 && tmo="timeout 60"
  # shellcheck disable=SC2086
  out=$($tmo git ls-remote --symref "$1" HEAD 2>/dev/null </dev/null) || return 1
  out=$(printf '%s\n' "$out" | sed -n 's|^ref: refs/heads/\([^[:space:]]*\)[[:space:]]*HEAD$|\1|p' | head -n1)
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

update() {
  local repo branch timeout url top
  local -a args=()
  CFG_REPO="" CFG_BRANCH="" CFG_TIMEOUT=""
  read_config "${SO_SYSTEM_CONFIG:-/etc/$NAME.conf}"
  read_config "${SO_CONFIG_FILE:-${XDG_CONFIG_HOME:-$SO_HOME/.config}/$NAME/config}"
  # Precedence as in the program: environment > files > default.
  repo="${SELF_UPDATE_REPO:-${CFG_REPO:-$DEFAULT_REPO}}"
  repo="${repo%/}"
  repo="${repo%.git}"
  branch="${SELF_UPDATE_BRANCH:-$CFG_BRANCH}"
  timeout="${DOWNLOAD_TIMEOUT:-${CFG_TIMEOUT:-300}}"
  if [ -n "${SO_TARBALL_URL:-}" ]; then
    url="$SO_TARBALL_URL"
  else
    if [ -z "$branch" ]; then
      branch=$(remote_default_branch "$repo") || branch=main
    fi
    url="$repo/archive/refs/heads/$branch.tar.gz"
  fi
  case "$url" in
    https://*) ;;
    file:///*) [ "${SYSTEM_OPTIMIZE_ALLOW_FILE_SOURCE:-0}" = 1 ] || die "refusing a non-https source: $url" ;;
    *) die "refusing a non-https source: $url" ;;
  esac
  command -v curl >/dev/null 2>&1 || die "curl is required for --update"
  TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/$NAME.update.XXXXXX")
  echo "downloading $url"
  curl -fsSL --proto '=https,file' --proto-redir '=https' --retry 2 --connect-timeout 20 \
    --max-time "$timeout" -o "$TMP_DIR/src.tar.gz" "$url" || die "download failed: $url"
  mkdir -p "$TMP_DIR/x"
  tar -xzf "$TMP_DIR/src.tar.gz" -C "$TMP_DIR/x" || die "could not extract the tarball"
  top=$(find "$TMP_DIR/x" -mindepth 1 -maxdepth 1 -type d | head -n1)
  { [ -n "$top" ] && [ -f "$top/install.sh" ] && [ -f "$top/bin/$NAME" ]; } ||
    die "the tarball does not contain $NAME (no install.sh and bin/$NAME); nothing changed"
  bash -n "$top/bin/$NAME" || die "the downloaded bin/$NAME does not parse; nothing changed"
  # Without --tree or --single, an existing tree installation stays a tree.
  if [ -z "$LAYOUT" ] && ours_tree "$SHARE_DIR" && ! is_bundle "$BUNDLE"; then
    LAYOUT=tree
    echo "keeping the tree layout of $SHARE_DIR (pass --single to switch to the single file)"
  fi
  case "$MODE" in
    user) args+=(--user) ;;
    prefix) args+=(--prefix "$PREFIX") ;;
  esac
  [ "$LAYOUT" = tree ] && args+=(--tree)
  env SO_SUDO="$SO_SUDO" SO_HOME="$SO_HOME" bash "$top/install.sh" ${args[@]+"${args[@]}"} </dev/null
}

# The component installer (Full, Custom, the manifest).
# shellcheck source=lib/install/installer.sh
. "$SRC/lib/install/installer.sh"

# From a terminal with no component options: the menu.
if [ "$ACTION" = install ] && [ -z "$INST_SELECT" ] && [ "$INST_YES" != 1 ] \
  && { [ "$INST_INTERACTIVE" = 1 ] || { [ -t 0 ] && [ -t 1 ]; }; }; then
  INST_INTERACTIVE=1
  INST_SELECT=menu
fi

case "$ACTION" in
  uninstall)
    inst_uninstall
    if [ "$INST_DRY_RUN" = 1 ]; then inst_dry "remove $BUNDLE and its completion"; else uninstall; fi ;;
  update) update ;;
  list) inst_list ;;
  install)
    if [ -n "$INST_SELECT" ] || [ "$INST_DRY_RUN" = 1 ]; then
      inst_run
    elif [ "$LAYOUT" = tree ]; then install_tree; else install_single; fi ;;
esac
