"""The full view: one resizable window with a sidebar and a page.

  Overview    what the machine is doing now: live tiles, the same resources
              as charts on one time axis with every setting change marked
              through all of them, and a status column
  Settings    everything that changes the machine (profile, apply, a switch
              per step) and the app's own preferences
  Changes     snapshots with Undo, the change log, the status report
  Benchmarks  the latest run against the baseline, the score over time
  Agent       the tuning agent's chat (only when the optional agent is installed)

A step and a resource each have a page of their own, opened from Settings
and Overview, with Back to where they came from. The quick view (the tray
icon's menu, the GNOME panel menu) is not here: see app.py and the
extension. Design notes: tray/docs/redesign.md.
"""

import html
import os
import threading
import time

from . import VERSION
from . import settings as settings_mod
from .cli import CliError
from .credits import GROUPS
from .model import (CHAT_PROMPT_SECONDS, PressureAlerts, actions_available, baseline_compare, categories,
                    category_count, change_log, chat_prompt, feature_entries, fmt_pct, gpu_top_text, llm_line,
                    measured_effect, quick_rows, score_series, steps_summary, warning_lines)
from .monitor import PSI_THRESHOLDS
from .qt import QtCore, QtGui, QtWidgets, Signal
from .theme import SERIES, apply_scheme, colors, figures, mono, stylesheet
from .widgets import Card, ElidedLabel, FeatureRow, ScoreBar, Switch, Tile, TileGrid, TimeChart

Qt = QtCore.Qt
DEFAULT_SIZE = (1040, 680)
MIN_SIZE = (720, 520)
SIDE_BY_SIDE = 980          # from this width the Overview's status column sits beside the charts
PAGES = (("overview", "Overview"), ("settings", "Settings"), ("changes", "Changes"),
         ("benchmarks", "Benchmarks"), ("agent", "Agent"))
ALIASES = {"history": "changes", "chat": "agent", "dashboard": "overview"}
THEMES = (("system", "Follow the desktop"), ("light", "Light"), ("dark", "Dark"))
# metric, tile title, unit, colour, fixed maximum
RESOURCES = (("cpu", "CPU load", "%", SERIES[0], 100), ("memory", "Memory", "%", SERIES[1], 100),
             ("cpu_temp", "CPU temperature", "°C", SERIES[4], None), ("disk", "Disk I/O", "MB/s", SERIES[3], None),
             ("gpu", "GPU busy", "%", SERIES[2], 100), ("gpu_mem", "GPU memory", "%", SERIES[5], 100))


def _iso_to_ts(text):
    from datetime import datetime, timezone
    try:
        dt = datetime.fromisoformat(str(text).replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        return time.mktime(dt.timetuple())
    return dt.astimezone(timezone.utc).timestamp()


def _snapshot_time(snap_id):
    """'Nov 03 11:40' from a snapshot id (20261103-114050)."""
    try:
        return time.strftime("%b %d %H:%M", time.strptime(snap_id[:15], "%Y%m%d-%H%M%S"))
    except ValueError:
        return snap_id


def _label(text, role=None, wrap=False):
    lab = QtWidgets.QLabel(text)
    if role:
        lab.setProperty("role", role)
    lab.setWordWrap(wrap)
    return lab


def _table(headers, stretch):
    t = QtWidgets.QTableWidget(0, len(headers))
    t.setHorizontalHeaderLabels(headers)
    t.verticalHeader().hide()
    t.setEditTriggers(QtWidgets.QAbstractItemView.EditTrigger.NoEditTriggers)
    t.setSelectionMode(QtWidgets.QAbstractItemView.SelectionMode.NoSelection)
    t.setShowGrid(False)
    t.setAlternatingRowColors(True)
    hh = t.horizontalHeader()
    for i in range(len(headers)):
        hh.setSectionResizeMode(i, QtWidgets.QHeaderView.ResizeMode.Stretch if i == stretch
                                else QtWidgets.QHeaderView.ResizeMode.ResizeToContents)
    t.setMinimumHeight(150)
    return t


def _set_row(table, r, texts, color=None, color_col=None):
    for col, text in enumerate(texts):
        item = QtWidgets.QTableWidgetItem(text)
        item.setToolTip(text)
        if color and col == color_col:
            item.setForeground(QtGui.QColor(color))
        table.setItem(r, col, item)


class Bridge(QtCore.QObject):
    done = Signal(int, object)


class Controller(QtCore.QObject):
    """State shared by the full view and the tray icon; runs slow work off
    the UI thread."""
    info_changed = Signal()
    sample_changed = Signal()
    busy_changed = Signal(bool)
    message = Signal(str, bool)          # text, is_error
    applied = Signal(str)                # a change went through: what it was
    alert = Signal(str)                  # a pressure (PSI) alert to notify about

    def __init__(self, cli, monitor, agent_factory=None, parent=None):
        super().__init__(parent)
        self.cli = cli
        self.monitor = monitor
        self.agent_factory = agent_factory  # () -> Agent, or None when not installed
        self.recorder = None                # history.Recorder when this process keeps resource averages
        self.trigger = None                 # trigger.TriageTrigger when this process is the all-day watcher
        self.pcp = None                     # pcp.PcpSource: Performance Co-Pilot's archives, when installed
        self.info = {"found": False, "features": [], "capabilities": []}
        self.history = {"benchmarks": [], "changes": [], "available": False}
        self.sample = None
        self.busy = False
        self.pressure = PressureAlerts()
        self.psi_alerts = settings_mod.load().get("PSI_ALERTS", "1") == "1"
        self._bridge = Bridge()
        self._bridge.done.connect(self._done)
        self._callbacks = {}
        self._token = 0

    # background work
    def run_bg(self, fn, cb=None, busy=False):
        self._token += 1
        tok = self._token
        self._callbacks[tok] = (cb, busy)
        if busy:
            self.busy = True
            self.busy_changed.emit(True)

        def work():
            try:
                res = fn()
            except CliError as exc:
                res = exc
            except Exception as exc:   # never let a worker kill the app
                res = CliError(str(exc))
            try:
                self._bridge.done.emit(tok, res)
            except RuntimeError:       # the window went away while this ran (PyQt6)
                pass

        threading.Thread(target=work, daemon=True).start()

    def _done(self, tok, res):
        cb, busy = self._callbacks.pop(tok, (None, False))
        if busy:
            self.busy = False
            self.busy_changed.emit(False)
        if cb:
            cb(res)

    def tick(self):
        try:
            self.sample = self.monitor.sample()
        except Exception:   # a broken sensor must not stop the readout
            self.sample = None
        if self.recorder and self.sample:
            self.recorder.add(self.sample)
        fresh = self.pressure.update(self.sample)
        if fresh and self.trigger:          # a pressure episode began: the agent's quick look
            self.trigger.fire()
        # psi-notify already notifies about the same thing: don't double up
        if self.psi_alerts and not (self.sample or {}).get("pressure_notifier"):
            for text in fresh:
                self.alert.emit(text)
        self.sample_changed.emit()

    def warnings(self):
        """Conflict warnings and current pressure."""
        return warning_lines(self.sample, self.info) + self.pressure.active

    def proposal(self):
        """The agent's pending suggestion, or None."""
        if self.agent_factory is None:
            return None
        try:
            from so_agent import store
            return store.load_proposal()
        except Exception:
            return None

    def quick_rows(self):
        return quick_rows(self.sample, self.info, self.proposal(), self.pressure.active)

    def refresh(self):
        def both():
            info = self.cli.describe()
            hist = self.cli.history(limit=200)
            return info, hist

        def done(res):
            if not isinstance(res, Exception):
                self.info, self.history = res
                self.info_changed.emit()
        self.run_bg(both, done)

    def change(self, fn, what):
        def done(res):
            if isinstance(res, Exception):
                self.message.emit(str(res), True)
            else:
                rc, out, err = res
                if rc == 0:
                    self.message.emit("%s: done." % what, False)
                    self.applied.emit(what)
                elif rc in (126, 127):
                    self.message.emit("Not changed: authorisation was cancelled or refused.", True)
                else:
                    tail = "\n".join([ln for ln in (out + err).splitlines() if ln.strip()][-3:])
                    self.message.emit("%s failed (exit %d)\n%s" % (what, rc, tail), True)
            self.refresh()
        self.run_bg(fn, done, busy=True)


class Panel(QtWidgets.QWidget):
    text_requested = Signal(str, str)   # title, text (shown in a dialog by the app)
    quit_requested = Signal()

    def __init__(self, ctl, parent=None):
        super().__init__(parent)
        self.setObjectName("Panel")
        self.setWindowTitle("system-optimize")
        self.ctl = ctl
        self.settings = settings_mod.load()
        apply_scheme(self.settings["THEME"])
        self.c = colors()
        self.setMinimumSize(*MIN_SIZE)
        self._restore_size()
        self.agent = None
        self.proposal = None
        self.detail_name = None
        self.resource_name = None
        self._origin = "overview"
        self._page = "overview"
        self._pulsed = None           # the suggestion whose row has already pulsed in this window
        self._suggested_row = None

        root = QtWidgets.QHBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)
        root.addWidget(self._build_sidebar())
        right = QtWidgets.QVBoxLayout()
        right.setContentsMargins(0, 0, 0, 0)
        right.setSpacing(0)
        self.stack = QtWidgets.QStackedWidget()
        right.addWidget(self.stack, 1)
        right.addWidget(self._build_message_bar())
        root.addLayout(right, 1)

        self.pages = {
            "overview": self._build_overview(),
            "settings": self._build_settings(),
            "changes": self._build_changes(),
            "benchmarks": self._build_benchmarks(),
            "agent": self._build_chat(),
        }
        self.dash = self.overview = self.pages["overview"]
        self.chat = self.pages["agent"]
        self.detail = self._build_detail()
        self.resource = self._build_resource()
        self.about = self._build_about()
        for w in (*self.pages.values(), self.detail, self.resource, self.about):
            self.stack.addWidget(w)

        ctl.sample_changed.connect(self._on_sample)
        ctl.info_changed.connect(self._on_info)
        ctl.busy_changed.connect(self._on_busy)
        ctl.message.connect(self.show_message)
        ctl.applied.connect(self._on_applied)
        self._shortcuts()
        self._restyle()
        self._on_info()
        # example questions take turns as the agent field's placeholder text
        self._prompt_i = int(time.time() // CHAT_PROMPT_SECONDS)
        self._rotate_prompt()
        self.prompt_timer = QtCore.QTimer(self)
        self.prompt_timer.timeout.connect(self._rotate_prompt)
        self.prompt_timer.start(CHAT_PROMPT_SECONDS * 1000)
        self.act_timer = QtCore.QTimer(self)      # the charts gain a point a minute
        self.act_timer.timeout.connect(lambda: self._page == "overview" and self.isVisible() and self._load_activity())
        self.act_timer.start(60000)
        self.show_page("overview")

    # -- window ------------------------------------------------------
    def _restore_size(self):
        w, h, maxed = *DEFAULT_SIZE, False
        saved = self.settings.get("WINDOW", "")
        if saved:
            size, _, flag = saved.partition(",")
            try:
                w, h = (int(x) for x in size.split("x"))
                maxed = flag == "max"
            except ValueError:
                pass
        screen = QtGui.QGuiApplication.primaryScreen()
        if screen is not None:
            area = screen.availableGeometry()
            w, h = min(w, area.width()), min(h, area.height())
        self.resize(max(w, MIN_SIZE[0]), max(h, MIN_SIZE[1]))
        self._normal_size = self.size()
        if maxed:
            self.setWindowState(self.windowState() | Qt.WindowState.WindowMaximized)

    def save_size(self):
        size = self.size() if not self.isMaximized() else self._normal_size
        value = "%dx%d%s" % (size.width(), size.height(), ",max" if self.isMaximized() else "")
        try:
            settings_mod.save("WINDOW", value)
            self.settings["WINDOW"] = value
        except (OSError, ValueError):
            pass

    def closeEvent(self, e):
        self.save_size()
        super().closeEvent(e)

    def resizeEvent(self, e):
        if not self.isMaximized():
            self._normal_size = self.size()
        self._reflow()
        super().resizeEvent(e)

    def _reflow(self):
        """Status column beside the charts when there is room, below otherwise."""
        wide = self.width() >= SIDE_BY_SIDE
        B = QtWidgets.QBoxLayout.Direction
        self.ov_body.setDirection(B.LeftToRight if wide else B.TopToBottom)
        if wide:
            self.status_col.setFixedWidth(300)
        else:
            self.status_col.setMinimumWidth(0)
            self.status_col.setMaximumWidth(16777215)
        self.status_wide = wide

    def _shortcuts(self):
        def key(seq, fn):
            sc = QtGui.QShortcut(QtGui.QKeySequence(seq), self)
            sc.activated.connect(fn)
        for i, (name, _title) in enumerate(PAGES):
            key("Ctrl+%d" % (i + 1), lambda n=name: self.show_page(n))
        key("Alt+Left", self.back)
        key(QtGui.QKeySequence.StandardKey.Quit, self.quit_requested.emit)
        key(QtGui.QKeySequence.StandardKey.Close, self.close)

    def keyPressEvent(self, e):
        # Escape goes back from a step's or a resource's page, unless a text
        # field has the keyboard (there it clears or leaves the field)
        if (e.key() == Qt.Key.Key_Escape and self.stack.currentWidget() in (self.detail, self.resource, self.about)
                and not isinstance(self.focusWidget(), QtWidgets.QLineEdit)):
            self.back()
        else:
            super().keyPressEvent(e)

    # -- theme -------------------------------------------------------
    def apply_theme(self, setting=None):
        if setting:
            self.settings["THEME"] = setting
            try:
                settings_mod.save("THEME", setting)
            except OSError:
                pass
        apply_scheme(self.settings["THEME"])
        self._restyle()

    def _restyle(self):
        self.c.update(colors())
        self._styled = dict(self.c)
        self.setStyleSheet(stylesheet(self.c))
        i = self.theme_box.findData(self.settings["THEME"])
        if i >= 0 and i != self.theme_box.currentIndex():
            self.theme_box.blockSignals(True)
            self.theme_box.setCurrentIndex(i)
            self.theme_box.blockSignals(False)
        self._on_info()
        for w in self.findChildren(QtWidgets.QWidget):
            w.update()

    def changeEvent(self, e):
        # The desktop switched between light and dark (or changed its accent):
        # take the new palette. Our own setStyleSheet also sends PaletteChange,
        # so restyle only when the colours really differ, or this loops.
        if e.type() == QtCore.QEvent.Type.PaletteChange and getattr(self, "_styled", None) is not None \
                and colors() != self._styled:
            QtCore.QTimer.singleShot(0, self._restyle)
        super().changeEvent(e)

    # -- sidebar and messages ------------------------------------------
    def _build_sidebar(self):
        side = QtWidgets.QWidget()
        side.setFixedWidth(196)
        lay = QtWidgets.QVBoxLayout(side)
        lay.setContentsMargins(10, 12, 10, 10)
        lay.setSpacing(8)
        head = QtWidgets.QHBoxLayout()
        icon = QtWidgets.QLabel()
        icon.setPixmap(QtGui.QIcon.fromTheme("system-optimize-tray").pixmap(24, 24))
        head.addWidget(icon)
        name = QtWidgets.QLabel("system-optimize")
        f = name.font()
        f.setWeight(QtGui.QFont.Weight.DemiBold)
        name.setFont(f)
        head.addWidget(name, 1)
        lay.addLayout(head)
        self.nav = QtWidgets.QListWidget()
        self.nav.setFrameShape(QtWidgets.QFrame.Shape.NoFrame)
        self.nav.setAccessibleName("Pages")
        self.nav.viewport().setAutoFillBackground(False)
        self.nav.setSpacing(1)
        for key, title in PAGES:
            item = QtWidgets.QListWidgetItem(title)
            item.setData(Qt.ItemDataRole.UserRole, key)
            item.setSizeHint(QtCore.QSize(0, 34))
            self.nav.addItem(item)
        self.nav.currentRowChanged.connect(lambda r: r >= 0 and self.show_page(PAGES[r][0]))
        lay.addWidget(self.nav, 1)
        self.version_label = ElidedLabel("")     # "system-optimize 2.0.1 (git 0ecd836, single file)" is long
        self.version_label.setProperty("role", "muted")
        lay.addWidget(self.version_label)
        self.menu_btn = QtWidgets.QToolButton()
        self.menu_btn.setText("Menu")
        micon = QtGui.QIcon.fromTheme("open-menu-symbolic")
        if not micon.isNull():
            self.menu_btn.setIcon(micon)
            self.menu_btn.setToolButtonStyle(Qt.ToolButtonStyle.ToolButtonTextBesideIcon)
        self.menu_btn.setPopupMode(QtWidgets.QToolButton.ToolButtonPopupMode.InstantPopup)
        self.menu_btn.setAccessibleName("Menu")
        menu = QtWidgets.QMenu(self.menu_btn)
        self.act_news = menu.addAction("What's new", lambda: self.open_whats_new())
        self.act_about = menu.addAction("About system-optimize", self.open_about)
        menu.addSeparator()
        self.act_quit = menu.addAction("Quit", self.quit_requested.emit)
        self.act_quit.setShortcut(QtGui.QKeySequence(QtGui.QKeySequence.StandardKey.Quit))
        self.menu_btn.setMenu(menu)
        lay.addWidget(self.menu_btn)
        return side

    def _build_message_bar(self):
        bar = QtWidgets.QWidget()
        lay = QtWidgets.QHBoxLayout(bar)
        lay.setContentsMargins(18, 6, 18, 8)
        self.toast = _label("", "muted", wrap=True)
        lay.addWidget(self.toast, 1)
        self.toast_undo = QtWidgets.QPushButton("Undo")
        self.toast_undo.setToolTip("Put back what that change replaced")
        self.toast_undo.clicked.connect(self._undo_last)
        self.toast_undo.hide()
        lay.addWidget(self.toast_undo)
        self.message_bar = bar
        bar.hide()
        self._toast_serial = 0
        return bar

    def show_message(self, text, error=False):
        self._toast_serial += 1
        serial = self._toast_serial
        self.toast.setText(text)
        self.toast.setProperty("role", "bad" if error else "muted")
        self.toast.style().unpolish(self.toast)
        self.toast.style().polish(self.toast)
        self.toast_undo.hide()           # _on_applied shows it again after a change that went through
        self.message_bar.show()
        keep = 12000 if error else 5000
        QtCore.QTimer.singleShot(keep, lambda: serial == self._toast_serial and self.message_bar.hide())

    def offer_whats_new(self):
        """The first time the window opens after an update, show the release
        notes themselves, once per version. Not on a fresh install: nothing
        is new to someone who has just arrived. True when shown."""
        from . import whatsnew
        seen = self.settings.get("SEEN_VERSION", "")
        if seen == VERSION:
            return False
        # no version recorded: an update from before this existed if the
        # settings file is already there, a fresh install if it is not
        fresh = not seen and not os.path.exists(settings_mod.path())
        try:
            settings_mod.save("SEEN_VERSION", VERSION)
            self.settings["SEEN_VERSION"] = VERSION
        except (OSError, ValueError):
            pass
        if fresh or not whatsnew.since(whatsnew.entries(whatsnew.load_text()), seen):
            return False
        self.open_whats_new(since=seen)
        return True

    def open_whats_new(self, since=None):
        """The release notes. From the menu: all of them. After an update:
        what is new since the version last seen, then the rest below."""
        from . import whatsnew
        notes = whatsnew.entries(whatsnew.load_text())
        d = QtWidgets.QDialog(self)
        d.setWindowTitle("What's new in system-optimize")
        d.resize(640, 660)
        lay = QtWidgets.QVBoxLayout(d)
        if since is not None:
            head = _label("system-optimize was updated to version %s. Here is what changed." % VERSION, wrap=True)
            lay.addWidget(head)
        view = QtWidgets.QTextBrowser(d)
        view.setOpenExternalLinks(True)
        view.setMarkdown(whatsnew.markdown(notes) if notes else "No release notes are installed with this copy.")
        lay.addWidget(view)
        foot = QtWidgets.QHBoxLayout()
        foot.addWidget(_label("Always available from Menu, What's new.", "muted"), 1)
        box = QtWidgets.QDialogButtonBox(QtWidgets.QDialogButtonBox.StandardButton.Close, d)
        box.rejected.connect(d.reject)
        foot.addWidget(box)
        lay.addLayout(foot)
        self.news_dialog = d
        self.news_view = view
        d.show()
        d.raise_()
        return d

    def _on_applied(self, what):
        # an Undo right where the change was made; the list is on Changes
        if "undo" in set(self.ctl.info.get("capabilities") or ()) and not what.startswith("Undo"):
            self.toast_undo.show()
            self._toast_serial += 1
            serial = self._toast_serial
            QtCore.QTimer.singleShot(12000, lambda: serial == self._toast_serial and self.message_bar.hide())

    def _undo_last(self):
        self.toast_undo.hide()
        self.ctl.change(self.ctl.cli.undo, "Undo")

    def _on_busy(self, busy):
        self._on_info()
        if busy:
            self.show_message("Working… (your password may be asked for)", False)

    # -- navigation ----------------------------------------------------
    def show_page(self, name):
        name = ALIASES.get(name, name)
        if name not in self.pages or (name == "agent" and self.ctl.agent_factory is None):
            name = "overview"
        self._page = name
        self.stack.setCurrentWidget(self.pages[name])
        row = [k for k, _ in PAGES].index(name)
        if self.nav.currentRow() != row:
            self.nav.blockSignals(True)
            self.nav.setCurrentRow(row)
            self.nav.blockSignals(False)
        if name == "overview":
            self._load_activity()
        elif name == "agent":
            self.chat_edit.setFocus()
            self._load_models()

    def goto(self, target):
        """Open a page by name, as the quick view and --page ask for it:
        a page, 'resource:cpu', 'step:sysctl' or 'about'."""
        target = target or "overview"
        if target.startswith("resource:"):
            self.open_resource(target.split(":", 1)[1])
        elif target.startswith("step:"):
            name = target.split(":", 1)[1]
            prop = self.ctl.proposal() or {}
            if prop.get("target") == name and prop.get("action") in ("enable_step", "disable_step"):
                # a suggestion about it: straight to the step's page, where it
                # can be applied; Back goes to the list, the row marked there
                self._page = "settings"
                self._pulsed = None
            self.open_feature(name)
        elif target == "about":
            self.open_about()
        else:
            self.show_page(target)

    def focus_step(self, name):
        """Settings, scrolled to one step, its row drawing the eye."""
        self.filter_edit.clear()
        self._pulsed = None
        self.show_page("settings")
        self._on_info()
        row = self._suggested_row or next((r for _h, rows in self._sections for r in rows if r.name == name), None)
        if row is None:
            return
        row.set_attention(True)
        area = self.pages["settings"].findChild(QtWidgets.QScrollArea)
        QtCore.QTimer.singleShot(0, lambda: area.ensureWidgetVisible(row, 0, 120))
        row.setFocus()

    def back(self):
        if self.stack.currentWidget() in (self.detail, self.resource, self.about):
            came_from_step = self.stack.currentWidget() is self.detail and self._origin == "settings"
            self.show_page(self._origin)
            prop = self.ctl.proposal() or {}
            if came_from_step and prop.get("target") == self.detail_name and \
                    prop.get("action") in ("enable_step", "disable_step"):
                self.focus_step(self.detail_name)

    def show_dashboard(self):
        self.show_page("overview")

    def _drill(self, widget):
        if self.stack.currentWidget() in self.pages.values():
            self._origin = self._page
        self.stack.setCurrentWidget(widget)

    def _scroll_page(self):
        page = QtWidgets.QWidget()
        outer = QtWidgets.QVBoxLayout(page)
        outer.setContentsMargins(0, 0, 0, 0)
        area = QtWidgets.QScrollArea()
        area.setWidgetResizable(True)
        area.setFrameShape(QtWidgets.QFrame.Shape.NoFrame)
        area.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        area.viewport().setAutoFillBackground(False)
        inner = QtWidgets.QWidget()
        inner.setAutoFillBackground(False)
        lay = QtWidgets.QVBoxLayout(inner)
        lay.setContentsMargins(18, 14, 18, 14)
        lay.setSpacing(10)
        area.setWidget(inner)
        outer.addWidget(area)
        return page, lay

    def _back_row(self, lay):
        top = QtWidgets.QHBoxLayout()
        back = QtWidgets.QPushButton("Back")
        icon = QtGui.QIcon.fromTheme("go-previous-symbolic")
        if not icon.isNull():
            back.setIcon(icon)
        back.setToolTip("Back (Alt+Left)")
        back.clicked.connect(self.back)
        top.addWidget(back)
        top.addStretch(1)
        lay.addLayout(top)
        return top

    # -- Overview ------------------------------------------------------
    def _open_suggestion(self):
        """Where the pending suggestion can be acted on."""
        from so_agent.tools import page_for
        prop = self.ctl.proposal() or {}
        self.goto(page_for(prop.get("action"), prop.get("target")))

    def _info_card(self, title, page=None):
        card = Card(clickable=bool(page))
        cl = QtWidgets.QVBoxLayout(card)
        cl.setContentsMargins(12, 9, 12, 10)
        cl.setSpacing(2)
        cl.addWidget(_label(title, "muted"))
        body = _label("", wrap=True)
        body.setTextFormat(Qt.TextFormat.PlainText)     # some of this is a model's words: never markup
        body.setFont(figures())
        cl.addWidget(body)
        if page:
            card.clicked.connect(lambda p=page: self.show_page(p))
            card.setAccessibleName(title)
        return card, body

    def _build_overview(self):
        from .history import RANGES
        page, lay = self._scroll_page()
        lay.addWidget(_label("Overview", "h1"))
        self.warn_label = _label("", "warn", wrap=True)
        self.warn_label.setAccessibleName("Warnings")
        self.warn_label.hide()
        lay.addWidget(self.warn_label)

        self.tile_grid = TileGrid()
        self.tiles = {}
        for key, title, unit, color, fixed in RESOURCES:
            t = Tile(key, title, unit, color, fixed_max=fixed)
            t.setToolTip("Averages over time and around each setting change")
            t.clicked.connect(lambda k=key: self.open_resource(k))
            self.tiles[key] = t
            self.tile_grid.add(t)
        self.tiles["gpu"].hide()            # shown once the machine reports them (amdgpu, or amdgpu_top)
        self.tiles["gpu_mem"].hide()
        self.tile_grid.relayout(force=True)
        lay.addWidget(self.tile_grid)

        self.ov_body = QtWidgets.QBoxLayout(QtWidgets.QBoxLayout.Direction.LeftToRight)
        self.ov_body.setSpacing(16)
        left = QtWidgets.QVBoxLayout()
        left.setSpacing(6)
        head = QtWidgets.QHBoxLayout()
        head.addWidget(_label("Activity", "h2"))
        head.addStretch(1)
        self.range_box = QtWidgets.QComboBox()
        self.range_box.setAccessibleName("Time range")
        for key, title, *_ in RANGES:
            self.range_box.addItem(title, key)
        self.range_box.setCurrentIndex(1)
        self.range_box.currentIndexChanged.connect(lambda _i: self._load_activity())
        head.addWidget(self.range_box)
        left.addLayout(head)
        self.act_note = _label("", "muted", wrap=True)
        left.addWidget(self.act_note)
        self.act_charts = {}
        for key, title, unit, color, _fixed in RESOURCES:
            ch = TimeChart(self.c, unit=unit, title=title, color=color)
            ch.clicked.connect(lambda k=key: self.open_resource(k))
            ch.setVisible(key not in ("gpu", "gpu_mem"))
            self.act_charts[key] = ch
            left.addWidget(ch)
        left.addStretch(1)
        self.ov_body.addLayout(left, 1)

        self.status_col = QtWidgets.QWidget()
        sl = QtWidgets.QVBoxLayout(self.status_col)
        sl.setContentsMargins(0, 0, 0, 0)
        sl.setSpacing(8)
        self.steps_card, self.steps_label = self._info_card("Tuning steps", "settings")
        self.steps_card.setToolTip("Open Settings")
        self.agent_card, self.proposal_label = self._info_card("Tuning agent suggests")
        self.agent_card._clickable = True
        self.agent_card.setCursor(Qt.CursorShape.PointingHandCursor)
        self.agent_card.setAccessibleName("Tuning agent suggests")
        self.agent_card.clicked.connect(self._open_suggestion)
        self.power_card, self.power_label = self._info_card("Power")
        self.pressure_card, self.pressure_label = self._info_card("Pressure")
        self.pressure_card.setToolTip("Share of the last 10 seconds that tasks spent waiting for the CPU, for memory "
                                      "and for the disk (the kernel's pressure stall information)")
        self.sensors_card, self.sensors_label = self._info_card("Hottest sensors")
        self.ov_bench_card, self.ov_bench_label = self._info_card("Benchmark", "benchmarks")
        self.ov_bench_card.setToolTip("Open Benchmarks")
        for card in (self.steps_card, self.agent_card, self.power_card, self.pressure_card, self.sensors_card,
                     self.ov_bench_card):
            sl.addWidget(card)
        sl.addStretch(1)
        self.agent_card.hide()
        self.ov_body.addWidget(self.status_col)
        lay.addLayout(self.ov_body)
        lay.addStretch(1)
        return page

    def _on_sample(self):
        s = self.ctl.sample or {}
        cpu, mem = s.get("cpu") or {}, s.get("memory") or {}
        temp, disk = s.get("temperature") or {}, s.get("disk") or {}
        self.tiles["cpu"].set(cpu.get("percent"), "%.0f",
                              ("%.2f GHz" % (cpu["mhz"] / 1000.0)) if cpu.get("mhz") else "")
        self.tiles["memory"].set(mem.get("percent"), "%.0f",
                                 ("%.1f of %.0f GB" % ((mem.get("used_mb") or 0) / 1024, mem["total_mb"] / 1024))
                                 if mem.get("total_mb") else "")
        self.tiles["cpu_temp"].set(temp.get("cpu"), "%.0f",
                                   ("GPU %d°" % round(temp["gpu"])) if temp.get("gpu") is not None else "")
        r, w = disk.get("read_mbs"), disk.get("write_mbs")
        total = None if r is None or w is None else r + w
        self.tiles["disk"].set(total, "%.1f", ("read %.1f, write %.1f" % (r, w)) if total is not None else "")
        gpu = s.get("gpu") or {}
        shown = False
        if gpu.get("busy_percent") is not None:
            shown |= self.tiles["gpu"].isHidden()
            self.tiles["gpu"].show()
            self.act_charts["gpu"].show()
            self.tiles["gpu"].set(gpu["busy_percent"], "%.0f", gpu.get("name") and gpu["name"][:18] or "")
        if gpu.get("mem_total_mb"):
            t = self.tiles["gpu_mem"]
            shown |= t.isHidden()
            t.show()
            self.act_charts["gpu_mem"].show()
            t.set(gpu.get("mem_percent"), "%.0f", "%.1f of %.0f GB" % ((gpu.get("mem_used_mb") or 0) / 1024,
                                                                      gpu["mem_total_mb"] / 1024))
            tip = "VRAM %.1f / %.1f GB · GTT (shared) %.1f / %.1f GB · from %s" % (
                (gpu.get("vram_used_mb") or 0) / 1024, (gpu.get("vram_total_mb") or 0) / 1024,
                (gpu.get("gtt_used_mb") or 0) / 1024, (gpu.get("gtt_total_mb") or 0) / 1024,
                gpu.get("source") or "?")
            top = gpu_top_text(gpu)
            t.setToolTip(tip + ("\n" + top if top else ""))
        if shown:
            self.tile_grid.relayout(force=True)
        self._show_warnings()
        rows = [r for r in quick_rows(s, self.ctl.info) if r["kind"] == "readout"]
        self.power_label.setText(rows[-1]["text"].replace("Power profile ", "", 1) if s else "–")
        parts = []
        pressure = s.get("pressure") or {}
        for res, name in (("cpu", "CPU"), ("memory", "Memory"), ("io", "Disk")):
            v = ((pressure.get(res) or {}).get(PSI_THRESHOLDS[res][0]) or {}).get("avg10")
            if v is not None:
                parts.append("%s %.1f%%" % (name, v))
        self.pressure_card.setVisible(bool(parts))
        self.pressure_label.setText("   ".join(parts))
        seen, hot = set(), []
        for sen in sorted(temp.get("sensors") or [], key=lambda x: -(x.get("c") or 0)):
            key = (sen.get("chip"), sen.get("label"))
            if key in seen or not sen.get("c"):
                continue
            seen.add(key)
            hot.append("%d°C  %s %s" % (round(sen["c"]), sen.get("chip") or "", sen.get("label") or ""))
            if len(hot) == 4:
                break
        self.sensors_card.setVisible(bool(hot))
        self.sensors_label.setText("\n".join(hot))
        if self.resource_name and self.stack.currentWidget() is self.resource:
            self._res_now()

    def _show_warnings(self):
        w = self.ctl.warnings()
        self.warn_label.setVisible(bool(w))
        self.warn_label.setText("\n".join("⚠ " + x for x in w))

    def _load_activity(self):
        from .history import History, activity, change_markers
        key = self.range_box.currentData() or "day"
        metrics = list(self.act_charts)
        markers = change_markers(self.ctl.history.get("changes") or [])

        def work():
            h = History()
            try:
                return activity(h, metrics, key)
            finally:
                h.close()

        def done(res):
            if isinstance(res, Exception) or key != (self.range_box.currentData() or "day"):
                return
            series, (t0, t1) = res
            if self.settings.get("RECORD_HISTORY", "1") != "1":
                empty = "Resource history is off. Turn it on in Settings."
            else:
                empty = "Nothing recorded for this period yet."
            for m, ch in self.act_charts.items():
                ch.set(series.get(m) or [], markers, (), empty_text=empty)
                ch.set_range(t0, t1)
            inside = [m for m in markers if t0 <= m[0] <= t1]
            if inside:
                self.act_note.setText("%d setting change%s in this period, marked in amber on every chart. "
                                      "Point at a marker for the steps." % (len(inside), "" if len(inside) == 1 else "s"))
            else:
                self.act_note.setText("Setting changes show as amber markers through every chart.")
        self.ctl.run_bg(work, done)

    # -- Settings ------------------------------------------------------
    def _build_settings(self):
        page, lay = self._scroll_page()
        title = QtWidgets.QHBoxLayout()
        title.addWidget(_label("Settings", "h1"), 1)
        self.btn_preview = QtWidgets.QPushButton("Preview changes")
        self.btn_preview.setToolTip("Dry run: show what applying everything would change")
        self.btn_preview.clicked.connect(lambda: self._text("Preview (dry run)", self.ctl.cli.preview))
        title.addWidget(self.btn_preview)
        self.btn_apply = QtWidgets.QPushButton("Apply all")
        self.btn_apply.setToolTip("Run every default step and the optional ones already chosen")
        self.btn_apply.clicked.connect(lambda: self.ctl.change(self.ctl.cli.apply_all, "Apply all"))
        title.addWidget(self.btn_apply)
        lay.addLayout(title)
        lay.addWidget(_label("Each step is one change to this computer. Turning one on or off asks for your "
                             "password and saves a snapshot first, so every change can be undone.", "muted", wrap=True))
        row = QtWidgets.QHBoxLayout()
        self.profile_label = _label("Workload profile")
        row.addWidget(self.profile_label)
        self.profile_box = QtWidgets.QComboBox()
        self.profile_box.setAccessibleName("Workload profile")
        self.profile_box.setToolTip("A profile turns on the optional steps that suit one kind of work")
        row.addWidget(self.profile_box)
        self.btn_profile = QtWidgets.QPushButton("Apply profile")
        self.btn_profile.clicked.connect(self._apply_profile)
        row.addWidget(self.btn_profile)
        row.addStretch(1)
        lay.addLayout(row)
        self.filter_edit = QtWidgets.QLineEdit()
        self.filter_edit.setPlaceholderText("Filter steps")
        self.filter_edit.setClearButtonEnabled(True)
        self.filter_edit.setAccessibleName("Filter steps")
        self.filter_edit.textChanged.connect(lambda _t: self._apply_filter())
        lay.addWidget(self.filter_edit)
        self.features_box = QtWidgets.QVBoxLayout()
        self.features_box.setSpacing(6)
        lay.addLayout(self.features_box)
        self._sections = []          # (header widget, [FeatureRow])

        lay.addSpacing(8)
        lay.addWidget(_label("This app", "h2"))
        form = QtWidgets.QFormLayout()
        form.setFieldGrowthPolicy(QtWidgets.QFormLayout.FieldGrowthPolicy.FieldsStayAtSizeHint)
        self.theme_box = QtWidgets.QComboBox()
        for key, title in THEMES:
            self.theme_box.addItem(title, key)
        self.theme_box.setCurrentIndex(max(0, self.theme_box.findData(self.settings["THEME"])))
        self.theme_box.currentIndexChanged.connect(lambda _i: self.apply_theme(self.theme_box.currentData()))
        form.addRow("Appearance", self.theme_box)
        self.res_record = Switch(self.c)
        self.res_record.setChecked(self.settings.get("RECORD_HISTORY", "1") == "1")
        self.res_record.setAccessibleName("Keep resource history")
        self.res_record.setToolTip("Minute, hourly and daily averages, kept on this computer only. Minutes are "
                                   "kept for a day, hours for 90 days, daily averages for good.")
        self.res_record.clicked.connect(self.set_recording)
        form.addRow("Keep resource history", self.res_record)
        self.psi_switch = Switch(self.c)
        self.psi_switch.setChecked(self.settings.get("PSI_ALERTS", "1") == "1")
        self.psi_switch.setAccessibleName("Pressure notifications")
        self.psi_switch.setToolTip("Notify when tasks stall waiting for the CPU, memory or the disk")
        self.psi_switch.clicked.connect(self.set_psi_alerts)
        form.addRow("Pressure notifications", self.psi_switch)
        lay.addLayout(form)
        lay.addStretch(1)
        return page

    def _apply_profile(self):
        name = self.profile_box.currentText()
        if name:
            self.ctl.change(lambda: self.ctl.cli.apply_profile(name), "Profile %s" % name)

    def set_psi_alerts(self, on):
        self.settings["PSI_ALERTS"] = "1" if on else "0"
        try:
            settings_mod.save("PSI_ALERTS", self.settings["PSI_ALERTS"])
        except (OSError, ValueError):
            pass
        self.ctl.psi_alerts = bool(on)

    def set_recording(self, on):
        self.settings["RECORD_HISTORY"] = "1" if on else "0"
        try:
            settings_mod.save("RECORD_HISTORY", self.settings["RECORD_HISTORY"])
        except (OSError, ValueError):
            pass
        if self.ctl.recorder is not None:
            self.ctl.recorder.enabled = bool(on)
        if self.resource_name:
            self._load_resource(self.resource_name)

    def _apply_filter(self):
        words = self.filter_edit.text().lower().split()
        for header, rows in self._sections:
            any_shown = False
            for row in rows:
                hay = ("%s %s %s" % (row.name, row.label, row.summary)).lower()
                show = all(w in hay for w in words)
                row.setVisible(show)
                any_shown |= show
            header.setVisible(any_shown)

    def toggle_feature(self, name, on):
        feat = next((f for f in self.ctl.info.get("features") or [] if f["name"] == name), None)
        if not feat:
            return
        self.ctl.change(lambda: self.ctl.cli.set_feature(feat, on), "%s %s" % (feat["title"], "on" if on else "off"))

    def _text(self, title, fn):
        def done(res):
            if isinstance(res, Exception):
                self.show_message(str(res), True)
            else:
                self.text_requested.emit(title, res[1])
        self.ctl.run_bg(fn, done)

    # -- Changes -------------------------------------------------------
    def _build_changes(self):
        page, lay = self._scroll_page()
        lay.addWidget(_label("Changes", "h1"))
        row = QtWidgets.QHBoxLayout()
        row.addWidget(_label("Every run that changed something saved a snapshot. Undo puts back what it "
                             "replaced.", "muted", wrap=True), 1)
        self.btn_status = QtWidgets.QPushButton("Status report")
        self.btn_status.clicked.connect(lambda: self._text("Status report", self.ctl.cli.status_text))
        row.addWidget(self.btn_status)
        self.btn_undo = QtWidgets.QPushButton("Undo last run")
        self.btn_undo.setToolTip("Restore the newest snapshot not yet undone")
        self.btn_undo.clicked.connect(lambda: self.ctl.change(self.ctl.cli.undo, "Undo"))
        row.addWidget(self.btn_undo)
        lay.addLayout(row)
        lay.addWidget(_label("Snapshots", "h2"))
        self.snap_table = _table(["When", "What changed", "State", ""], 1)
        lay.addWidget(self.snap_table)
        lay.addWidget(_label("Change log", "h2"))
        self.log_table = _table(["When", "Step", "Change", "Benchmark"], 2)
        self.log_table.setMinimumHeight(220)
        lay.addWidget(self.log_table, 1)
        return page

    def _fill_changes(self, avail):
        snaps = self.ctl.info.get("snapshots") or []
        self.snap_table.setRowCount(0)
        for snap in snaps:
            r = self.snap_table.rowCount()
            self.snap_table.insertRow(r)
            _set_row(self.snap_table, r, (_snapshot_time(snap["id"]), snap.get("summary") or "",
                                          "undone" if snap.get("undone") else "in effect"))
            if not snap.get("undone"):
                b = QtWidgets.QPushButton("Undo")
                b.setEnabled(avail["undo"] and not self.ctl.busy)
                b.setAccessibleName("Undo the run of %s" % _snapshot_time(snap["id"]))
                b.clicked.connect(lambda _=False, i=snap["id"]: self.ctl.change(
                    lambda: self.ctl.cli.undo(i), "Undo %s" % _snapshot_time(i)))
                self.snap_table.setCellWidget(r, 3, b)
        if not snaps:
            self.snap_table.insertRow(0)
            _set_row(self.snap_table, 0, ("", "No snapshots yet: nothing has been changed through system-optimize.", ""))
        log = change_log(self.ctl.history)
        self.log_table.setRowCount(0)
        for c in reversed(log):
            r = self.log_table.rowCount()
            self.log_table.insertRow(r)
            ts = _iso_to_ts(c["time"])
            when = time.strftime("%b %d %H:%M", time.localtime(ts)) if ts else c["time"]
            change = "%s  %s → %s" % (c.get("target") or c.get("kind") or "", c.get("old") or "∅", c.get("new") or "∅")
            if c.get("undone"):
                change += "  (undone)"
            color = None
            if c.get("delta_pct") is not None:
                color = self.c["good"] if c["delta_pct"] >= 0 else self.c["bad"]
            _set_row(self.log_table, r, (when, c.get("step") or "", change, fmt_pct(c.get("delta_pct"))), color, 3)
        if not log:
            self.log_table.insertRow(0)
            _set_row(self.log_table, 0, ("", "", "No changes recorded yet." if self.ctl.history.get("available")
                                         else "Needs a system-optimize with --history.", ""))

    # -- Benchmarks ----------------------------------------------------
    def _build_benchmarks(self):
        page, lay = self._scroll_page()
        lay.addWidget(_label("Benchmarks", "h1"))
        bench = Card()
        bl = QtWidgets.QVBoxLayout(bench)
        bl.setContentsMargins(14, 12, 14, 12)
        top = QtWidgets.QHBoxLayout()
        top.addWidget(_label("Latest run against your baseline", "muted"))
        top.addStretch(1)
        self.bench_value = QtWidgets.QLabel("–")
        self.bench_value.setFont(figures(15, bold=True))
        top.addWidget(self.bench_value)
        bl.addLayout(top)
        self.bench_bar = ScoreBar(self.c)
        bl.addWidget(self.bench_bar)
        bottom = QtWidgets.QHBoxLayout()
        self.bench_note = _label("", "muted")
        self.bench_note.setFont(figures())
        bottom.addWidget(self.bench_note, 1)
        self.bench_btn = QtWidgets.QPushButton("Run benchmark")
        self.bench_btn.setToolTip("Measures CPU, memory and disk for a minute or two; changes nothing")
        self.bench_btn.clicked.connect(self.run_benchmark)
        bottom.addWidget(self.bench_btn)
        bl.addLayout(bottom)
        self.llm_label = _label("", "muted", wrap=True)
        self.llm_label.setToolTip("llama-bench tokens per second (prompt processing and generation), "
                                  "first run → latest")
        self.llm_label.hide()
        bl.addWidget(self.llm_label)
        lay.addWidget(bench)
        self.bench_card = bench
        lay.addWidget(_label("Score over time", "h2"))
        self.bench_chart = TimeChart(self.c, unit="score")
        lay.addWidget(self.bench_chart)
        lay.addWidget(_label("Runs", "h2"))
        self.runs_table = _table(["When", "Overall", "Profile"], 2)
        lay.addWidget(self.runs_table, 1)
        return page

    def run_benchmark(self):
        self.show_message("Benchmark running; this takes a minute or two", False)

        def done(res):
            if isinstance(res, Exception):
                self.show_message(str(res), True)
            else:
                self.text_requested.emit("Benchmark", res[1])
            self.ctl.refresh()
        self.ctl.run_bg(self.ctl.cli.benchmark, done, busy=True)

    def _fill_benchmarks(self, avail):
        from .history import change_markers
        hist = self.ctl.history
        cmp_ = baseline_compare(hist)
        self.bench_btn.setVisible(avail["benchmark"])
        self.bench_btn.setEnabled(not self.ctl.busy)
        role = None
        if cmp_ and cmp_["count"] >= 2:
            self.bench_value.setText(fmt_pct(cmp_["pct"]))
            role = "good" if (cmp_["pct"] or 0) >= 0 else "bad"
            self.bench_note.setText("%d runs, baseline %.0f, latest %.0f" % (cmp_["count"], cmp_["baseline"], cmp_["latest"]))
            self.ov_bench_label.setText("%s against your baseline, over %d runs" % (fmt_pct(cmp_["pct"]), cmp_["count"]))
        elif cmp_:
            self.bench_value.setText("baseline")
            self.bench_note.setText("1 run so far; the next shows the change")
            self.ov_bench_label.setText("Baseline recorded. Run another to see the change.")
        else:
            self.bench_value.setText("–")
            none = "No benchmark yet" if avail["benchmark"] else "Needs a system-optimize with --benchmark"
            self.bench_note.setText(none)
            self.ov_bench_label.setText(none + ("." if not avail["benchmark"] else ". Run one to set your baseline."))
        self.bench_value.setProperty("role", role)
        self.bench_value.style().unpolish(self.bench_value)
        self.bench_value.style().polish(self.bench_value)
        self.bench_bar.set(cmp_)
        llm = llm_line(hist)
        self.llm_label.setVisible(bool(llm))
        self.llm_label.setText(llm or "")
        points = [(_iso_to_ts(t), v) for t, v in score_series(hist)]
        points = [(t, v) for t, v in points if t is not None]
        empty = ("No benchmarks yet. The first run is your baseline; each later run is compared with it."
                 if hist.get("available") else "Needs a system-optimize with --history to show scores over time.")
        self.bench_chart.set(points, change_markers(hist.get("changes") or []) if points else (), (), empty_text=empty)
        self.runs_table.setRowCount(0)
        for b, (t, v) in zip(reversed([x for x in hist.get("benchmarks") or []]), reversed(points)):
            r = self.runs_table.rowCount()
            self.runs_table.insertRow(r)
            _set_row(self.runs_table, r, (time.strftime("%b %d %H:%M", time.localtime(t)), "%.0f" % v,
                                          b.get("profile") or ""))
        if not points:
            self.runs_table.insertRow(0)
            _set_row(self.runs_table, 0, ("", "", "no runs yet"))

    # -- everything that follows the CLI's state -------------------------
    def _on_info(self):
        info = self.ctl.info
        self.version_label.setText(info.get("version") or ("system-optimize not found" if not info.get("found") else ""))
        avail = actions_available(info)
        idle = not self.ctl.busy
        # Settings: the steps, grouped
        while self.features_box.count():
            item = self.features_box.takeAt(0)
            if item.widget():
                item.widget().deleteLater()
        self._sections = []
        prop = self.ctl.proposal() or {}
        suggested = prop.get("target") if prop.get("action") in ("enable_step", "disable_step") else None
        self._suggested_row = None
        summaries = {f["name"]: f.get("summary") or "" for f in info.get("features") or []}
        if not info.get("found"):
            self.features_box.addWidget(_label("system-optimize is not installed. Install it, then reopen this window.",
                                               "muted", wrap=True))
        for g in categories(info, self.ctl.history):
            head = QtWidgets.QWidget()
            hl = QtWidgets.QHBoxLayout(head)
            hl.setContentsMargins(2, 10, 2, 0)
            hl.addWidget(_label(g["title"], "h2"))
            hl.addWidget(_label(category_count(g), "muted"))
            hl.addStretch(1)
            if g["trend_pct"] is not None:
                tr = _label(fmt_pct(g["trend_pct"]), "good" if g["trend_pct"] >= 0 else "bad")
                tr.setToolTip("Benchmark change measured after this category's changes")
                hl.addWidget(tr)
            head.setAccessibleName("%s, %s" % (g["title"], category_count(g)))
            self.features_box.addWidget(head)
            rows = []
            for name, label, checked, enabled, tip in g["entries"]:
                row = FeatureRow(name, label, summaries.get(name, ""), checked, enabled and idle, tip, self.c)
                row.toggled.connect(self.toggle_feature)
                row.opened.connect(self.open_feature)
                self.features_box.addWidget(row)
                rows.append(row)
                if name == suggested:
                    # rebuilt on every refresh: pulse only when the suggestion is new to this window
                    row.suggest("Suggested: %s. Open it to apply." % prop.get("summary", ""),
                                pulse=self._pulsed != (name, prop.get("created")))
                    self._suggested_row = row
            self._sections.append((head, rows))
        self._apply_filter()
        if self._suggested_row is not None and self._page == "settings" and self.isVisible():
            self._pulsed = (suggested, prop.get("created"))
        profiles = avail["profiles"]
        for w in (self.profile_label, self.profile_box, self.btn_profile):
            w.setVisible(bool(profiles))
        if [self.profile_box.itemText(i) for i in range(self.profile_box.count())] != profiles:
            self.profile_box.clear()
            self.profile_box.addItems(profiles)
        if info.get("profile") in profiles:
            self.profile_box.setCurrentText(info["profile"])
        self.btn_profile.setEnabled(idle)
        self.btn_preview.setEnabled(avail["preview"] and idle)
        self.btn_apply.setEnabled(avail["apply_all"] and idle)
        self.btn_undo.setEnabled(avail["undo"] and idle)
        self.toast_undo.setEnabled(idle)
        self.btn_status.setEnabled(avail["status"])
        self.steps_label.setText(steps_summary(info))
        self._fill_changes(avail)
        self._fill_benchmarks(avail)
        self._show_warnings()
        self._refresh_agent()
        if self.stack.currentWidget() is self.detail and self.detail_name:
            self._fill_detail(self.detail_name)
        if self.stack.currentWidget() is self.resource and self.resource_name:
            self._load_resource(self.resource_name)
        if self._page == "overview" and self.isVisible():
            self._load_activity()

    # -- a step's page -------------------------------------------------
    def _build_detail(self):
        page, lay = self._scroll_page()
        top = self._back_row(lay)
        self.detail_switch = Switch(self.c)
        self.detail_switch.clicked.connect(lambda on: self.toggle_feature(self.detail_name, on))
        top.addWidget(self.detail_switch)
        self.detail_title = _label("", "h1", wrap=True)
        lay.addWidget(self.detail_title)
        self.detail_summary = _label("", "muted", wrap=True)
        lay.addWidget(self.detail_summary)
        # the tuning agent's (or triage's) suggestion about this step, where it can be acted on
        self.detail_proposal = Card()
        dp = QtWidgets.QHBoxLayout(self.detail_proposal)
        dp.setContentsMargins(12, 8, 10, 8)
        self.detail_proposal_label = _label("", wrap=True)
        self.detail_proposal_label.setTextFormat(Qt.TextFormat.PlainText)
        dp.addWidget(self.detail_proposal_label, 1)
        self.detail_dismiss = QtWidgets.QPushButton("Dismiss")
        self.detail_dismiss.clicked.connect(self.dismiss_proposal)
        dp.addWidget(self.detail_dismiss)
        self.detail_approve = QtWidgets.QPushButton("Apply suggestion")
        self.detail_approve.setDefault(True)
        self.detail_approve.clicked.connect(self.approve_proposal)
        dp.addWidget(self.detail_approve)
        self.detail_proposal.hide()
        lay.addWidget(self.detail_proposal)
        lay.addWidget(_label("What it does", "h2"))
        self.detail_doc = QtWidgets.QTextBrowser()
        self.detail_doc.setOpenExternalLinks(False)
        self.detail_doc.document().setDefaultStyleSheet("table { border-collapse: collapse; } td, th { padding: 3px 8px; }")
        self.detail_doc.setMinimumHeight(190)
        lay.addWidget(self.detail_doc)
        lay.addWidget(_label("Performance history", "h2"))
        self.detail_effect = _label("", "muted", wrap=True)
        lay.addWidget(self.detail_effect)
        self.detail_chart = TimeChart(self.c, unit="score")
        lay.addWidget(self.detail_chart)
        self.detail_log = _table(["When", "Change", "Effect"], 1)
        lay.addWidget(self.detail_log)
        lay.addStretch(1)
        return page

    def open_feature(self, name):
        self.detail_name = name
        self._fill_detail(name)
        self._drill(self.detail)

        def done(res):
            if not isinstance(res, Exception) and self.detail_name == name:
                self.detail_doc.setMarkdown(res.get("doc") or "_No description available._")
        self.detail_doc.setMarkdown("_Loading…_")
        self.ctl.run_bg(lambda: self.ctl.cli.describe_step(name), done)

    def _fill_detail(self, name):
        info = self.ctl.info
        feat = next((f for f in info.get("features") or [] if f["name"] == name), None)
        if not feat:
            return
        entry = next((e for e in feature_entries(info) if e[0] == name), None)
        self.detail_title.setText(feat["title"] + ("  (optional)" if feat.get("kind") == "opt-in" else ""))
        self.detail_summary.setText(feat.get("summary") or "")
        self.detail_switch.setChecked(bool(feat.get("applied")))
        self.detail_switch.setEnabled(bool(entry and entry[3]) and not self.ctl.busy)
        self.detail_switch.setToolTip(entry[4] if entry else "")
        self.detail_switch.setAccessibleName(feat["title"])
        prop = self.ctl.proposal()
        mine = bool(prop) and prop.get("target") == name and prop.get("action") in ("enable_step", "disable_step")
        self.detail_proposal.setVisible(mine)
        self.detail_proposal.set_attention(mine, pulse=mine and not self.detail_proposal.attention())
        if mine:
            self.proposal = prop
            self.detail_proposal_label.setText("Suggested: %s.\n%s" % (prop.get("summary", ""), prop.get("reason", "")))
            for b in (self.detail_approve, self.detail_dismiss):
                b.setEnabled(not self.ctl.busy)
        hist = self.ctl.history
        log = change_log(hist, step=name)
        points = [(_iso_to_ts(t), v) for t, v in score_series(hist)]
        points = [(t, v) for t, v in points if t is not None]
        markers = [(_iso_to_ts(c["time"]), c.get("target") or "") for c in log if _iso_to_ts(c["time"])]
        empty = ("No benchmarks yet. Run one from Benchmarks; each later run is compared with it."
                 if hist.get("available") else "Needs system-optimize with --history to show scores over time.")
        self.detail_chart.set(points, markers, (), empty_text=empty)
        runs, total = measured_effect(log)
        if runs:
            self.detail_effect.setText("Benchmark change across this step's %d measured run%s: %s" % (
                runs, "" if runs == 1 else "s", fmt_pct(total)))
        else:
            self.detail_effect.setText("Markers show when this step changed a setting.")
        self.detail_log.setRowCount(0)
        for c in reversed(log):
            r = self.detail_log.rowCount()
            self.detail_log.insertRow(r)
            ts = _iso_to_ts(c["time"])
            when = time.strftime("%b %d %H:%M", time.localtime(ts)) if ts else c["time"]
            change = "%s  %s → %s" % (c.get("target") or c.get("kind") or "", c.get("old") or "∅", c.get("new") or "∅")
            if c.get("undone"):
                change += "  (undone)"
            eff_text = fmt_pct(c.get("delta_pct"))
            if c.get("llm_delta_pct") is not None:
                eff_text += "  LLM %s" % fmt_pct(c["llm_delta_pct"])
            color = None
            if c.get("delta_pct") is not None:
                color = self.c["good"] if c["delta_pct"] >= 0 else self.c["bad"]
            _set_row(self.detail_log, r, (when, change, eff_text), color, 2)
        if not log:
            self.detail_log.insertRow(0)
            self.detail_log.setItem(0, 1, QtWidgets.QTableWidgetItem("no changes recorded for this step"))

    # -- a resource's page ---------------------------------------------
    def _build_resource(self):
        page, lay = self._scroll_page()
        self._back_row(lay)
        self.res_title = _label("", "h1")
        lay.addWidget(self.res_title)
        stats = QtWidgets.QHBoxLayout()
        stats.setSpacing(8)
        self.res_stats = {}
        for key, title in (("now", "Now"), ("avg", "30-day average"), ("since", "Since the first change")):
            card = Card()
            cl = QtWidgets.QVBoxLayout(card)
            cl.setContentsMargins(12, 9, 12, 9)
            cl.setSpacing(2)
            cl.addWidget(_label(title, "muted"))
            value = QtWidgets.QLabel("–")
            value.setFont(figures(15, bold=True))
            cl.addWidget(value)
            self.res_stats[key] = value
            stats.addWidget(card, 1)
        lay.addLayout(stats)
        lay.addWidget(_label("Daily average", "h2"))
        self.res_note = _label("", "muted", wrap=True)
        lay.addWidget(self.res_note)
        self.res_chart = TimeChart(self.c)
        self.res_chart.setMinimumHeight(220)
        lay.addWidget(self.res_chart)
        lay.addWidget(_label("Around each change", "h2"))
        self.res_log = _table(["When", "Change", "7 days before → after"], 1)
        lay.addWidget(self.res_log)
        lay.addStretch(1)
        return page

    def _res_now(self):
        from .history import METRICS, value
        unit = METRICS[self.resource_name][1]
        self.res_stats["now"].setText(self._fmt_value(value(self.ctl.sample, self.resource_name), unit))

    def open_resource(self, name):
        from .history import METRICS
        if name not in METRICS:
            return
        self.resource_name = name
        self.res_title.setText(METRICS[name][0])
        self.res_chart.unit = METRICS[name][1]
        self._drill(self.resource)
        # the last page's numbers must not show under this title while the
        # history loads (Performance Co-Pilot's archives can take a while)
        for key in ("avg", "since"):
            self.res_stats[key].setText("–")
            self._role(self.res_stats[key], None)
        self.res_note.setText("Loading…")
        self.res_chart.set([], [], (), empty_text="Loading…")
        self.res_log.setRowCount(0)
        self._res_now()
        self._load_resource(name)

    def _load_resource(self, name):
        from .history import History, resource_report
        from .pcp import pick_history
        changes = self.ctl.history.get("changes") or []
        source_setting = self.settings.get("HISTORY_SOURCE", "auto")

        def work():
            own = History()
            try:
                hist, source = pick_history(name, own, self.ctl.pcp, source_setting)
                rep = resource_report(hist, name, changes)
                rep["source"] = source
                return rep
            finally:
                own.close()

        def done(res):
            if self.resource_name == name and not isinstance(res, Exception):
                self._fill_resource(res)
        self.ctl.run_bg(work, done)

    def _fmt_value(self, v, unit):
        if v is None:
            return "–"
        return ("%.1f" if unit == "MB/s" else "%.0f") % v + ("%" if unit == "%" else " " + unit)

    def _effect_role(self, delta, better):
        if delta is None or better is None or abs(delta) < 0.05:
            return None
        return "good" if (delta < 0 if better == "lower" else delta > 0) else "bad"

    @staticmethod
    def _role(label, role):
        label.setProperty("role", role)
        label.style().unpolish(label)
        label.style().polish(label)

    def _fill_resource(self, rep):
        unit = rep["unit"]
        self.res_stats["avg"].setText(self._fmt_value(rep["avg30"], unit))
        since = rep["since_first_pct"]
        self.res_stats["since"].setText(fmt_pct(since))
        self._role(self.res_stats["since"], self._effect_role(since, rep["better"]))
        self.res_stats["since"].setToolTip(
            "Average since the first recorded setting change, against the 7 days before it")
        points = [(start + 43200, avg) for start, avg, *_ in rep["series"]]
        markers = [(g["time"], g["changes"][0].get("target") or g["changes"][0].get("step") or "")
                   for g in rep["markers"]]
        periods = [(pd["start"], pd["end"], pd["avg"]) for pd in rep["periods"]]
        if self.settings.get("RECORD_HISTORY", "1") != "1":
            empty = "Resource history is off. Turn it on in Settings to start recording."
        elif self.ctl.recorder is None and not points:
            empty = ("Nothing recorded yet. The tray icon (or the GNOME extension) records while it runs; "
                     "the first point appears after a day.")
        else:
            empty = "Recording. The first daily average appears after the first day."
        self.res_chart.set(points, markers, periods, empty_text=empty)
        note = ("Dashed lines: the average between setting changes. Markers: when settings changed."
                if points else "")
        if rep.get("source") == "pcp":
            note = (note + " " if note else "") + "From Performance Co-Pilot's archives."
        self.res_note.setText(note)
        self.res_log.setRowCount(0)
        for eff in reversed(rep["effects"]):
            r = self.res_log.rowCount()
            self.res_log.insertRow(r)
            when = time.strftime("%b %d %H:%M", time.localtime(eff["time"]))
            names = sorted({c.get("step") or c.get("target") or "" for c in eff["changes"]})
            what = ", ".join(n for n in names if n) or "settings"
            if len(eff["changes"]) > 1:
                what += "  (%d changes)" % len(eff["changes"])
            if eff["before"] is None or eff["after"] is None:
                ba = "not enough data"
            else:
                ba = "%s → %s  %s" % (self._fmt_value(eff["before"], unit), self._fmt_value(eff["after"], unit),
                                      fmt_pct(eff["delta_pct"]))
            role = self._effect_role(eff["delta_pct"], rep["better"])
            _set_row(self.res_log, r, (when, what, ba), self.c[role] if role else None, 2)
        if not rep["effects"]:
            self.res_log.insertRow(0)
            self.res_log.setItem(0, 1, QtWidgets.QTableWidgetItem("no setting changes recorded yet"))

    # -- Agent ---------------------------------------------------------
    def _build_chat(self):
        page = QtWidgets.QWidget()
        lay = QtWidgets.QVBoxLayout(page)
        lay.setContentsMargins(18, 14, 18, 10)
        lay.setSpacing(8)
        lay.addWidget(_label("Tuning agent", "h1"))
        self.agent_status = _label("", "muted", wrap=True)
        lay.addWidget(self.agent_status)
        mrow = QtWidgets.QHBoxLayout()
        mrow.addWidget(_label("Model"))
        self.model_box = QtWidgets.QComboBox()
        self.model_box.setEditable(True)
        self.model_box.setAccessibleName("Model")
        self.model_box.setToolTip("Any model your Ollama or llama.cpp server has; type a name to use another")
        mrow.addWidget(self.model_box, 1)
        use = QtWidgets.QPushButton("Use this model")
        use.clicked.connect(self._set_model)
        mrow.addWidget(use)
        lay.addLayout(mrow)
        self.transcript = QtWidgets.QTextBrowser()
        lay.addWidget(self.transcript, 1)
        self.chat_proposal = Card()
        cp = QtWidgets.QHBoxLayout(self.chat_proposal)
        cp.setContentsMargins(12, 8, 10, 8)
        self.chat_proposal_label = _label("", wrap=True)
        cp.addWidget(self.chat_proposal_label, 1)
        self.dismiss_btn = QtWidgets.QPushButton("Dismiss")
        self.dismiss_btn.clicked.connect(self.dismiss_proposal)
        self.approve_btn = QtWidgets.QPushButton("Apply suggestion")
        self.approve_btn.setDefault(True)
        self.approve_btn.clicked.connect(self.approve_proposal)
        cp.addWidget(self.dismiss_btn)
        cp.addWidget(self.approve_btn)
        self.chat_proposal.hide()
        lay.addWidget(self.chat_proposal)
        row = QtWidgets.QHBoxLayout()
        self.chat_edit = QtWidgets.QLineEdit()
        self.chat_edit.setPlaceholderText("Ask about this machine's performance…")
        self.chat_edit.setAccessibleName("Question for the tuning agent")
        self.chat_edit.returnPressed.connect(self._send)
        row.addWidget(self.chat_edit, 1)
        self.send_btn = QtWidgets.QPushButton("Send")
        self.send_btn.clicked.connect(self._send)
        row.addWidget(self.send_btn)
        lay.addLayout(row)
        return page

    def _refresh_agent(self):
        has = self.ctl.agent_factory is not None
        item = self.nav.item([k for k, _ in PAGES].index("agent"))
        item.setHidden(not has)
        if not has:
            self.agent_card.hide()
            return
        from so_agent import config as acfg
        from so_agent import schedule as asched
        self.proposal = self.ctl.proposal()
        pending = bool(self.proposal)
        self.agent_card.setVisible(pending)
        self.agent_card.set_attention(pending, pulse=pending and not self.agent_card.attention())
        if pending:
            self.proposal_label.setText(self.proposal.get("summary", ""))
            self.chat_proposal_label.setText("Suggests: <b>%s</b><br>%s" % (
                html.escape(self.proposal.get("summary", "")), html.escape(self.proposal.get("reason", ""))))
        self.chat_proposal.setVisible(pending)
        for w in (self.approve_btn, self.dismiss_btn):
            w.setEnabled(not self.ctl.busy)
        try:
            cfg = acfg.load()
            self.agent_status.setText("Model %s, schedule %s" % (cfg["AGENT_MODEL"], cfg["AGENT_SCHEDULE"]))
            if self.model_box.count() == 0:
                self.model_box.addItem(cfg["AGENT_MODEL"])
        except Exception as exc:
            self.agent_status.setText("agent config: %s" % exc)
            return
        nxt = getattr(self, "_next_run", None)
        if nxt is None:
            self._next_run = ""
            self.ctl.run_bg(asched.next_run, lambda r: (setattr(self, "_next_run", "" if isinstance(r, Exception) else (r or "")),
                                                         self._refresh_agent()))
        elif nxt:
            self.agent_status.setText(self.agent_status.text() + ", next run " + nxt)

    def _rotate_prompt(self):
        """Show the next example question in the empty agent field."""
        self._prompt_i += 1
        if not self.chat_edit.text():
            self.chat_edit.setPlaceholderText(chat_prompt(self._prompt_i))

    def open_chat(self):
        self.show_page("agent")

    def _load_models(self):
        if self.ctl.agent_factory is None:
            return
        from so_agent import config as acfg
        from so_agent.llm import client

        def fetch():
            cfg = acfg.load()
            return cfg["AGENT_MODEL"], client(cfg, acfg.backend_url(cfg)).models()

        def done(res):
            if isinstance(res, Exception):
                self._say("system", "The model server is not reachable: %s" % res)
                return
            current, models = res
            self.model_box.clear()
            self.model_box.addItems(sorted(set(models) | {current}))
            self.model_box.setCurrentText(current)
        self.ctl.run_bg(fetch, done)

    def _set_model(self):
        from so_agent import config as acfg
        name = self.model_box.currentText().strip()
        try:
            acfg.write_user_setting("AGENT_MODEL", name)
        except acfg.ConfigError as exc:
            self.show_message(str(exc), True)
            return
        self.agent = None
        self._say("system", "Model set to %s." % name)
        self._refresh_agent()

    def _say(self, who, text):
        color = {"you": self.c["accent"], "agent": self.c["text"], "system": self.c["muted"]}[who]
        name = {"you": "You", "agent": "Agent", "system": ""}[who]
        body = html.escape(text).replace("\n", "<br>")
        self.transcript.append('<p style="color:%s">%s%s</p>' % (
            color, ("<b>%s</b>  " % name) if name else "", body))

    def _send(self):
        q = self.chat_edit.text().strip()
        if not q or self.ctl.agent_factory is None:
            return
        self.chat_edit.clear()
        self._say("you", q)
        self.send_btn.setEnabled(False)
        if self.agent is None:
            self.agent = self.ctl.agent_factory()

        def done(res):
            self.send_btn.setEnabled(True)
            if isinstance(res, Exception):
                self._say("system", str(res))
                return
            self._say("agent", res.text or "(no answer)")
            if res.proposal:
                from so_agent import store
                store.save_proposal(res.proposal.to_dict())
            self._refresh_agent()
        self.ctl.run_bg(lambda: self.agent.ask(q), done)

    def approve_proposal(self):
        if not self.proposal:
            return
        from so_agent import store
        from so_agent.tools import Proposal
        p = Proposal.from_dict(self.proposal)

        def run():
            res = p.execute(self.ctl.cli)
            if res[0] == 0:
                store.clear_proposal()
            return res
        self.ctl.change(run, "Agent suggestion (%s)" % p.summary())

    def dismiss_proposal(self):
        from so_agent import store
        store.clear_proposal()
        self._refresh_agent()
        if self.detail_name:
            self._fill_detail(self.detail_name)

    # -- About ---------------------------------------------------------
    def _build_about(self):
        page = QtWidgets.QWidget()
        lay = QtWidgets.QVBoxLayout(page)
        lay.setContentsMargins(18, 14, 18, 14)
        self._back_row(lay)
        self.about_text = QtWidgets.QTextBrowser()
        self.about_text.setOpenExternalLinks(True)
        lay.addWidget(self.about_text, 1)
        return page

    def open_about(self):
        self.about_text.document().setDefaultStyleSheet(
            "a { color: %s; text-decoration: none; font-weight: 600; }" % self.c["accent"])
        self.about_text.setHtml(about_html(self.ctl.info.get("version") or "not installed", self.c))
        self._drill(self.about)


def about_html(cli_version, c):
    from .credits import load_credits
    e = html.escape
    out = ['<h2 style="margin-bottom:0">system-optimize</h2>',
           '<p style="color:%s">%s<br>%s</p>' % (c["muted"], e(version_text()), e(cli_version)),
           '<p>Tunes a Linux machine for its hardware, reversibly, and shows what each change did.</p>',
           '<p><a href="https://github.com/bradvrudney/system-optimize">Source code</a> · '
           '<a href="https://github.com/bradvrudney/system-optimize/tree/main/docs">Documentation</a> · '
           'License: GPL-3.0</p>',
           '<h3>Thanks</h3><p>system-optimize stands on the work of these open-source projects:</p>']
    projects = load_credits()
    for key, title in GROUPS:
        items = [p for p in projects if p.get("group") == key]
        if not items:
            continue
        out.append('<p style="color:%s; margin-top:10px"><b>%s</b></p>' % (c["muted"], e(title)))
        for p in items:
            by = (" by %s" % e(p["by"])) if p.get("by") else ""
            out.append('<p style="margin:2px 0"><a href="%s">%s</a>%s <span style="color:%s">%s</span><br>'
                       '<span style="color:%s">%s</span></p>' % (
                           e(p["url"]), e(p["name"]), by, c["muted"], e(p["license"]), c["muted"], e(p["role"])))
    return "\n".join(out)


def version_text():
    return "system-optimize-tray %s" % VERSION
