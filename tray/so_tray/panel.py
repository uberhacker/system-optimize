"""The panel: dashboard, a detail screen per feature and the agent chat.

Layout (one window, three screens in a stack):
  dashboard  live tiles with sparklines, benchmark vs baseline, a row per
             step with a switch (click the row for its detail screen), the
             agent's pending proposal and a box to ask it, quick actions
  feature    what the step does (the CLI's own docs), a chart of benchmark
             scores with this step's changes marked, and its change log
  chat       the tuning agent (only when the optional agent is installed)
"""

import html
import threading
import time

from . import VERSION
from . import settings as settings_mod
from .cli import CliError
from .credits import GROUPS
from .model import (CHAT_PROMPT_SECONDS, PressureAlerts, actions_available, baseline_compare, categories,
                    category_count, change_log, chat_prompt, feature_entries, fmt_pct, gpu_top_text, llm_line, measured_effect, readout_lines, score_series,
                    warning_lines)
from .qt import QtCore, QtGui, QtWidgets, Signal
from .theme import SERIES, colors, mono, resolve, stylesheet
from .widgets import Card, FeatureRow, ScoreBar, Switch, Tile, TimeChart

Qt = QtCore.Qt
WIDTH = 440


def _iso_to_ts(text):
    from datetime import datetime, timezone
    try:
        dt = datetime.fromisoformat(str(text).replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        return time.mktime(dt.timetuple())
    return dt.astimezone(timezone.utc).timestamp()


def _label(text, role=None, wrap=False):
    lab = QtWidgets.QLabel(text)
    if role:
        lab.setProperty("role", role)
    lab.setWordWrap(wrap)
    return lab


class Bridge(QtCore.QObject):
    done = Signal(int, object)


class Controller(QtCore.QObject):
    """State shared by the panel and the tray icon; runs slow work off the
    UI thread."""
    info_changed = Signal()
    sample_changed = Signal()
    busy_changed = Signal(bool)
    message = Signal(str, bool)          # text, is_error
    alert = Signal(str)                  # a pressure (PSI) alert to notify about

    def __init__(self, cli, monitor, agent_factory=None, parent=None):
        super().__init__(parent)
        self.cli = cli
        self.monitor = monitor
        self.agent_factory = agent_factory  # () -> (Agent, client) or None when not installed
        self.recorder = None                # history.Recorder when this process keeps resource averages
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
            except RuntimeError:       # the panel went away while this ran (PyQt6)
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
        # psi-notify already notifies about the same thing: don't double up
        if self.psi_alerts and not (self.sample or {}).get("pressure_notifier"):
            for text in fresh:
                self.alert.emit(text)
        self.sample_changed.emit()

    def warnings(self):
        """Conflict warnings and current pressure, for the dashboard."""
        return warning_lines(self.sample, self.info) + self.pressure.active

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
                    self.message.emit("%s: done. Undo restores the previous settings." % what, False)
                elif rc in (126, 127):
                    self.message.emit("Not changed: authorisation was cancelled or refused.", True)
                else:
                    tail = "\n".join([ln for ln in (out + err).splitlines() if ln.strip()][-3:])
                    self.message.emit("%s failed (exit %d)\n%s" % (what, rc, tail), True)
            self.refresh()
        self.run_bg(fn, done, busy=True)


class Panel(QtWidgets.QWidget):
    text_requested = Signal(str, str)   # title, text (shown in a dialog by the app)

    def __init__(self, ctl, parent=None):
        super().__init__(parent)
        self.setObjectName("Panel")
        self.setWindowTitle("system-optimize")
        self.setAttribute(Qt.WidgetAttribute.WA_StyledBackground, True)
        self.ctl = ctl
        self.settings = settings_mod.load()
        self.c = colors(resolve(self.settings["THEME"]))
        self.setFixedWidth(WIDTH)
        self.resize(WIDTH, 720)
        self.agent = None
        self.proposal = None
        self.detail_name = None

        root = QtWidgets.QVBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        self.stack = QtWidgets.QStackedWidget()
        root.addWidget(self.stack)
        self.toast = _label("", "muted", wrap=True)
        self.toast.setContentsMargins(14, 4, 14, 8)
        self.toast.hide()
        root.addWidget(self.toast)

        self.dash = self._build_dashboard()
        self.detail = self._build_detail()
        self.chat = self._build_chat()
        self.about = self._build_about()
        self.resource = self._build_resource()
        self.resource_name = None
        for w in (self.dash, self.detail, self.chat, self.about, self.resource):
            self.stack.addWidget(w)

        ctl.sample_changed.connect(self._on_sample)
        ctl.info_changed.connect(self._on_info)
        ctl.busy_changed.connect(self._on_busy)
        ctl.message.connect(self.show_message)
        hints = QtGui.QGuiApplication.styleHints()
        if hasattr(hints, "colorSchemeChanged"):
            hints.colorSchemeChanged.connect(lambda *_: self.apply_theme())
        self.apply_theme()
        self._on_info()
        # example questions take turns as the agent fields' placeholder text
        self._prompt_i = int(time.time() // CHAT_PROMPT_SECONDS)
        self._rotate_prompt()
        self.prompt_timer = QtCore.QTimer(self)
        self.prompt_timer.timeout.connect(self._rotate_prompt)
        self.prompt_timer.start(CHAT_PROMPT_SECONDS * 1000)

    # -- theme -------------------------------------------------------
    def apply_theme(self, setting=None):
        if setting:
            self.settings["THEME"] = setting
            try:
                settings_mod.save("THEME", setting)
            except OSError:
                pass
        mode = resolve(self.settings["THEME"])
        self._applied_mode = mode
        self.c.update(colors(mode))
        self.setStyleSheet(stylesheet(self.c))
        for a in self.theme_actions:
            a.setChecked(a.data() == self.settings["THEME"])
        self.update()
        for w in self.findChildren(QtWidgets.QWidget):
            w.update()

    def changeEvent(self, e):
        # Our own setStyleSheet also sends PaletteChange: re-apply only when the
        # desktop really switched between light and dark, or this loops forever.
        if (e.type() == QtCore.QEvent.Type.PaletteChange and self.settings["THEME"] == "system"
                and resolve("system") != getattr(self, "_applied_mode", None)):
            QtCore.QTimer.singleShot(0, self.apply_theme)
        super().changeEvent(e)

    # -- dashboard ---------------------------------------------------
    def _scroll_page(self):
        page = QtWidgets.QWidget()
        outer = QtWidgets.QVBoxLayout(page)
        outer.setContentsMargins(0, 0, 0, 0)
        area = QtWidgets.QScrollArea()
        area.setWidgetResizable(True)
        area.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        inner = QtWidgets.QWidget()
        lay = QtWidgets.QVBoxLayout(inner)
        lay.setContentsMargins(14, 12, 14, 12)
        lay.setSpacing(10)
        area.setWidget(inner)
        outer.addWidget(area)
        return page, lay

    def _build_dashboard(self):
        page, lay = self._scroll_page()
        head = QtWidgets.QHBoxLayout()
        icon = QtWidgets.QLabel()
        icon.setPixmap(QtGui.QIcon.fromTheme("system-optimize-tray").pixmap(26, 26))
        head.addWidget(icon)
        title = QtWidgets.QVBoxLayout()
        title.setSpacing(0)
        title.addWidget(_label("system-optimize", "h1"))
        self.version_label = _label("", "muted")
        self.version_label.setFont(mono(8))
        title.addWidget(self.version_label)
        head.addLayout(title, 1)
        self.profile_chip = _label("", "chip")
        self.profile_chip.hide()
        head.addWidget(self.profile_chip)
        theme_btn = QtWidgets.QPushButton("◐")
        theme_btn.setProperty("flat", True)
        theme_btn.setToolTip("Theme")
        theme_btn.setAccessibleName("Theme")
        menu = QtWidgets.QMenu(theme_btn)
        grp = QtGui.QActionGroup(menu)
        self.theme_actions = []
        for key, text in (("system", "System default"), ("light", "Light"), ("dark", "Dark")):
            a = menu.addAction(text)
            a.setCheckable(True)
            a.setData(key)
            grp.addAction(a)
            a.triggered.connect(lambda _=False, k=key: self.apply_theme(k))
            self.theme_actions.append(a)
        theme_btn.setMenu(menu)
        head.addWidget(theme_btn)
        about_btn = QtWidgets.QPushButton("ⓘ")
        about_btn.setProperty("flat", True)
        about_btn.setToolTip("About and credits")
        about_btn.setAccessibleName("About")
        about_btn.clicked.connect(self.open_about)
        head.addWidget(about_btn)
        lay.addLayout(head)

        self.warn_label = _label("", "warn", wrap=True)
        self.warn_label.setAccessibleName("Warnings")
        self.warn_label.hide()
        lay.addWidget(self.warn_label)

        grid = QtWidgets.QGridLayout()
        grid.setSpacing(8)
        self.tiles = {
            "cpu": Tile("cpu", "CPU load", "%", SERIES[0], fixed_max=100),
            "memory": Tile("memory", "Memory", "%", SERIES[1], fixed_max=100),
            "cpu_temp": Tile("cpu_temp", "CPU temp", "°C", SERIES[4]),
            "disk": Tile("disk", "Disk I/O", "MB/s", SERIES[3]),
            # shown once the machine reports them (amdgpu, or amdgpu_top)
            "gpu": Tile("gpu", "GPU busy", "%", SERIES[2], fixed_max=100),
            "gpu_mem": Tile("gpu_mem", "GPU memory", "%", SERIES[5], fixed_max=100),
        }
        for i, t in enumerate(self.tiles.values()):
            grid.addWidget(t, i // 2, i % 2)
            t.setToolTip("Averages over time and around each setting change")
            t.clicked.connect(lambda k=t.key: self.open_resource(k))
        self.tiles["gpu"].hide()
        self.tiles["gpu_mem"].hide()
        lay.addLayout(grid)
        self.power_label = _label("", "muted", wrap=True)
        self.power_label.setFont(mono(8))
        lay.addWidget(self.power_label)

        bench = Card()
        bl = QtWidgets.QVBoxLayout(bench)
        bl.setContentsMargins(12, 10, 12, 10)
        top = QtWidgets.QHBoxLayout()
        top.addWidget(_label("BENCHMARK VS BASELINE", "muted"))
        top.addStretch(1)
        self.bench_value = QtWidgets.QLabel("–")
        self.bench_value.setFont(mono(13, bold=True))
        top.addWidget(self.bench_value)
        bl.addLayout(top)
        self.bench_bar = ScoreBar(self.c)
        bl.addWidget(self.bench_bar)
        bottom = QtWidgets.QHBoxLayout()
        self.bench_note = _label("", "muted")
        self.bench_note.setFont(mono(8))
        bottom.addWidget(self.bench_note, 1)
        self.bench_btn = QtWidgets.QPushButton("Run benchmark")
        self.bench_btn.clicked.connect(self.run_benchmark)
        bottom.addWidget(self.bench_btn)
        bl.addLayout(bottom)
        self.llm_label = _label("", "muted", wrap=True)
        self.llm_label.setFont(mono(8))
        self.llm_label.setToolTip("llama-bench tokens per second (prompt processing and generation), "
                                  "first run → latest")
        self.llm_label.hide()
        bl.addWidget(self.llm_label)
        lay.addWidget(bench)
        self.bench_card = bench

        lay.addWidget(_label("Optimizations", "h2"))
        self.features_box = QtWidgets.QVBoxLayout()
        self.features_box.setSpacing(6)
        lay.addLayout(self.features_box)

        # agent
        self.agent_card = Card()
        al = QtWidgets.QVBoxLayout(self.agent_card)
        al.setContentsMargins(12, 10, 12, 10)
        al.addWidget(_label("TUNING AGENT", "muted"))
        self.proposal_label = _label("", wrap=True)
        al.addWidget(self.proposal_label)
        prow = QtWidgets.QHBoxLayout()
        self.approve_btn = QtWidgets.QPushButton("Apply")
        self.approve_btn.setProperty("primary", True)
        self.approve_btn.clicked.connect(self.approve_proposal)
        self.dismiss_btn = QtWidgets.QPushButton("Dismiss")
        self.dismiss_btn.clicked.connect(self.dismiss_proposal)
        prow.addStretch(1)
        prow.addWidget(self.dismiss_btn)
        prow.addWidget(self.approve_btn)
        al.addLayout(prow)
        ask = QtWidgets.QHBoxLayout()
        self.ask_edit = QtWidgets.QLineEdit()
        self.ask_edit.setPlaceholderText("Ask the tuning agent…")
        self.ask_edit.returnPressed.connect(self._ask_from_dashboard)
        ask.addWidget(self.ask_edit)
        al.addLayout(ask)
        self.agent_status = _label("", "muted")
        self.agent_status.setFont(mono(8))
        al.addWidget(self.agent_status)
        lay.addWidget(self.agent_card)

        acts = QtWidgets.QHBoxLayout()
        self.btn_preview = QtWidgets.QPushButton("Preview")
        self.btn_preview.setToolTip("Dry run: show what a run would change")
        self.btn_preview.clicked.connect(lambda: self._text("Preview (dry run)", self.ctl.cli.preview))
        self.btn_apply = QtWidgets.QPushButton("Apply all")
        self.btn_apply.clicked.connect(lambda: self.ctl.change(self.ctl.cli.apply_all, "Apply all"))
        self.btn_undo = QtWidgets.QPushButton("Undo")
        self.btn_undo.setToolTip("Restore the newest snapshot")
        self.btn_undo.clicked.connect(lambda: self.ctl.change(self.ctl.cli.undo, "Undo"))
        self.btn_status = QtWidgets.QPushButton("Status")
        self.btn_status.clicked.connect(lambda: self._text("Status report", self.ctl.cli.status_text))
        for b in (self.btn_preview, self.btn_apply, self.btn_undo, self.btn_status):
            acts.addWidget(b)
        lay.addLayout(acts)
        lay.addStretch(1)
        return page

    def _on_sample(self):
        s = self.ctl.sample or {}
        cpu, mem = s.get("cpu") or {}, s.get("memory") or {}
        temp, disk = s.get("temperature") or {}, s.get("disk") or {}
        self.tiles["cpu"].set(cpu.get("percent"), "%.0f",
                              ("%.2f GHz" % (cpu["mhz"] / 1000.0)) if cpu.get("mhz") else "")
        self.tiles["memory"].set(mem.get("percent"), "%.0f",
                                 ("%.1f/%.0f GB" % ((mem.get("used_mb") or 0) / 1024, mem["total_mb"] / 1024))
                                 if mem.get("total_mb") else "")
        self.tiles["cpu_temp"].set(temp.get("cpu"), "%.0f",
                                   ("GPU %d°" % round(temp["gpu"])) if temp.get("gpu") is not None else "")
        r, w = disk.get("read_mbs"), disk.get("write_mbs")
        total = None if r is None or w is None else r + w
        self.tiles["disk"].set(total, "%.1f", ("R %.1f W %.1f" % (r, w)) if total is not None else "")
        gpu = s.get("gpu") or {}
        if gpu.get("busy_percent") is not None:
            self.tiles["gpu"].show()
            self.tiles["gpu"].set(gpu["busy_percent"], "%.0f", gpu.get("name") and gpu["name"][:18] or "")
        if gpu.get("mem_total_mb"):
            t = self.tiles["gpu_mem"]
            t.show()
            t.set(gpu.get("mem_percent"), "%.0f", "%.1f/%.0f GB" % ((gpu.get("mem_used_mb") or 0) / 1024,
                                                                   gpu["mem_total_mb"] / 1024))
            tip = "VRAM %.1f / %.1f GB · GTT (shared) %.1f / %.1f GB · from %s" % (
                (gpu.get("vram_used_mb") or 0) / 1024, (gpu.get("vram_total_mb") or 0) / 1024,
                (gpu.get("gtt_used_mb") or 0) / 1024, (gpu.get("gtt_total_mb") or 0) / 1024,
                gpu.get("source") or "?")
            top = gpu_top_text(gpu)
            t.setToolTip(tip + ("\n" + top if top else ""))
        self._show_warnings()
        lines = readout_lines(s)
        self.power_label.setText(lines[-1] if lines else "")
        if self.resource_name and self.stack.currentWidget() is self.resource:
            self._res_now()

    def _res_now(self):
        from .history import METRICS, value
        unit = METRICS[self.resource_name][1]
        self.res_stats["now"].setText(self._fmt_value(value(self.ctl.sample, self.resource_name), unit))

    def _show_warnings(self):
        w = self.ctl.warnings()
        self.warn_label.setVisible(bool(w))
        self.warn_label.setText("\n".join("⚠ " + x for x in w))

    def _on_info(self):
        info = self.ctl.info
        self.version_label.setText(info.get("version") or ("system-optimize not found" if not info.get("found") else ""))
        prof = info.get("profile")
        self.profile_chip.setVisible(bool(prof))
        self.profile_chip.setText(prof or "")
        # features
        while self.features_box.count():
            item = self.features_box.takeAt(0)
            if item.widget():
                item.widget().deleteLater()
        summaries = {f["name"]: f.get("summary") or "" for f in info.get("features") or []}
        if not info.get("found"):
            self.features_box.addWidget(_label("system-optimize is not installed. Install it, then reopen this panel.",
                                               "muted", wrap=True))
        expanded = set(filter(None, self.settings.get("EXPANDED", "").split(",")))
        for g in categories(info, self.ctl.history):
            head = Card(clickable=True)
            head.setSizePolicy(QtWidgets.QSizePolicy.Policy.Preferred, QtWidgets.QSizePolicy.Policy.Fixed)
            hl = QtWidgets.QHBoxLayout(head)
            hl.setContentsMargins(12, 7, 12, 7)
            is_open = g["key"] in expanded
            arrow = _label("▾" if is_open else "▸", "muted")
            hl.addWidget(arrow)
            t = QtWidgets.QLabel(g["title"])
            f = t.font()
            f.setWeight(QtGui.QFont.Weight.DemiBold)
            t.setFont(f)
            hl.addWidget(t, 1)
            count = _label(category_count(g), "muted")
            count.setFont(mono(8))
            hl.addWidget(count)
            if g["trend_pct"] is not None:
                tr = QtWidgets.QLabel(fmt_pct(g["trend_pct"]))
                tr.setFont(mono(8, bold=True))
                tr.setStyleSheet("color: %s;" % (self.c["good"] if g["trend_pct"] >= 0 else self.c["bad"]))
                tr.setToolTip("Benchmark change measured after this category's changes")
                hl.addWidget(tr)
            head.setAccessibleName("%s, %s, %s" % (g["title"], category_count(g),
                                                    "expanded" if is_open else "collapsed"))
            head.clicked.connect(lambda k=g["key"]: self.toggle_category(k))
            self.features_box.addWidget(head)
            if not is_open:
                continue
            box = QtWidgets.QWidget()
            bl = QtWidgets.QVBoxLayout(box)
            bl.setContentsMargins(14, 0, 0, 4)
            bl.setSpacing(6)
            for name, label, checked, enabled, tip in g["entries"]:
                row = FeatureRow(name, label, summaries.get(name, ""), checked, enabled and not self.ctl.busy,
                                 tip, self.c)
                row.toggled.connect(self.toggle_feature)
                row.opened.connect(self.open_feature)
                bl.addWidget(row)
            self.features_box.addWidget(box)
        avail = actions_available(info)
        self.btn_preview.setEnabled(avail["preview"] and not self.ctl.busy)
        self.btn_apply.setEnabled(avail["apply_all"] and not self.ctl.busy)
        self.btn_undo.setEnabled(avail["undo"] and not self.ctl.busy)
        self.btn_status.setEnabled(avail["status"])
        # benchmark
        cmp_ = baseline_compare(self.ctl.history)
        self.bench_btn.setVisible(avail["benchmark"])
        self.bench_btn.setEnabled(not self.ctl.busy)
        if cmp_ and cmp_["count"] >= 2:
            self.bench_value.setText(fmt_pct(cmp_["pct"]))
            color = self.c["good"] if (cmp_["pct"] or 0) >= 0 else self.c["bad"]
            self.bench_value.setStyleSheet("color: %s;" % color)
            self.bench_note.setText("%d runs · baseline %.0f → %.0f" % (cmp_["count"], cmp_["baseline"], cmp_["latest"]))
        elif cmp_:
            self.bench_value.setText("baseline")
            self.bench_value.setStyleSheet("")
            self.bench_note.setText("1 run so far; the next shows the change")
        else:
            self.bench_value.setText("–")
            self.bench_value.setStyleSheet("")
            self.bench_note.setText("no benchmark yet" if avail["benchmark"] else "needs system-optimize with --benchmark")
        self.bench_bar.set(cmp_)
        llm = llm_line(self.ctl.history)
        self.llm_label.setVisible(bool(llm))
        self.llm_label.setText(llm or "")
        self._show_warnings()
        self._refresh_agent()
        if self.stack.currentWidget() is self.detail and self.detail_name:
            self._fill_detail(self.detail_name)
        if self.stack.currentWidget() is self.resource and self.resource_name:
            self._load_resource(self.resource_name)

    def toggle_category(self, key):
        expanded = set(filter(None, self.settings.get("EXPANDED", "").split(",")))
        expanded ^= {key}
        self.settings["EXPANDED"] = ",".join(sorted(expanded))
        try:
            settings_mod.save("EXPANDED", self.settings["EXPANDED"])
        except (OSError, ValueError):
            pass
        self._on_info()

    def _on_busy(self, busy):
        self._on_info()
        if busy:
            self.show_message("Working… (your password may be asked for)", False)

    def show_message(self, text, error=False):
        self.toast.setText(text)
        self.toast.setStyleSheet("color: %s;" % (self.c["bad"] if error else self.c["muted"]))
        self.toast.show()
        QtCore.QTimer.singleShot(9000 if error else 5000, self.toast.hide)

    def toggle_feature(self, name, on):
        feat = next((f for f in self.ctl.info.get("features") or [] if f["name"] == name), None)
        if not feat:
            return
        self.ctl.change(lambda: self.ctl.cli.set_feature(feat, on), "%s %s" % (feat["title"], "on" if on else "off"))

    def run_benchmark(self):
        self.show_message("Benchmark running; this takes a minute or two", False)

        def done(res):
            if isinstance(res, Exception):
                self.show_message(str(res), True)
            else:
                self.text_requested.emit("Benchmark", res[1])
            self.ctl.refresh()
        self.ctl.run_bg(self.ctl.cli.benchmark, done, busy=True)

    def _text(self, title, fn):
        def done(res):
            if isinstance(res, Exception):
                self.show_message(str(res), True)
            else:
                self.text_requested.emit(title, res[1])
        self.ctl.run_bg(fn, done)

    # -- feature detail ----------------------------------------------
    def _build_detail(self):
        page, lay = self._scroll_page()
        top = QtWidgets.QHBoxLayout()
        back = QtWidgets.QPushButton("‹ Back")
        back.setProperty("flat", True)
        back.clicked.connect(self.show_dashboard)
        top.addWidget(back)
        top.addStretch(1)
        self.detail_switch = Switch(self.c)
        self.detail_switch.clicked.connect(lambda on: self.toggle_feature(self.detail_name, on))
        top.addWidget(self.detail_switch)
        lay.addLayout(top)
        self.detail_title = _label("", "h1", wrap=True)
        lay.addWidget(self.detail_title)
        self.detail_summary = _label("", "muted", wrap=True)
        lay.addWidget(self.detail_summary)
        lay.addWidget(_label("What it does", "h2"))
        self.detail_doc = QtWidgets.QTextBrowser()
        self.detail_doc.setOpenExternalLinks(False)
        self.detail_doc.document().setDefaultStyleSheet("table { border-collapse: collapse; } td, th { padding: 3px 8px; }")
        self.detail_doc.setMinimumHeight(190)
        lay.addWidget(self.detail_doc)
        lay.addWidget(_label("Performance history", "h2"))
        self.detail_effect = _label("", "muted", wrap=True)
        self.detail_effect.setFont(mono(8))
        lay.addWidget(self.detail_effect)
        self.detail_chart = TimeChart(self.c, unit="score")
        lay.addWidget(self.detail_chart)
        self.detail_log = QtWidgets.QTableWidget(0, 3)
        self.detail_log.setHorizontalHeaderLabels(["When", "Change", "Effect"])
        self.detail_log.verticalHeader().hide()
        self.detail_log.setEditTriggers(QtWidgets.QAbstractItemView.EditTrigger.NoEditTriggers)
        self.detail_log.setSelectionMode(QtWidgets.QAbstractItemView.SelectionMode.NoSelection)
        self.detail_log.setFont(mono(8))
        hh = self.detail_log.horizontalHeader()
        hh.setSectionResizeMode(0, QtWidgets.QHeaderView.ResizeMode.ResizeToContents)
        hh.setSectionResizeMode(1, QtWidgets.QHeaderView.ResizeMode.Stretch)
        hh.setSectionResizeMode(2, QtWidgets.QHeaderView.ResizeMode.ResizeToContents)
        self.detail_log.setMinimumHeight(150)
        lay.addWidget(self.detail_log)
        lay.addStretch(1)
        return page

    def open_feature(self, name):
        self.detail_name = name
        self._fill_detail(name)
        self.stack.setCurrentWidget(self.detail)

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
        hist = self.ctl.history
        log = change_log(hist, step=name)
        points = [(_iso_to_ts(t), v) for t, v in score_series(hist)]
        points = [(t, v) for t, v in points if t is not None]
        markers = [(_iso_to_ts(c["time"]), c.get("target") or "") for c in log if _iso_to_ts(c["time"])]
        empty = ("No benchmarks yet. Run one from the dashboard; each later run is compared with it."
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
            eff = QtWidgets.QTableWidgetItem(eff_text)
            if c.get("delta_pct") is not None:
                eff.setForeground(QtGui.QColor(self.c["good"] if c["delta_pct"] >= 0 else self.c["bad"]))
            for col, item in enumerate((QtWidgets.QTableWidgetItem(when), QtWidgets.QTableWidgetItem(change), eff)):
                item.setToolTip(item.text())
                self.detail_log.setItem(r, col, item)
        if not log:
            self.detail_log.insertRow(0)
            self.detail_log.setItem(0, 1, QtWidgets.QTableWidgetItem("no changes recorded for this step"))

    def show_dashboard(self):
        self.stack.setCurrentWidget(self.dash)

    # -- resources ---------------------------------------------------
    def _build_resource(self):
        page, lay = self._scroll_page()
        top = QtWidgets.QHBoxLayout()
        back = QtWidgets.QPushButton("‹ Back")
        back.setProperty("flat", True)
        back.clicked.connect(self.show_dashboard)
        top.addWidget(back)
        top.addStretch(1)
        lay.addLayout(top)
        self.res_title = _label("", "h1")
        lay.addWidget(self.res_title)
        stats = QtWidgets.QHBoxLayout()
        stats.setSpacing(8)
        self.res_stats = {}
        for key, title in (("now", "NOW"), ("avg", "30-DAY AVERAGE"), ("since", "SINCE FIRST CHANGE")):
            card = Card()
            cl = QtWidgets.QVBoxLayout(card)
            cl.setContentsMargins(10, 8, 10, 8)
            cl.setSpacing(2)
            cl.addWidget(_label(title, "muted"))
            value = QtWidgets.QLabel("–")
            value.setFont(mono(13, bold=True))
            cl.addWidget(value)
            self.res_stats[key] = value
            stats.addWidget(card, 1)
        lay.addLayout(stats)
        lay.addWidget(_label("Daily average", "h2"))
        self.res_note = _label("", "muted", wrap=True)
        self.res_note.setFont(mono(8))
        lay.addWidget(self.res_note)
        self.res_chart = TimeChart(self.c)
        lay.addWidget(self.res_chart)
        lay.addWidget(_label("Around each change", "h2"))
        self.res_log = QtWidgets.QTableWidget(0, 3)
        self.res_log.setHorizontalHeaderLabels(["When", "Change", "7 days before → after"])
        self.res_log.verticalHeader().hide()
        self.res_log.setEditTriggers(QtWidgets.QAbstractItemView.EditTrigger.NoEditTriggers)
        self.res_log.setSelectionMode(QtWidgets.QAbstractItemView.SelectionMode.NoSelection)
        self.res_log.setFont(mono(8))
        hh = self.res_log.horizontalHeader()
        hh.setSectionResizeMode(0, QtWidgets.QHeaderView.ResizeMode.ResizeToContents)
        hh.setSectionResizeMode(1, QtWidgets.QHeaderView.ResizeMode.Stretch)
        hh.setSectionResizeMode(2, QtWidgets.QHeaderView.ResizeMode.ResizeToContents)
        self.res_log.setMinimumHeight(150)
        lay.addWidget(self.res_log)
        rec = QtWidgets.QHBoxLayout()
        rec.addWidget(_label("Keep resource history", None), 1)
        self.res_record = Switch(self.c)
        self.res_record.setChecked(self.settings.get("RECORD_HISTORY", "1") == "1")
        self.res_record.clicked.connect(self.set_recording)
        rec.addWidget(self.res_record)
        lay.addLayout(rec)
        lay.addWidget(_label("Hourly and daily averages, kept on this computer only. Hourly detail is kept for "
                             "90 days, daily averages for good.", "muted", wrap=True))
        lay.addStretch(1)
        return page

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

    def open_resource(self, name):
        from .history import METRICS
        if name not in METRICS:
            return
        self.resource_name = name
        self.res_title.setText(METRICS[name][0])
        self.res_chart.unit = METRICS[name][1]
        self.stack.setCurrentWidget(self.resource)
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

    def _effect_color(self, delta, better):
        if delta is None or better is None or abs(delta) < 0.05:
            return None
        good = delta < 0 if better == "lower" else delta > 0
        return self.c["good"] if good else self.c["bad"]

    def _fill_resource(self, rep):
        unit = rep["unit"]
        self.res_stats["avg"].setText(self._fmt_value(rep["avg30"], unit))
        since = rep["since_first_pct"]
        self.res_stats["since"].setText(fmt_pct(since))
        color = self._effect_color(since, rep["better"])
        self.res_stats["since"].setStyleSheet("color: %s;" % color if color else "")
        self.res_stats["since"].setToolTip(
            "Average since the first recorded setting change, against the 7 days before it")
        points = [(start + 43200, avg) for start, avg, *_ in rep["series"]]
        markers = [(g["time"], g["changes"][0].get("target") or g["changes"][0].get("step") or "")
                   for g in rep["markers"]]
        periods = [(pd["start"], pd["end"], pd["avg"]) for pd in rep["periods"]]
        if self.settings.get("RECORD_HISTORY", "1") != "1":
            empty = "Resource history is off. Turn it on below to start recording."
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
            cells = (QtWidgets.QTableWidgetItem(when), QtWidgets.QTableWidgetItem(what), QtWidgets.QTableWidgetItem(ba))
            color = self._effect_color(eff["delta_pct"], rep["better"])
            if color:
                cells[2].setForeground(QtGui.QColor(color))
            for col, item in enumerate(cells):
                item.setToolTip(item.text())
                self.res_log.setItem(r, col, item)
        if not rep["effects"]:
            self.res_log.insertRow(0)
            self.res_log.setItem(0, 1, QtWidgets.QTableWidgetItem("no setting changes recorded yet"))

    # -- agent -------------------------------------------------------
    def _build_chat(self):
        page = QtWidgets.QWidget()
        lay = QtWidgets.QVBoxLayout(page)
        lay.setContentsMargins(14, 12, 14, 12)
        lay.setSpacing(8)
        top = QtWidgets.QHBoxLayout()
        back = QtWidgets.QPushButton("‹ Back")
        back.setProperty("flat", True)
        back.clicked.connect(self.show_dashboard)
        top.addWidget(back)
        top.addStretch(1)
        lay.addLayout(top)
        lay.addWidget(_label("Tuning agent", "h1"))
        mrow = QtWidgets.QHBoxLayout()
        mrow.addWidget(_label("Model", "muted"))
        self.model_box = QtWidgets.QComboBox()
        self.model_box.setEditable(True)
        self.model_box.setToolTip("Any model your Ollama or llama.cpp server has; type a name to use another")
        mrow.addWidget(self.model_box, 1)
        use = QtWidgets.QPushButton("Use")
        use.clicked.connect(self._set_model)
        mrow.addWidget(use)
        lay.addLayout(mrow)
        self.transcript = QtWidgets.QTextBrowser()
        lay.addWidget(self.transcript, 1)
        self.chat_proposal = Card()
        cp = QtWidgets.QHBoxLayout(self.chat_proposal)
        cp.setContentsMargins(10, 8, 10, 8)
        self.chat_proposal_label = _label("", wrap=True)
        cp.addWidget(self.chat_proposal_label, 1)
        b1 = QtWidgets.QPushButton("Dismiss")
        b1.clicked.connect(self.dismiss_proposal)
        b2 = QtWidgets.QPushButton("Apply")
        b2.setProperty("primary", True)
        b2.clicked.connect(self.approve_proposal)
        cp.addWidget(b1)
        cp.addWidget(b2)
        self.chat_proposal.hide()
        lay.addWidget(self.chat_proposal)
        row = QtWidgets.QHBoxLayout()
        self.chat_edit = QtWidgets.QLineEdit()
        self.chat_edit.setPlaceholderText("Ask about this machine's performance…")
        self.chat_edit.returnPressed.connect(self._send)
        row.addWidget(self.chat_edit, 1)
        self.send_btn = QtWidgets.QPushButton("Send")
        self.send_btn.setProperty("primary", True)
        self.send_btn.clicked.connect(self._send)
        row.addWidget(self.send_btn)
        lay.addLayout(row)
        return page

    def _refresh_agent(self):
        has = self.ctl.agent_factory is not None
        self.agent_card.setVisible(has)
        if not has:
            return
        from so_agent import store
        from so_agent import config as acfg
        from so_agent import schedule as asched
        self.proposal = store.load_proposal()
        if self.proposal:
            self.proposal_label.setText("Suggests: <b>%s</b><br><span>%s</span>" % (
                html.escape(self.proposal.get("summary", "")), html.escape(self.proposal.get("reason", ""))))
        else:
            self.proposal_label.setText("No pending suggestion.")
        for w in (self.approve_btn, self.dismiss_btn):
            w.setVisible(bool(self.proposal))
            w.setEnabled(not self.ctl.busy)
        self.chat_proposal.setVisible(bool(self.proposal))
        if self.proposal:
            self.chat_proposal_label.setText("Suggests: %s" % self.proposal.get("summary", ""))
        try:
            cfg = acfg.load()
            sched = cfg["AGENT_SCHEDULE"]
            self.agent_status.setText("model %s · schedule %s" % (cfg["AGENT_MODEL"], sched))
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
            self.agent_status.setText(self.agent_status.text() + " · next " + nxt)

    def _rotate_prompt(self):
        """Show the next example question in each empty agent field."""
        self._prompt_i += 1
        text = chat_prompt(self._prompt_i)
        for edit in (self.chat_edit, self.ask_edit):
            if not edit.text():
                edit.setPlaceholderText(text)

    def open_chat(self):
        self.stack.setCurrentWidget(self.chat)
        self.chat_edit.setFocus()
        self._load_models()

    def _load_models(self):
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

    def _ask_from_dashboard(self):
        q = self.ask_edit.text().strip()
        self.ask_edit.clear()
        self.open_chat()
        if q:
            self.chat_edit.setText(q)
            self._send()

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


    # -- about -------------------------------------------------------
    def _build_about(self):
        page = QtWidgets.QWidget()
        lay = QtWidgets.QVBoxLayout(page)
        lay.setContentsMargins(14, 12, 14, 12)
        top = QtWidgets.QHBoxLayout()
        back = QtWidgets.QPushButton("‹ Back")
        back.setProperty("flat", True)
        back.clicked.connect(self.show_dashboard)
        top.addWidget(back)
        top.addStretch(1)
        lay.addLayout(top)
        self.about_text = QtWidgets.QTextBrowser()
        self.about_text.setOpenExternalLinks(True)
        lay.addWidget(self.about_text, 1)
        return page

    def open_about(self):
        self.about_text.document().setDefaultStyleSheet(
            "a { color: %s; text-decoration: none; font-weight: 600; }" % self.c["accent"])
        self.about_text.setHtml(about_html(self.ctl.info.get("version") or "not installed", self.c))
        self.stack.setCurrentWidget(self.about)




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
