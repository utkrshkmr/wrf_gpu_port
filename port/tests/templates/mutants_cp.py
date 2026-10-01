#!/usr/bin/env python3
"""Negative controls for T-TMPL-CP (see ../mutants_lib.py).  Usage: mutants_cp.py [gnu|nvhpc]"""
import os
import sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import mutants_lib  # noqa: E402

here = os.path.dirname(os.path.abspath(__file__))
# t_tmpl_cp.F90 includes WRF/inc/gpu_col.h
inc = os.path.abspath(os.path.join(here, "..", "..", "..", "WRF", "inc"))
os.environ["MUTANT_EXTRA_FLAGS"] = (os.environ.get("MUTANT_EXTRA_FLAGS", "") + " -I" + inc).strip()
MUT = {
    "scatter by a reciprocal (th = t*(1/pii))": ("th(i, k, j) = t(1, kk)/pii(i, k, j)",
                                                 "th(i, k, j) = t(1, kk)*(1./pii(i, k, j))"),
    "sedimentation loop turned upward": ("      do k = kte - 1, kts, -1\n", "      do k = kts, kte - 1\n"),
    "updated value used instead of the saved copy": ("cpm = cpmcal(rh(i, k))", "cpm = cpmcal(q(i, k))"),
    "accumulator not written back": ("         rainnc(i, j) = rn(1)\n", ""),
    "column one level short": ("      nz = kte - kts + 1\n", "      nz = kte - kts\n"),
}
sys.exit(mutants_lib.run(os.path.join(here, "t_tmpl_cp.F90"), MUT, "subroutine tcp_run_gpu", args=("6",)))
