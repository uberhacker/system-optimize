#!/usr/bin/env bash
# lib/tweaks/pkgs.sh - opt-in steps "pkgmgr" and "ccache": faster package
# downloads and a compiler cache (new in 2.1).
#
# pkgmgr  Raises the number of parallel downloads to PARALLEL_DOWNLOADS
#         (default 10, kept between 1 and 20; a higher value already set is
#         kept):
#           dnf 4 and dnf5  /etc/dnf/dnf.conf [main]
#                           max_parallel_downloads=N (dnf's maximum is 20)
#                           and fastestmirror=True (dnf5 implements it as
#                           well: libdnf5 passes it to librepo); an explicit
#                           fastestmirror=False is the owner's and stays
#           pacman          /etc/pacman.conf [options] ParallelDownloads = N
#                           (the commented default line is uncommented)
#           zypper          /etc/zypp/zypp.conf [main]
#                           download.max_concurrent_connections = N (when
#                           only /usr/etc/zypp/zypp.conf exists, as on
#                           current Tumbleweed, it is copied to /etc first)
#         apt, apk, xbps and emerge are skipped: apt and apk already fetch
#         in parallel or have no such setting, xbps has none, and emerge's
#         parallel fetching is a FEATURES choice for the owner. rpm-ostree
#         does not read dnf.conf. Every other byte of the file is kept.
# ccache  Installs ccache from the official repositories. Where the
#         package already puts its compiler wrappers first in PATH for
#         login shells (Fedora's /etc/profile.d/ccache.sh), that is all;
#         elsewhere /etc/profile.d/system-optimize-ccache.sh adds the
#         wrapper directory (/usr/lib/ccache/bin on Arch, Alpine, Void and
#         Gentoo, /usr/lib64/ccache on openSUSE, /usr/lib/ccache on Debian)
#         to the front of PATH once. It applies to new login shells.
#
# Undo: the configuration files are restored from the snapshot (or
# removed), and a package this step installed is removed.

step_def pkgmgr opt-in pkgmgr_step '' \
  "Faster package downloads" \
  "Parallel downloads (PARALLEL_DOWNLOADS, default 10) for dnf, pacman and zypper." \
  helpers

step_def ccache opt-in ccache_step '' \
  "Compiler cache (ccache)" \
  "Installs ccache and puts its compiler wrappers first in PATH for login shells." \
  helpers

SO_CCACHE_PROFILE=/etc/profile.d/system-optimize-ccache.sh

# ---------------------------------------------------------------------------
# INI-style files
# ---------------------------------------------------------------------------
# pkgs_ini_get FILE SECTION KEYRE: the value of the first active KEYRE line
# in [SECTION] (KEYRE is an ERE for the key name), or failure.
pkgs_ini_get() {
  awk -v sec="$2" -v key="$3" '
    /^[[:space:]]*\[[^]]*\][[:space:]]*$/ {
      name = $0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", name)
      insec = (name == sec); next
    }
    insec && $0 ~ ("^[[:space:]]*" key "[[:space:]]*=") {
      v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v)
      print v; found = 1; exit
    }
    END { exit !found }' "$1"
}

# pkgs_ini_set IN OUT SECTION KEYRE LINE: copy IN to OUT with LINE in
# [SECTION]: in place of the first active KEYRE line there, else of the
# first commented one (#KEYRE = ...), else after the section's last
# non-blank line; a missing section is added at the end. Every other line
# is copied unchanged.
pkgs_ini_set() {
  local in="$1" out="$2" sec="$3" key="$4" line="$5" mode=insert
  if pkgs_ini_get "$in" "$sec" "$key" >/dev/null; then
    mode=active
  elif awk -v sec="$sec" -v key="$key" '
      /^[[:space:]]*\[[^]]*\][[:space:]]*$/ {
        name = $0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", name); insec = (name == sec); next
      }
      insec && $0 ~ ("^[[:space:]]*#[[:space:]]*" key "[[:space:]]*=") { found = 1; exit }
      END { exit !found }' "$in"; then
    mode=commented
  fi
  awk -v sec="$sec" -v key="$key" -v line="$line" -v mode="$mode" '
    function flush_blanks(   i) { for (i = 0; i < nb; i++) print blanks[i]; nb = 0 }
    /^[[:space:]]*\[[^]]*\][[:space:]]*$/ {
      if (insec && !done) { print line; done = 1 }
      flush_blanks()
      name = $0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", name)
      insec = (name == sec); if (insec) seen = 1
      print; next
    }
    insec && !done && /^[[:space:]]*$/ { blanks[nb++] = $0; next }
    {
      flush_blanks()
      if (insec && !done) {
        if (mode == "active" && $0 ~ ("^[[:space:]]*" key "[[:space:]]*=")) { print line; done = 1; next }
        if (mode == "commented" && $0 ~ ("^[[:space:]]*#[[:space:]]*" key "[[:space:]]*=")) { print line; done = 1; next }
      }
      print
    }
    END {
      if (insec && !done) { print line; done = 1 }
      flush_blanks()
      if (!seen) { if (NR > 0) print ""; print "[" sec "]"; print line }
    }' "$in" > "$out"
}

# pkgs_want: PARALLEL_DOWNLOADS kept between 1 and 20.
pkgs_want() {
  local n
  n=$(cfg PARALLEL_DOWNLOADS)
  [[ "$n" =~ ^[0-9]+$ ]] || n=10
  n=$((10#$n))
  if [ "$n" -lt 1 ]; then log_warn "PARALLEL_DOWNLOADS=$n is below 1; using 1"; n=1; fi
  if [ "$n" -gt 20 ]; then log_warn "PARALLEL_DOWNLOADS=$n is above 20; using 20"; n=20; fi
  printf '%s\n' "$n"
}

# pkgs_raise IN OUT SECTION KEYRE LINE N: pkgs_ini_set unless the value set
# already is N or more. Returns 0 when OUT differs from IN, 3 when it was
# left as it is.
pkgs_raise() {
  local in="$1" out="$2" sec="$3" key="$4" line="$5" n="$6" cur
  if cur=$(pkgs_ini_get "$in" "$sec" "$key") && [[ "$cur" =~ ^[0-9]+$ ]] && [ "$((10#$cur))" -ge "$n" ]; then
    log_detail "$key is $cur already (wanted $n); kept"
    cp -- "$in" "$out"
    return 3
  fi
  pkgs_ini_set "$in" "$out" "$sec" "$key" "$line" || return 1
  return 0
}

pkgmgr_step() {
  local n file src a b changed=0 rc=0 fm what
  case "$SO_PKG_MANAGER" in
    dnf) file=/etc/dnf/dnf.conf ;;
    pacman) file=/etc/pacman.conf ;;
    zypper) file=/etc/zypp/zypp.conf ;;
    apt) step_skip "apt has no parallel-downloads setting (it already fetches from different servers at once)"; return 0 ;;
    apk) step_skip "apk has no parallel-downloads setting"; return 0 ;;
    xbps) step_skip "xbps has no parallel-downloads setting"; return 0 ;;
    emerge) step_skip "Gentoo: parallel fetching is a FEATURES choice in make.conf; left to you"; return 0 ;;
    rpm-ostree) step_skip "rpm-ostree does not read dnf.conf"; return 0 ;;
    *) step_skip "no package manager to tune ($SO_PKG_MANAGER)"; return 0 ;;
  esac
  n=$(pkgs_want)
  src=$(so_path "$file")
  if [ ! -f "$src" ] && [ "$SO_PKG_MANAGER" = zypper ] && [ -f "$(so_path /usr/etc/zypp/zypp.conf)" ]; then
    src=$(so_path /usr/etc/zypp/zypp.conf)
  fi
  if ! a=$(tmp_file) || ! b=$(tmp_file); then step_fail "could not create a temporary file"; return 1; fi
  if [ -f "$src" ]; then cp -- "$src" "$a" || { step_fail "could not read $file"; return 1; }
  elif [ "$SO_PKG_MANAGER" = pacman ]; then step_skip "no $file"; return 0
  else : > "$a"
  fi
  case "$SO_PKG_MANAGER" in
    dnf)
      pkgs_raise "$a" "$b" main max_parallel_downloads "max_parallel_downloads=$n" "$n" || rc=$?
      [ "$rc" = 0 ] || [ "$rc" = 3 ] || { step_fail "could not edit $file"; return 1; }
      cp -- "$b" "$a"
      if fm=$(pkgs_ini_get "$a" main fastestmirror); then
        case "${fm,,}" in
          1|true|yes|on) ;;
          *) log_detail "fastestmirror=$fm is set in $file; kept" ;;
        esac
      else
        pkgs_ini_set "$a" "$b" main fastestmirror "fastestmirror=True" || { step_fail "could not edit $file"; return 1; }
        cp -- "$b" "$a"
      fi
      what="max_parallel_downloads=$n and fastestmirror" ;;
    pacman)
      pkgs_raise "$a" "$b" options ParallelDownloads "ParallelDownloads = $n" "$n" || rc=$?
      [ "$rc" = 0 ] || [ "$rc" = 3 ] || { step_fail "could not edit $file"; return 1; }
      cp -- "$b" "$a"
      what="ParallelDownloads = $n" ;;
    zypper)
      pkgs_raise "$a" "$b" main 'download\.max_concurrent_connections' "download.max_concurrent_connections = $n" "$n" || rc=$?
      [ "$rc" = 0 ] || [ "$rc" = 3 ] || { step_fail "could not edit $file"; return 1; }
      cp -- "$b" "$a"
      what="download.max_concurrent_connections = $n" ;;
  esac
  rc=0
  install_file "$file" 0644 < "$a" || rc=$?
  case "$rc" in
    0) changed=1 ;;
    3) ;;
    *) step_fail "could not write $file"; return 1 ;;
  esac
  if [ "$changed" = 0 ]; then
    step_ok "$file already allows $n or more parallel downloads"
  elif [ "$SO_DRY_RUN" = 1 ]; then
    step_dry "would set $what in $file"
  else
    step_updated "$what in $file"
  fi
}

# ---------------------------------------------------------------------------
# ccache
# ---------------------------------------------------------------------------
# pkgs_can_query: the package manager can say what is installed.
pkgs_can_query() {
  case "$SO_PKG_MANAGER" in
    dnf|zypper|rpm-ostree|apt|pacman|apk|xbps) return 0 ;;
    *) return 1 ;;
  esac
}

# ccache_distro_profile: a profile.d script of the package's own that puts
# the wrappers in PATH (printed), or failure.
ccache_distro_profile() {
  local f
  for f in "$(so_path /etc/profile.d)"/*.sh; do
    [ -f "$f" ] || continue
    [ "${f##*/}" = "${SO_CCACHE_PROFILE##*/}" ] && continue
    if grep -qE '/usr/lib(64)?/ccache' "$f" 2>/dev/null; then
      printf '/etc/profile.d/%s\n' "${f##*/}"
      return 0
    fi
  done
  return 1
}

# ccache_dir: the compiler wrapper directory (the one that exists, else the
# usual one for this package manager).
ccache_dir() {
  local d
  for d in /usr/lib/ccache/bin /usr/lib64/ccache /usr/lib/ccache; do
    [ -d "$(so_path "$d")" ] && { printf '%s\n' "$d"; return 0; }
  done
  case "$SO_PKG_MANAGER" in
    dnf|zypper|rpm-ostree) echo /usr/lib64/ccache ;;
    apt) echo /usr/lib/ccache ;;
    *) echo /usr/lib/ccache/bin ;;
  esac
}

ccache_profile_content() {
  cat <<EOF
# Written by system-optimize ($(version_string)). Undo: system-optimize --undo
# ccache's compiler wrappers first in PATH, once.
case ":\$PATH:" in
  *":$1:"*) ;;
  *) PATH="$1:\$PATH"; export PATH ;;
esac
EOF
}

ccache_step() {
  local installed=1 own dir rc=0 note=""
  if ! pkg_installed ccache && { pkgs_can_query || ! has_cmd ccache; }; then
    installed=0
    if ! pkg_can_install; then
      step_skip "cannot install packages with $SO_PKG_MANAGER here; $(pkg_hand_hint ccache)"
      return 0
    fi
    pkg_add ccache || { step_fail "could not install ccache"; return 1; }
  fi
  if [ "$SO_DRY_RUN" = 1 ] && [ "$installed" = 0 ]; then
    step_dry "would install ccache and put its compiler wrappers first in PATH for login shells (unless the package does)"
    return 0
  fi
  if own=$(ccache_distro_profile); then
    note="the package's $own puts its wrappers first in PATH"
    if [ "$installed" = 0 ]; then step_updated "installed ccache; $note"
    else step_ok "ccache installed; $note"
    fi
    return 0
  fi
  dir=$(ccache_dir)
  install_file "$SO_CCACHE_PROFILE" 0644 < <(ccache_profile_content "$dir") || rc=$?
  case "$rc" in
    0)
      if [ "$SO_DRY_RUN" = 1 ]; then step_dry "would put $dir first in PATH in $SO_CCACHE_PROFILE"
      else step_updated "$([ "$installed" = 0 ] && echo "installed ccache; ")$dir first in PATH for new login shells ($SO_CCACHE_PROFILE)"
      fi ;;
    3)
      if [ "$installed" = 0 ]; then step_updated "installed ccache; $dir already first in PATH"
      else step_ok "ccache installed and $dir first in PATH"
      fi ;;
    *) step_fail "could not write $SO_CCACHE_PROFILE"; return 1 ;;
  esac
}
