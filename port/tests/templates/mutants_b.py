#!/usr/bin/env python3
"""Negative controls for T-TMPL-B (see ../mutants_lib.py).  Usage: mutants_b.py [gnu|nvhpc]"""
import os
import sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import mutants_lib  # noqa: E402

MUT = {
    "Y2 starts at j_start (one row too many)": ("   DO j = j_start+1, j_end+1\n", "   DO j = j_start, j_end+1\n"),
    # equivalent mutants (exact in IEEE, so not listed): a-b -> -b+a; 0.5*(a+b) -> 0.5*a+0.5*b
    "Y2 divergence distributed": ("mrdy*(fqy3(i,k,j)-fqy3(i,k,j-1))", "(mrdy*fqy3(i,k,j)-mrdy*fqy3(i,k,j-1))"),
    "Y2 uses msfux of row j": ("            mrdy=msfux(i,j-1)*rdy", "            mrdy=msfux(i,j)*rdy"),
    "Y1 north 2nd-order branch dropped": ("      ELSE IF ( j == jde-1 ) THEN", "      ELSE IF ( j == -99 ) THEN"),
    "Y1 face range one row short": ("   DO j = j_start, j_end+1\n   DO k=kts,ktf\n   DO i = i_start, i_end\n      IF(",
                                    "   DO j = j_start, j_end\n   DO k=kts,ktf\n   DO i = i_start, i_end\n      IF("),
    "2nd-order flux distributed": ("              fqy3(i, k, j) = 0.25*(rv(i,k,j)+rv(i-1,k,j))  &\n                                     *(u(i,k,j)+u(i,k,j-1))",
                                   "              fqy3(i, k, j) = 0.25*(rv(i,k,j)*(u(i,k,j)+u(i,k,j-1))+rv(i-1,k,j)*(u(i,k,j)+u(i,k,j-1)))"),
}
here = os.path.dirname(os.path.abspath(__file__))
sys.exit(mutants_lib.run(os.path.join(here, "t_tmpl_b.F90"), MUT, "SUBROUTINE advect_u_yflux_gpu", args=("6",)))
