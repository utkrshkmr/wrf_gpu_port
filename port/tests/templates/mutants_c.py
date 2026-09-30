#!/usr/bin/env python3
"""Negative controls for T-TMPL-C (see ../mutants_lib.py).  Usage: mutants_c.py [gnu|nvhpc]"""
import os
import sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import mutants_lib  # noqa: E402

MUT = {
    "range guard dropped (recurrence over its..ite)": ("        IF (i <= itf) THEN\n", "        IF (.TRUE.) THEN\n"),
    "zeroing only over its..itf": ("          dmdts = 0.\n          ww(i,1,j) = 0.\n          ww(i,kte,j) = 0.\n\n        IF (i <= itf) THEN\n",
                                   "        IF (i <= itf) THEN\n          dmdts = 0.\n          ww(i,1,j) = 0.\n          ww(i,kte,j) = 0.\n"),
    "dmdt summed top-down": ("        DO k=kts,ktf\n          divv_col(k)", "        DO k=ktf,kts,-1\n          divv_col(k)"),
    "recurrence term order changed": ("ww(i,k-1,j) - dnw(k-1)*c1h(k-1)*dmdts - divv_col(k-1)",
                                      "ww(i,k-1,j) - (dnw(k-1)*c1h(k-1)*dmdts + divv_col(k-1))"),
    "muu one column short (its..ite)": ("      DO i=its,min(ite+1,ide)\n", "      DO i=its,ite\n"),
}
here = os.path.dirname(os.path.abspath(__file__))
sys.exit(mutants_lib.run(os.path.join(here, "t_tmpl_c.F90"), MUT, "SUBROUTINE calc_ww_cp_gpu", args=("6",)))
