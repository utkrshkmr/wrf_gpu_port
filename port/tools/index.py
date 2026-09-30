#!/usr/bin/env python3
"""Map of a WRF source file: its modules, subroutines and functions with line
ranges and sizes, so that you never need to open a large file whole
(port/agent/WORKFLOW.md section 11).  Read a routine with ref.py <routine> or
sed -n 'a,bp'.

  index.py <WRF file> [--base] [--grep TEXT]
     --base   the CPU-view base commit version (default: working tree)
     --grep   only entries whose name contains TEXT
"""
import argparse
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
START = re.compile(r"^\s*(?:(?:recursive|pure|elemental|impure)\s+)*(?:(?:real|integer|logical|double\s+precision)"
                   r"(?:\s*\([^)]*\))?\s+)?(module|subroutine|function|program)\s+(\w+)", re.I)
END = re.compile(r"^\s*end\s*(module|subroutine|function|program)\b", re.I)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("file")
    ap.add_argument("--base", action="store_true")
    ap.add_argument("--grep")
    a = ap.parse_args()
    rel = os.path.relpath(os.path.abspath(a.file), REPO) if os.path.exists(a.file) else a.file
    if a.base:
        base = [l.split("#")[0].strip() for l in open(os.path.join(REPO, "port", "agent", "cpu_view_base"))]
        base = next(b for b in base if b)
        lines = subprocess.run(["git", "-C", REPO, "show", f"{base}:{rel}"], capture_output=True, text=True,
                               errors="replace").stdout.split("\n")
    else:
        lines = open(os.path.join(REPO, rel), errors="replace").read().split("\n")
    stack, out = [], []
    for n, l in enumerate(lines, 1):
        if l.lstrip().startswith("!"):
            continue
        m = START.match(l)
        if m and not re.match(r"^\s*module\s+procedure\b", l, re.I):
            stack.append((m.group(1).lower(), m.group(2), n))
            continue
        if END.match(l) and stack:
            kind, name, a0 = stack.pop()
            out.append((a0, n, kind, name, len(stack)))
    out.sort()
    print(f"{rel}: {len(lines)} lines{' (base)' if a.base else ''}")
    for a0, b0, kind, name, depth in out:
        if a.grep and a.grep.lower() not in name.lower():
            continue
        print(f"  {'  ' * depth}{kind:10s} {name:36s} {a0:6d}-{b0:<6d} {b0 - a0 + 1:6d} lines")
    return 0


if __name__ == "__main__":
    sys.exit(main())
