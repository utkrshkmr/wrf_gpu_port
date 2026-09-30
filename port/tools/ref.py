#!/usr/bin/env python3
"""Show the CPU code of a kernel, route or routine, in pages that fit the
context (port/agent/WORKFLOW.md section 11).  Use it instead of opening
KERNEL_REFS.md, kernels.csv, ROUTES.md or a whole WRF file.

  ref.py <kernel id | route | routine> [--part N] [--lines L] [--context C] [--info]

  kernel id  e.g. K-ADVU-Y1 (also a group key such as K-PREP-3a..d): the kernels.csv row
             and the CPU lines the kernel replaces (plan.md's refs, +-C lines)
  route      e.g. advect_u: the route's routines (definition ranges), call sites and
             kernel rows; the code of its first routine
  routine    e.g. calc_ww_cp (any SUBROUTINE of the base commit): its definition
  --part N   page N of the code (default 1); every page ends with the command for the next
  --lines L  lines per page (default 250)
  --info     only the row(s), no code

All line numbers are those of the CPU-view base commit (port/agent/cpu_view_base),
the code you port.  Map a line to your working tree: python3 port/tools/locate.py.
"""
import argparse
import csv
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PORT = os.path.dirname(HERE)
REPO = os.path.dirname(PORT)
AG = os.path.join(PORT, "agent")


def base_rev():
    for line in open(os.path.join(AG, "cpu_view_base")):
        line = line.split("#")[0].strip()
        if line:
            return line
    raise SystemExit("no base in port/agent/cpu_view_base")


def show(rev, path):
    r = subprocess.run(["git", "-C", REPO, "show", f"{rev}:WRF/{path}"], capture_output=True, text=True,
                       errors="replace")
    if r.returncode != 0:
        raise SystemExit(f"ref: cannot read WRF/{path} at {rev[:12]}")
    return r.stdout.split("\n")


def parse_refs(text):
    """'dyn_em/x.F:12-30; dyn_em/x.F:40' -> [(path, a, b)]"""
    out = []
    for part in re.split(r"[;<]|br>", text):
        m = re.search(r"(?:WRF/)?([\w/]+\.(?:F|F90|f90|inc|h)):(\d+)(?:-(\d+))?", part)
        if m:
            a = int(m.group(2))
            out.append((m.group(1), a, int(m.group(3) or a)))
    return out


def routes_rows():
    rows = {}
    p = os.path.join(AG, "ROUTES.md")
    for l in open(p, errors="replace"):
        if l.startswith("| `"):
            cells = [c.strip() for c in l.strip().strip("|").split("|")]
            rows[cells[0].strip("`")] = cells
    return rows


def routine_def(rev, name):
    """find SUBROUTINE name in the base commit: (path, a, b)"""
    r = subprocess.run(["git", "-C", REPO, "grep", "-n", "-i", "-E",
                        r"^\s*(recursive\s+|pure\s+|elemental\s+)*subroutine\s+" + name + r"\b", rev, "--",
                        "WRF/dyn_em", "WRF/phys", "WRF/share", "WRF/frame", "WRF/main"],
                       capture_output=True, text=True)
    hits = [l for l in r.stdout.split("\n") if l.strip()]
    if not hits:
        return None
    _, path, line = hits[0].split(":", 3)[:3]
    path = path[4:] if path.startswith("WRF/") else path
    a = int(line)
    lines = show(rev, path)
    b = a
    for i in range(a, len(lines)):
        if re.match(r"^\s*end\s*subroutine\b", lines[i], re.I):
            b = i + 1
            break
    return path, a, b


def page(rev, spans, part, per, ctx, label, again):
    """print the union of spans (path, a, b), paged"""
    merged = []
    for path, a, b in sorted(spans, key=lambda x: (x[0], x[1])):
        if merged and merged[-1][0] == path and a - ctx <= merged[-1][2] + ctx + 1:
            merged[-1] = (path, merged[-1][1], max(b, merged[-1][2]))
        else:
            merged.append((path, a, b))
    out = []
    for path, a, b in merged:
        lines = show(rev, path)
        a0, b0 = max(1, a - ctx), min(len(lines), b + ctx)
        out.append(f"--- WRF/{path}:{a0}-{b0} (base {rev[:12]})")
        out += [f"{n:6d}  {lines[n - 1]}" for n in range(a0, b0 + 1)]
    npages = max(1, (len(out) + per - 1) // per)
    part = min(max(1, part), npages)
    print(f"=== {label}: part {part}/{npages} ({len(out)} lines)")
    print("\n".join(out[(part - 1) * per:part * per]))
    if part < npages:
        print(f"=== next: python3 port/tools/ref.py {again} --part {part + 1}")
    else:
        print("=== end")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("what")
    ap.add_argument("--part", type=int, default=1)
    ap.add_argument("--lines", type=int, default=250)
    ap.add_argument("--context", type=int, default=3)
    ap.add_argument("--info", action="store_true")
    a = ap.parse_args()
    rev = base_rev()
    rows = list(csv.DictReader(open(os.path.join(AG, "kernels.csv"))))
    w = a.what
    kid = [r for r in rows if r["key"] == w or re.search(r"(^|[ ,/])" + re.escape(w) + r"($|[ ,/.])", r["kernels"])]
    routes = routes_rows()
    again = w + (f" --lines {a.lines}" if a.lines != 250 else "")
    if kid:
        for r in kid:
            print(f"{r['key']}: kernels {r['kernels']} | template {r['template']} | route {r['route']} | "
                  f"status {r['status']}{(' | ' + r['notes']) if r['notes'] else ''}")
            print(f"  routine: {r['routines']}")
            print(f"  CPU lines (base): {r['base_refs']}")
        if a.info:
            return 0
        spans = []
        for r in kid:
            for s in parse_refs(r["base_refs"]):
                if s not in spans:
                    spans.append(s)
        if all(x[1] == x[2] for x in spans):     # only routine start lines: show the routines
            spans = []
            for r in kid:
                for s in parse_refs(r["routines"]):
                    if s not in spans:
                        spans.append(s)
        page(rev, spans, a.part, a.lines, a.context, w, again)
        return 0
    if w in routes:
        c = routes[w]
        print(f"route {w} ({c[1]})")
        print(f"  routines (base): {c[2].replace('<br>', '; ')}")
        print(f"  call sites (base): {c[3].replace('<br>', '; ')}")
        print(f"  kernel rows: {c[4] if len(c) > 4 else '-'}   (ref.py <kernel id> shows each kernel's lines)")
        if a.info:
            return 0
        spans = parse_refs(c[2])[:1]
        page(rev, spans, a.part, a.lines, 0, w, again)
        return 0
    d = routine_def(rev, w)
    if d is None:
        print(f"ref: {w} is no kernel id, route or SUBROUTINE of the base commit")
        return 1
    print(f"routine {w}: WRF/{d[0]}:{d[1]}-{d[2]} ({d[2] - d[1] + 1} lines, base {rev[:12]})")
    if not a.info:
        page(rev, [d], a.part, a.lines, 0, w, again)
    return 0


if __name__ == "__main__":
    sys.exit(main())
