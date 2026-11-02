"""system-optimize-tray: a panel indicator for system-optimize.

The package is shared by the Qt tray app (KDE, Xfce, LXQt, GNOME with the
AppIndicator extension) and by the backend command that the native GNOME
Shell extension drives. Nothing in it runs as root; changes go through the
polkit-approved helper (helper/system-optimize-helper).
"""

VERSION = "0.1.0"
APP_ID = "io.github.bradvrudney.SystemOptimizeTray"
EXTENSION_UUID = "system-optimize@bradvrudney.github.io"
