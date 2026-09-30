#!/usr/bin/env python3
"""Negative controls for T-TMPL-G (see ../mutants_lib.py).  Usage: mutants_g.py [gnu|nvhpc]"""
import os
import sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import mutants_lib  # noqa: E402

MUT = {
    "y strips over the tile only (corners and x halo missed)": (
        "            DO i = i_start, i_end\n              dat(i,k,jds-1) = dat(i,k,jds)",
        "            DO i = i_start+5, i_end-5\n              dat(i,k,jds-1) = dat(i,k,jds)"),
    "x strips without the halo rows": (
        "            DO j = jts-bdyzone, MIN(jte,jde+jstag)+bdyzone\n",
        "            DO j = jts, MIN(jte,jde+jstag)\n"),
    "xe u-branch copies from ide-1": ("              dat(ide+1,k,j) = dat(ide,k,j)", "              dat(ide+1,k,j) = dat(ide-1,k,j)"),
}
here = os.path.dirname(os.path.abspath(__file__))
sys.exit(mutants_lib.run(os.path.join(here, "t_tmpl_g.F90"), MUT, "SUBROUTINE set_physical_bc3d_gpu", args=("2",)))
