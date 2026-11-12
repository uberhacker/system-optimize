"""Agent settings: defaults < /etc/system-optimize/agent.conf <
~/.config/system-optimize/agent.conf < SO_AGENT_* environment < flags.

KEY=value lines, '#' comments; parsed and checked, never sourced.
"""

import os
import re

from . import DEFAULT_MODEL

DEFAULTS = {
    "AGENT_BACKEND": "ollama",              # ollama | llamacpp (OpenAI-compatible server)
    "AGENT_MODEL": DEFAULT_MODEL,
    "AGENT_URL": "",                        # default per backend, see backend_url()
    "AGENT_SCHEDULE": "@daily",             # cron expression, or "off"
    "AGENT_KEEP_ALIVE": "5m",               # how long Ollama keeps the model loaded after a chat
    "AGENT_BENCHMARK": "1",                 # scheduled runs benchmark first (when the CLI can)
    "AGENT_NOTIFY": "1",                    # desktop notification when a proposal is ready
    "AGENT_TIMEOUT": "300",                 # seconds per model request
    "AGENT_MAX_ROUNDS": "6",                # tool-call rounds per question
    "AGENT_TRIAGE": "rules",                # rules | laya (needs pip install laya) | off; see triage.py
    "AGENT_TRIAGE_WAKE": "0",               # 1: when a pressure episode leaves triage unsure, ask the model
}
VALID = {
    "AGENT_BACKEND": re.compile(r"^(ollama|llamacpp)$"),
    "AGENT_MODEL": re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/@-]{0,127}$"),
    "AGENT_URL": re.compile(r"^(https?://[A-Za-z0-9.:\[\]_-]+(/[A-Za-z0-9._/-]*)?)?$"),
    "AGENT_SCHEDULE": re.compile(r"^[A-Za-z0-9@*/,\- ]{1,64}$"),
    "AGENT_KEEP_ALIVE": re.compile(r"^(-1|0|\d+[smh]?)$"),
    "AGENT_BENCHMARK": re.compile(r"^[01]$"),
    "AGENT_NOTIFY": re.compile(r"^[01]$"),
    "AGENT_TIMEOUT": re.compile(r"^\d{1,5}$"),
    "AGENT_MAX_ROUNDS": re.compile(r"^([1-9]|1\d|20)$"),
    "AGENT_TRIAGE": re.compile(r"^(rules|laya|off)$"),
    "AGENT_TRIAGE_WAKE": re.compile(r"^[01]$"),
}
SYSTEM_FILE = "/etc/system-optimize/agent.conf"


def user_file():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "system-optimize", "agent.conf")


def state_dir():
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(base, "system-optimize-tray", "agent")


class ConfigError(Exception):
    pass


def parse(text, source="config"):
    """{KEY: value} from KEY=value text; unknown keys and bad values raise."""
    out = {}
    for n, raw in enumerate((text or "").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ConfigError("%s:%d: expected KEY=value" % (source, n))
        key, value = (s.strip() for s in line.split("=", 1))
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        check(key, value, "%s:%d" % (source, n))
        out[key] = value
    return out


def check(key, value, where="config"):
    if key not in DEFAULTS:
        raise ConfigError("%s: unknown setting %s" % (where, key))
    if not VALID[key].match(value):
        raise ConfigError("%s: bad value for %s: %r" % (where, key, value))


def load(files=None, environ=None, overrides=None):
    cfg = dict(DEFAULTS)
    for path in files if files is not None else (SYSTEM_FILE, user_file()):
        try:
            with open(path, encoding="utf-8") as fh:
                cfg.update(parse(fh.read(), path))
        except FileNotFoundError:
            continue
    env = os.environ if environ is None else environ
    for key in DEFAULTS:
        v = env.get("SO_" + key)
        if v is not None:
            check(key, v, "SO_" + key)
            cfg[key] = v
    for key, v in (overrides or {}).items():
        if v is not None:
            check(key, v, "option")
            cfg[key] = v
    return cfg


def backend_url(cfg):
    if cfg.get("AGENT_URL"):
        return cfg["AGENT_URL"].rstrip("/")
    return "http://127.0.0.1:11434" if cfg["AGENT_BACKEND"] == "ollama" else "http://127.0.0.1:8080"


def write_user_setting(key, value, path=None):
    """Set KEY=value in the user's agent.conf, keeping the other lines."""
    check(key, value)
    path = path or user_file()
    lines = []
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except FileNotFoundError:
        pass
    out, done = [], False
    for line in lines:
        if line.split("=", 1)[0].strip() == key:
            if not done:
                out.append("%s=%s" % (key, value))
                done = True
            continue
        out.append(line)
    if not done:
        out.append("%s=%s" % (key, value))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write("\n".join(out) + "\n")
    os.replace(tmp, path)
