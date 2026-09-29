#!/usr/bin/env python3
"""Experiment E1 (plan.md P0.14): change one value of a WRF input file by 1 ulp.

Copies the input file and replaces one value of one variable by the next
representable float (towards +inf by default).  Default: T at k = 10 (0-based
bottom_top index 9) at the point of d02 nearest the ignition point.

Usage:
  perturb_input.py wrfinput_d02 wrfinput_d02.e1 [--var T] [--k 9]
                   [--lat 34.18604 --lon -118.09325] [--i I --j J] [--down]
"""

import argparse
import shutil
import sys

import numpy as np
from netCDF4 import Dataset


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--var", default="T")
    ap.add_argument("--k", type=int, default=9, help="0-based vertical index")
    ap.add_argument("--lat", type=float, default=34.18604)
    ap.add_argument("--lon", type=float, default=-118.09325)
    ap.add_argument("--i", type=int, help="0-based west_east index (overrides --lat/--lon)")
    ap.add_argument("--j", type=int, help="0-based south_north index")
    ap.add_argument("--down", action="store_true", help="perturb towards -inf")
    args = ap.parse_args()

    shutil.copyfile(args.src, args.dst)
    d = Dataset(args.dst, "r+")
    if args.i is None or args.j is None:
        lat = d.variables["XLAT"][0]
        lon = d.variables["XLONG"][0]
        dist = (lat - args.lat) ** 2 + ((lon - args.lon) * np.cos(np.radians(args.lat))) ** 2
        j, i = np.unravel_index(np.argmin(dist), dist.shape)
    else:
        i, j = args.i, args.j
    v = d.variables[args.var]
    dims = v.dimensions
    idx = []
    for dim in dims:
        if dim == "Time":
            idx.append(0)
        elif dim.startswith("bottom_top") or dim.startswith("soil"):
            idx.append(args.k)
        elif dim.startswith("south_north"):
            idx.append(j)
        elif dim.startswith("west_east"):
            idx.append(i)
        else:
            idx.append(0)
    idx = tuple(idx)
    old = np.float32(v[idx])
    new = np.nextafter(old, np.float32(-np.inf if args.down else np.inf))
    v[idx] = new
    d.close()
    print(f"{args.var}{list(idx)}: {old!r} (0x{old.view(np.uint32):08x}) -> {new!r} (0x{new.view(np.uint32):08x})")
    print(f"wrote {args.dst}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
