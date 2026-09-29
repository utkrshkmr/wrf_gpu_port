#!/usr/bin/env python3
"""Compare WRF netCDF files field by field (plan.md P0.12).

For every variable present in both files: number of differing values (bit
patterns; NaNs with identical bits count as equal), maximum absolute and
relative difference, and the number of agreeing significant digits.

Usage:
  compare_fields.py A.nc B.nc [--bitwise] [--vars U V T ...] [--all]
  compare_fields.py --dirs runA runB [--pattern 'wrfout_d02_*'] [--bitwise]

--bitwise   exit status 1 if any compared value differs (acceptance mode)
--all       also list identical variables
--dirs      compare every file matching --pattern present in both directories
"""

import argparse
import fnmatch
import math
import os
import sys

import numpy as np
from netCDF4 import Dataset

SKIP = {"Times"}


def bits(a):
    a = np.ascontiguousarray(a)
    if a.dtype.kind == "f":
        return a.view(np.uint32 if a.dtype.itemsize == 4 else np.uint64)
    return a


def compare_var(va, vb):
    a = va[...]
    b = vb[...]
    a = np.asarray(a.filled(np.nan) if np.ma.isMaskedArray(a) else a)
    b = np.asarray(b.filled(np.nan) if np.ma.isMaskedArray(b) else b)
    if a.shape != b.shape:
        return {"shape": f"{a.shape} vs {b.shape}"}
    if a.dtype.kind in "SU" or a.dtype.kind == "O":
        nd = int(np.sum(a != b))
        return {"ndiff": nd, "n": a.size}
    diff = bits(a) != bits(b)
    nd = int(diff.sum())
    res = {"ndiff": nd, "n": a.size}
    if nd and a.dtype.kind == "f":
        da = a[diff].astype(np.float64)
        db = b[diff].astype(np.float64)
        finite = np.isfinite(da) & np.isfinite(db)
        if finite.any():
            ad = np.abs(da[finite] - db[finite])
            scale = np.maximum(np.abs(da[finite]), np.abs(db[finite]))
            rel = np.where(scale > 0, ad / np.where(scale > 0, scale, 1), 0.0)
            res["maxabs"] = float(ad.max())
            res["maxrel"] = float(rel.max())
            res["digits"] = (-math.log10(res["maxrel"])) if res["maxrel"] > 0 else float("inf")
        res["nonfinite_diff"] = int((~finite).sum())
    elif nd:
        res["maxabs"] = float(np.abs(a[diff].astype(np.float64) - b[diff].astype(np.float64)).max())
    return res


def compare_files(fa, fb, varlist=None, show_all=False):
    da = Dataset(fa)
    db = Dataset(fb)
    names = varlist or [v for v in da.variables if v in db.variables and v not in SKIP]
    only_a = sorted(set(da.variables) - set(db.variables))
    only_b = sorted(set(db.variables) - set(da.variables))
    ndiff_vars = 0
    rows = []
    for v in names:
        if v not in da.variables or v not in db.variables:
            rows.append((v, "missing in one file"))
            ndiff_vars += 1
            continue
        r = compare_var(da.variables[v], db.variables[v])
        if "shape" in r:
            rows.append((v, "shape " + r["shape"]))
            ndiff_vars += 1
        elif r["ndiff"]:
            ndiff_vars += 1
            s = f"{r['ndiff']} of {r['n']} differ"
            if "maxabs" in r:
                s += f"  max|d|={r['maxabs']:.3e}"
            if "maxrel" in r:
                s += f"  max rel={r['maxrel']:.3e}  digits={r['digits']:.1f}"
            if r.get("nonfinite_diff"):
                s += f"  non-finite differing={r['nonfinite_diff']}"
            rows.append((v, s))
        elif show_all:
            rows.append((v, "identical"))
    print(f"== {fa}\n   {fb}")
    for v, s in rows:
        print(f"   {v:20s} {s}")
    if only_a or only_b:
        print(f"   variables only in A: {len(only_a)}  only in B: {len(only_b)}")
    print(f"   {len(names)} variables compared, {ndiff_vars} differ")
    da.close()
    db.close()
    return ndiff_vars == 0 and not only_a and not only_b


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("--dirs", action="store_true")
    ap.add_argument("--pattern", default="wrf*_d0*")
    ap.add_argument("--vars", nargs="*")
    ap.add_argument("--bitwise", action="store_true")
    ap.add_argument("--all", action="store_true")
    args = ap.parse_args()
    ok = True
    if args.dirs:
        fa = sorted(f for f in os.listdir(args.a) if fnmatch.fnmatch(f, args.pattern))
        if not fa:
            print(f"no files matching {args.pattern} in {args.a}")
            return 2
        for f in fa:
            pb = os.path.join(args.b, f)
            if not os.path.exists(pb):
                print(f"== {f}: missing in {args.b}")
                ok = False
                continue
            ok = compare_files(os.path.join(args.a, f), pb, args.vars, args.all) and ok
    else:
        ok = compare_files(args.a, args.b, args.vars, args.all)
    print("RESULT:", "IDENTICAL" if ok else "DIFFERENT")
    if args.bitwise and not ok:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
