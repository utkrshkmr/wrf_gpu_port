#!/usr/bin/env python3
"""Compare two bit-hash traces (plan.md P0.7).

Each trace line is  "itimestep rk_stage tag field hsum hpos"  as written by
WRF/frame/module_bittrace.F to bittrace.d0N.txt.  Records are matched by
(itimestep, rk_stage, tag, field, occurrence); the report gives the first
differing record in run order, the first difference of every field, and a
summary.  Exit status 0 only if both traces cover the same records with
identical hashes.

Usage:
  bittrace_diff.py A/bittrace.d02.txt B/bittrace.d02.txt
  bittrace_diff.py --dir A B          (compare every bittrace.d0N.txt present in A)
"""

import argparse
import collections
import glob
import os
import sys


def load(path):
    recs = collections.OrderedDict()
    seen = collections.Counter()
    with open(path) as f:
        for n, line in enumerate(f, 1):
            p = line.split()
            if len(p) != 6:
                continue
            step, rk, tag, field, hs, hp = p
            key0 = (int(step), int(rk), tag, field)
            occ = seen[key0]
            seen[key0] += 1
            recs[key0 + (occ,)] = (hs, hp, n)
    return recs


def compare(a_path, b_path, label, max_fields=40):
    a = load(a_path)
    b = load(b_path)
    common = [k for k in a if k in b]
    only_a = [k for k in a if k not in b]
    only_b = [k for k in b if k not in a]
    diff = [k for k in common if a[k][:2] != b[k][:2]]
    steps = sorted({k[0] for k in common})
    print(f"== {label}")
    print(f"   {a_path}: {len(a)} records;  {b_path}: {len(b)} records")
    if steps:
        print(f"   common records: {len(common)} over itimestep {steps[0]}..{steps[-1]}")
    if diff:
        k = diff[0]
        print(f"   FIRST DIFFERENCE: itimestep {k[0]} rk_stage {k[1]} tag {k[2]} field {k[3]}"
              f"  (line {a[k][2]} vs {b[k][2]})")
        first_by_field = collections.OrderedDict()
        for k in diff:
            first_by_field.setdefault(k[3], k)
        print(f"   {len(diff)} differing records; first difference per field:")
        for i, (fld, k) in enumerate(first_by_field.items()):
            if i >= max_fields:
                print("   ...")
                break
            print(f"     {fld:14s} itimestep {k[0]:8d} rk {k[1]} tag {k[2]}")
    else:
        print("   no differing records")
    if only_a or only_b:
        print(f"   records only in A: {len(only_a)}, only in B: {len(only_b)}")
        for k in (only_a[:3] + only_b[:3]):
            print(f"     e.g. itimestep {k[0]} rk {k[1]} tag {k[2]} field {k[3]}")
    ok = not diff and not only_a and not only_b and len(common) > 0
    print(f"   RESULT: {'IDENTICAL' if ok else 'DIFFERENT'}")
    return ok


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("--dir", action="store_true", help="a and b are run directories")
    args = ap.parse_args()
    if args.dir:
        files = sorted(glob.glob(os.path.join(args.a, "bittrace.d*.txt")))
        if not files:
            print(f"no bittrace.d*.txt in {args.a}")
            return 2
        ok = True
        for fa in files:
            fb = os.path.join(args.b, os.path.basename(fa))
            if not os.path.exists(fb):
                print(f"== {os.path.basename(fa)}: missing in {args.b}")
                ok = False
                continue
            ok = compare(fa, fb, os.path.basename(fa)) and ok
        return 0 if ok else 1
    return 0 if compare(args.a, args.b, os.path.basename(args.a)) else 1


if __name__ == "__main__":
    sys.exit(main())
