#!/usr/bin/env python3
"""Switch single GPU kernels to the host, temporarily, to confirm which kernel
of a routine causes a mismatch (port/agent/DEBUGGING.md; routes switch whole
routines, this switches one loop nest).

  kernel_off.py --list <file> [routine]          number, line, kernel ID and route of every kernel
  kernel_off.py <file> <kernel> [<kernel> ...]   run these kernels on the host
  kernel_off.py --revert <file> [<file> ...]     undo every kernel_off edit in the files

<kernel> is a kernel ID written in a comment within the 3 lines above the
directive (e.g. K-ADVU-Y1; CODING_STANDARD.md asks for one), or
<routine>:<n>, the n-th kernel of the routine as --list numbers them.

The edit, for each kernel:
  - before the directive: if the data are on the device (.NOT. gpu_world_host,
    i.e. the routine's island moved them there), copy every array of the
    kernel's shared(...) clause to the host;
  - the kernel's if(target: ...) becomes if(target: .FALSE.): it runs on the
    host, over host data, with the same code;
  - after the loop nest: copy the same arrays back to the device.
So the rest of the routine keeps running on the device and the results are
those of the host execution of this one kernel.  Then rebuild (gpu-repro or
gpu-debug, --worktree) and rerun the failing comparison: if it passes now
(or the first difference moves later), this kernel is wrong.

Every inserted or changed line is marked KOFF-TEMP; static.sh fails while
any is left in WRF/, so the edit cannot be committed.  --revert restores the
original lines exactly.
"""
import os
import re
import sys

KERNEL = re.compile(r"^\s*!\$omp\s+target\s+(teams|parallel|loop|simd)\b", re.I)
CONT = re.compile(r"^\s*!\$omp&", re.I)
SUB = re.compile(r"^\s*(?:(?:recursive|pure|elemental)\s+)*subroutine\s+(\w+)", re.I)
ENDSUB = re.compile(r"^\s*end\s*subroutine\b", re.I)
DO = re.compile(r"^\s*(?:\w+\s*:\s*)?do\b(?!\s*=)", re.I)
ENDDO = re.compile(r"^\s*end\s*do\b", re.I)
KID = re.compile(r"\bK-[A-Z0-9]+(?:-[A-Z0-9]+)*\b")
IFT = re.compile(r"if\s*\(\s*target\s*:", re.I)
MARK = "KOFF-TEMP"


def is_comment(l):
    s = l.lstrip()
    return s.startswith("!") and not s.lower().startswith("!$omp")


def kernels(lines):
    """[(routine, n, d0, d1, end, kid, route)] with 0-based line indices."""
    out = []
    routine, count = None, 0
    i = 0
    while i < len(lines):
        l = lines[i]
        m = SUB.match(l)
        if m and not is_comment(l):
            routine, count = m.group(1).lower(), 0
        if KERNEL.match(l):
            d0 = i
            d1 = i
            while d1 + 1 < len(lines) and CONT.match(lines[d1 + 1]):
                d1 += 1
            text = " ".join(x.strip() for x in lines[d0:d1 + 1])
            end = loop_end(lines, d1, text)
            kid = None
            for k in range(max(0, d0 - 3), d0):
                mk = KID.search(lines[k])
                if mk and is_comment(lines[k]):
                    kid = mk.group(0)
            mr = re.search(r"gpu_on\s*\(\s*(R_\w+)\s*\)", text, re.I)
            count += 1
            out.append((routine, count, d0, d1, end, kid, mr.group(1) if mr else None))
            i = d1 + 1
            continue
        i += 1
    return out


def loop_end(lines, d1, text):
    """last line of the construct that starts after directive line d1"""
    j = d1 + 1
    if not re.search(r"\b(parallel\s+do|distribute|loop|simd|\bdo\b)", text, re.I):
        # block construct: up to !$omp end target
        while j < len(lines) and not re.match(r"^\s*!\$omp\s+end\s+target\b", lines[j], re.I):
            j += 1
        return j
    depth = 0
    while j < len(lines):
        l = lines[j]
        if not (is_comment(l) or l.lstrip().startswith("#") or not l.strip()):
            if DO.match(l):
                depth += 1
            elif ENDDO.match(l):
                depth -= 1
                if depth == 0:
                    k = j + 1
                    while k < len(lines) and not lines[k].strip():
                        k += 1
                    if k < len(lines) and re.match(r"^\s*!\$omp\s+end\s+target", lines[k], re.I):
                        return k
                    return j
        j += 1
    raise SystemExit("kernel_off: could not find the end of the loop nest after line %d" % (d1 + 1))


def shared_arrays(text):
    names = []
    for m in re.finditer(r"\bshared\s*\(([^)]*)\)", text, re.I):
        names += [x.strip() for x in m.group(1).split(",") if x.strip()]
    return names


def block(direction, arrays, indent):
    return [f"! {MARK}-BEGIN kernel_off.py: copy for the host run of the next/previous kernel",
            "#ifdef WRF_GPU",
            f"{indent}IF (.NOT. gpu_world_host) THEN",
            f"!$omp target update {direction}({', '.join(arrays)})",
            f"{indent}END IF",
            "#endif",
            f"! {MARK}-END"]


def switch_off(path, wanted):
    lines = open(path).read().split("\n")
    if any(MARK in l for l in lines):
        raise SystemExit(f"kernel_off: {path} already has {MARK} edits; --revert first")
    ks = kernels(lines)
    chosen = []
    for w in wanted:
        if ":" in w:
            r, n = w.split(":", 1)
            hit = [k for k in ks if k[0] == r.lower() and k[1] == int(n)]
        else:
            hit = [k for k in ks if k[5] == w]
        if len(hit) != 1:
            raise SystemExit(f"kernel_off: '{w}' matches {len(hit)} kernels in {path} (see --list)")
        chosen.append(hit[0])
    if "gpu_world_host" not in "\n".join(lines).lower():
        print(f"warning: {path} does not mention gpu_world_host (USE module_gpu_route, ONLY : ..., gpu_world_host)")
    # apply from the bottom up so indices stay valid
    for (routine, n, d0, d1, end, kid, route) in sorted(chosen, key=lambda k: -k[2]):
        text = " ".join(x.strip() for x in lines[d0:d1 + 1])
        arrays = shared_arrays(text)
        if not arrays:
            print(f"warning: {routine}:{n} has no shared(...) clause: nothing to copy")
        k = next((x for x in range(d0, d1 + 1) if IFT.search(lines[x])), None)
        if k is None:
            raise SystemExit(f"kernel_off: {routine}:{n} (line {d0 + 1}) has no if(target: ...) clause")
        orig = lines[k]
        new = re.sub(r"(if\s*\(\s*target\s*:)\s*(?:[^()]|\([^()]*\))*\)", r"\1 .FALSE.)", orig, count=1,
                     flags=re.I)
        after = block("to", arrays, "      ") if arrays else []
        lines[end + 1:end + 1] = after
        lines[k] = new
        before = (block("from", arrays, "      ") if arrays else []) + \
                 [f"! {MARK}-ORIG +{k - d0} {orig}"]
        lines[d0:d0] = before
        print(f"{path}: {routine}:{n} {kid or ''} (line {d0 + 1}) now runs on the host; arrays: {', '.join(arrays)}")
    open(path, "w").write("\n".join(lines))


def revert(path):
    lines = open(path).read().split("\n")
    out = []
    i = 0
    n = 0
    pending = None
    while i < len(lines):
        l = lines[i]
        if l.startswith(f"! {MARK}-BEGIN"):
            while i < len(lines) and not lines[i].startswith(f"! {MARK}-END"):
                i += 1
            i += 1
            n += 1
            continue
        m = re.match(rf"^! {MARK}-ORIG \+(\d+) (.*)$", l)
        if m:
            off, orig = int(m.group(1)), m.group(2)
            j = i + 1 + off
            lines[j] = orig
            i += 1
            n += 1
            continue
        out.append(l)
        i += 1
    open(path, "w").write("\n".join(out))
    left = sum(MARK in l for l in out)
    print(f"{path}: {n} kernel_off edit(s) reverted" + (f"; {left} {MARK} lines left" if left else ""))
    return left == 0


def main():
    a = sys.argv[1:]
    if not a or a[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    if a[0] == "--list":
        lines = open(a[1]).read().split("\n")
        for (routine, n, d0, d1, end, kid, route) in kernels(lines):
            if len(a) > 2 and routine != a[2].lower():
                continue
            print(f"{routine}:{n:<3d} line {d0 + 1:6d}-{end + 1:<6d} {kid or '-':14s} {route or '-'}")
        return 0
    if a[0] == "--revert":
        ok = all([revert(p) for p in a[1:]])
        return 0 if ok else 1
    switch_off(a[0], a[1:])
    return 0


if __name__ == "__main__":
    sys.exit(main())
