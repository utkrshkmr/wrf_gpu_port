#!/usr/bin/env python3
"""Minimal editor for WRF namelist.input files (used by the port scripts).

Only whole entries are replaced; comments and the layout of other lines are
kept.  Values are given exactly as they should appear after "=".

Usage:
  nml.py namelist.input set run_hours=1 restart=.true. 'e_we=450, 181'
  nml.py namelist.input get e_we
  python: from nml import read_value, set_values
"""

import re
import sys


def _entry_re(name):
    return re.compile(r"^(\s*)" + re.escape(name) + r"(\s*=\s*)([^!\n]*?)(\s*)(!.*)?$", re.I | re.M)


def read_value(text, name):
    m = _entry_re(name).search(text)
    if not m:
        return None
    return m.group(3).strip().rstrip(",").strip()


def set_values(text, pairs, group_for_new="time_control"):
    """pairs: list of (name, value).  Adds missing entries to group_for_new."""
    for name, value in pairs:
        r = _entry_re(name)
        if r.search(text):
            text = r.sub(lambda m: f"{m.group(1)}{name}{m.group(2)}{value},{m.group(4) or ''}"
                         f"{m.group(5) or ''}", text, count=1)
        else:
            g = re.search(r"^\s*&" + re.escape(group_for_new) + r"\b.*$", text, re.I | re.M)
            if not g:
                raise SystemExit(f"nml: no &{group_for_new} group to add {name}")
            text = text[:g.end()] + f"\n {name} = {value}," + text[g.end():]
    return text


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    path, cmd, args = argv[0], argv[1], argv[2:]
    text = open(path).read()
    if cmd == "get":
        for a in args:
            print(f"{a} = {read_value(text, a)}")
        return 0
    if cmd == "set":
        pairs = []
        group = "time_control"
        for a in args:
            if a.startswith("--group="):
                group = a.split("=", 1)[1]
                continue
            k, v = a.split("=", 1)
            pairs.append((k.strip(), v.strip()))
        text = set_values(text, pairs, group)
        with open(path, "w") as f:
            f.write(text)
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
