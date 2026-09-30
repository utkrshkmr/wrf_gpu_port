#!/usr/bin/env python3
"""Negative controls for T-PDLIM (see ../mutants_lib.py).  Usage: mutants.py [gnu|nvhpc]"""
import os
import sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import mutants_lib  # noqa: E402

MUT = {
    "x donor range check dropped": ("          IF (i-1 >= i_start) THEN\n", "          IF (.TRUE.) THEN\n"),
    # (">= instead of >" is an equivalent mutant: scaling a zero flux gives the same bits)
    "x inflow scaled by the wrong cell": ("            IF (lim(i-1,k,j)) fqx(i,k,j) = scl(i-1,k,j)*fqx(i,k,j)",
                                          "            IF (lim(i,k,j)) fqx(i,k,j) = scl(i,k,j)*fqx(i,k,j)"),
    "z sign not reversed": ("        IF (fqz(i,k,j) .lt. 0.) THEN\n          IF (k-1 >= kts)",
                            "        IF (fqz(i,k,j) .gt. 0.) THEN\n          IF (k-1 >= kts)"),
    "y outflow face range too short": ("      DO j = j_start, j_end+1\n", "      DO j = j_start, j_end\n"),
    "sentinel instead of flag": ("            IF (lim(i-1,k,j)) fqx(i,k,j)", "            IF (scl(i-1,k,j) > 0.) fqx(i,k,j)"),
    "limiter scale reassociated": ("          scl(i,k,j) = max(0.,ph_low(i,k,j)/(flux_out(i,k,j)+eps))",
                                   "          scl(i,k,j) = max(0.,ph_low(i,k,j)*(1./(flux_out(i,k,j)+eps)))"),
}
here = os.path.dirname(os.path.abspath(__file__))
sys.exit(mutants_lib.run(os.path.join(here, "t_pdlim.F90"), MUT, "SUBROUTINE pdlim_split", args=("100",)))
