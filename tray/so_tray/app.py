"""The Qt tray app (system-optimize-tray).

A StatusNotifierItem icon: native on KDE Plasma, Xfce, LXQt, Cinnamon and
Budgie, and on GNOME with the AppIndicator extension (Ubuntu ships it).
Left click opens the panel; right click has a short menu. On stock GNOME
the Shell extension in gnome-extension/ is the panel-bar front end and
opens this app's panel as a window (--panel).
"""

import argparse
import os
import subprocess
import sys

from . import APP_ID, EXTENSION_UUID, VERSION
from .cli import Cli
from .history import METRICS
from .monitor import Monitor, summary
from .panel import Controller, Panel
from .qt import QtCore, QtGui, QtWidgets

ICON_NAME = "system-optimize-tray"
HERE = os.path.dirname(os.path.abspath(__file__))


def gnome_extension_enabled(run=subprocess.run, environ=None):
    """True on GNOME when our Shell extension is enabled."""
    env = os.environ if environ is None else environ
    if "GNOME" not in env.get("XDG_CURRENT_DESKTOP", "").upper():
        return False
    try:
        res = run(["gsettings", "get", "org.gnome.shell", "enabled-extensions"],
                  capture_output=True, text=True, timeout=5, check=False)
        off = run(["gsettings", "get", "org.gnome.shell", "disable-user-extensions"],
                  capture_output=True, text=True, timeout=5, check=False)
    except (OSError, subprocess.SubprocessError):
        return False
    return EXTENSION_UUID in (res.stdout or "") and (off.stdout or "").strip() != "true"


def load_icon():
    icon = QtGui.QIcon.fromTheme(ICON_NAME)
    if icon.isNull():
        for cand in (os.path.join(HERE, "..", "data", "icons", ICON_NAME + ".svg"),
                     os.path.join(HERE, ICON_NAME + ".svg")):
            if os.path.exists(cand):
                return QtGui.QIcon(cand)
    return icon


def agent_factory_or_none():
    """A factory for the tuning agent when the optional package is installed."""
    try:
        from so_agent import config as acfg
        from so_agent.agent import Agent
        from so_agent.llm import client
    except ImportError:
        return None

    def make(cli=None):
        cfg = acfg.load()
        c = client(cfg, acfg.backend_url(cfg))
        return Agent(c, cli or Cli(), max_rounds=int(cfg["AGENT_MAX_ROUNDS"]))
    return make


class OutputDialog(QtWidgets.QDialog):
    def __init__(self, title, text, parent=None):
        super().__init__(parent)
        self.setWindowTitle(title)
        self.resize(760, 520)
        lay = QtWidgets.QVBoxLayout(self)
        view = QtWidgets.QPlainTextEdit(self)
        view.setReadOnly(True)
        view.setPlainText(text)
        view.setFont(QtGui.QFontDatabase.systemFont(QtGui.QFontDatabase.SystemFont.FixedFont))
        lay.addWidget(view)
        box = QtWidgets.QDialogButtonBox(QtWidgets.QDialogButtonBox.StandardButton.Close, self)
        box.rejected.connect(self.reject)
        lay.addWidget(box)


class App(QtCore.QObject):
    def __init__(self, cli=None, monitor=None, interval_ms=2000, tray=True, agent_factory=None, recorder=None):
        super().__init__()
        self.cli = cli or Cli()
        factory = agent_factory if agent_factory is not None else agent_factory_or_none()
        self.ctl = Controller(self.cli, monitor or Monitor(root=os.environ.get("SO_ROOT", "/")),
                              agent_factory=(lambda: factory(self.cli)) if factory else None)
        if tray and recorder is None:
            # the tray (not a --panel window) keeps the resource averages; on
            # GNOME the extension's monitor does it instead
            from .history import Recorder
            recorder = Recorder()
        self.ctl.recorder = recorder
        if os.environ.get("SO_ROOT", "/") == "/":
            from .pcp import PcpSource
            self.ctl.pcp = PcpSource()
        self.panel = Panel(self.ctl)
        self.panel.setWindowIcon(load_icon())
        self.panel.text_requested.connect(self.show_text)
        self.dialogs = []
        self.tray = None
        if tray:
            self.tray = QtWidgets.QSystemTrayIcon(load_icon(), self)
            menu = QtWidgets.QMenu()
            menu.addAction("Open system-optimize", self.show_panel)
            menu.addAction("Preview changes…", lambda: self.panel.btn_preview.click())
            menu.addAction("Undo last run", lambda: self.panel.btn_undo.click())
            menu.addSeparator()
            menu.addAction("Quit", QtWidgets.QApplication.quit)
            self._menu = menu
            self.tray.setContextMenu(menu)
            self.tray.activated.connect(self._activated)
            self.ctl.sample_changed.connect(self._tooltip)
            self.ctl.message.connect(self._notify)
            self.ctl.alert.connect(lambda text: self._notify(text, True))
        self.timer = QtCore.QTimer(self)
        self.timer.timeout.connect(self.ctl.tick)
        self.timer.start(interval_ms)
        self.ctl.monitor.cpu()          # prime the counters
        self.ctl.tick()
        self.ctl.refresh()

    def _tooltip(self):
        if self.ctl.sample:
            self.tray.setToolTip("system-optimize\n" + summary(self.ctl.sample))

    def _notify(self, text, error):
        if self.tray and not self.panel.isVisible():
            icon = (QtWidgets.QSystemTrayIcon.MessageIcon.Warning if error
                    else QtWidgets.QSystemTrayIcon.MessageIcon.Information)
            self.tray.showMessage("system-optimize", text, icon, 6000)

    def _activated(self, reason):
        if reason in (QtWidgets.QSystemTrayIcon.ActivationReason.Trigger,
                      QtWidgets.QSystemTrayIcon.ActivationReason.DoubleClick):
            if self.panel.isVisible():
                self.panel.hide()
            else:
                self.show_panel()

    def show_panel(self, page=None):
        geo = self.tray.geometry() if self.tray else QtCore.QRect()
        screen = QtGui.QGuiApplication.screenAt(geo.center()) if geo.isValid() else None
        screen = screen or QtGui.QGuiApplication.primaryScreen()
        if geo.isValid() and screen and QtGui.QGuiApplication.platformName() == "xcb":
            area = screen.availableGeometry()
            x = min(max(area.left(), geo.center().x() - self.panel.width() // 2), area.right() - self.panel.width())
            y = area.top() if geo.center().y() < area.center().y() else area.bottom() - self.panel.height()
            self.panel.move(x, y)
        self.ctl.refresh()
        if page == "chat":
            self.panel.open_chat()
        elif page and page.startswith("resource:"):
            self.panel.open_resource(page.split(":", 1)[1])
        self.panel.show()
        self.panel.raise_()
        self.panel.activateWindow()

    def show_text(self, title, text):
        d = OutputDialog(title, text, self.panel)
        d.finished.connect(lambda _=0, dd=d: self.dialogs.remove(dd) if dd in self.dialogs else None)
        self.dialogs.append(d)
        d.show()


def main(argv=None):
    p = argparse.ArgumentParser(prog="system-optimize-tray", description="A panel indicator for system-optimize.")
    p.add_argument("--version", action="version", version="system-optimize-tray " + VERSION)
    p.add_argument("--panel", action="store_true", help="open the panel as a window, without a tray icon")
    p.add_argument("--chat", action="store_true", help="open the panel on the tuning agent's chat")
    p.add_argument("--resource", choices=sorted(METRICS), help="open the panel on a resource's history")
    p.add_argument("--force", action="store_true",
                   help="show the tray icon even when the GNOME Shell extension is enabled")
    args = p.parse_args(argv)

    QtWidgets.QApplication.setApplicationName("system-optimize-tray")
    QtWidgets.QApplication.setDesktopFileName(APP_ID)
    app = QtWidgets.QApplication(sys.argv[:1])

    if args.panel or args.chat or args.resource:
        a = App(tray=False)
        app.setQuitOnLastWindowClosed(True)
        a.show_panel("chat" if args.chat else ("resource:" + args.resource) if args.resource else None)
        return app.exec()

    if not args.force and gnome_extension_enabled():
        return 0      # the Shell extension is the front end on GNOME; don't show twice
    if not QtWidgets.QSystemTrayIcon.isSystemTrayAvailable():
        print("system-optimize-tray: this desktop shows no tray icons. On GNOME, enable the "
              "system-optimize Shell extension (gnome-extensions enable %s), or run "
              "system-optimize-tray --panel." % EXTENSION_UUID, file=sys.stderr)
        return 1
    app.setQuitOnLastWindowClosed(False)
    a = App()
    a.tray.show()
    return app.exec()
