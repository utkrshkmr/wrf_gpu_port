#!/usr/bin/env python3
"""Check the infrastructure tier of the port's files (AGENTS.md rule 3;
WORKFLOW.md "Tool problems").  LOCKED.

port/agent/infra.md5 holds the checksums of the build/run/setup scripts as the
project owner left them.  The coding agent may fix these scripts, but every
file whose content differs from infra.md5 must be named in a row of the table
in port/agent/TOOL_FIXES.md, and that row must fill every column.

  check_tool_fixes.py [--repo DIR]   exit status 0 if every changed infrastructure file is logged
"""
import hashlib
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
AGENT = os.path.join(REPO, "port", "agent")
COLS = ["date", "files", "problem", "fix", "unchanged"]


def rows(path):
    """Table rows of TOOL_FIXES.md below its header row: list of cell lists."""
    out = []
    if not os.path.exists(path):
        return out
    header = False
    for l in open(path, errors="replace"):
        l = l.rstrip("\n")
        if not l.startswith("|"):
            continue
        cells = [c.strip() for c in l.strip().strip("|").split("|")]
        if not header:
            header = cells and cells[0].lower() == "date"
            continue
        if all(re.fullmatch(r":?-+:?", c) for c in cells if c):
            continue
        out.append(cells)
    return out


def main():
    global REPO, AGENT
    if sys.argv[1:2] == ["--repo"]:
        REPO = os.path.abspath(sys.argv[2])
        AGENT = os.path.join(REPO, "port", "agent")
    infra = os.path.join(AGENT, "infra.md5")
    if not os.path.exists(infra):
        print("check_tool_fixes: FAIL: port/agent/infra.md5 missing")
        return 1
    changed = []
    for l in open(infra):
        l = l.strip()
        if not l:
            continue
        h, rel = l.split(None, 1)
        f = os.path.normpath(os.path.join(AGENT, rel))
        cur = hashlib.md5(open(f, "rb").read()).hexdigest() if os.path.exists(f) else "missing"
        if cur != h:
            changed.append(os.path.relpath(f, REPO))
    table = rows(os.path.join(AGENT, "TOOL_FIXES.md"))
    errs = []
    for i, r in enumerate(table, 1):
        if len(r) < len(COLS) or any(not c for c in r[:len(COLS)]):
            errs.append(f"TOOL_FIXES.md row {i}: every column ({', '.join(COLS)}) must be filled")
    logged = " ".join(r[1] for r in table if len(r) > 1)
    for f in changed:
        if f not in logged and os.path.basename(f) not in re.findall(r"[\w./-]+", logged):
            errs.append(f"{f} differs from infra.md5 but no row of port/agent/TOOL_FIXES.md names it")
    for e in errs:
        print("  " + e)
    print(f"check_tool_fixes: {len(changed)} infrastructure file(s) changed, {len(table)} logged fix(es): "
          f"{'PASS' if not errs else 'FAIL'}")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
