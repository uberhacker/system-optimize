"""system-optimize-tray-backend: the tray app's logic as a command.

The GNOME Shell extension runs this (as the user) and reads JSON from it, so
both front ends share one implementation of monitoring and of talking to
system-optimize.

  monitor [--watch] [--interval S] [--record]
                                     one JSON sample, or one per line forever;
                                     --record also keeps resource averages
                                     (at most once a minute, see history.py)
  features                           steps, their state, capabilities (JSON)
  set NAME on|off                    turn one step on or off (pkexec)
  apply-all                          a normal run of every default step (pkexec)
  undo [ID]                          restore a snapshot (pkexec)
  profile NAME                       apply a workload profile (pkexec)
  preview [STEP...]                  dry run; text
  status                             system-optimize --status; text
  benchmark                          system-optimize --benchmark-only; text

Commands that change something print {"ok": bool, "code": N, "output": "..."}.
"""

import argparse
import json
import os
import sys
import time

from . import VERSION
from .cli import Cli, CliError
from .monitor import Monitor


def _emit(obj, stream=sys.stdout):
    stream.write(json.dumps(obj, separators=(",", ":"), sort_keys=True) + "\n")
    stream.flush()


def _result(rc_out_err):
    rc, out, err = rc_out_err
    text = (out or "") + (err or "")
    if rc == 126 or rc == 127:
        # pkexec: 126 = the user dismissed the dialog / not authorised.
        text = text or "not authorised"
    return {"ok": rc == 0, "code": rc, "output": text.strip()}


def cmd_monitor(args, out=sys.stdout, recorder=None, trigger=None):
    mon = Monitor(root=os.environ.get("SO_ROOT", "/"))
    alerts = None
    if args.record and recorder is None:
        from .history import Recorder
        recorder = Recorder()
    if args.record:
        # the recording monitor is the one that runs all day (the GNOME
        # extension's): it also starts the agent's quick look when a
        # pressure episode begins
        from .model import PressureAlerts
        from .trigger import TriageTrigger
        alerts = PressureAlerts()
        trigger = trigger or TriageTrigger()

    def one():
        sample = mon.sample()
        _emit(sample, out)
        if recorder:
            recorder.add(sample)
        if alerts is not None and alerts.update(sample):
            trigger.fire()

    mon.cpu()                    # prime the CPU counters
    time.sleep(min(0.5, args.interval))
    try:
        one()
        while args.watch:
            time.sleep(args.interval)
            one()
    except (KeyboardInterrupt, BrokenPipeError):
        pass
    finally:
        if recorder:
            recorder.close()
    return 0


def cmd_features(cli, out=sys.stdout):
    _emit(cli.describe(), out)
    return 0


def cmd_set(cli, name, state, out=sys.stdout):
    info = cli.describe()
    feat = next((f for f in info["features"] if f["name"] == name), None)
    if feat is None:
        _emit({"ok": False, "code": 2, "output": "no such step: %s" % name}, out)
        return 2
    res = _result(cli.set_feature(feat, state == "on"))
    _emit(res, out)
    return 0 if res["ok"] else 1


def _text(rc_text, out=sys.stdout):
    rc, text = rc_text
    out.write(text + "\n")
    return rc


def build_parser():
    p = argparse.ArgumentParser(prog="system-optimize-tray-backend",
                                description="Monitoring and control for the system-optimize tray app.")
    p.add_argument("--version", action="version", version="system-optimize-tray " + VERSION)
    sub = p.add_subparsers(dest="cmd", required=True)
    m = sub.add_parser("monitor")
    m.add_argument("--watch", action="store_true")
    m.add_argument("--interval", type=float, default=2.0)
    m.add_argument("--record", action="store_true", help="keep hourly and daily averages for the dashboard")
    sub.add_parser("features")
    s = sub.add_parser("set")
    s.add_argument("name")
    s.add_argument("state", choices=("on", "off"))
    sub.add_parser("apply-all")
    u = sub.add_parser("undo")
    u.add_argument("snapshot", nargs="?")
    pr = sub.add_parser("profile")
    pr.add_argument("name")
    pv = sub.add_parser("preview")
    pv.add_argument("steps", nargs="*")
    sub.add_parser("status")
    sub.add_parser("benchmark")
    return p


def main(argv=None, cli=None, out=sys.stdout):
    args = build_parser().parse_args(argv)
    if args.cmd == "monitor":
        if args.interval < 0.5 or args.interval > 3600:
            print("interval must be between 0.5 and 3600 seconds", file=sys.stderr)
            return 2
        return cmd_monitor(args, out)
    cli = cli or Cli()
    try:
        if args.cmd == "features":
            return cmd_features(cli, out)
        if not cli.available():
            _emit({"ok": False, "code": 127, "output": "system-optimize is not installed"}, out)
            return 1
        if args.cmd == "set":
            return cmd_set(cli, args.name, args.state, out)
        if args.cmd == "apply-all":
            res = _result(cli.apply_all())
        elif args.cmd == "undo":
            res = _result(cli.undo(args.snapshot))
        elif args.cmd == "profile":
            res = _result(cli.apply_profile(args.name))
        elif args.cmd == "preview":
            return _text(cli.preview(args.steps), out)
        elif args.cmd == "status":
            return _text(cli.status_text(), out)
        elif args.cmd == "benchmark":
            return _text(cli.benchmark(), out)
        else:  # pragma: no cover - argparse rejects it first
            return 2
    except CliError as exc:
        _emit({"ok": False, "code": 2, "output": str(exc)}, out)
        return 2
    _emit(res, out)
    return 0 if res["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
