"""Colours and fonts for the panel. Follows the desktop's light or dark
palette; the accent and status colours are fixed so numbers read the same
everywhere."""

from .qt import QtCore, QtGui, QtWidgets

ACCENT = "#3584e4"
GOOD = "#33d17a"
BAD = "#ed333b"
WARN = "#f6d32d"
SERIES = ["#3584e4", "#33d17a", "#f6d32d", "#c061cb", "#ff7800", "#26a269"]



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


def colors(mode="dark"):
    dark = mode == "dark"
    if dark:
        return {"bg": "#16181d", "card": "#1f232a", "card_hover": "#272c35", "border": "#2e343e",
                "text": "#e8eaed", "muted": "#8b939e", "grid": "#2b3039", "accent": ACCENT,
                "good": GOOD, "bad": BAD, "warn": WARN, "dark": True}
    return {"bg": "#f6f7f9", "card": "#ffffff", "card_hover": "#eef2f7", "border": "#dde1e6",
            "text": "#1c1f24", "muted": "#626b76", "grid": "#e6e9ee", "accent": "#1c71d8",
            "good": "#26a269", "bad": "#c01c28", "warn": "#c88800", "dark": False}


def mono(size=10, bold=False):
    f = QtGui.QFontDatabase.systemFont(QtGui.QFontDatabase.SystemFont.FixedFont)
    f.setPointSizeF(size)
    f.setBold(bold)
    f.setStyleHint(QtGui.QFont.StyleHint.Monospace)
    return f


def stylesheet(c):
    return """
QWidget#Panel {{ background: {bg}; }}
QWidget#Panel QLabel {{ color: {text}; }}
QLabel[role="muted"] {{ color: {muted}; }}
QLabel[role="h1"] {{ font-size: 15pt; font-weight: 600; }}
QLabel[role="h2"] {{ font-size: 11pt; font-weight: 600; color: {text}; }}
QLabel[role="chip"] {{ background: {card}; border: 1px solid {border}; border-radius: 9px; padding: 1px 8px; color: {muted}; }}
QLabel[role="warn"] {{ background: {card}; border: 1px solid {warn}; border-left: 4px solid {warn}; border-radius: 8px; padding: 6px 10px; color: {text}; }}
QFrame[card="true"] {{ background: {card}; border: 1px solid {border}; border-radius: 10px; }}
QFrame[card="true"][hover="true"] {{ background: {card_hover}; }}
QPushButton {{ background: {card}; color: {text}; border: 1px solid {border}; border-radius: 7px; padding: 4px 10px; }}
QPushButton:hover {{ border-color: {accent}; }}
QPushButton:disabled {{ color: {muted}; }}
QPushButton[primary="true"] {{ background: {accent}; color: white; border-color: {accent}; }}
QPushButton[flat="true"] {{ background: transparent; border: none; color: {muted}; padding: 2px 4px; }}
QPushButton[flat="true"]:hover {{ color: {accent}; }}
QLineEdit, QComboBox {{ background: {card}; color: {text}; border: 1px solid {border}; border-radius: 7px; padding: 5px 8px; }}
QLineEdit:focus, QComboBox:focus {{ border-color: {accent}; }}
QTextBrowser {{ background: {card}; color: {text}; border: 1px solid {border}; border-radius: 10px; padding: 6px; }}
QScrollArea, QScrollArea > QWidget > QWidget {{ background: transparent; border: none; }}
QTableWidget {{ background: {card}; color: {text}; border: 1px solid {border}; border-radius: 10px; gridline-color: {grid}; }}
QHeaderView::section {{ background: {card}; color: {muted}; border: none; border-bottom: 1px solid {border}; padding: 4px; }}
QScrollBar:vertical {{ background: transparent; width: 8px; }}
QScrollBar::handle:vertical {{ background: {border}; border-radius: 4px; min-height: 24px; }}
QScrollBar::add-line, QScrollBar::sub-line {{ height: 0; }}
""".format(**c)
