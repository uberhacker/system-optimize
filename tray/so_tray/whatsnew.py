"""Release notes written for the people who use the app, not for the
people who build it: data/whats-new.md, shown from the dashboard's menu, and
by themselves the first time the dashboard opens after an update.

The file is Markdown with one "## VERSION (DATE)" heading per release,
newest first."""

import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
CANDIDATES = (
    os.path.join(HERE, "..", "whats-new.md"),                 # installed: PKGDATADIR/whats-new.md
    os.path.join(HERE, "..", "data", "whats-new.md"),         # source tree
    "/usr/share/system-optimize-tray/whats-new.md",
)
HEADING = re.compile(r"^## +(\d+(?:\.\d+){1,3})(?: +\(([^)\n]*)\))? *$", re.M)


def load_text(paths=CANDIDATES):
    for p in paths:
        try:
            with open(p, encoding="utf-8") as fh:
                return fh.read()
        except OSError:
            continue
    return ""


def version_key(v):
    """'0.10.1' -> (0, 10, 1), for comparing; () for anything else."""
    try:
        return tuple(int(x) for x in str(v).split("."))
    except ValueError:
        return ()


def entries(text):
    """[{'version', 'date', 'body'}], newest first, as the file has them."""
    marks = list(HEADING.finditer(text or ""))
    out = []
    for m, nxt in zip(marks, marks[1:] + [None]):
        body = text[m.end():nxt.start() if nxt else len(text)].strip()
        out.append({"version": m.group(1), "date": m.group(2) or "", "body": body})
    return out


def since(notes, seen):
    """The releases newer than the version the user last saw (all of them
    when that is unknown)."""
    key = version_key(seen)
    return [n for n in notes if not key or version_key(n["version"]) > key]


def markdown(notes):
    """The notes as one Markdown document for the dialog."""
    return "\n\n".join("## Version %s%s\n\n%s" % (n["version"], ("  (%s)" % n["date"]) if n["date"] else "", n["body"])
                       for n in notes)
