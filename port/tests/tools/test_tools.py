#!/usr/bin/env python3
"""Self-test of the port's Python tools on small synthetic files.

Covers nml.py, make_dev_case.py, perturb_input.py, compare_fields.py,
compare_fire.py and bittrace_diff.py.  Run: python3 port/tests/tools/test_tools.py
"""

import os
import subprocess
import sys
import tempfile

import numpy as np
from netCDF4 import Dataset

PORT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, PORT)
import nml  # noqa: E402

NAMELIST = """ &time_control
 run_hours                           = 17,
 history_interval                    = -1, 15,
 restart                             = .false.,
 /
 &domains
 max_dom                             = 2,
 e_we                                = 450, 91,
 e_sn                                = 450, 91,
 e_vert                              = 60,   60,
 dx                                  = 900, 100,
 i_parent_start                      = 1,    180,
 j_parent_start                      = 1,    180,
 parent_grid_ratio                   = 1,     9,
 sr_x                                = 0,     4,
 sr_y                                = 0,     4,
 /
"""


def fake_wrfinput(path, n=91, nz=5, sr=4, lat0=34.18604, lon0=-118.09325):
    d = Dataset(path, "w", format="NETCDF3_64BIT_OFFSET")
    d.createDimension("Time", None)
    d.createDimension("west_east", n - 1)
    d.createDimension("south_north", n - 1)
    d.createDimension("west_east_stag", n)
    d.createDimension("south_north_stag", n)
    d.createDimension("bottom_top", nz)
    d.createDimension("west_east_subgrid", n*sr)
    d.createDimension("south_north_subgrid", n*sr)
    jj, ii = np.meshgrid(np.arange(n - 1), np.arange(n - 1), indexing="ij")
    # ignition at mass point (i=60, j=30)
    lat = d.createVariable("XLAT", "f4", ("Time", "south_north", "west_east"))
    lon = d.createVariable("XLONG", "f4", ("Time", "south_north", "west_east"))
    lat[0] = lat0 + (jj - 30)*0.0009
    lon[0] = lon0 + (ii - 60)*0.0011
    t = d.createVariable("T", "f4", ("Time", "bottom_top", "south_north", "west_east"))
    t[0] = (np.arange(nz)[:, None, None]*1e6 + jj[None]*1000 + ii[None]).astype(np.float32)
    u = d.createVariable("U", "f4", ("Time", "bottom_top", "south_north", "west_east_stag"))
    u[0] = (np.arange(nz)[:, None, None]*1e6 + np.arange(n - 1)[None, :, None]*1000 + np.arange(n)[None, None, :])
    f = d.createVariable("NFUEL_CAT", "f4", ("Time", "south_north_subgrid", "west_east_subgrid"))
    fj, fi = np.meshgrid(np.arange(n*sr), np.arange(n*sr), indexing="ij")
    f[0] = (fj*10000 + fi).astype(np.float32)
    d.setncatts({"WEST-EAST_GRID_DIMENSION": np.int32(n), "SOUTH-NORTH_GRID_DIMENSION": np.int32(n),
                 "DX": np.float32(100.0), "DY": np.float32(100.0)})
    d.close()


def run(*cmd):
    r = subprocess.run([sys.executable] + list(cmd), capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


def check(cond, msg):
    print(("ok    " if cond else "FAIL  ") + msg)
    return 0 if cond else 1


def main():
    bad = 0
    with tempfile.TemporaryDirectory() as tmp:
        # nml.py
        txt = nml.set_values(NAMELIST, [("run_hours", "1"), ("e_we", "450, 37"), ("new_entry", "3")])
        bad += check(nml.read_value(txt, "run_hours") == "1", "nml set/read")
        bad += check(nml.read_value(txt, "e_we") == "450, 37", "nml multi-column value")
        bad += check(nml.read_value(txt, "new_entry") == "3", "nml adds a missing entry")

        # make_dev_case.py
        case = os.path.join(tmp, "case")
        os.makedirs(case)
        fake_wrfinput(os.path.join(case, "wrfinput_d02"))
        with open(os.path.join(case, "namelist.input"), "w") as f:
            f.write(NAMELIST)
        out = os.path.join(tmp, "small")
        rc, log = run(os.path.join(PORT, "make_dev_case.py"), "--case-dir", case,
                      "--namelist", os.path.join(case, "namelist.input"), "--out", out, "--n", "37")
        bad += check(rc == 0, "make_dev_case runs")
        if rc != 0:
            print(log)
        else:
            a = Dataset(os.path.join(case, "wrfinput_d02"))
            b = Dataset(os.path.join(out, "wrfinput_d02"))
            txt = open(os.path.join(out, "namelist.input")).read()
            i0 = (int(nml.read_value(txt, "i_parent_start").split(",")[1]) - 180)*9
            j0 = (int(nml.read_value(txt, "j_parent_start").split(",")[1]) - 180)*9
            bad += check(i0 % 9 == 0 and j0 % 9 == 0, f"window aligned to parent points (i0={i0}, j0={j0})")
            bad += check(b.dimensions["west_east"].size == 36 and b.dimensions["west_east_stag"].size == 37,
                         "new mass/staggered sizes")
            bad += check(b.dimensions["west_east_subgrid"].size == 148, "new fire mesh size")
            bad += check(np.array_equal(b["T"][0], a["T"][0, :, j0:j0 + 36, i0:i0 + 36]), "T cut exactly")
            bad += check(np.array_equal(b["U"][0], a["U"][0, :, j0:j0 + 36, i0:i0 + 37]), "U (staggered) cut exactly")
            bad += check(np.array_equal(b["NFUEL_CAT"][0], a["NFUEL_CAT"][0, j0*4:j0*4 + 148, i0*4:i0*4 + 148]),
                         "fire mesh cut with offset x sr")
            bad += check(int(b.getncattr("WEST-EAST_GRID_DIMENSION")) == 37, "grid dimension attribute")
            bad += check(nml.read_value(txt, "e_we") == "450, 37", "namelist e_we updated")
            lat = b["XLAT"][0]
            lon = b["XLONG"][0]
            dist = (lat - 34.18604)**2 + (lon + 118.09325)**2
            jc, ic = np.unravel_index(np.argmin(dist), dist.shape)
            bad += check(abs(ic - 18) <= 5 and abs(jc - 18) <= 5, f"ignition near the centre ({ic},{jc})")
            a.close()
            b.close()

        # perturb_input.py and compare_fields.py
        src = os.path.join(case, "wrfinput_d02")
        dst = os.path.join(tmp, "wrfinput_d02.e1")
        rc, log = run(os.path.join(PORT, "perturb_input.py"), src, dst, "--k", "2")
        bad += check(rc == 0, "perturb_input runs")
        rc, log = run(os.path.join(PORT, "compare_fields.py"), src, dst, "--bitwise")
        bad += check(rc == 1 and "T " in log and "1 of" in log, "compare_fields finds exactly one changed value")
        rc, log = run(os.path.join(PORT, "compare_fields.py"), src, src, "--bitwise")
        bad += check(rc == 0, "compare_fields: identical files pass")

        # compare_fire.py on two fake history files
        for tag, shift in (("a", 0), ("b", 1)):
            os.makedirs(os.path.join(tmp, tag))
            d = Dataset(os.path.join(tmp, tag, "wrfout_d02_x"), "w")
            d.createDimension("Time", None)
            d.createDimension("west_east_stag", 11)
            d.createDimension("south_north_stag", 11)
            d.createDimension("west_east_subgrid", 44)
            d.createDimension("south_north_subgrid", 44)
            d.DX = 100.0
            d.DY = 100.0
            xt = d.createVariable("XTIME", "f4", ("Time",))
            lfn = d.createVariable("LFN", "f4", ("Time", "south_north_subgrid", "west_east_subgrid"))
            tg = d.createVariable("TIGN_G", "f4", ("Time", "south_north_subgrid", "west_east_subgrid"))
            for t in range(2):
                xt[t] = 15.0*(t + 1)
                m = np.ones((44, 44), np.float32)
                m[10:20, 10:20 + (shift if t == 1 else 0)] = -1.0
                lfn[t] = m
                tg[t] = np.where(m <= 0, 100.0, 900.0*(t + 1)).astype(np.float32)
            d.close()
        rc, log = run(os.path.join(PORT, "compare_fire.py"), os.path.join(tmp, "a"), os.path.join(tmp, "b"),
                      "--pattern", "wrfout_d02_*")
        bad += check(rc == 1 and "differing      10" in log.replace("differing       10", "differing      10"),
                     "compare_fire counts 10 differing cells in frame 2")
        rc, log = run(os.path.join(PORT, "compare_fire.py"), os.path.join(tmp, "a"), os.path.join(tmp, "a"),
                      "--pattern", "wrfout_d02_*")
        bad += check(rc == 0 and "IDENTICAL FIRE SPREAD" in log, "compare_fire: identical runs pass")

        # bittrace_diff.py
        ta = os.path.join(tmp, "ta.txt")
        tb = os.path.join(tmp, "tb.txt")
        lines = [f"{s:9d} {r} tag{t} F{f} {s*7 + f:016X} {s*3 + t:016X}\n"
                 for s in range(1, 4) for r in (1, 2) for t in (1, 2) for f in (1, 2)]
        open(ta, "w").writelines(lines)
        lines_b = list(lines)
        lines_b[9] = lines_b[9][:-17] + "FFFFFFFFFFFFFFFF\n"
        open(tb, "w").writelines(lines_b)
        rc, log = run(os.path.join(PORT, "bittrace_diff.py"), ta, tb)
        bad += check(rc == 1 and "FIRST DIFFERENCE: itimestep 2" in log, "bittrace_diff finds the first difference")
        rc, log = run(os.path.join(PORT, "bittrace_diff.py"), ta, ta)
        bad += check(rc == 0, "bittrace_diff: identical traces pass")
    print("RESULT:", "PASS" if bad == 0 else f"FAIL ({bad})")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
