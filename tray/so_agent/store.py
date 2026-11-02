"""The pending proposal and a short log of agent runs, in the user's state
directory (0700). The CLI owns the benchmark history; this is only the
agent's own bookkeeping."""

import json
import os
import time

from .config import state_dir


def _path(name, base=None):
    return os.path.join(base or state_dir(), name)


def _ensure(base=None):
    d = base or state_dir()
    os.makedirs(d, mode=0o700, exist_ok=True)
    return d


def save_proposal(proposal_dict, base=None):
    d = _ensure(base)
    data = dict(proposal_dict, created=int(time.time()))
    tmp = _path("proposal.json.tmp", d)
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(data, fh)
    os.replace(tmp, _path("proposal.json", d))


def load_proposal(base=None):
    try:
        with open(_path("proposal.json", base), encoding="utf-8") as fh:
            d = json.load(fh)
        return d if isinstance(d, dict) and d.get("action") else None
    except (OSError, ValueError):
        return None


def clear_proposal(base=None):
    try:
        os.remove(_path("proposal.json", base))
    except FileNotFoundError:
        pass


def log_run(entry, base=None, keep=200):
    d = _ensure(base)
    path = _path("runs.jsonl", d)
    lines = []
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()[-(keep - 1):]
    except FileNotFoundError:
        pass
    lines.append(json.dumps(dict(entry, time=int(time.time()))))
    fd = os.open(path + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    os.replace(path + ".tmp", path)
