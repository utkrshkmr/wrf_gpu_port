#!/usr/bin/env python3
"""Compare the fire spread of two WRF-Fire runs frame by frame (plan.md P0.12).

For every history frame present in both runs (matched by file name and
XTIME):
  burned cells       LFN <= 0 (the level-set sign; TIGN_G < frame time if LFN
                     is missing).  Unburned cells hold TIGN_G = current time.
  differing cells    cells burned in exactly one run
  symmetric area     differing cells x fire-cell area (DX*DY/(sr_x*sr_y))
  |dTIGN_G|          max and mean over cells burned in both runs
  FIRE_AREA, FUEL_FRAC, FGRNHFX: max |difference|

Writes a CSV (--csv) and, if matplotlib is installed and --png is given, a PNG
per frame with differing cells.  Exit status 1 if any frame has differing
cells (the acceptance criterion is 0 at every frame).

Usage:
  compare_fire.py runA runB [--pattern 'wrfout_d02_*'] [--csv out.csv] [--png dir]
"""

import argparse
import csv
import fnmatch
import os
import sys

import numpy as np
from netCDF4 import Dataset


def frames(path):
    d = Dataset(path)
    xt = d.variables["XTIME"][:] if "XTIME" in d.variables else np.arange(d.dimensions["Time"].size)
    return d, [float(x) for x in np.atleast_1d(xt)]


def get(d, name, t):
    if name not in d.variables:
        return None
    v = d.variables[name][t]
    return np.asarray(v.filled(np.nan) if np.ma.isMaskedArray(v) else v)


def burned(d, t, tsec):
    lfn = get(d, "LFN", t)
    if lfn is not None:
        return lfn <= 0.0
    tign = get(d, "TIGN_G", t)
    return tign < tsec


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("--pattern", default="wrfout_d02_*")
    ap.add_argument("--csv")
    ap.add_argument("--png")
    args = ap.parse_args()

    files = sorted(f for f in os.listdir(args.a) if fnmatch.fnmatch(f, args.pattern))
    if not files:
        print(f"no files matching {args.pattern} in {args.a}")
        return 2
    rows = []
    worst = 0
    for f in files:
        pb = os.path.join(args.b, f)
        if not os.path.exists(pb):
            print(f"{f}: missing in {args.b}")
            worst = max(worst, 1)
            continue
        da, xa = frames(os.path.join(args.a, f))
        db, xb = frames(pb)
        if "TIGN_G" not in da.variables:
            print(f"{f}: no fire variables")
            continue
        dx = float(getattr(da, "DX", 1.0))
        dy = float(getattr(da, "DY", 1.0))
        srx = da.dimensions["west_east_subgrid"].size // da.dimensions["west_east_stag"].size \
            if "west_east_subgrid" in da.dimensions else 1
        sry = da.dimensions["south_north_subgrid"].size // da.dimensions["south_north_stag"].size \
            if "south_north_subgrid" in da.dimensions else 1
        cell = dx*dy/(srx*sry)
        for ta, xt in enumerate(xa):
            if xt not in xb:
                continue
            tb = xb.index(xt)
            tsec = xt*60.0
            ba = burned(da, ta, tsec)
            bb = burned(db, tb, tsec)
            dmask = ba != bb
            both = ba & bb
            ga = get(da, "TIGN_G", ta)
            gb = get(db, "TIGN_G", tb)
            dt = np.abs(ga[both].astype(np.float64) - gb[both].astype(np.float64)) if both.any() else np.zeros(1)
            row = {
                "file": f, "xtime_min": xt,
                "burned_a": int(ba.sum()), "burned_b": int(bb.sum()),
                "differing_cells": int(dmask.sum()),
                "sym_diff_area_m2": float(dmask.sum()*cell),
                "burned_area_a_m2": float(ba.sum()*cell), "burned_area_b_m2": float(bb.sum()*cell),
                "max_abs_dtign_s": float(dt.max()), "mean_abs_dtign_s": float(dt.mean()),
            }
            for v in ("FIRE_AREA", "FUEL_FRAC", "FGRNHFX", "ROS"):
                va, vb = get(da, v, ta), get(db, v, tb)
                row[f"max_abs_d{v.lower()}"] = float(np.nanmax(np.abs(va.astype(np.float64) - vb.astype(np.float64)))) \
                    if va is not None and vb is not None else float("nan")
            bits_equal = all(
                (get(da, v, ta) is None) or np.array_equal(get(da, v, ta).view(np.uint32), get(db, v, tb).view(np.uint32))
                for v in ("TIGN_G", "FIRE_AREA", "FUEL_FRAC", "LFN", "FGRNHFX", "FGRNQFX", "ROS"))
            row["fire_arrays_bitwise_equal"] = bits_equal
            rows.append(row)
            if row["differing_cells"] > 0:
                worst = max(worst, 1)
            print(f"{f} t={xt:8.2f} min  burned {row['burned_a']:9d} {row['burned_b']:9d}  "
                  f"differing {row['differing_cells']:7d} ({row['sym_diff_area_m2']:.0f} m2)  "
                  f"max|dtign| {row['max_abs_dtign_s']:.3g} s  bitwise {bits_equal}")
            if args.png and row["differing_cells"] > 0:
                try:
                    import matplotlib
                    matplotlib.use("Agg")
                    import matplotlib.pyplot as plt
                    os.makedirs(args.png, exist_ok=True)
                    img = np.zeros(ba.shape, np.int8)
                    img[ba & ~bb] = 1
                    img[bb & ~ba] = -1
                    plt.figure(figsize=(8, 8))
                    plt.imshow(img, origin="lower", cmap="bwr", vmin=-1, vmax=1, interpolation="nearest")
                    plt.title(f"{f} t={xt} min: red burned only in A, blue only in B")
                    plt.savefig(os.path.join(args.png, f"{f}_t{xt:08.2f}.png"), dpi=100)
                    plt.close()
                except ImportError:
                    pass
        da.close()
        db.close()
    if args.csv and rows:
        with open(args.csv, "w", newline="") as fh:
            w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
            w.writeheader()
            w.writerows(rows)
    nbad = sum(1 for r in rows if r["differing_cells"] > 0)
    print(f"{len(rows)} frames compared, {nbad} with differing burned cells")
    print("RESULT:", "IDENTICAL FIRE SPREAD" if nbad == 0 and rows else "DIFFERENT")
    return worst


if __name__ == "__main__":
    sys.exit(main())
