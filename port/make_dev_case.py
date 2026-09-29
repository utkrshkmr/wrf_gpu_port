#!/usr/bin/env python3
"""Make the development case eaton_small (plan.md P0.16) from the full case.

Instead of rerunning WPS and real.exe, cut a window out of the full case's
wrfinput_d02: an N x N nest (default 181, i.e. 20 parent cells at ratio 9)
whose lower-left corner sits on a parent grid point, centred on the ignition
point.  Every column of the new nest is a column of the old nest, so its
initial state is exactly the old state there; d01 and wrfbdy_d01 are used
unchanged.  The fire mesh (NFUEL_CAT, ZSF, slopes, FXLAT/FXLONG, ...) is cut
with the same offset times the refinement ratio.

Outputs (in --out):
  wrfinput_d02     the cut nest input
  namelist.input   the case namelist with e_we, e_sn, i_parent_start and
                   j_parent_start of d02 changed
  README.md        where the window is and how it was made

Usage:
  make_dev_case.py --case-dir <full case run folder> --namelist <namelist.input>
                   --out <dir> [--n 181] [--lat 34.18604 --lon -118.09325]
"""

import argparse
import os
import re
import sys

import numpy as np
from netCDF4 import Dataset

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from nml import read_value, set_values  # noqa: E402


def col(value, k):
    """k-th (0-based) comma-separated entry of a namelist value."""
    parts = [p.strip() for p in value.split(",") if p.strip()]
    return parts[k]


def with_col(value, k, new):
    parts = [p.strip() for p in value.split(",") if p.strip()]
    parts[k] = str(new)
    return ", ".join(parts)


def cut(src, dst, i0, j0, n, sr_x, sr_y):
    """Copy src to dst keeping west_east[i0:i0+n-1] etc."""
    ds = Dataset(src)
    fmt = ds.data_model
    dd = Dataset(dst, "w", format=fmt)
    sl = {
        "west_east": slice(i0, i0 + n - 1), "west_east_stag": slice(i0, i0 + n),
        "south_north": slice(j0, j0 + n - 1), "south_north_stag": slice(j0, j0 + n),
        "west_east_subgrid": slice(i0*sr_x, (i0 + n)*sr_x),
        "south_north_subgrid": slice(j0*sr_y, (j0 + n)*sr_y),
    }
    for name, dim in ds.dimensions.items():
        if dim.isunlimited():
            dd.createDimension(name, None)
        elif name in sl:
            s = sl[name]
            dd.createDimension(name, s.stop - s.start)
        else:
            dd.createDimension(name, len(dim))
    for name, v in ds.variables.items():
        fill = getattr(v, "_FillValue", None)
        nv = dd.createVariable(name, v.datatype, v.dimensions, fill_value=fill)
        nv.setncatts({k: v.getncattr(k) for k in v.ncattrs() if k != "_FillValue"})
        idx = tuple(sl.get(dim, slice(None)) for dim in v.dimensions)
        nv[...] = v[idx]
    atts = {k: ds.getncattr(k) for k in ds.ncattrs()}
    atts["WEST-EAST_GRID_DIMENSION"] = np.int32(n)
    atts["SOUTH-NORTH_GRID_DIMENSION"] = np.int32(n)
    for k in list(atts):
        if k.startswith("WEST-EAST_PATCH_END_UNSTAG") or k.startswith("SOUTH-NORTH_PATCH_END_UNSTAG"):
            atts[k] = np.int32(n - 1)
        elif k.startswith("WEST-EAST_PATCH_END_STAG") or k.startswith("SOUTH-NORTH_PATCH_END_STAG"):
            atts[k] = np.int32(n)
        elif k.endswith("PATCH_START_UNSTAG") or k.endswith("PATCH_START_STAG"):
            if k.startswith("WEST-EAST") or k.startswith("SOUTH-NORTH"):
                atts[k] = np.int32(1)
    if "XLAT" in dd.variables:
        c = (n - 1)//2
        atts["CEN_LAT"] = np.float32(dd.variables["XLAT"][0, c, c])
        atts["CEN_LON"] = np.float32(dd.variables["XLONG"][0, c, c])
    dd.setncatts(atts)
    ds.close()
    dd.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--case-dir", required=True, help="full case run folder (with wrfinput_d02)")
    ap.add_argument("--namelist", required=True, help="namelist.input of the full case")
    ap.add_argument("--out", required=True)
    ap.add_argument("--n", type=int, default=181, help="new e_we = e_sn of d02 (must be k*ratio+1)")
    ap.add_argument("--lat", type=float, default=34.18604)
    ap.add_argument("--lon", type=float, default=-118.09325)
    args = ap.parse_args()

    text = open(args.namelist).read()
    ratio = int(col(read_value(text, "parent_grid_ratio"), 1))
    e_we = int(col(read_value(text, "e_we"), 1))
    e_sn = int(col(read_value(text, "e_sn"), 1))
    ips = int(col(read_value(text, "i_parent_start"), 1))
    jps = int(col(read_value(text, "j_parent_start"), 1))
    sr_x = int(col(read_value(text, "sr_x"), 1))
    sr_y = int(col(read_value(text, "sr_y"), 1))
    n = args.n
    if (n - 1) % ratio != 0:
        raise SystemExit(f"--n must be a multiple of the ratio plus 1 (ratio {ratio})")
    if n > min(e_we, e_sn):
        raise SystemExit("--n larger than the full nest")

    src = os.path.join(args.case_dir, "wrfinput_d02")
    ds = Dataset(src)
    lat = np.asarray(ds.variables["XLAT"][0])
    lon = np.asarray(ds.variables["XLONG"][0])
    ds.close()
    dist = (lat - args.lat)**2 + ((lon - args.lon)*np.cos(np.radians(args.lat)))**2
    jc, ic = np.unravel_index(np.argmin(dist), dist.shape)
    # lower-left mass point of the window (0-based), on a parent grid point
    i0 = int(round((ic - (n - 1)/2)/ratio))*ratio
    j0 = int(round((jc - (n - 1)/2)/ratio))*ratio
    i0 = min(max(i0, 0), (e_we - n)//ratio*ratio)
    j0 = min(max(j0, 0), (e_sn - n)//ratio*ratio)
    new_ips = ips + i0//ratio
    new_jps = jps + j0//ratio
    print(f"ignition nearest d02 point (0-based i,j) = ({ic},{jc})")
    print(f"window: i {i0}..{i0 + n - 1}, j {j0}..{j0 + n - 1}  -> ignition at ({ic - i0},{jc - j0}) of {n - 1}")
    print(f"new i_parent_start = {new_ips}, j_parent_start = {new_jps}")

    os.makedirs(args.out, exist_ok=True)
    cut(src, os.path.join(args.out, "wrfinput_d02"), i0, j0, n, sr_x, sr_y)
    text = set_values(text, [
        ("e_we", with_col(read_value(text, "e_we"), 1, n)),
        ("e_sn", with_col(read_value(text, "e_sn"), 1, n)),
        ("i_parent_start", with_col(read_value(text, "i_parent_start"), 1, new_ips)),
        ("j_parent_start", with_col(read_value(text, "j_parent_start"), 1, new_jps)),
    ])
    with open(os.path.join(args.out, "namelist.input"), "w") as f:
        f.write(text)
    with open(os.path.join(args.out, "README.md"), "w") as f:
        f.write(f"""# Development case eaton_small (plan.md P0.16)

Made by `port/make_dev_case.py` from `{os.path.abspath(src)}`.

| Item | Value |
|---|---|
| d02 size | {n} x {n} (was {e_we} x {e_sn}) |
| window in the full d02 (0-based mass points) | i {i0}..{i0 + n - 2}, j {j0}..{j0 + n - 2} |
| i_parent_start, j_parent_start | {new_ips}, {new_jps} (was {ips}, {jps}) |
| fire mesh | {n*sr_x} x {n*sr_y}, offset ({i0*sr_x}, {j0*sr_y}) |
| ignition | ({args.lat}, {args.lon}), nest point ({ic - i0}, {jc - j0}) |

wrfinput_d01, wrfbdy_d01 and the tables are those of the full case.
Every column of this nest is a column of the full nest, so the initial state
is the full case's initial state restricted to the window.
""")
    print(f"wrote {args.out}/wrfinput_d02, namelist.input, README.md")
    return 0


if __name__ == "__main__":
    sys.exit(main())
