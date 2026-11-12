"""Custom-painted widgets for the full view: cards, resource tiles with a
sparkline, a switch, step rows, the benchmark bar and a time chart with
change markers. They take their colours from the desktop's palette (see
theme.colors); nothing here is styled with a style sheet."""

import time
from collections import deque

from .qt import QtCore, QtGui, QtWidgets, Signal
from .theme import figures

Qt = QtCore.Qt


def _qc(hexcolor, alpha=None):
    c = QtGui.QColor(hexcolor)
    if alpha is not None:
        c.setAlpha(alpha)
    return c


class Card(QtWidgets.QFrame):
    """A quiet surface: the palette's base colour with a hairline border."""
    clicked = Signal()

    def __init__(self, clickable=False, colors=None, parent=None):
        super().__init__(parent)
        self.c = colors
        self._clickable = clickable
        self._hover = False
        self._attention = False       # an accent outline that pulses for a few seconds, then stays
        self._pulse = 0.0
        self._pulse_timer = None
        if clickable:
            self.setCursor(Qt.CursorShape.PointingHandCursor)
            self.setFocusPolicy(Qt.FocusPolicy.TabFocus)

    def paintEvent(self, _e):
        p = QtGui.QPainter(self)
        p.setRenderHint(QtGui.QPainter.RenderHint.Antialiasing)
        pal = self.palette()
        R = QtGui.QPalette.ColorRole
        base, text = pal.color(R.Base), pal.color(R.WindowText)
        fill = QtGui.QColor(base)
        if self._hover and self._clickable:
            fill = QtGui.QColor(*(round(b + (t - b) * 0.06) for b, t in zip(base.getRgb()[:3], text.getRgb()[:3])))
        border = QtGui.QColor(text)
        border.setAlpha(150 if self.hasFocus() else 38)
        if self.hasFocus():
            border = pal.color(R.Highlight)
        p.setPen(QtGui.QPen(border, 1))
        p.setBrush(fill)
        p.drawRoundedRect(QtCore.QRectF(self.rect()).adjusted(0.5, 0.5, -0.5, -0.5), 8, 8)
        if self._attention:
            accent = QtGui.QColor(pal.color(R.Highlight))
            wash = QtGui.QColor(accent)
            wash.setAlpha(int(14 + 34 * self._pulse))
            p.setPen(QtGui.QPen(accent, 2))
            p.setBrush(wash)
            p.drawRoundedRect(QtCore.QRectF(self.rect()).adjusted(1, 1, -1, -1), 8, 8)
        p.end()

    PULSE_SECONDS = 9             # then the outline stays, still: motion is for arriving, not for nagging

    def set_attention(self, on, pulse=True):
        """Mark this card as the thing to look at: an accent outline that
        breathes for a few seconds and then holds."""
        if on == self._attention and (not on or self._pulse_timer is not None or not pulse):
            return
        self._attention = bool(on)
        if self._pulse_timer is not None:
            self._pulse_timer.stop()
            self._pulse_timer = None
        self._pulse = 0.0
        if on and pulse:
            self._pulse_start = time.monotonic()
            self._pulse_timer = QtCore.QTimer(self)
            self._pulse_timer.timeout.connect(self._pulse_step)
            self._pulse_timer.start(40)
        self.update()

    def attention(self):
        return self._attention

    def pulsing(self):
        return self._pulse_timer is not None

    def _pulse_step(self):
        import math
        t = time.monotonic() - self._pulse_start
        if t >= self.PULSE_SECONDS:
            self._pulse_timer.stop()
            self._pulse_timer = None
            self._pulse = 0.35
        else:
            self._pulse = 0.5 - 0.5 * math.cos(t * 2 * math.pi / 1.5)      # one breath every 1.5 s
        self.update()

    def enterEvent(self, e):
        self._hover = True
        self.update()
        super().enterEvent(e)

    def leaveEvent(self, e):
        self._hover = False
        self.update()
        super().leaveEvent(e)

    def mouseReleaseEvent(self, e):
        if self._clickable and e.button() == Qt.MouseButton.LeftButton:
            self.clicked.emit()
        super().mouseReleaseEvent(e)

    def keyPressEvent(self, e):
        if self._clickable and e.key() in (Qt.Key.Key_Return, Qt.Key.Key_Enter, Qt.Key.Key_Space):
            self.clicked.emit()
        else:
            super().keyPressEvent(e)


class Sparkline(QtWidgets.QWidget):
    def __init__(self, color, maxlen=90, fixed_max=None, parent=None):
        super().__init__(parent)
        self.values = deque(maxlen=maxlen)
        self.color = color
        self.fixed_max = fixed_max
        self.setMinimumHeight(30)

    def push(self, v):
        self.values.append(v)
        self.update()

    def paintEvent(self, _e):
        vals = [v for v in self.values if v is not None]
        if len(vals) < 2:
            return
        p = QtGui.QPainter(self)
        p.setRenderHint(QtGui.QPainter.RenderHint.Antialiasing)
        w, h = self.width(), self.height() - 2
        hi = self.fixed_max or max(max(vals) * 1.15, 1e-6)
        lo = 0.0
        n = self.values.maxlen
        pts = []
        start = n - len(self.values)
        for i, v in enumerate(self.values):
            if v is None:
                continue
            x = (start + i) * w / max(1, n - 1)
            y = 1 + h - (min(v, hi) - lo) / (hi - lo) * h
            pts.append(QtCore.QPointF(x, y))
        if len(pts) < 2:
            return
        path = QtGui.QPainterPath(pts[0])
        for pt in pts[1:]:
            path.lineTo(pt)
        fill = QtGui.QPainterPath(path)
        fill.lineTo(pts[-1].x(), h + 1)
        fill.lineTo(pts[0].x(), h + 1)
        fill.closeSubpath()
        grad = QtGui.QLinearGradient(0, 0, 0, h)
        grad.setColorAt(0, _qc(self.color, 70))
        grad.setColorAt(1, _qc(self.color, 0))
        p.fillPath(fill, grad)
        p.setPen(QtGui.QPen(_qc(self.color), 1.6))
        p.drawPath(path)
        p.end()


class Tile(Card):
    """A resource tile: its name, the reading now, a sparkline of the last
    few minutes. Click for the resource's page."""

    def __init__(self, key, title, unit, color, fixed_max=None, parent=None):
        super().__init__(clickable=True, parent=parent)
        self.key = key
        self.setMinimumWidth(170)
        self.setAccessibleName(title)
        lay = QtWidgets.QVBoxLayout(self)
        lay.setContentsMargins(12, 10, 12, 8)
        lay.setSpacing(2)
        top = QtWidgets.QHBoxLayout()
        self.title = QtWidgets.QLabel(title)
        self.title.setProperty("role", "muted")
        top.addWidget(self.title)
        top.addStretch(1)
        self.sub = QtWidgets.QLabel("")
        self.sub.setProperty("role", "muted")
        self.sub.setFont(figures())
        top.addWidget(self.sub)
        lay.addLayout(top)
        row = QtWidgets.QHBoxLayout()
        row.setSpacing(4)
        self.value = QtWidgets.QLabel("–")
        self.value.setFont(figures(20, bold=True))
        row.addWidget(self.value, 0, Qt.AlignmentFlag.AlignBottom)
        self.unit = QtWidgets.QLabel(unit)
        self.unit.setProperty("role", "muted")
        row.addWidget(self.unit, 0, Qt.AlignmentFlag.AlignBottom)
        row.addStretch(1)
        lay.addLayout(row)
        self.spark = Sparkline(color, fixed_max=fixed_max)
        lay.addWidget(self.spark)

    def set(self, value, fmt="%.0f", sub=""):
        self.value.setText("–" if value is None else fmt % value)
        self.sub.setText(sub)
        self.spark.push(value)


class Switch(QtWidgets.QAbstractButton):
    """An on/off switch, painted, keyboard accessible."""

    def __init__(self, colors, parent=None):
        super().__init__(parent)
        self.setCheckable(True)
        self.c = colors
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self.setFixedSize(40, 22)
        self.setFocusPolicy(Qt.FocusPolicy.StrongFocus)

    def paintEvent(self, _e):
        p = QtGui.QPainter(self)
        p.setRenderHint(QtGui.QPainter.RenderHint.Antialiasing)
        r = QtCore.QRectF(1, 1, self.width() - 2, self.height() - 2)
        on = self.isChecked()
        pal = self.palette()
        track = pal.color(QtGui.QPalette.ColorRole.Highlight) if on else _qc(self.c["text"], 70)
        if not self.isEnabled():
            track.setAlpha(60)
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(track)
        p.drawRoundedRect(r, r.height() / 2, r.height() / 2)
        d = r.height() - 4
        x = r.right() - d - 2 if on else r.left() + 2
        p.setBrush(QtGui.QColor("white"))
        p.drawEllipse(QtCore.QRectF(x, r.top() + 2, d, d))
        if self.hasFocus():
            p.setPen(QtGui.QPen(_qc(self.c["text"], 160), 1.2))
            p.setBrush(Qt.BrushStyle.NoBrush)
            p.drawRoundedRect(r, r.height() / 2, r.height() / 2)
        p.end()

    def sizeHint(self):
        return QtCore.QSize(40, 22)


class ElidedLabel(QtWidgets.QLabel):
    """One line, cut with an ellipsis to the space it has; full text as tooltip."""

    def __init__(self, text="", parent=None):
        super().__init__(parent)
        self._full = text
        self.setToolTip(text)
        self.setSizePolicy(QtWidgets.QSizePolicy.Policy.Ignored, QtWidgets.QSizePolicy.Policy.Preferred)
        self.setMinimumWidth(20)
        super().setText(text)

    def full_text(self):
        return self._full

    def setText(self, text):
        self._full = text
        self.setToolTip(text)
        self._elide()

    def _elide(self):
        super().setText(self.fontMetrics().elidedText(self._full, Qt.TextElideMode.ElideRight, self.width()))

    def resizeEvent(self, e):
        self._elide()
        super().resizeEvent(e)


class FeatureRow(Card):
    """One tuning step: its title, a line about it, a switch. Click the row
    for the step's page."""
    toggled = Signal(str, bool)
    opened = Signal(str)

    def __init__(self, name, label, summary, checked, enabled, tip, colors, parent=None):
        super().__init__(clickable=True, parent=parent)
        self.name = name
        self.label = label
        self.summary = summary or ""
        # keep its height when the window is short: the page scrolls instead
        self.setSizePolicy(QtWidgets.QSizePolicy.Policy.Preferred, QtWidgets.QSizePolicy.Policy.Fixed)
        lay = QtWidgets.QHBoxLayout(self)
        lay.setContentsMargins(12, 8, 8, 8)
        text = QtWidgets.QVBoxLayout()
        text.setSpacing(0)
        t = QtWidgets.QLabel(label)
        f = t.font()
        f.setWeight(QtGui.QFont.Weight.DemiBold)
        t.setFont(f)
        t.setWordWrap(True)      # titles are whole sentences; the row grows, the window never widens
        text.addWidget(t)
        if summary:
            s = ElidedLabel(summary)
            s.setProperty("role", "muted")
            text.addWidget(s)
        self.suggested = QtWidgets.QLabel("")       # "Suggested: ..." while a suggestion is about this step
        self.suggested.setTextFormat(Qt.TextFormat.PlainText)
        self.suggested.setWordWrap(True)
        fs = self.suggested.font()
        fs.setWeight(QtGui.QFont.Weight.DemiBold)
        self.suggested.setFont(fs)
        self.suggested.hide()
        text.addWidget(self.suggested)
        lay.addLayout(text, 1)
        self.switch = Switch(colors)
        self.switch.setChecked(checked)
        self.switch.setEnabled(enabled)
        self.switch.setToolTip(tip)
        self.switch.setAccessibleName(label)
        self.switch.clicked.connect(lambda on: self.toggled.emit(self.name, on))
        lay.addWidget(self.switch)
        chev = QtWidgets.QLabel("›")
        chev.setProperty("role", "muted")
        fc = chev.font()
        fc.setPointSizeF(16)
        chev.setFont(fc)
        lay.addWidget(chev)
        self.setToolTip(tip)
        self.clicked.connect(lambda: self.opened.emit(self.name))

    def suggest(self, text, pulse=True):
        """Show that a suggestion is about this step, and draw the eye to it."""
        self.suggested.setText(text or "")
        self.suggested.setVisible(bool(text))
        self.set_attention(bool(text), pulse)


class ScoreBar(QtWidgets.QWidget):
    """Latest benchmark against the baseline: a bar with a baseline tick."""

    def __init__(self, colors, parent=None):
        super().__init__(parent)
        self.c = colors
        self.data = None
        self.setMinimumHeight(14)

    def set(self, data):
        self.data = data
        self.update()

    def paintEvent(self, _e):
        p = QtGui.QPainter(self)
        p.setRenderHint(QtGui.QPainter.RenderHint.Antialiasing)
        r = QtCore.QRectF(0, 3, self.width(), self.height() - 6)
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(_qc(self.c["grid"]))
        p.drawRoundedRect(r, 4, 4)
        if self.data and self.data.get("pct") is not None:
            pct = max(-50.0, min(50.0, self.data["pct"]))
            mid = r.left() + r.width() / 2
            w = r.width() / 2 * abs(pct) / 50.0
            color = self.c["good"] if pct >= 0 else self.c["bad"]
            p.setBrush(_qc(color))
            bar = QtCore.QRectF(mid, r.top(), w, r.height()) if pct >= 0 else QtCore.QRectF(mid - w, r.top(), w, r.height())
            p.drawRoundedRect(bar, 3, 3)
            p.setPen(QtGui.QPen(_qc(self.c["text"]), 1.5))
            p.drawLine(QtCore.QPointF(mid, r.top() - 3), QtCore.QPointF(mid, r.bottom() + 3))
        p.end()


class TimeChart(QtWidgets.QWidget):
    """Values over time with vertical change markers and dashed period
    averages. points: [(unix time, value)]; markers: [(unix time, label)];
    periods: [(start, end, avg)]. With a title it is a compact strip for
    the Overview, where several share one time range (set_range) so a
    change marker lines up through all of them."""
    clicked = Signal()

    def __init__(self, colors, unit="", title=None, color=None, parent=None):
        super().__init__(parent)
        self.c = colors
        self.unit = unit
        self.title = title
        self.color = color
        self.points, self.markers, self.periods = [], [], []
        self.range = None
        self.empty_text = "No data yet"
        self.setMinimumHeight(96 if title else 170)
        self.setMouseTracking(True)
        self._hover = None
        self._hover_marker = None
        if title:
            self.setCursor(Qt.CursorShape.PointingHandCursor)
            self.setAccessibleName(title)

    def set(self, points, markers=(), periods=(), empty_text=None):
        self.points = sorted((t, v) for t, v in points if v is not None)
        self.markers = list(markers)
        self.periods = list(periods)
        if empty_text:
            self.empty_text = empty_text
        self._hover = self._hover_marker = None
        self.update()

    def set_range(self, t0, t1):
        """Fix the time axis (shared between stacked charts)."""
        self.range = (t0, t1) if t0 is not None and t1 is not None and t1 > t0 else None
        self.update()

    def _frame(self):
        top = 22 if self.title else 12
        return QtCore.QRectF(46, top, self.width() - 56, self.height() - top - 22)

    def _ranges(self):
        ts = [t for t, _ in self.points] + [m[0] for m in self.markers]
        vs = [v for _, v in self.points] + [a for *_, a in self.periods]
        if self.range:
            t0, t1 = self.range
        else:
            t0, t1 = min(ts), max(ts)
            if t1 - t0 < 3600:
                t0, t1 = t0 - 1800, t1 + 1800
        lo, hi = min(vs), max(vs)
        pad = (hi - lo) * 0.15 or abs(hi) * 0.1 or 1.0
        return t0, t1, max(0.0, lo - pad) if lo >= 0 else lo - pad, hi + pad

    @staticmethod
    def _tick(t, span):
        fmt = "%H:%M" if span <= 6 * 3600 else "%a %H:%M" if span <= 2 * 86400 else "%b %d"
        return time.strftime(fmt, time.localtime(t))

    def paintEvent(self, _e):
        p = QtGui.QPainter(self)
        p.setRenderHint(QtGui.QPainter.RenderHint.Antialiasing)
        fr = self._frame()
        small = figures()
        small.setPointSizeF(max(7.0, small.pointSizeF() - 1.5))
        p.setFont(small)
        if self.title:
            p.setPen(_qc(self.c["text"]))
            p.drawText(QtCore.QRectF(fr.left(), 2, fr.width(), 16), Qt.AlignmentFlag.AlignLeft, self.title)
        if len(self.points) < 1:
            p.setPen(_qc(self.c["muted"]))
            p.drawText(QtCore.QRectF(self.rect()), Qt.AlignmentFlag.AlignCenter, self.empty_text)
            p.end()
            return
        t0, t1, lo, hi = self._ranges()
        span = t1 - t0
        X = lambda t: fr.left() + (t - t0) / span * fr.width()                # noqa: E731
        Y = lambda v: fr.bottom() - (v - lo) / (hi - lo) * fr.height()        # noqa: E731
        lines = 3 if self.title else 5
        for i in range(lines):
            v = lo + (hi - lo) * i / (lines - 1)
            y = Y(v)
            p.setPen(QtGui.QPen(_qc(self.c["grid"]), 1))
            p.drawLine(QtCore.QPointF(fr.left(), y), QtCore.QPointF(fr.right(), y))
            p.setPen(_qc(self.c["muted"]))
            p.drawText(QtCore.QRectF(0, y - 7, 40, 14), Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter,
                       ("%.0f" if abs(hi) >= 100 else "%.1f") % v)
        p.drawText(QtCore.QRectF(fr.left(), fr.bottom() + 4, 120, 14), Qt.AlignmentFlag.AlignLeft, self._tick(t0, span))
        p.drawText(QtCore.QRectF(fr.right() - 120, fr.bottom() + 4, 120, 14), Qt.AlignmentFlag.AlignRight,
                   self._tick(t1, span))
        p.setClipRect(fr.adjusted(-1, -8, 1, 1))
        p.setPen(QtGui.QPen(_qc(self.c["muted"]), 1.2, Qt.PenStyle.DashLine))
        for a, b, avg in self.periods:
            p.drawLine(QtCore.QPointF(X(max(a, t0)), Y(avg)), QtCore.QPointF(X(min(b, t1)), Y(avg)))
        for t, _label in self.markers:
            if not t0 <= t <= t1:
                continue
            x = X(t)
            p.setPen(QtGui.QPen(_qc(self.c["change"], 220), 1.4))
            p.drawLine(QtCore.QPointF(x, fr.top()), QtCore.QPointF(x, fr.bottom()))
            p.setBrush(_qc(self.c["change"]))
            p.setPen(Qt.PenStyle.NoPen)
            p.drawPolygon(QtGui.QPolygonF([QtCore.QPointF(x - 4, fr.top() - 6), QtCore.QPointF(x + 4, fr.top() - 6),
                                           QtCore.QPointF(x, fr.top())]))
        color = self.color or self.c["accent"]
        pts = [(t, v) for t, v in self.points if t0 <= t <= t1]
        if len(pts) >= 2:
            path = QtGui.QPainterPath(QtCore.QPointF(X(pts[0][0]), Y(pts[0][1])))
            for t, v in pts[1:]:
                path.lineTo(X(t), Y(v))
            p.setPen(QtGui.QPen(_qc(color), 1.8))
            p.setBrush(Qt.BrushStyle.NoBrush)
            p.drawPath(path)
        if len(pts) <= 45:
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(_qc(color))
            for t, v in pts:
                p.drawEllipse(QtCore.QPointF(X(t), Y(v)), 2.4, 2.4)
        p.setClipping(False)
        label = None
        if self._hover_marker is not None:
            t, text = self._hover_marker
            label = "%s  %s" % (time.strftime("%b %d %H:%M", time.localtime(t)), text)
        elif self._hover is not None:
            t, v = self._hover
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(_qc(self.c["text"]))
            p.drawEllipse(QtCore.QPointF(X(t), Y(v)), 3.5, 3.5)
            label = "%s  %s%s" % (time.strftime("%b %d %H:%M", time.localtime(t)),
                                  ("%.1f" % v), (" " + self.unit) if self.unit else "")
        if label:
            p.setPen(_qc(self.c["text"]))
            p.drawText(QtCore.QRectF(fr.left(), 2 if self.title else fr.top() - 12, fr.width(), 14),
                       Qt.AlignmentFlag.AlignRight, label)
        p.end()

    def marker_at(self, x):
        """The (time, label) of the change marker within a few pixels of x."""
        if not self.points and not self.markers:
            return None
        fr = self._frame()
        try:
            t0, t1, _, _ = self._ranges()
        except ValueError:
            return None
        for t, label in self.markers:
            if t0 <= t <= t1 and abs(fr.left() + (t - t0) / (t1 - t0) * fr.width() - x) <= 5:
                return t, label
        return None

    def mouseMoveEvent(self, e):
        if not self.points:
            return
        fr = self._frame()
        t0, t1, _, _ = self._ranges()
        x = e.position().x() if hasattr(e, "position") else e.x()
        self._hover_marker = self.marker_at(x)
        t = t0 + (x - fr.left()) / max(1.0, fr.width()) * (t1 - t0)
        inside = [pt for pt in self.points if t0 <= pt[0] <= t1]
        self._hover = min(inside, key=lambda pt: abs(pt[0] - t)) if inside else None
        self.setToolTip(self._hover_marker[1] if self._hover_marker else "")
        self.update()

    def leaveEvent(self, _e):
        self._hover = self._hover_marker = None
        self.update()

    def mouseReleaseEvent(self, e):
        if e.button() == Qt.MouseButton.LeftButton:
            self.clicked.emit()
        super().mouseReleaseEvent(e)


class TileGrid(QtWidgets.QWidget):
    """Tiles in as many columns as fit, so they reflow with the window."""
    MIN_COLUMN = 190

    def __init__(self, parent=None):
        super().__init__(parent)
        self.grid = QtWidgets.QGridLayout(self)
        self.grid.setContentsMargins(0, 0, 0, 0)
        self.grid.setSpacing(8)
        self.items = []
        self.columns = 0
        # its own minimum, two tiles wide: without one the grid's current
        # columns would set it, and a wide window could never narrow again
        self.setMinimumWidth(2 * 170 + 8)

    def add(self, w):
        self.items.append(w)
        w.setParent(self)

    def relayout(self, force=False):
        shown = [w for w in self.items if not w.isHidden()]
        cols = max(2, min(len(shown) or 2, self.width() // self.MIN_COLUMN or 2))
        if cols == self.columns and not force:
            return
        self.columns = cols
        for w in self.items:
            self.grid.removeWidget(w)
        for i, w in enumerate(shown):
            self.grid.addWidget(w, i // cols, i % cols)
        for c in range(8):
            self.grid.setColumnStretch(c, 1 if c < cols else 0)

    def resizeEvent(self, e):
        self.relayout()
        super().resizeEvent(e)
