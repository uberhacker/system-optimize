"""Tray settings in ~/.config/system-optimize/tray.conf (KEY=value; parsed,
never sourced). The GNOME Shell extension reads the same file.

  THEME=system | light | dark      default system (follows the desktop live)
  EXPANDED=memory,storage          from the old panel's collapsible categories; read but no longer used
  RECORD_HISTORY=1 | 0             keep hourly and daily resource averages (default 1)
  HISTORY_SOURCE=auto | tray       auto: read CPU, memory and disk history from Performance Co-Pilot
                                   when its archives go back further than the tray's own
  PSI_ALERTS=1 | 0                 notify when pressure stall (PSI) crosses psi-notify's thresholds
  SEEN_VERSION=0.2.0               the version whose "What's new" you have been offered
  WINDOW=1040x680[,max]            the full view's size when it was last closed (no position: Wayland
                                   places windows itself)
"""

import os
import re

DEFAULTS = {"THEME": "system", "EXPANDED": "", "RECORD_HISTORY": "1", "PSI_ALERTS": "1", "HISTORY_SOURCE": "auto",
            "WINDOW": "", "SEEN_VERSION": ""}
VALID = {"THEME": re.compile(r"^(system|light|dark)$"),
         "EXPANDED": re.compile(r"^[a-z0-9_,-]*$"),
         "RECORD_HISTORY": re.compile(r"^[01]$"),
         "PSI_ALERTS": re.compile(r"^[01]$"),
         "HISTORY_SOURCE": re.compile(r"^(auto|tray)$"),
         "WINDOW": re.compile(r"^(\d{3,5}x\d{3,5}(,max)?)?$"),
         "SEEN_VERSION": re.compile(r"^(\d+(\.\d+){1,3})?$")}


def path():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "system-optimize", "tray.conf")


def load(p=None):
    out = dict(DEFAULTS)
    try:
        with open(p or path(), encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = (s.strip().strip("\"'") for s in line.split("=", 1))
                if k in VALID and VALID[k].match(v):
                    out[k] = v
    except OSError:
        pass
    return out


def save(key, value, p=None):
    if key not in VALID or not VALID[key].match(value):
        raise ValueError("bad setting %s=%s" % (key, value))
    p = p or path()
    lines = []
    try:
        with open(p, encoding="utf-8") as fh:
            lines = [ln.rstrip("\n") for ln in fh if ln.split("=", 1)[0].strip() != key]
    except OSError:
        pass
    lines.append("%s=%s" % (key, value))
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p + ".tmp", "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    os.replace(p + ".tmp", p)
