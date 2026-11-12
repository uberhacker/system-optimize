"""Colours and fonts for the full view. The window uses the platform's
style and the desktop's palette, light or dark; the explicit Light and Dark
choices switch the application's colour scheme (Qt 6.8+) or, on older Qt,
install a fixed palette. Status colours and the chart series are fixed so a
resource reads the same on every desktop."""

from .qt import QtCore, QtGui, QtWidgets

SERIES = ["#3584e4", "#2ec27e", "#e5a50a", "#c061cb", "#ff7800", "#1a9a8a"]
CHANGE = "#e0a21a"      # a setting change, on every chart

_FIXED = {
    "dark": {"window": "#242424", "base": "#303030", "text": "#f2f2f2", "highlight": "#3584e4"},
    "light": {"window": "#fafafa", "base": "#ffffff", "text": "#1f1f1f", "highlight": "#1c71d8"},
}


def system_is_dark():
    """The desktop's preference: Qt's colour scheme (6.5+, fed by the
    freedesktop appearance portal on GNOME and by the Plasma palette on
    KDE), else the palette's window colour."""
    hints = QtGui.QGuiApplication.styleHints()
    scheme = getattr(hints, "colorScheme", None)
    if scheme is not None:
        v = scheme()
        if v == QtCore.Qt.ColorScheme.Dark:
            return True
        if v == QtCore.Qt.ColorScheme.Light:
            return False
    pal = QtWidgets.QApplication.palette()
    return pal.color(QtGui.QPalette.ColorRole.Window).lightness() < 128


def resolve(setting):
    """'light' or 'dark' for a THEME setting (system | light | dark)."""
    if setting in ("light", "dark"):
        return setting
    return "dark" if system_is_dark() else "light"


def _fixed_palette(mode):
    f = _FIXED[mode]
    R = QtGui.QPalette.ColorRole
    pal = QtGui.QPalette()
    window, base, text = QtGui.QColor(f["window"]), QtGui.QColor(f["base"]), QtGui.QColor(f["text"])
    for role, color in ((R.Window, window), (R.Base, base), (R.AlternateBase, window), (R.Button, base),
                        (R.ToolTipBase, base), (R.WindowText, text), (R.Text, text), (R.ButtonText, text),
                        (R.ToolTipText, text), (R.Highlight, QtGui.QColor(f["highlight"])),
                        (R.HighlightedText, QtGui.QColor("white")),
                        (R.PlaceholderText, _mix(text, window, 0.5))):
        pal.setColor(role, color)
    G = QtGui.QPalette.ColorGroup
    for role in (R.WindowText, R.Text, R.ButtonText):
        pal.setColor(G.Disabled, role, _mix(text, window, 0.55))
    return pal


def apply_scheme(setting):
    """Make the application light, dark or whatever the desktop is."""
    app = QtWidgets.QApplication.instance()
    if app is None:
        return
    hints = QtGui.QGuiApplication.styleHints()
    CS = getattr(QtCore.Qt, "ColorScheme", None)
    if CS is not None and hasattr(hints, "setColorScheme"):
        hints.setColorScheme({"light": CS.Light, "dark": CS.Dark}.get(setting, CS.Unknown))
        app.setPalette(QtGui.QPalette())        # drop a palette an older call installed
        if setting not in ("light", "dark"):
            return
        dark = app.palette().color(QtGui.QPalette.ColorRole.Window).lightness() < 128
        if dark == (setting == "dark"):
            return                               # the platform followed
    if setting in ("light", "dark"):
        app.setPalette(_fixed_palette(setting))
    else:
        app.setPalette(app.style().standardPalette())


def _mix(a, b, t):
    """Colour a moved a fraction t of the way to b."""
    a, b = QtGui.QColor(a), QtGui.QColor(b)
    return QtGui.QColor(round(a.red() + (b.red() - a.red()) * t), round(a.green() + (b.green() - a.green()) * t),
                        round(a.blue() + (b.blue() - a.blue()) * t))


def colors(mode=None):
    """The colours custom-painted parts use, read from the application's
    palette (after apply_scheme). mode is kept for callers that name one:
    without an application it picks the fixed set."""
    app = QtWidgets.QApplication.instance()
    R = QtGui.QPalette.ColorRole
    if app is not None:
        pal = app.palette()
        window, base, text = pal.color(R.Window), pal.color(R.Base), pal.color(R.WindowText)
        accent = pal.color(R.Highlight)
    else:
        f = _FIXED[mode if mode in _FIXED else "light"]
        window, base, text, accent = (QtGui.QColor(f[k]) for k in ("window", "base", "text", "highlight"))
    dark = window.lightness() < 128
    return {
        "bg": window.name(), "card": base.name(), "card_hover": _mix(base, text, 0.06).name(),
        "border": _mix(window, text, 0.16).name(), "text": text.name(), "muted": _mix(text, window, 0.42).name(),
        "grid": _mix(window, text, 0.09).name(), "accent": accent.name(),
        "good": "#33d17a" if dark else "#1b8553", "bad": "#ff7b72" if dark else "#c01c28",
        "warn": "#f5c211" if dark else "#9c6e03", "change": CHANGE, "dark": dark,
    }


def mono(size=10, bold=False):
    """The fixed-width face, for command output only."""
    f = QtGui.QFontDatabase.systemFont(QtGui.QFontDatabase.SystemFont.FixedFont)
    f.setPointSizeF(size)
    f.setBold(bold)
    f.setStyleHint(QtGui.QFont.StyleHint.Monospace)
    return f


def figures(size=None, bold=False):
    """The interface font with tabular figures (Qt 6.7+), so a number that
    changes every two seconds does not shift what is next to it."""
    f = QtWidgets.QApplication.font() if QtWidgets.QApplication.instance() else QtGui.QFont()
    if size:
        f.setPointSizeF(size)
    f.setBold(bold)
    try:
        f.setFeature(QtGui.QFont.Tag("tnum"), 1)
    except (AttributeError, TypeError):
        pass
    return f


def stylesheet(c):
    """Only text roles: any rule on buttons, fields or lists would switch
    those widgets from the platform's drawing to Qt's style-sheet look."""
    return """
QLabel[role="muted"] {{ color: {muted}; }}
QLabel[role="h1"] {{ font-size: 15pt; font-weight: 600; }}
QLabel[role="h2"] {{ font-size: 11pt; font-weight: 600; }}
QLabel[role="warn"] {{ border-left: 3px solid {warn}; padding: 4px 10px; }}
QLabel[role="good"] {{ color: {good}; }}
QLabel[role="bad"] {{ color: {bad}; }}
""".format(**c)
