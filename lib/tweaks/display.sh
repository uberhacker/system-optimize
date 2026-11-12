#!/usr/bin/env bash
# lib/tweaks/display.sh - opt-in steps "fonts" and "display".
#
# fonts: font hinting and subpixel rendering, from FONT_HINTING (none,
# slight, medium, full; default slight) and FONT_SUBPIXEL (none, rgb, bgr,
# vrgb, vbgr; default rgb). Every program that draws text with fontconfig
# reads /etc/fonts/conf.d/99-system-optimize.conf; GNOME draws its own
# interface from org.gnome.desktop.interface (font-hinting,
# font-antialiasing, font-rgba-order), so for a GNOME desktop user those
# three keys are set too. KDE reads fontconfig for its applications and has
# its own Fonts page in System Settings, which is left alone. Skipped where
# there is no fontconfig (/etc/fonts missing: servers, minimal containers).
# The conf.d file sorts after 50-user.conf, so it wins over a user's own
# ~/.config/fontconfig settings for these five properties.
#
# display: GNOME or KDE Plasma on Wayland only (X11 and other desktops are
# skipped with the reason).
#   GNOME  adds 'scale-monitor-framebuffer' (fractional scaling in Settings)
#          and 'variable-refresh-rate' (a VRR switch in Settings > Displays)
#          to org.gnome.mutter experimental-features, keeping what is there.
#          Only the names the installed Mutter's schema still lists are
#          added (gsettings range): from GNOME 48 VRR is a regular setting,
#          and gsettings refuses the whole list when one name is unknown.
#          GNOME 51 has no experimental-features key at all: both are
#          built in, and the step reports itself as in place.
#          Display modes are not changed on GNOME (Mutter keeps them in the
#          user's monitors.xml and the Settings app is the safe way to pick
#          one); the step reports each screen's refresh rate and the highest
#          one it offers at the same resolution.
#   KDE    with kscreen-doctor, for each enabled output: the VRR policy
#          "automatic" where the output supports VRR and its policy is
#          "never" ("always" is a stronger choice and is kept), and the mode
#          with the highest refresh rate at the current resolution.
#          KScreen keeps both in the user's configuration.
#
# Both steps change the desktop user's settings as that user, never as
# root. Undo: the fontconfig file is restored or removed (kind file), the
# gsettings keys get their old values (kind gsettings), and kscreen-doctor
# puts each output's VRR policy and mode back (kind kscreen,
# "USER:OUTPUT:vrrpolicy" and "USER:OUTPUT:mode" with the mode's name,
# WIDTHxHEIGHT@RATE).

step_def fonts opt-in fonts_step 'desktop' \
  "Font hinting and subpixel rendering" \
  "Sets FONT_HINTING (slight) and FONT_SUBPIXEL (rgb) for fontconfig and the GNOME desktop." \
  display

step_def display opt-in display_step 'desktop' \
  "Fractional scaling, variable refresh, highest refresh rate" \
  "GNOME or KDE on Wayland only: fractional scaling, VRR and the highest refresh rate the screen offers." \
  display

SO_FONTS_CONF=/etc/fonts/conf.d/99-system-optimize.conf

# ---------------------------------------------------------------------------
# fonts
# ---------------------------------------------------------------------------
# display_fonts_content HINTING SUBPIXEL: the fontconfig file.
display_fonts_content() {
  local hinting="$1" subpixel="$2" hint=true
  [ "$hinting" = none ] && hint=false
  cat <<EOF
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<!-- Written by system-optimize ($(version_string | sed 's/--*/-/g')); its undo option removes it. -->
<!-- Font smoothing for every program that uses fontconfig. -->
<fontconfig>
  <match target="font">
    <edit name="antialias" mode="assign"><bool>true</bool></edit>
    <edit name="hinting" mode="assign"><bool>$hint</bool></edit>
    <edit name="hintstyle" mode="assign"><const>hint$hinting</const></edit>
    <edit name="rgba" mode="assign"><const>$subpixel</const></edit>
EOF
  if [ "$subpixel" != none ]; then
    printf '%s\n' '    <edit name="lcdfilter" mode="assign"><const>lcddefault</const></edit>'
  fi
  printf '%s\n' '  </match>' '</fontconfig>'
}

# _display_gs USER SCHEMA KEY VALUE: gsettings_set, counting into the
# caller's changed/failed; a key this GNOME does not have is passed over.
_display_gs() {
  local rc=0
  if ! gsettings_get "$1" "$2" "$3" >/dev/null; then
    log_detail "gsettings: no $2 $3 here; left alone"
    return 0
  fi
  gsettings_set "$@" || rc=$?
  case "$rc" in
    0) changed=$((changed + 1)) ;;
    3) ;;
    *) failed=$((failed + 1)) ;;
  esac
}

fonts_step() {
  local hinting subpixel user rc=0 changed=0 failed=0 what aa
  hinting=$(cfg FONT_HINTING); hinting="${hinting:-slight}"
  subpixel=$(cfg FONT_SUBPIXEL); subpixel="${subpixel:-rgb}"
  if [ ! -d "$(so_path /etc/fonts)" ]; then
    step_skip "no fontconfig here (/etc/fonts is missing)"
    return 0
  fi
  install_file "$SO_FONTS_CONF" 0644 < <(display_fonts_content "$hinting" "$subpixel") || rc=$?
  case "$rc" in
    0) changed=$((changed + 1)) ;;
    3) ;;
    *) step_fail "could not write $SO_FONTS_CONF"; return 1 ;;
  esac
  what="fontconfig"
  user=$(desktop_user)
  if [ -n "$user" ] && [ "$(desktop_kind)" = gnome ] && has_cmd gsettings; then
    what+=" and GNOME for $user"
    aa=grayscale
    [ "$subpixel" = none ] || aa=rgba
    _display_gs "$user" org.gnome.desktop.interface font-hinting "'$hinting'"
    _display_gs "$user" org.gnome.desktop.interface font-antialiasing "'$aa'"
    if [ "$subpixel" != none ]; then
      _display_gs "$user" org.gnome.desktop.interface font-rgba-order "'$subpixel'"
    fi
  fi
  if [ "$failed" -gt 0 ]; then
    step_warn "$failed GNOME font setting(s) could not be changed; $SO_FONTS_CONF is in place"
  elif [ "$changed" = 0 ]; then
    step_ok "hinting $hinting, subpixel $subpixel already set ($what)"
  elif [ "$SO_DRY_RUN" = 1 ]; then
    step_dry "would set hinting $hinting, subpixel $subpixel ($what)"
  else
    step_updated "hinting $hinting, subpixel $subpixel ($what); programs pick it up when they start"
  fi
}

# ---------------------------------------------------------------------------
# display: GNOME
# ---------------------------------------------------------------------------
SO_DISPLAY_MUTTER_FEATURES="scale-monitor-framebuffer variable-refresh-rate"

# display_strv_items VALUE: the entries of a GVariant string array
# ("['a', 'b']" or "@as []"), one per line.
display_strv_items() {
  grep -o "'[^']*'" <<< "$1" | tr -d "'"
}

# display_strv LIST: a GVariant string array from a space-separated LIST.
display_strv() {
  local x out=""
  for x in $1; do out+="${out:+, }'$x'"; done
  printf '[%s]\n' "$out"
}

# display_gnome_rates USER: one line per screen, "CONNECTOR WxH CURRENT MAX"
# (refresh rates in Hz, MAX the highest at the current resolution), from
# Mutter's DisplayConfig (read only).
display_gnome_rates() {
  local out
  has_cmd gdbus || return 1
  out=$(so_as_user "$1" gdbus call --session --dest org.gnome.Mutter.DisplayConfig \
    --object-path /org/gnome/Mutter/DisplayConfig \
    --method org.gnome.Mutter.DisplayConfig.GetCurrentState 2>/dev/null) || return 1
  # Each physical monitor starts with "(('CONNECTOR', ...". Its modes are
  # ('WxH@RATE', W, H, RATE, scale, [scales], {properties}).
  printf '%s\n' "$out" | sed "s/(('/\\
(('/g" | awk -v q="'" '
    function fmt(r) { r = sprintf("%.2f", r); sub(/0+$/, "", r); sub(/\.$/, "", r); return r }
    index($0, "((" q) == 1 {
      line = $0
      split(line, p, q); conn = p[2]
      cur = ""; curres = ""; n = 0
      while (match(line, "\\(" q "[0-9]+x[0-9]+@[0-9.]+" q ", [^{]*[{][^}]*[}]")) {
        m = substr(line, RSTART, RLENGTH)
        line = substr(line, RSTART + RLENGTH)
        split(m, p, q); split(p[2], a, "@")
        n++; res[n] = a[1]; rate[n] = a[2] + 0
        if (index(m, q "is-current" q ": <true>")) { cur = rate[n]; curres = a[1] }
      }
      if (curres == "") next
      max = cur
      for (i = 1; i <= n; i++) if (res[i] == curres && rate[i] > max) max = rate[i]
      printf "%s %s %s %s\n", conn, curres, fmt(cur), fmt(max)
    }'
}

# _display_gnome_report USER: the refresh-rate sentence for the step note.
_display_gnome_report() {
  local conn res cur max out="" better=0
  while read -r conn res cur max; do
    [ -n "$conn" ] || continue
    out+="${out:+; }$conn $res at $cur Hz"
    if [ "$cur" != "$max" ]; then
      out+=" (up to $max Hz available)"
      better=1
    fi
  done < <(display_gnome_rates "$1")
  if [ -z "$out" ]; then
    printf '%s\n' "pick the highest refresh rate in Settings > Displays > Refresh Rate"
  elif [ "$better" = 1 ]; then
    printf '%s\n' "$out; pick the highest in Settings > Displays > Refresh Rate"
  else
    printf '%s\n' "$out (the highest offered)"
  fi
}

# _display_gnome_allowed USER: the names Mutter's schema accepts in
# experimental-features, one per line; nothing when gsettings cannot say
# (then every name is tried, as before).
_display_gnome_allowed() {
  so_as_user "$1" gsettings range org.gnome.mutter experimental-features 2>/dev/null | sed -n "s/^'\(.*\)'$/\1/p"
}

_display_gnome() {
  local user="$1" cur want f items rc=0 missing="" regular="" allowed report
  if ! has_cmd gsettings; then
    step_skip "GNOME without gsettings for $user"
    return 0
  fi
  if ! cur=$(gsettings_get "$user" org.gnome.mutter experimental-features); then
    # Mutter 51 dropped the key: both are regular settings there. With the
    # schema present and the key gone there is nothing to turn on, which is
    # "on", not "skipped" (the tray would show the step as off for good).
    if so_as_user "$user" gsettings list-keys org.gnome.mutter >/dev/null 2>&1; then
      step_ok "fractional scaling and VRR are built into this GNOME; $(_display_gnome_report "$user")"
    else
      step_skip "GNOME without the org.gnome.mutter settings (gsettings) for $user"
    fi
    return 0
  fi
  items=$(display_strv_items "$cur" | tr '\n' ' ')
  allowed=$(_display_gnome_allowed "$user" | tr '\n' ' ')
  want="$items"
  for f in $SO_DISPLAY_MUTTER_FEATURES; do
    list_has "$items" "$f" && continue
    if [ -n "$allowed" ] && ! list_has "$allowed" "$f"; then
      regular+="${regular:+ and }$f"     # no longer experimental: a regular setting here
      continue
    fi
    want+=" $f"
    missing+="${missing:+, }$f"
  done
  report=$(_display_gnome_report "$user")
  [ -z "$regular" ] || log_detail "$regular is a regular setting on this GNOME, not an experimental feature"
  if [ -z "$missing" ]; then
    step_ok "fractional scaling and VRR already offered; $report"
    return 0
  fi
  gsettings_set "$user" org.gnome.mutter experimental-features "$(display_strv "$want")" || rc=$?
  case "$rc" in
    0|3) ;;
    *) step_fail "could not set org.gnome.mutter experimental-features for $user"; return 1 ;;
  esac
  if [ "$SO_DRY_RUN" = 1 ]; then
    step_dry "would add $missing to Mutter's experimental features; $report"
  else
    step_updated "added $missing (log out and in for the Settings switches); ${regular:+$regular is a regular setting on this GNOME; }$report"
  fi
}

# ---------------------------------------------------------------------------
# display: KDE
# ---------------------------------------------------------------------------
# display_kscreen_parse: kscreen-doctor -o's text (stdin; Plasma 5.27's one
# line per output and Plasma 6's indented lines, with or without colour) as
# one tab-separated line per output:
#   NAME  ENABLED(1/0)  CUR_ID  CUR_MODE  VRR  BEST_ID  BEST_MODE
# VRR is the policy in lower case (never, always, automatic) or incapable;
# BEST is the mode with the highest refresh rate at the current resolution
# (the current one when none is higher).
display_kscreen_parse() {
  sed "s/$(printf '\033')\\[[0-9;]*[A-Za-z]//g" | awk '
    function flush(   i, best, bestid, bestname, w) {
      if (name == "") return
      best = currate; bestid = curid; bestname = curname
      for (i = 1; i <= nm; i++) {
        split(mname[i], w, "@")
        if (w[1] == curres && mrate[i] > best) { best = mrate[i]; bestid = mid[i]; bestname = mname[i] }
      }
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", name, en, curid, curname, (vrr == "" ? "incapable" : vrr), bestid, bestname
      name = ""
    }
    { for (i = 1; i <= NF; i++) tok[++n] = $i }
    END {
      for (i = 1; i <= n; i++) {
        t = tok[i]
        if (t == "Output:") {
          flush()
          name = tok[i + 2]; en = (tok[i + 3] == "enabled") ? 1 : 0
          curid = ""; curname = ""; curres = ""; currate = 0; vrr = ""; nm = 0; inmodes = 0
          i += 3
          continue
        }
        if (name == "") continue
        if (t == "Modes:") { inmodes = 1; continue }
        if (inmodes && t ~ /^[0-9]+:[0-9]+x[0-9]+@[0-9.]+[*!]*$/) {
          split(t, a, ":"); id = a[1]; mn = a[2]; cur = (mn ~ /\*/); gsub(/[*!]/, "", mn)
          nm++; mid[nm] = id; mname[nm] = mn
          split(mn, b, "@"); mrate[nm] = b[2] + 0
          if (cur) { curid = id; curname = mn; curres = b[1]; currate = b[2] + 0 }
          continue
        }
        inmodes = 0
        if (t == "Vrr:") vrr = tolower(tok[i + 1])
      }
      flush()
    }'
}

_display_kde() {
  local user="$1" out name en curid curmode vrr bestid bestmode
  local changed=0 failed=0 outputs=0 kde_notes=""
  if ! has_cmd kscreen-doctor; then
    step_skip "KDE without kscreen-doctor (install the kscreen package)"
    return 0
  fi
  if ! out=$(so_as_user "$user" kscreen-doctor -o 2>/dev/null) || [ -z "$out" ]; then
    step_skip "kscreen-doctor could not read the outputs of $user's session"
    return 0
  fi
  while IFS=$'\t' read -r name en curid curmode vrr bestid bestmode; do
    if [ "$en" != 1 ] || [ -z "$curid" ]; then continue; fi
    if ! [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
      log_warn "display: output name $name is not one --undo could restore; left alone"
      continue
    fi
    outputs=$((outputs + 1))
    case "$vrr" in
      never)
        if [ "$SO_DRY_RUN" = 1 ]; then
          log_dry "would set $name VRR policy: never -> automatic"
          plan_note kscreen "$name vrrpolicy ($user)" never automatic
          changed=$((changed + 1))
        elif snap_record kscreen "$user:$name:vrrpolicy" never automatic &&
             do_as_user "$user" kscreen-doctor "output.$name.vrrpolicy.automatic" >/dev/null; then
          changed=$((changed + 1))
          kde_notes+="${kde_notes:+; }$name VRR automatic"
        else
          failed=$((failed + 1))
        fi ;;
      *) log_detail "$name: VRR $vrr" ;;
    esac
    if [ "$bestid" != "$curid" ] && [ -n "$bestid" ]; then
      if [ "$SO_DRY_RUN" = 1 ]; then
        log_dry "would set $name mode: $curmode -> $bestmode"
        plan_note kscreen "$name mode ($user)" "$curmode" "$bestmode"
        changed=$((changed + 1))
      elif snap_record kscreen "$user:$name:mode" "$curmode" "$bestmode" &&
           do_as_user "$user" kscreen-doctor "output.$name.mode.$bestid" >/dev/null; then
        changed=$((changed + 1))
        kde_notes+="${kde_notes:+; }$name $curmode -> $bestmode"
      else
        failed=$((failed + 1))
      fi
    else
      log_detail "$name: $curmode is the highest refresh rate at this resolution"
    fi
  done < <(display_kscreen_parse <<< "$out")
  if [ "$outputs" = 0 ]; then
    step_skip "kscreen-doctor shows no enabled outputs"
  elif [ "$failed" -gt 0 ]; then
    step_warn "$failed display change(s) failed${kde_notes:+; done: $kde_notes}"
  elif [ "$changed" = 0 ]; then
    step_ok "$outputs output(s) already at their highest refresh rate with VRR on or not offered"
  elif [ "$SO_DRY_RUN" = 1 ]; then
    step_dry "would make $changed change(s) on $outputs output(s)"
  else
    step_updated "$kde_notes"
  fi
}

display_step() {
  local user kind type
  if [ "$SO_IN_CONTAINER" = 1 ]; then
    step_skip "container"
    return 0
  fi
  user=$(desktop_user)
  if [ -z "$user" ]; then
    step_skip "no desktop user (run it with sudo from the desktop session)"
    return 0
  fi
  kind=$(desktop_kind)
  type=$(desktop_session_type)
  case "$kind" in
    gnome|kde) ;;
    *) step_skip "only GNOME and KDE Plasma are handled (this desktop: $kind)"; return 0 ;;
  esac
  if [ "$type" != wayland ]; then
    step_skip "the $kind session is $type, not Wayland"
    return 0
  fi
  if [ "$kind" = gnome ]; then
    _display_gnome "$user"
  else
    _display_kde "$user"
  fi
}
