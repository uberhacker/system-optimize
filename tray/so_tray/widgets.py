"""Custom-painted widgets for the panel: sparkline tiles, a switch, feature
rows, the benchmark bar and a time-series chart with change markers."""

import time
from collections import deque

from .qt import QtCore, QtGui, QtWidgets, Signal
from .theme import mono

Qt = QtCore.Qt


def _qc(hexcolor, alpha=None):
    c = QtGui.QColor(hexcolor)
    if alpha is not None:
        c.setAlpha(alpha)
    return c


class Card(QtWidgets.QFrame):
    clicked = Signal()

    def __init__(self, clickable=False, parent=None):
        super().__init__(parent)
        self.setProperty("card", True)
        self._clickable = clickable
        if clickable:
            self.setCursor(Qt.CursorShape.PointingHandCursor)

    def enterEvent(self, e):
        if self._clickable:
            self.setProperty("hover", True)
            self.style().polish(self)
        super().enterEvent(e)

    def leaveEvent(self, e):
        self.setProperty("hover", False)
        self.style().polish(self)
        super().leaveEvent(e)

    def mouseReleaseEvent(self, e):
        if self._clickable and e.button() == Qt.MouseButton.LeftButton:
            self.clicked.emit()
        super().mouseReleaseEvent(e)


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
        grad.setColorAt(0, _qc(self.color, 90))
        grad.setColorAt(1, _qc(self.color, 0))
        p.fillPath(fill, grad)
        p.setPen(QtGui.QPen(_qc(self.color), 1.6))
        p.drawPath(path)
        p.end()


class Tile(Card):
    """A resource tile: label, big monospace value, sparkline."""

    def __init__(self, key, title, unit, color, fixed_max=None, parent=None):
        super().__init__(clickable=True, parent=parent)
        self.key = key
        lay = QtWidgets.QVBoxLayout(self)
        lay.setContentsMargins(12, 10, 12, 8)
        lay.setSpacing(2)
        top = QtWidgets.QHBoxLayout()
        self.title = QtWidgets.QLabel(title.upper())
        self.title.setProperty("role", "muted")
        f = self.title.font()
        f.setPointSizeF(8)
        f.setLetterSpacing(QtGui.QFont.SpacingType.AbsoluteSpacing, 0.8)
        self.title.setFont(f)
        top.addWidget(self.title)
        top.addStretch(1)
        self.sub = QtWidgets.QLabel("")
        self.sub.setProperty("role", "muted")
        self.sub.setFont(mono(8))
        top.addWidget(self.sub)
        lay.addLayout(top)
        row = QtWidgets.QHBoxLayout()
        row.setSpacing(4)
        self.value = QtWidgets.QLabel("–")
        self.value.setFont(mono(19, bold=True))
        row.addWidget(self.value, 0, Qt.AlignmentFlag.AlignBottom)
        self.unit = QtWidgets.QLabel(unit)
        self.unit.setProperty("role", "muted")
        self.unit.setFont(mono(10))
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
        track = _qc(self.c["accent"]) if on else _qc(self.c["border"])
        if not self.isEnabled():
            track.setAlpha(90)
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(track)
        p.drawRoundedRect(r, r.height() / 2, r.height() / 2)
        d = r.height() - 4
        x = r.right() - d - 2 if on else r.left() + 2
        p.setBrush(QtGui.QColor("white"))
        p.drawEllipse(QtCore.QRectF(x, r.top() + 2, d, d))
        if self.hasFocus():
            p.setPen(QtGui.QPen(_qc(self.c["accent"]), 1.2))
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

    def resizeEvent(self, e):
        super().setText(self.fontMetrics().elidedText(self._full, Qt.TextElideMode.ElideRight, self.width()))
        super().resizeEvent(e)


class FeatureRow(Card):
    toggled = Signal(str, bool)
    opened = Signal(str)

    def __init__(self, name, label, summary, checked, enabled, tip, colors, parent=None):
        super().__init__(clickable=True, parent=parent)
        self.name = name
        # keep its height when the panel is short: the panel scrolls instead
        self.setSizePolicy(QtWidgets.QSizePolicy.Policy.Preferred, QtWidgets.QSizePolicy.Policy.Fixed)
        lay = QtWidgets.QHBoxLayout(self)
        lay.setContentsMargins(12, 8, 8, 8)
        text = QtWidgets.QVBoxLayout()
        text.setSpacing(0)
        t = QtWidgets.QLabel(label)
        f = t.font()
        f.setWeight(QtGui.QFont.Weight.DemiBold)
        t.setFont(f)
        text.addWidget(t)
        if summary:
            s = ElidedLabel(summary)
            s.setProperty("role", "muted")
            fs = s.font()
            fs.setPointSizeF(max(7.5, fs.pointSizeF() - 1))
            s.setFont(fs)
            text.addWidget(s)
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
    periods: [(start, end, avg)]."""

    def __init__(self, colors, unit="", parent=None):
        super().__init__(parent)
        self.c = colors
        self.unit = unit
        self.points, self.markers, self.periods = [], [], []
        self.empty_text = "No data yet"
        self.setMinimumHeight(170)
        self.setMouseTracking(True)
        self._hover = None

    def set(self, points, markers=(), periods=(), empty_text=None):
        self.points = sorted((t, v) for t, v in points if v is not None)
        self.markers = list(markers)
        self.periods = list(periods)
        if empty_text:
            self.empty_text = empty_text
        self.update()

    def _frame(self):
        return QtCore.QRectF(44, 10, self.width() - 54, self.height() - 34)

    def _ranges(self):
        ts = [t for t, _ in self.points] + [m[0] for m in self.markers]
        vs = [v for _, v in self.points] + [a for *_, a in self.periods]
        t0, t1 = min(ts), max(ts)
        if t1 - t0 < 3600:
            t0, t1 = t0 - 1800, t1 + 1800
        lo, hi = min(vs), max(vs)
        pad = (hi - lo) * 0.15 or abs(hi) * 0.1 or 1.0
        return t0, t1, lo - pad, hi + pad

    def paintEvent(self, _e):
        p = QtGui.QPainter(self)
        p.setRenderHint(QtGui.QPainter.RenderHint.Antialiasing)
        fr = self._frame()
        p.setFont(mono(7.5))
        if len(self.points) < 1:
            p.setPen(_qc(self.c["muted"]))
            p.drawText(self.rect(), Qt.AlignmentFlag.AlignCenter, self.empty_text)
            p.end()
            return
        t0, t1, lo, hi = self._ranges()
        X = lambda t: fr.left() + (t - t0) / (t1 - t0) * fr.width()          # noqa: E731
        Y = lambda v: fr.bottom() - (v - lo) / (hi - lo) * fr.height()        # noqa: E731
        # grid + y labels
        for i in range(5):
            v = lo + (hi - lo) * i / 4
            y = Y(v)
            p.setPen(QtGui.QPen(_qc(self.c["grid"]), 1))
            p.drawLine(QtCore.QPointF(fr.left(), y), QtCore.QPointF(fr.right(), y))
            p.setPen(_qc(self.c["muted"]))
            p.drawText(QtCore.QRectF(0, y - 7, 40, 14), Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter,
                       ("%.0f" if abs(hi) >= 100 else "%.1f") % v)
        # x labels: first and last date
        p.drawText(QtCore.QRectF(fr.left(), fr.bottom() + 4, 120, 14), Qt.AlignmentFlag.AlignLeft,
                   time.strftime("%b %d", time.localtime(t0)))
        p.drawText(QtCore.QRectF(fr.right() - 120, fr.bottom() + 4, 120, 14), Qt.AlignmentFlag.AlignRight,
                   time.strftime("%b %d", time.localtime(t1)))
        # period averages
        pen = QtGui.QPen(_qc(self.c["muted"]), 1.2, Qt.PenStyle.DashLine)
        p.setPen(pen)
        for a, b, avg in self.periods:
            p.drawLine(QtCore.QPointF(X(max(a, t0)), Y(avg)), QtCore.QPointF(X(min(b, t1)), Y(avg)))
        # change markers
        for t, label in self.markers:
            x = X(t)
            p.setPen(QtGui.QPen(_qc(self.c["warn"], 200), 1.2))
            p.drawLine(QtCore.QPointF(x, fr.top()), QtCore.QPointF(x, fr.bottom()))
            p.setBrush(_qc(self.c["warn"]))
            p.setPen(Qt.PenStyle.NoPen)
            p.drawPolygon(QtGui.QPolygonF([QtCore.QPointF(x - 4, fr.top() - 6), QtCore.QPointF(x + 4, fr.top() - 6),
                                           QtCore.QPointF(x, fr.top())]))
        # the series
        accent = self.c["accent"]
        if len(self.points) >= 2:
            path = QtGui.QPainterPath(QtCore.QPointF(X(self.points[0][0]), Y(self.points[0][1])))
            for t, v in self.points[1:]:
                path.lineTo(X(t), Y(v))
            p.setPen(QtGui.QPen(_qc(accent), 2))
            p.setBrush(Qt.BrushStyle.NoBrush)
            p.drawPath(path)
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(_qc(accent))
        for t, v in self.points:
            p.drawEllipse(QtCore.QPointF(X(t), Y(v)), 2.6, 2.6)
        # hover readout
        if self._hover is not None:
            t, v = self._hover
            x, y = X(t), Y(v)
            p.setBrush(_qc(self.c["text"]))
            p.drawEllipse(QtCore.QPointF(x, y), 3.5, 3.5)
            label = "%s  %s%s" % (time.strftime("%b %d %H:%M", time.localtime(t)),
                                  ("%.1f" % v), (" " + self.unit) if self.unit else "")
            p.setPen(_qc(self.c["text"]))
            p.drawText(QtCore.QRectF(fr.left(), fr.top() - 2, fr.width(), 14), Qt.AlignmentFlag.AlignRight, label)
        p.end()

    def mouseMoveEvent(self, e):
        if not self.points:
            return
        fr = self._frame()
        t0, t1, _, _ = self._ranges()
        x = e.position().x() if hasattr(e, "position") else e.x()
        t = t0 + (x - fr.left()) / max(1.0, fr.width()) * (t1 - t0)
        self._hover = min(self.points, key=lambda pt: abs(pt[0] - t))
        self.update()

    def leaveEvent(self, _e):
        self._hover = None
        self.update()
