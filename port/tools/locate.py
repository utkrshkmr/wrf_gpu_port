#!/usr/bin/env python3
"""Map a line number of WRF v4.6.0 (what plan.md cites, e.g. 'SS:1308') to
the same line in the current working tree, and show it.

plan.md's file:line references are to the unmodified v4.6.0 sources (commit
99becf4).  Phase 0 and every later commit shift lines a little; this tool
follows them through the diff.

Usage:
  locate.py WRF/dyn_em/module_small_step_em.F 1308 [--context 5]
  locate.py SS 1308            (plan.md's abbreviations, see ABBREV below)
  locate.py SS 1308-1467       (a range: prints the current range)
"""

import argparse
import difflib
import os
import subprocess
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
BASE = "99becf4"
ABBREV = {
    "SS": "WRF/dyn_em/module_small_step_em.F", "BSU": "WRF/dyn_em/module_big_step_utilities_em.F",
    "ADV": "WRF/dyn_em/module_advect_em.F", "DIF": "WRF/dyn_em/module_diffusion_em.F",
    "EM": "WRF/dyn_em/module_em.F", "BC": "WRF/share/module_bc.F", "BCE": "WRF/dyn_em/module_bc_em.F",
    "ST": "WRF/dyn_em/solve_em.F", "P2": "WRF/dyn_em/module_first_rk_step_part2.F",
    "P1": "WRF/dyn_em/module_first_rk_step_part1.F", "IEVA": "WRF/dyn_em/module_ieva_em.F",
    "DD": "WRF/phys/module_diagnostics_driver.F", "DMISC": "WRF/phys/module_diag_misc.F",
    "ADDT": "WRF/phys/module_physics_addtendc.F", "MASSV": "WRF/frame/libmassv.F",
    "MW": "WRF/phys/module_mp_wsm6.F", "MC": "WRF/phys/physics_mmm/mp_wsm6.F90",
    "ME": "WRF/phys/physics_mmm/mp_wsm6_effectRad.F90", "SD": "WRF/phys/module_surface_driver.F",
    "SLW": "WRF/phys/module_sf_sfclayrev.F", "SLC": "WRF/phys/physics_mmm/sf_sfclayrev.F90",
    "ND": "WRF/phys/module_sf_noahdrv.F", "NL": "WRF/phys/module_sf_noahlsm.F",
    "NGL": "WRF/phys/module_sf_noahlsm_glacial_only.F", "NSI": "WRF/phys/module_sf_noah_seaice.F",
    "DG": "WRF/phys/module_sf_sfcdiags.F", "PD": "WRF/phys/module_pbl_driver.F",
    "YW": "WRF/phys/module_bl_ysu.F", "YC": "WRF/phys/physics_mmm/bl_ysu.F90",
    "RD": "WRF/phys/module_radiation_driver.F", "LW": "WRF/phys/module_ra_rrtmg_lw.F",
    "SW": "WRF/phys/module_ra_sw.F", "ECL": "WRF/phys/module_ra_eclipse.F",
    "driver": "WRF/phys/module_fr_fire_driver.F", "core": "WRF/phys/module_fr_fire_core.F",
    "phys": "WRF/phys/module_fr_fire_phys.F", "util": "WRF/phys/module_fr_fire_util.F",
    "atm": "WRF/phys/module_fr_fire_atm.F", "model": "WRF/phys/module_fr_fire_model.F",
}


def map_line(old_lines, new_lines, n):
    """Current line for v4.6.0 line n (1-based); None if the line was removed."""
    sm = difflib.SequenceMatcher(None, old_lines, new_lines, autojunk=False)
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if i1 <= n - 1 < i2:
            if tag == "equal":
                return j1 + (n - 1 - i1) + 1, True
            return j1 + 1, False        # changed or deleted: nearest current line
    return len(new_lines), False


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("file")
    ap.add_argument("line")
    ap.add_argument("--context", type=int, default=3)
    args = ap.parse_args()
    path = ABBREV.get(args.file, args.file)
    if not path.startswith("WRF/") and os.path.exists(os.path.join(REPO, "WRF", path)):
        path = "WRF/" + path
    old = subprocess.run(["git", "-C", REPO, "show", f"{BASE}:{path}"], capture_output=True, text=True).stdout
    if not old:
        print(f"{path} not found in {BASE}")
        return 2
    new = open(os.path.join(REPO, path), errors="replace").read()
    ol, nl = old.split("\n"), new.split("\n")
    parts = args.line.split("-")
    a = int(parts[0])
    b = int(parts[1]) if len(parts) > 1 else a
    ca, exact_a = map_line(ol, nl, a)
    cb, exact_b = map_line(ol, nl, b)
    note = "" if (exact_a and exact_b) else "  (the v4.6.0 line was changed; nearest current line shown)"
    print(f"{path}: v4.6.0 {args.line}  ->  current {ca}" + (f"-{cb}" if b != a else "") + note)
    lo, hi = max(1, ca - args.context), min(len(nl), cb + args.context)
    for k in range(lo, hi + 1):
        mark = ">" if ca <= k <= cb else " "
        print(f"{mark}{k:6d}  {nl[k - 1]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
