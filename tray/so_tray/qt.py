"""Qt bindings: PySide6 when installed, otherwise PyQt6. SO_TRAY_QT=pyqt6
(or pyside6) picks one, for testing both."""

import os

_order = ("PyQt6", "PySide6") if os.environ.get("SO_TRAY_QT", "").lower() == "pyqt6" else ("PySide6", "PyQt6")
try:  # pragma: no cover - depends on what is installed
    if _order[0] == "PySide6":
        from PySide6 import QtCore, QtGui, QtWidgets  # noqa: F401
    else:
        from PyQt6 import QtCore, QtGui, QtWidgets  # noqa: F401
    BINDING = _order[0]
except ImportError:  # pragma: no cover
    if _order[1] == "PySide6":
        from PySide6 import QtCore, QtGui, QtWidgets  # noqa: F401
    else:
        from PyQt6 import QtCore, QtGui, QtWidgets  # noqa: F401
    BINDING = _order[1]

Signal = getattr(QtCore, "Signal", None) or getattr(QtCore, "pyqtSignal")
