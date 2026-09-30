#!/usr/bin/env python3
"""Check that the 'original' code copied into the standalone tests is really
the WRF source (so a test cannot be made to pass by editing the reference).

A test marks a copied block with
    ! BEGIN VERBATIM WRF/<path> [@<git revision>]
    ...
    ! END VERBATIM
The block's statements (comments, blank lines, preprocessor lines and
directive lines such as '!$omp declare target' ignored; case and blanks
normalized) must appear as one contiguous run of statements in <path> at the
revision (default: the CPU-view base commit in port/agent/cpu_view_base).

Usage: check_verbatim.py [files...]   (default: every *.F90/*.F under port/tests)
Exit status 0 if every block matches.
"""

import glob
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PORT = os.path.dirname(HERE)
REPO = os.path.dirname(PORT)
sys.path.insert(0, HERE)
import ftn  # noqa: E402

BEGIN = re.compile(r"^\s*!\s*BEGIN VERBATIM\s+(\S+)(?:\s+@(\S+))?", re.I)
END = re.compile(r"^\s*!\s*END VERBATIM", re.I)


def base_rev():
    f = os.path.join(PORT, "agent", "cpu_view_base")
    if os.path.exists(f):
        for line in open(f):
            s = line.split("#")[0].strip()
            if s:
                return s
    return "HEAD"


def stmts(lines):
    out = []
    for n, s, is_dir in ftn.statements(list(enumerate(lines, 1))):
        if is_dir or s.lstrip().startswith("#"):
            continue
        out.append((n, normalize(s)))
    return out


def normalize(s):
    q, r = None, []
    for c in s:
        if q:
            r.append(c)
            if c == q:
                q = None
        elif c in "'\"":
            q = c
            r.append(c)
        elif not c.isspace():
            r.append(c.lower())
    return "".join(r)


def find_run(needle, hay):
    n = len(needle)
    first = needle[0] if needle else None
    for i in range(len(hay) - n + 1):
        if hay[i] == first and hay[i:i + n] == needle:
            return i
    return -1


def check_file(path, cache):
    lines = open(path).read().split("\n")
    bad, nblk = 0, 0
    i = 0
    while i < len(lines):
        m = BEGIN.match(lines[i])
        if not m:
            i += 1
            continue
        j = i + 1
        while j < len(lines) and not END.match(lines[j]):
            j += 1
        if j == len(lines):
            print(f"FAIL  {path}:{i + 1}: BEGIN VERBATIM without END VERBATIM")
            return 1, nblk + 1
        src, rev = m.group(1), m.group(2) or base_rev()
        key = (src, rev)
        if key not in cache:
            r = subprocess.run(["git", "-C", REPO, "show", f"{rev}:{src}"], capture_output=True, text=True)
            cache[key] = [s for _, s in stmts(r.stdout.split("\n"))] if r.returncode == 0 else None
        hay = cache[key]
        blk = [s for _, s in stmts(lines[i + 1:j])]
        nblk += 1
        if hay is None:
            print(f"FAIL  {path}:{i + 1}: cannot read {src} at {rev}")
            bad += 1
        elif not blk:
            print(f"FAIL  {path}:{i + 1}: empty block")
            bad += 1
        elif find_run(blk, hay) < 0:
            # name the first statement that breaks the run
            k0 = find_run(blk[:1], hay)
            detail = "its first statement is not in the source"
            if k0 >= 0:
                for k in range(1, len(blk)):
                    if find_run(blk[:k + 1], hay) < 0:
                        detail = f"statement {k + 1} of the block differs from the source: {blk[k][:100]}"
                        break
            print(f"FAIL  {path}:{i + 1}: block is not a verbatim copy of {src}@{rev[:10]}: {detail}")
            bad += 1
        else:
            print(f"ok    {os.path.relpath(path, REPO)}:{i + 1}: {len(blk)} statements = {src}@{rev[:10]}")
        i = j + 1
    return bad, nblk


def main():
    files = sys.argv[1:] or sorted(glob.glob(os.path.join(PORT, "tests", "**", "*.F90"), recursive=True) +
                                   glob.glob(os.path.join(PORT, "tests", "**", "*.F"), recursive=True))
    cache, bad, n = {}, 0, 0
    for f in files:
        b, k = check_file(f, cache)
        bad += b
        n += k
    print(f"check_verbatim: {n} blocks, {'PASS' if not bad else 'FAIL (' + str(bad) + ')'}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
