"""The Qt app (system-optimize-tray): the tray icon with its quick view,
and the full view.

The icon is a StatusNotifierItem: native on KDE Plasma, Xfce, LXQt,
Cinnamon and Budgie, and on GNOME with the AppIndicator extension. Its menu
is the quick view (the same rows as the GNOME panel menu: model.quick_rows);
left click opens the full view. On stock GNOME the Shell extension in
gnome-extension/ is the icon, and this program is only the full view.

There is one full view per user: a second start hands its page to the
running one over a socket in XDG_RUNTIME_DIR and exits.
"""

import argparse
import json
import os
import socket
import stat
import struct
import subprocess
import sys

from . import APP_ID, EXTENSION_UUID, VERSION
from .cli import NAME_RE, Cli
from .history import METRICS
from .monitor import Monitor, summary
from .panel import Controller, Panel
from .qt import QtCore, QtGui, QtWidgets, Signal

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


QUICK_ROWS = 12          # the menu has a fixed set of rows: hosts flicker when rows come and go


def runtime_dir():
    """A directory only this user can use: XDG_RUNTIME_DIR, else a private
    one under the home directory. Never a shared one such as /tmp, where
    another user could put a socket with our name."""
    d = os.environ.get("XDG_RUNTIME_DIR")
    if d and _private_dir(d):
        return d
    d = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state"),
                     "system-optimize-tray", "run")
    os.makedirs(d, mode=0o700, exist_ok=True)
    os.chmod(d, 0o700)
    return d


def _private_dir(d):
    try:
        st = os.stat(d)
    except OSError:
        return False
    return stat.S_ISDIR(st.st_mode) and st.st_uid == os.getuid() and not st.st_mode & 0o077


def _peer_is_us(conn):
    """The process at the other end runs as this user (SO_PEERCRED)."""
    try:
        creds = conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
        _pid, uid, _gid = struct.unpack("3i", creds)
    except (OSError, AttributeError, struct.error):
        return False
    return uid == os.getuid()


def socket_path():
    return os.path.join(runtime_dir(), "system-optimize-tray-%d.sock" % os.getuid())


def quit_flag():
    """Present while the GNOME extension has been quit for this session
    (the extension writes and watches it; starting the app removes it)."""
    return os.path.join(runtime_dir(), "system-optimize-tray.quit")


def send_to_running(msg, path=None, timeout=1.0):
    """Hand a request to the running instance. False when there is none."""
    path = path or socket_path()
    try:
        st = os.lstat(path)
    except OSError:
        return False
    if not stat.S_ISSOCK(st.st_mode) or st.st_uid != os.getuid():
        return False                         # not ours: say nothing to it
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect(path)
        if not _peer_is_us(s):
            return False
        s.sendall((json.dumps(msg) + "\n").encode("utf-8"))
        return s.recv(16) == b"ok\n"
    except OSError:
        return False
    finally:
        s.close()


class Listener(QtCore.QObject):
    """The running instance's end of the socket: one JSON object per
    connection ({"page": ...} or {"quit": true}); anything else just
    brings the window forward."""
    received = Signal(dict)

    def __init__(self, path=None, parent=None):
        super().__init__(parent)
        self.path = path or socket_path()
        try:
            os.unlink(self.path)             # left by a crash: nobody answered on it
        except OSError:
            pass
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        old = os.umask(0o077)                # the socket is private from the moment it exists
        try:
            self.sock.bind(self.path)
            self.sock.listen(4)
            self.sock.setblocking(False)
        except OSError:
            self.sock.close()
            self.sock = None
            return
        finally:
            os.umask(old)
        self.notifier = QtCore.QSocketNotifier(self.sock.fileno(), QtCore.QSocketNotifier.Type.Read, self)
        self.notifier.activated.connect(self._accept)

    def _accept(self, *_):
        try:
            conn, _addr = self.sock.accept()
        except OSError:
            return
        if not _peer_is_us(conn):
            conn.close()
            return
        try:
            conn.settimeout(0.5)
            data = conn.recv(4096)
            try:
                msg = json.loads(data.decode("utf-8", "replace").strip() or "{}")
            except ValueError:
                msg = {}
            conn.sendall(b"ok\n")
        except OSError:
            msg = {}
        finally:
            conn.close()
        self.received.emit(msg if isinstance(msg, dict) else {})

    def close(self):
        if self.sock is not None:
            self.notifier.setEnabled(False)
            self.sock.close()
            self.sock = None
            try:
                os.unlink(self.path)
            except OSError:
                pass


class App(QtCore.QObject):
    def __init__(self, cli=None, monitor=None, interval_ms=2000, tray=True, agent_factory=None, recorder=None):
        super().__init__()
        self.cli = cli or Cli()
        factory = agent_factory if agent_factory is not None else agent_factory_or_none()
        self.ctl = Controller(self.cli, monitor or Monitor(root=os.environ.get("SO_ROOT", "/")),
                              agent_factory=(lambda: factory(self.cli)) if factory else None)
        if tray and recorder is None:
            # the tray (not a window opened from the GNOME menu) keeps the
            # resource averages; on GNOME the extension's monitor does
            from .history import Recorder
            recorder = Recorder()
        self.ctl.recorder = recorder
        if tray:                            # the icon runs all day: it starts the agent's quick look
            from .trigger import TriageTrigger
            self.ctl.trigger = TriageTrigger()
        if os.environ.get("SO_ROOT", "/") == "/":
            from .pcp import PcpSource
            self.ctl.pcp = PcpSource()
        self.panel = Panel(self.ctl)
        self.panel.setWindowIcon(load_icon())
        self.panel.text_requested.connect(self.show_text)
        self.panel.quit_requested.connect(self.quit)
        self.dialogs = []
        self._news_offered = False
        self.tray = None
        self.listener = None
        if tray:
            self.tray = QtWidgets.QSystemTrayIcon(load_icon(), self)
            self._menu = self._build_quick_menu()
            self.tray.setContextMenu(self._menu)
            self.tray.activated.connect(self._activated)
            self.ctl.sample_changed.connect(self._update_quick)
            self.ctl.info_changed.connect(self._update_quick)
            self.ctl.message.connect(self._notify)
            self.ctl.alert.connect(lambda text: self._notify(text, True))
        self.timer = QtCore.QTimer(self)
        self.timer.timeout.connect(self.ctl.tick)
        self.timer.start(interval_ms)
        self.ctl.monitor.cpu()          # prime the counters
        self.ctl.tick()
        self.ctl.refresh()

    # -- the quick view: the tray icon's menu ----------------------------
    def _build_quick_menu(self):
        menu = QtWidgets.QMenu()
        self.quick_actions = []
        for _ in range(QUICK_ROWS):
            a = menu.addAction("")
            a.setVisible(False)
            a.triggered.connect(lambda _=False, act=a: self.show_panel(act.data()))
            self.quick_actions.append(a)
        menu.addSeparator()
        menu.addAction("Open dashboard", lambda: self.show_panel("overview"))
        menu.addAction("Settings…", lambda: self.show_panel("settings"))
        menu.addSeparator()
        menu.addAction("Quit", self.quit)
        return menu

    def _update_quick(self):
        rows = self.ctl.quick_rows()[:QUICK_ROWS]
        for i, a in enumerate(self.quick_actions):
            if i < len(rows):
                if a.text() != rows[i]["text"]:
                    a.setText(rows[i]["text"])
                a.setData(rows[i]["page"])
            if a.isVisible() != (i < len(rows)):
                a.setVisible(i < len(rows))
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
            if self.panel.isVisible() and self.panel.isActiveWindow():
                self.panel.close()
            else:
                self.show_panel()

    # -- the full view ---------------------------------------------------
    def show_panel(self, page=None, token=None):
        self.ctl.refresh()
        if page:
            self.panel.goto(page)
        if token:                       # Wayland: the launcher's permission to take focus
            os.environ["XDG_ACTIVATION_TOKEN"] = token
        if self.panel.isMinimized():
            self.panel.setWindowState(self.panel.windowState() & ~QtCore.Qt.WindowState.WindowMinimized)
        self.panel.show()
        self.panel.raise_()
        self.panel.activateWindow()
        handle = self.panel.windowHandle()
        if handle is not None:
            handle.requestActivate()
        if not self._news_offered:          # once per start: is this the first look since an update?
            self._news_offered = True
            QtCore.QTimer.singleShot(1200, self.panel.offer_whats_new)

    def listen(self, path=None):
        self.listener = Listener(path, self)
        self.listener.received.connect(self.handle)
        return self.listener.sock is not None

    def handle(self, msg):
        """A request from a second start (see send_to_running)."""
        if msg.get("quit"):
            self.quit()
        elif not msg.get("ping"):
            page = msg.get("page")
            self.show_panel(page if isinstance(page, str) else None,
                            msg.get("token") if isinstance(msg.get("token"), str) else None)

    def quit(self):
        from .pcp import stop_readers
        stop_readers()
        self.panel.save_size()
        if self.listener:
            self.listener.close()
        if self.ctl.recorder:
            self.ctl.recorder.close()
        QtWidgets.QApplication.quit()

    def show_text(self, title, text):
        d = OutputDialog(title, text, self.panel)
        d.finished.connect(lambda _=0, dd=d: self.dialogs.remove(dd) if dd in self.dialogs else None)
        self.dialogs.append(d)
        d.show()


def build_parser():
    p = argparse.ArgumentParser(prog="system-optimize-tray",
                                description="The system-optimize tray icon and its full view.")
    p.add_argument("--version", action="version", version="system-optimize-tray " + VERSION)
    p.add_argument("--panel", action="store_true", help="only the full view as a window, without a tray icon")
    p.add_argument("--page", choices=("overview", "settings", "changes", "benchmarks", "agent", "about"),
                   help="open the full view on this page")
    p.add_argument("--chat", action="store_true", help="open the full view on the tuning agent (--page agent)")
    p.add_argument("--resource", choices=sorted(METRICS), help="open the full view on a resource's history")
    p.add_argument("--step", metavar="NAME", help="open the full view on a tuning step's page")
    p.add_argument("--autostart", action="store_true",
                   help="start the tray icon without opening the full view (what the login autostart runs)")
    p.add_argument("--quit", action="store_true", help="quit the running instance")
    p.add_argument("--force", action="store_true",
                   help="show the tray icon even when the GNOME Shell extension is enabled")
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    if args.quit:
        send_to_running({"quit": True})
        return 0
    page = "agent" if args.chat else ("resource:" + args.resource) if args.resource else args.page
    if args.step:
        if not NAME_RE.match(args.step):
            print("system-optimize-tray: not a step name: %s" % args.step, file=sys.stderr)
            return 2
        page = "step:" + args.step
    extension = not args.force and gnome_extension_enabled()
    if args.autostart:
        if extension or send_to_running({"ping": True}):
            return 0      # the Shell extension is the icon on GNOME; or the icon is already there
    else:
        if extension:
            try:
                os.unlink(quit_flag())      # opening the app brings a quit indicator back
            except OSError:
                pass
        if send_to_running({"page": page or "overview", "token": os.environ.get("XDG_ACTIVATION_TOKEN")}):
            return 0

    QtWidgets.QApplication.setApplicationName("system-optimize-tray")
    QtWidgets.QApplication.setDesktopFileName(APP_ID)
    app = QtWidgets.QApplication(sys.argv[:1])
    tray = not args.panel and not extension and QtWidgets.QSystemTrayIcon.isSystemTrayAvailable()
    if args.autostart and not tray:
        print("system-optimize-tray: this desktop shows no tray icons. On GNOME, enable the "
              "system-optimize Shell extension (gnome-extensions enable %s); system-optimize-tray "
              "without --autostart opens the full view as a window." % EXTENSION_UUID, file=sys.stderr)
        return 1
    a = App(tray=tray)
    a.listen()
    app.setQuitOnLastWindowClosed(not tray)
    if tray:
        a.tray.show()
        a._update_quick()
    if not args.autostart:
        a.show_panel(page)
    return app.exec()
