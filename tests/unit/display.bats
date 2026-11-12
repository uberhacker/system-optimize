#!/usr/bin/env bats
# tests/unit/display.bats - opt-in steps "fonts" (fontconfig and GNOME's
# font settings) and "display" (Mutter's experimental features, KDE's VRR
# policy and refresh rate).

load ../test_helper

setup() { setup_sandbox; }

FONTS=/etc/fonts/conf.d/99-system-optimize.conf

gnome_fonts() {
  with_stub gsettings
  as_desktop gnome
  gs_put org.gnome.desktop.interface font-hinting "'full'"
  gs_put org.gnome.desktop.interface font-antialiasing "'grayscale'"
  gs_put org.gnome.desktop.interface font-rgba-order "'rgb'"
}

# gdbus_stub: Mutter's GetCurrentState with one 2560x1440 screen running at
# 60 Hz that offers 165 Hz, and a laptop panel at its only rate.
gdbus_stub() {
  local d="$BATS_TEST_TMPDIR/extra"
  mkdir -p "$d"
  cat > "$d/gdbus" <<'EOF'
#!/usr/bin/env bash
printf 'gdbus %s\n' "$*" >> "$STUB_LOG"
cat <<'OUT'
(uint32 7, [(('DP-1', 'DEL', 'DELL S2721DGF', '0x1234'), [('2560x1440@165.000', 2560, 1440, 165.0, 1.0, [1.0, 2.0], {'is-preferred': <true>}), ('2560x1440@59.951', 2560, 1440, 59.951, 1.0, [1.0, 2.0], {'is-current': <true>}), ('1920x1080@240.000', 1920, 1080, 240.0, 1.0, [1.0], {})], {'is-builtin': <false>, 'display-name': <'Dell 27"'>}), (('eDP-1', 'BOE', '0x0bca', '0x0'), [('2256x1504@60.000', 2256, 1504, 60.0, 1.5, [1.0, 1.5, 2.0], {'is-current': <true>, 'is-preferred': <true>})], {'is-builtin': <true>})], [(0, 0, 1.0, uint32 0, true, [('DP-1', 'DEL', 'DELL S2721DGF', '0x1234')], @a{sv} {})], {'layout-mode': <uint32 1>})
OUT
EOF
  chmod +x "$d/gdbus"
  export PATH="$d:$PATH"
}

kde_outputs() {
  with_stub kscreen-doctor
  as_desktop kde
  cat > "$STUB_STATE/kscreen" <<'EOF'
DP-1|enabled|Never|1:2560x1440@60* 2:2560x1440@144 3:2560x1440@165 4:1920x1080@240
eDP-1|enabled|incapable|1:1920x1200@60* 2:1600x1200@60
HDMI-A-1|disabled|Never|1:1920x1080@60* 2:1920x1080@75
EOF
}

# --- fonts ------------------------------------------------------------------

@test "fonts: fontconfig file and GNOME keys; a second run changes nothing" {
  mkdir -p "$SANDBOX/etc/fonts/conf.d"
  gnome_fonts
  run "$SO" -y --only fonts
  [ "$status" -eq 0 ]
  assert_output_contains "hinting slight, subpixel rgb (fontconfig and GNOME for $(id -un))"
  local f
  f=$(get "$FONTS")
  assert_contains "$f" '<edit name="hinting" mode="assign"><bool>true</bool></edit>'
  assert_contains "$f" '<const>hintslight</const>'
  assert_contains "$f" '<edit name="rgba" mode="assign"><const>rgb</const></edit>'
  assert_contains "$f" '<const>lcddefault</const>'
  assert_contains "$f" '<edit name="antialias" mode="assign"><bool>true</bool></edit>'
  [ "$(gs_get org.gnome.desktop.interface font-hinting)" = "'slight'" ]
  [ "$(gs_get org.gnome.desktop.interface font-antialiasing)" = "'rgba'" ]
  [ "$(gs_get org.gnome.desktop.interface font-rgba-order)" = "'rgb'" ]
  local m
  m=$(snapshots | tail -n1)/manifest
  grep -q $'^file\t/etc/fonts/conf.d/99-system-optimize.conf\tabsent\tfonts\t' "$m"
  grep -q $'^gsettings\t'"$(id -un)"$':org.gnome.desktop.interface:font-hinting\t\'full\'\tfonts\t' "$m"
  ! grep -q 'font-rgba-order' "$m"
  run "$SO" -y --only fonts
  [ "$status" -eq 0 ]
  assert_output_contains "already set"
}

@test "fonts: the XML is well formed" {
  command -v xmllint >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || skip "no XML parser"
  load_so
  display_fonts_content slight rgb > "$BATS_TEST_TMPDIR/a.conf"
  display_fonts_content none none > "$BATS_TEST_TMPDIR/b.conf"
  if command -v xmllint >/dev/null 2>&1; then
    xmllint --noout "$BATS_TEST_TMPDIR/a.conf" "$BATS_TEST_TMPDIR/b.conf"
  else
    python3 -c 'import sys, xml.dom.minidom as m; [m.parse(f) for f in sys.argv[1:]]' "$BATS_TEST_TMPDIR/a.conf" "$BATS_TEST_TMPDIR/b.conf"
  fi
}

@test "fonts: no hinting and no subpixel order; grayscale on GNOME" {
  mkdir -p "$SANDBOX/etc/fonts"
  gnome_fonts
  run env FONT_HINTING=none FONT_SUBPIXEL=none "$SO" -y --only fonts
  [ "$status" -eq 0 ]
  local f
  f=$(get "$FONTS")
  assert_contains "$f" '<edit name="hinting" mode="assign"><bool>false</bool></edit>'
  assert_contains "$f" '<const>hintnone</const>'
  assert_contains "$f" '<const>none</const>'
  assert_not_contains "$f" lcdfilter
  [ "$(gs_get org.gnome.desktop.interface font-antialiasing)" = "'grayscale'" ]
  [ "$(gs_get org.gnome.desktop.interface font-hinting)" = "'none'" ]
  assert_not_called "gsettings set org.gnome.desktop.interface font-rgba-order"
}

@test "fonts: dry run changes nothing" {
  mkdir -p "$SANDBOX/etc/fonts"
  gnome_fonts
  run "$SO" -n --only fonts
  [ "$status" -eq 0 ]
  assert_output_contains "would set hinting slight, subpixel rgb"
  [ ! -e "$SANDBOX$FONTS" ]
  [ "$(gs_get org.gnome.desktop.interface font-hinting)" = "'full'" ]
  [ -z "$(snapshots)" ]
}

@test "fonts: without fontconfig it skips; without GNOME only the file is written" {
  run "$SO" -y --only fonts
  [ "$status" -eq 0 ]
  assert_output_contains "no fontconfig here"
  mkdir -p "$SANDBOX/etc/fonts"
  with_stub gsettings
  run env SO_DESKTOP_USER="$(id -un)" SO_DESKTOP=kde "$SO" -y --only fonts
  [ "$status" -eq 0 ]
  assert_output_contains "subpixel rgb (fontconfig)"
  [ -f "$SANDBOX$FONTS" ]
  assert_not_called "gsettings"
}

@test "fonts: --undo removes the file and restores the GNOME keys" {
  mkdir -p "$SANDBOX/etc/fonts"
  gnome_fonts
  run "$SO" -y --only fonts
  [ "$status" -eq 0 ]
  run "$SO" --undo -y
  [ "$status" -eq 0 ]
  [ ! -e "$SANDBOX$FONTS" ]
  [ "$(gs_get org.gnome.desktop.interface font-hinting)" = "'full'" ]
  [ "$(gs_get org.gnome.desktop.interface font-antialiasing)" = "'grayscale'" ]
}

# --- display ----------------------------------------------------------------

@test "display: GNOME adds fractional scaling and VRR, keeps other features and reports the refresh rate" {
  with_stub gsettings
  gdbus_stub
  as_desktop gnome wayland
  gs_put org.gnome.mutter experimental-features "['kms-modifiers']"
  run "$SO" -y --only display
  [ "$status" -eq 0 ]
  assert_output_contains "added scale-monitor-framebuffer, variable-refresh-rate"
  assert_output_contains "DP-1 2560x1440 at 59.95 Hz (up to 165 Hz available)"
  assert_output_contains "eDP-1 2256x1504 at 60 Hz"
  assert_output_contains "Settings > Displays > Refresh Rate"
  [ "$(gs_get org.gnome.mutter experimental-features)" = "['kms-modifiers', 'scale-monitor-framebuffer', 'variable-refresh-rate']" ]
  grep -q $'^gsettings\t'"$(id -un)"$':org.gnome.mutter:experimental-features\t\[\'kms-modifiers\'\]\tdisplay\t' "$(snapshots | tail -n1)/manifest"
  run "$SO" -y --only display
  [ "$status" -eq 0 ]
  assert_output_contains "fractional scaling and VRR already offered"
  run "$SO" --undo -y --only display
  [ "$status" -eq 0 ]
  [ "$(gs_get org.gnome.mutter experimental-features)" = "['kms-modifiers']" ]
}

@test "display: GNOME from an empty list; dry run changes nothing; no gdbus still says where to pick the rate" {
  with_stub gsettings
  as_desktop gnome wayland
  gs_put org.gnome.mutter experimental-features "@as []"
  run "$SO" -n --only display
  [ "$status" -eq 0 ]
  assert_output_contains "would add scale-monitor-framebuffer, variable-refresh-rate"
  [ "$(gs_get org.gnome.mutter experimental-features)" = "@as []" ]
  [ -z "$(snapshots)" ]
  run "$SO" -y --only display
  [ "$status" -eq 0 ]
  [ "$(gs_get org.gnome.mutter experimental-features)" = "['scale-monitor-framebuffer', 'variable-refresh-rate']" ]
}

@test "display: GNOME 48+ has VRR as a normal setting; only what the schema still lists is added" {
  # Mutter 48 moved variable-refresh-rate out of experimental-features; gsettings
  # refuses the whole list when one name is unknown ("outside of the valid range").
  with_stub gsettings
  as_desktop gnome wayland
  gs_put org.gnome.mutter experimental-features "@as []"
  gs_range org.gnome.mutter experimental-features "scale-monitor-framebuffer kms-modifiers autoclose-xwayland xwayland-native-scaling"
  run "$SO" -y --only display
  [ "$status" -eq 0 ]
  assert_output_contains "added scale-monitor-framebuffer"
  assert_output_contains "variable-refresh-rate is a regular setting on this GNOME"
  assert_output_not_contains "outside of the valid range"
  [ "$(gs_get org.gnome.mutter experimental-features)" = "['scale-monitor-framebuffer']" ]
  run "$SO" -y --only display
  [ "$status" -eq 0 ]
  assert_output_contains "fractional scaling and VRR already offered"
}

@test "display: a GNOME where both are regular settings has nothing to add" {
  with_stub gsettings
  as_desktop gnome wayland
  gs_put org.gnome.mutter experimental-features "@as []"
  gs_range org.gnome.mutter experimental-features "kms-modifiers autoclose-xwayland"
  run "$SO" -y --only display
  [ "$status" -eq 0 ]
  assert_output_contains "fractional scaling and VRR already offered"
  assert_not_called "gsettings set"
  [ -z "$(snapshots)" ]
}

@test "display: GNOME 51 has no experimental-features key at all; both are built in, so the step is on" {
  # Mutter 51 removed the key: fractional scaling and VRR are regular
  # settings. "skipped" would show the step as off in the tray for good.
  with_stub gsettings
  as_desktop gnome wayland
  gs_schema org.gnome.mutter
  gs_put org.gnome.mutter dynamic-workspaces true
  run "$SO" -y --only display
  [ "$status" -eq 0 ]
  assert_output_contains "fractional scaling and VRR are built into this GNOME"
  assert_output_contains "1 ok, 0 updated, 0 skipped"
  assert_not_called "gsettings set"
  [ -z "$(snapshots)" ]
}

@test "display: X11, other desktops, no desktop user and containers are skipped" {
  with_stub gsettings
  run env SO_DESKTOP_USER="$(id -un)" SO_DESKTOP=gnome SO_SESSION_TYPE=x11 "$SO" -y --only display
  assert_output_contains "the gnome session is x11, not Wayland"
  run env SO_DESKTOP_USER="$(id -un)" SO_DESKTOP=xfce SO_SESSION_TYPE=wayland "$SO" -y --only display
  assert_output_contains "only GNOME and KDE Plasma are handled (this desktop: other)"
  if [ "$(id -u)" -eq 0 ]; then   # root without sudo or a graphical session
    run env SO_DESKTOP_USER= SUDO_USER= "$SO" -y --only display
    assert_output_contains "no desktop user"
  fi
  run env SO_CONTAINER=docker "$SO" -y --force --only display
  assert_output_contains "display: container"
  [ -z "$(snapshots)" ]
}

@test "display: KDE parses Plasma 6 text and Plasma 5 one-line output" {
  load_so
  local p6 p5
  p6=$(printf '\033[01;32mOutput: \033[0;0m1 DP-1\n\tenabled\n\tconnected\n\tModes:  1:\033[01;32m2560x1440@60*!\033[0;0m  2:2560x1440@165  3:1920x1080@240\n\tVrr: Never\n\tHDR: enabled\n' | display_kscreen_parse)
  [ "$p6" = $'DP-1\t1\t1\t2560x1440@60\tnever\t2\t2560x1440@165' ]
  p5=$(printf 'Output: 2 eDP-1 enabled connected priority 1 Panel Modes: 0:1920x1200@60*! 1:1920x1200@48 Geometry: 0,0 1920x1200 Scale: 1 Rotation: 1 Overscan: 0 Vrr: incapable RgbRange: unknown\nOutput: 3 HDMI-A-1 disabled connected Modes: 0:1920x1080@60* Vrr: Automatic\n' | display_kscreen_parse)
  [ "$(sed -n 1p <<< "$p5")" = $'eDP-1\t1\t0\t1920x1200@60\tincapable\t0\t1920x1200@60' ]
  [ "$(sed -n 2p <<< "$p5")" = $'HDMI-A-1\t0\t0\t1920x1080@60\tautomatic\t0\t1920x1080@60' ]
}

@test "display: KDE sets VRR automatic and the highest rate at the current resolution; second run ok; undo restores" {
  kde_outputs
  run "$SO" -n --only display
  [ "$status" -eq 0 ]
  assert_output_contains "would make 2 change(s) on 2 output(s)"
  assert_not_called "kscreen-doctor output."
  [ -z "$(snapshots)" ]
  run "$SO" -y --only display
  [ "$status" -eq 0 ]
  assert_output_contains "DP-1 VRR automatic; DP-1 2560x1440@60 -> 2560x1440@165"
  assert_called "kscreen-doctor output.DP-1.vrrpolicy.automatic"
  assert_called "kscreen-doctor output.DP-1.mode.3"
  assert_not_called "output.HDMI-A-1"
  assert_not_called "output.eDP-1"
  grep -q '^DP-1|enabled|Automatic|1:2560x1440@60 2:2560x1440@144 3:2560x1440@165\* 4:1920x1080@240$' "$STUB_STATE/kscreen"
  local m
  m=$(snapshots | tail -n1)/manifest
  grep -q $'^kscreen\t'"$(id -un)"$':DP-1:vrrpolicy\tnever\tdisplay\tautomatic\t' "$m"
  grep -q $'^kscreen\t'"$(id -un)"$':DP-1:mode\t2560x1440@60\tdisplay\t2560x1440@165\t' "$m"
  run "$SO" -y --only display
  [ "$status" -eq 0 ]
  assert_output_contains "2 output(s) already at their highest refresh rate"
  run "$SO" --undo -y
  [ "$status" -eq 0 ]
  assert_called "kscreen-doctor output.DP-1.mode.2560x1440@60"
  assert_called "kscreen-doctor output.DP-1.vrrpolicy.never"
  grep -q '^DP-1|enabled|Never|1:2560x1440@60\* 2:2560x1440@144 3:2560x1440@165 4:1920x1080@240$' "$STUB_STATE/kscreen"
}

@test "display: KDE keeps VRR always, and skips without kscreen-doctor" {
  as_desktop kde
  run "$SO" -y --only display
  assert_output_contains "KDE without kscreen-doctor"
  kde_outputs
  printf 'DP-1|enabled|Always|1:2560x1440@165*\n' > "$STUB_STATE/kscreen"
  run "$SO" -y --only display
  [ "$status" -eq 0 ]
  assert_output_contains "1 output(s) already at their highest refresh rate"
  assert_not_called "kscreen-doctor output."
}

# fake_session_tools LIST: loginctl with the sessions in LIST ("id:type:active:
# name:desktop" words) and a pgrep that finds nothing, as under sudo on a box
# whose session is locked or on a second seat.
fake_session_tools() {
  local d="$BATS_TEST_TMPDIR/session"
  mkdir -p "$d"
  printf '%s\n' "$1" | tr ' ' '\n' | sed '/^$/d' > "$d/sessions"
  cat > "$d/loginctl" <<EOF
#!/usr/bin/env bash
f="$d/sessions"
case "\$1" in
  list-sessions) cut -d: -f1 "\$f" | sed 's/\$/ 1000 user seat0/' ;;
  show-session)
    line=\$(grep "^\$2:" "\$f") || exit 1
    case "\$4" in
      Type) cut -d: -f2 <<< "\$line" ;;
      Active) cut -d: -f3 <<< "\$line" ;;
      Name) cut -d: -f4 <<< "\$line" ;;
      Desktop) cut -d: -f5 <<< "\$line" ;;
    esac ;;
esac
EOF
  printf '#!/usr/bin/env bash\nexit 1\n' > "$d/pgrep"
  chmod +x "$d/loginctl" "$d/pgrep"
  export PATH="$d:$PATH"
}

@test "desktop: under sudo with no XDG_CURRENT_DESKTOP, GNOME comes from the user's session or the installed shell" {
  unset SO_DESKTOP XDG_CURRENT_DESKTOP
  export SO_DESKTOP_USER=brad
  fake_session_tools "c1:tty:yes:root: 3:wayland:no:brad:GNOME"
  load_so
  [ "$(desktop_kind)" = gnome ]
  fake_session_tools ""
  load_so
  [ "$(desktop_kind)" = none ]
  mkdir -p "$SANDBOX/usr/bin"
  printf '#!/bin/sh\n' > "$SANDBOX/usr/bin/gnome-shell"; chmod +x "$SANDBOX/usr/bin/gnome-shell"
  [ "$(desktop_kind)" = gnome ]
  cp "$SANDBOX/usr/bin/gnome-shell" "$SANDBOX/usr/bin/plasmashell"
  [ "$(desktop_kind)" = none ]
}
