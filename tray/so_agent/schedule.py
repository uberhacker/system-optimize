"""When the agent runs on its own: a cron expression, installed as a
systemd user timer (or a crontab line where there is no systemd user
session). The default, @daily, is once every 24 hours; a run missed while
the machine was off happens at the next boot."""

import os
import re
import shutil
import subprocess

UNIT = "system-optimize-agent"
CRON_TAG = "# system-optimize-agent (managed; edit with system-optimize-agent schedule)"
MACROS = {
    "@hourly": ("0 * * * *", "hourly"),
    "@daily": ("0 0 * * *", "daily"),
    "@midnight": ("0 0 * * *", "daily"),
    "@weekly": ("0 0 * * 0", "weekly"),
    "@monthly": ("0 0 1 * *", "monthly"),
}
FIELD = re.compile(r"^(\*|\d+(-\d+)?)(/\d+)?(,(\*|\d+(-\d+)?)(/\d+)?)*$")
RANGES = ((0, 59), (0, 23), (1, 31), (1, 12), (0, 7))
DOW = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]


class ScheduleError(Exception):
    pass


def _check_field(text, lo, hi, what):
    if not FIELD.match(text):
        raise ScheduleError("bad %s field %r" % (what, text))
    for n in re.findall(r"\d+", re.sub(r"/\d+", "", text)):
        if not lo <= int(n) <= hi:
            raise ScheduleError("%s %s out of range %d-%d" % (what, n, lo, hi))
    for step in re.findall(r"/(\d+)", text):
        if int(step) == 0:
            raise ScheduleError("step of 0 in %s" % what)


def normalise(expr):
    """(five-field cron text, OnCalendar value) for a cron expression."""
    expr = " ".join((expr or "").split())
    if expr in MACROS:
        return MACROS[expr]
    parts = expr.split(" ")
    if len(parts) != 5:
        raise ScheduleError("a schedule is five cron fields (minute hour day month weekday) or @daily, "
                            "@hourly, @weekly, @monthly; got %r" % expr)
    names = ("minute", "hour", "day of month", "month", "weekday")
    for text, (lo, hi), what in zip(parts, RANGES, names):
        _check_field(text, lo, hi, what)
    return expr, to_oncalendar(parts)


def _sd(field, width=2):
    """A cron field in systemd syntax: 1-5 -> 01..05, */15 -> 00/15, a,b -> a,b."""
    out = []
    for item in field.split(","):
        base, _, step = item.partition("/")
        if base == "*":
            out.append("*" + ("/" + step if step else ""))
            continue
        lo, _, hi = base.partition("-")
        s = "%0*d" % (width, int(lo))
        if hi:
            s += "..%0*d" % (width, int(hi))
        if step:
            s += "/" + step
        out.append(s)
    return ",".join(out)


def _dow(field):
    if field == "*":
        return ""
    out = []
    for item in field.split(","):
        if "/" in item:
            raise ScheduleError("steps in the weekday field are not supported")
        lo, _, hi = item.partition("-")
        out.append(DOW[int(lo)] + (".." + DOW[int(hi)] if hi else ""))
    return ",".join(out) + " "


def to_oncalendar(parts):
    minute, hour, dom, month, dow = parts
    return "%s*-%s-%s %s:%s:00" % (_dow(dow), _sd(month), _sd(dom), _sd(hour), _sd(minute))


def unit_dir():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "systemd", "user")


def service_text(exe):
    return ("[Unit]\nDescription=system-optimize tuning agent (scheduled check)\n"
            "Documentation=https://github.com/bradvrudney/system-optimize\n\n"
            "[Service]\nType=oneshot\nExecStart=%s run --scheduled\nNice=10\n"
            "IOSchedulingClass=idle\nTimeoutStartSec=1h\n" % exe)


def timer_text(oncalendar):
    return ("[Unit]\nDescription=Run the system-optimize tuning agent on a schedule\n\n"
            "[Timer]\nOnCalendar=%s\nPersistent=true\nRandomizedDelaySec=15min\n\n"
            "[Install]\nWantedBy=timers.target\n" % oncalendar)


def _systemd_user_ok(run):
    if not shutil.which("systemctl"):
        return False
    res = run(["systemctl", "--user", "is-system-running"])
    return res[0] in (0, 1) and res[1].strip() not in ("", "offline")


def _run(argv, stdin=None):
    try:
        r = subprocess.run(argv, input=stdin, capture_output=True, text=True, timeout=30, check=False)
    except (OSError, subprocess.SubprocessError) as exc:
        return 127, "", str(exc)
    return r.returncode, r.stdout, r.stderr


def install(expr, exe, run=_run, udir=None):
    """Install or replace the schedule. 'off' removes it. Returns a message."""
    if (expr or "").strip().lower() == "off":
        return remove(run=run, udir=udir)
    cron, cal = normalise(expr)
    udir = udir or unit_dir()
    if _systemd_user_ok(run):
        os.makedirs(udir, exist_ok=True)
        with open(os.path.join(udir, UNIT + ".service"), "w", encoding="utf-8") as fh:
            fh.write(service_text(exe))
        with open(os.path.join(udir, UNIT + ".timer"), "w", encoding="utf-8") as fh:
            fh.write(timer_text(cal))
        run(["systemctl", "--user", "daemon-reload"])
        rc, _, err = run(["systemctl", "--user", "enable", "--now", UNIT + ".timer"])
        if rc != 0:
            raise ScheduleError("systemctl --user enable failed: %s" % err.strip())
        _cron_remove(run)
        return "systemd user timer %s.timer: OnCalendar=%s (cron %s)" % (UNIT, cal, cron)
    if shutil.which("crontab"):
        _cron_set(run, "%s %s run --scheduled %s" % (cron, exe, CRON_TAG))
        return "crontab: %s" % cron
    raise ScheduleError("neither a systemd user session nor crontab is available")


def remove(run=_run, udir=None):
    udir = udir or unit_dir()
    removed = []
    if shutil.which("systemctl"):
        run(["systemctl", "--user", "disable", "--now", UNIT + ".timer"])
    for ext in (".timer", ".service"):
        p = os.path.join(udir, UNIT + ext)
        if os.path.exists(p):
            os.remove(p)
            removed.append(p)
    if removed and shutil.which("systemctl"):
        run(["systemctl", "--user", "daemon-reload"])
    if _cron_remove(run):
        removed.append("crontab line")
    return "schedule removed" if removed else "no schedule was installed"


def _cron_lines(run):
    rc, out, _ = run(["crontab", "-l"])
    return out.splitlines() if rc == 0 else []


def _cron_set(run, line):
    lines = [x for x in _cron_lines(run) if CRON_TAG not in x] + [line]
    run(["crontab", "-"], stdin="\n".join(lines) + "\n")


def _cron_remove(run):
    if not shutil.which("crontab"):
        return False
    lines = _cron_lines(run)
    keep = [x for x in lines if CRON_TAG not in x]
    if len(keep) == len(lines):
        return False
    run(["crontab", "-"], stdin="\n".join(keep) + ("\n" if keep else ""))
    return True


def next_run(run=_run):
    """When the timer fires next, as systemd prints it, or None."""
    if not shutil.which("systemctl"):
        return None
    rc, out, _ = run(["systemctl", "--user", "show", UNIT + ".timer", "--property=NextElapseUSecRealtime",
                      "--value"])
    out = out.strip()
    return out if rc == 0 and out and out != "n/a" else None
