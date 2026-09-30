#!/usr/bin/env python3
"""Self-test of the agent guardrail tools (port/tools/*, port/check_case.py).

Run: python3 port/tests/tools/test_agent_tools.py
All checks run on synthetic inputs or on files of the base commit, so they
pass on any machine with Python 3 (numpy/netCDF4 only for check_case's fuel
check, which is skipped here).
"""

import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PORT = os.path.abspath(os.path.join(HERE, "..", ".."))
REPO = os.path.dirname(PORT)
TOOLS = os.path.join(PORT, "tools")
sys.path.insert(0, TOOLS)
sys.path.insert(0, PORT)

bad = 0


def check(cond, msg, detail=""):
    global bad
    print(("ok    " if cond else "FAIL  ") + msg)
    if not cond:
        bad += 1
        if detail:
            print(detail)


def run(*cmd):
    r = subprocess.run([sys.executable] + list(cmd), capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


def base_sha():
    f = os.path.join(PORT, "agent", "cpu_view_base")
    if os.path.exists(f):
        for l in open(f):
            if l.split("#")[0].strip():
                return l.split("#")[0].strip()
    return "HEAD"


# ---- self-tests built into the tools
rc, out = run(os.path.join(TOOLS, "arith_guard.py"), "--self-test")
check(rc == 0, "arith_guard --self-test", out)
rc, out = run(os.path.join(TOOLS, "kernel_lint.py"), "--self-test")
check(rc == 0, "kernel_lint --self-test", out)

# ---- arith_guard and kernel_lint on a real routine: the Template C port of
# calc_coef_w from port/agent/CODING_STANDARD.md must pass, a reassociated
# version must fail
BASE = base_sha()
src = subprocess.run(["git", "-C", REPO, "show", f"{BASE}:WRF/dyn_em/module_small_step_em.F"],
                     capture_output=True, text=True).stdout
anchor_ok = "SUBROUTINE calc_coef_w" in src and "      IF(top_lid)lid_flag=0\n     outer_j_loop:" in src
GPU = open(os.path.join(HERE, "calc_coef_w_gpu.inc")).read()
if not anchor_ok:
    print("skip  calc_coef_w example: routine changed in the base commit")
else:
    i = src.index("SUBROUTINE calc_coef_w")
    k = src.index("      IMPLICIT NONE  ! religion first", i)
    s = src[:k] + "      USE module_gpu_route, ONLY : gpu_on, gpu_island, gpu_world_host, R_CALC_COEF_W\n" + src[k:]
    i = s.index("SUBROUTINE calc_coef_w")
    d = s.index("  INTEGER :: ij, ijp, ijm, lid_flag\n", i) + len("  INTEGER :: ij, ijp, ijm, lid_flag\n")
    s = s[:d] + "#ifdef WRF_GPU\n  REAL :: cofs\n  LOGICAL :: gpu_isl\n#endif\n" + s[d:]
    entry = ("#ifdef WRF_GPU\n      gpu_isl = gpu_island(R_CALC_COEF_W)\n      IF (gpu_isl) THEN\n"
             "        IF (gpu_world_host) THEN\n!$omp target update to(a, alpha, gamma, mut, c1h, c2h, c1f, c2f, &\n"
             "!$omp&   c3h, c4h, c3f, c4f, cqw, rdn, rdnw, c2a)\n        ELSE\n"
             "!$omp target update from(a, alpha, gamma, mut, c1h, c2h, c1f, c2f, &\n"
             "!$omp&   c3h, c4h, c3f, c4f, cqw, rdn, rdnw, c2a)\n        END IF\n"
             "        gpu_world_host = .NOT. gpu_world_host\n      END IF\n#endif\n")
    s = s.replace("      i_start = its\n      i_end   = min(ite,ide-1)\n      j_start = jts\n      j_end   = min(jte,jde-1)\n"
                  "      k_start = kts\n", entry + "      i_start = its\n      i_end   = min(ite,ide-1)\n"
                  "      j_start = jts\n      j_end   = min(jte,jde-1)\n      k_start = kts\n", 1)
    s = s.replace("      IF(top_lid)lid_flag=0\n     outer_j_loop:", "      IF(top_lid)lid_flag=0\n" + GPU +
                  "     outer_j_loop:", 1)
    tmp = tempfile.mkdtemp()
    good = os.path.join(tmp, "good", "WRF", "dyn_em", "module_small_step_em.F")
    badf = os.path.join(tmp, "bad", "WRF", "dyn_em", "module_small_step_em.F")
    os.makedirs(os.path.dirname(good))
    os.makedirs(os.path.dirname(badf))
    open(good, "w").write(s)
    open(badf, "w").write(s.replace("-cqw(i,k,j)*cofs*rdn(k)*rdnw(k  )*c2a(i,k,j  )",
                                    "-cqw(i,k,j)*(cofs*rdn(k))*rdnw(k  )*c2a(i,k,j  )", 1))
    rc, out = run(os.path.join(TOOLS, "arith_guard.py"), "--base", BASE, good)
    check(rc == 0, "arith_guard: Template C port of calc_coef_w passes", out)
    rc, out = run(os.path.join(TOOLS, "arith_guard.py"), "--base", BASE, badf)
    check(rc == 1 and "new arithmetic" in out, "arith_guard: a reassociation in the GPU code fails", out)
    rc, out = run(os.path.join(TOOLS, "kernel_lint.py"), good)
    check(rc == 0 and "1 kernels" in out, "kernel_lint: Template C port of calc_coef_w passes", out)
    open(badf, "w").write(s.replace("gpu_isl = gpu_island(R_CALC_COEF_W)", "gpu_isl = .FALSE."))
    rc, out = run(os.path.join(TOOLS, "kernel_lint.py"), badf)
    check(rc == 1 and "E9" in out, "kernel_lint: a kernel without an island fails (E9)", out)
    rc, out = run(os.path.join(TOOLS, "gen_island.py"), os.path.join(REPO, "WRF", "dyn_em", "module_small_step_em.F"),
                  "calc_coef_w")
    check(rc == 0 and "!$omp target update from(a, alpha, gamma)" in out and "gpu_island(R_CALC_COEF_W)" in out,
          "gen_island: calc_coef_w island (16 arrays in, 3 out)", out)
    s_cpu = s.replace("          c =   -cqw(i,k,j)*cof(i)*rdn(k)*rdnw(k  )*c2a(i,k,j  )",
                      "          c =   -cqw(i,k,j)*cof(i)*rdn(k)*(rdnw(k  )*c2a(i,k,j  ))", 1)
    open(badf, "w").write(s_cpu)
    rc, out = run(os.path.join(TOOLS, "arith_guard.py"), "--base", BASE, badf)
    check(rc == 1 and "CPU view" in out, "arith_guard: a change in the CPU-REF code fails", out)

# ---- Template A example of CODING_STANDARD.md (calc_alt, with its island) passes both guards
src = subprocess.run(["git", "-C", REPO, "show", f"{BASE}:WRF/dyn_em/module_big_step_utilities_em.F"],
                     capture_output=True, text=True).stdout
ex = open(os.path.join(HERE, "example_calc_alt.F")).read()
i = src.find("SUBROUTINE calc_alt (")
e = src.find("END SUBROUTINE calc_alt", i) + len("END SUBROUTINE calc_alt")
if i < 0:
    print("skip  calc_alt example: routine not in the base commit")
else:
    tmp = tempfile.mkdtemp()
    f = os.path.join(tmp, "WRF", "dyn_em", "module_big_step_utilities_em.F")
    os.makedirs(os.path.dirname(f))
    open(f, "w").write(src[:i] + ex.rstrip("\n") + src[e:])
    rc, out = run(os.path.join(TOOLS, "arith_guard.py"), "--base", BASE, f)
    check(rc == 0, "arith_guard: CODING_STANDARD Template A example (calc_alt) passes", out)
    rc, out = run(os.path.join(TOOLS, "kernel_lint.py"), f)
    check(rc == 0 and "1 kernels" in out, "kernel_lint: CODING_STANDARD Template A example (calc_alt) passes", out)
    open(f, "w").write(src[:i] + ex.rstrip("\n").replace("al(i,k,j)+alb(i,k,j)", "alb(i,k,j)+al(i,k,j)") + src[e:])
    rc, out = run(os.path.join(TOOLS, "arith_guard.py"), "--base", BASE, f)
    check(rc == 1 and "CPU view" in out, "arith_guard: swapping the operands of the calc_alt sum fails", out)

# ---- check_generated on a tiny synthetic Registry output
tmp = tempfile.mkdtemp()
os.makedirs(os.path.join(tmp, "inc"))
ok_alloc = """IF(okay_to_alloc.AND.in_use_for_config(id,'u_2'))THEN
  ALLOCATE(grid%u_2(sm31:em31,sm32:em32,sm33:em33),STAT=ierr)
  if (ierr.ne.0) then
    CALL wrf_error_fatal ('x')
  endif
  IF ( setinitval .EQ. 1 .OR. setinitval .EQ. 3 ) grid%u_2=initial_data_value
#ifdef WRF_GPU
  IF (.NOT. grid%is_intermediate) THEN
!$omp target enter data map(to:grid%u_2)
  ENDIF
#endif
ELSE
  ALLOCATE(grid%u_2(1,1,1),STAT=ierr)
  if (ierr.ne.0) then
    CALL wrf_error_fatal ('x')
  endif
#ifdef WRF_GPU
  IF (.NOT. grid%is_intermediate) THEN
!$omp target enter data map(to:grid%u_2)
  ENDIF
#endif
ENDIF
"""
ok_dealloc = """IF ( ASSOCIATED( grid%u_2 ) ) THEN
#ifdef WRF_GPU
!$omp target exit data map(delete:grid%u_2)
#endif
  DEALLOCATE(grid%u_2,STAT=ierr)
ENDIF
"""
open(os.path.join(tmp, "inc", "allocs.inc"), "w").write(ok_alloc)
open(os.path.join(tmp, "inc", "deallocs.inc"), "w").write(ok_dealloc)
rc, out = run(os.path.join(TOOLS, "check_generated.py"), tmp, "--only", "C1,C2,C3")
check(rc == 0, "check_generated: correct enter/exit data passes", out)
open(os.path.join(tmp, "inc", "allocs.inc"), "w").write(
    ok_alloc.replace("  IF ( setinitval .EQ. 1 .OR. setinitval .EQ. 3 ) grid%u_2=initial_data_value\n", "")
            .replace("  endif\n#ifdef WRF_GPU", "  endif\n#ifdef WRF_GPU", 1)
            .replace("!$omp target enter data map(to:grid%u_2)\n  ENDIF\n#endif\nELSE",
                     "!$omp target enter data map(to:grid%u_2)\n  ENDIF\n#endif\n"
                     "  IF ( setinitval .EQ. 1 ) grid%u_2=initial_data_value\nELSE", 1))
rc, out = run(os.path.join(TOOLS, "check_generated.py"), tmp, "--only", "C1")
check(rc == 1 and "before its initial value" in out, "check_generated: enter data before initialization fails", out)
open(os.path.join(tmp, "inc", "deallocs.inc"), "w").write(ok_dealloc.replace(
    "#ifdef WRF_GPU\n!$omp target exit data map(delete:grid%u_2)\n#endif\n", ""))
rc, out = run(os.path.join(TOOLS, "check_generated.py"), tmp, "--only", "C3")
check(rc == 1, "check_generated: missing exit data fails", out)
upd_ok = "IF (in_use_for_config(grid%id,'u_2')) THEN\n!$omp target update to(grid%u_2)\nENDIF\n"
open(os.path.join(tmp, "inc", "gpu_upd_dev_all.inc"), "w").write(upd_ok)
open(os.path.join(tmp, "inc", "gpu_upd_host_all.inc"), "w").write(upd_ok.replace("update to", "update from"))
rc, out = run(os.path.join(TOOLS, "check_generated.py"), tmp, "--only", "C4,C7")
check(rc == 0, "check_generated: complete, guarded update lists pass", out)
open(os.path.join(tmp, "inc", "gpu_upd_host_all.inc"), "w").write("!$omp target update from(grid%u_2)\n")
rc, out = run(os.path.join(TOOLS, "check_generated.py"), tmp, "--only", "C7")
check(rc == 1, "check_generated: unguarded update fails", out)

# ---- locate: an unchanged v4.6.0 line maps to the same text
rc, out = run(os.path.join(TOOLS, "locate.py"), "SS", "1308", "--context", "0")
v460 = subprocess.run(["git", "-C", REPO, "show", "99becf4:WRF/dyn_em/module_small_step_em.F"],
                      capture_output=True, text=True).stdout.split("\n")[1307]
check(rc == 0 and v460.strip() in out, "locate: v4.6.0 SS:1308 found in the current file", out)

# ---- nsys_copies on both CSV layouts
tmp = tempfile.mkdtemp()
trace = os.path.join(tmp, "trace.csv")
open(trace, "w").write("Start (ns),Duration (ns),CorrId,GrdX,GrdY,GrdZ,BlkX,BlkY,BlkZ,Reg/Trd,StcSMem (MB),"
                       "DymSMem (MB),Bytes (MB),Throughput (MBps),SrcMemKd,DstMemKd,Device,Ctx,Strm,Name\n"
                       "1,2,3,,,,,,,,,,161.821,1,Pageable,Device,H100,1,7,[CUDA memcpy Host-to-Device]\n"
                       "5,2,4,,,,,,,,,,161.821,1,Device,Pageable,H100,1,7,[CUDA memcpy Device-to-Host]\n"
                       "9,2,5,1,1,1,128,1,1,32,0,0,,,,,H100,1,7,nvkernel_advance_w_F1L1308_2\n"
                       "11,2,6,,,,,,,,,,0.004,1,Pageable,Device,H100,1,7,[CUDA memcpy HtoD]\n")
rc, out = run(os.path.join(TOOLS, "nsys_copies.py"), trace)
check(rc == 0 and re.search(r"HtoD\s+2 copies", out) and re.search(r"DtoH\s+1 copies", out), "nsys_copies: trace report", out)
rc, out = run(os.path.join(TOOLS, "nsys_copies.py"), trace, "--max-h2d", "1")
check(rc == 1, "nsys_copies: limit exceeded fails", out)
summ = os.path.join(tmp, "sum.csv")
open(summ, "w").write("Total (MB),Count,Avg (MB),Med (MB),Min (MB),Max (MB),StdDev (MB),Operation\n"
                      "323.642,2,161.821,161.821,161.821,161.821,0.0,[CUDA memcpy Host-to-Device]\n"
                      "161.821,1,161.821,161.821,161.821,161.821,0.0,[CUDA memcpy Device-to-Host]\n")
rc, out = run(os.path.join(TOOLS, "nsys_copies.py"), summ)
check(rc == 0 and re.search(r"HtoD\s+2 copies", out) and "323.642" in out, "nsys_copies: summary report", out)

# ---- check_verbatim: the reference tests' copies of WRF code, and a tampered copy
rc, out = run(os.path.join(TOOLS, "check_verbatim.py"))
check(rc == 0, "check_verbatim: the copies in port/tests are verbatim", out)
tmp = tempfile.mkdtemp()
t = open(os.path.join(PORT, "tests", "pdlim", "t_pdlim.F90")).read()
tampered = os.path.join(tmp, "t.F90")
open(tampered, "w").write(t.replace("scale = max(0.,ph_low(i,k,j)/(flux_out(i,k,j)+eps))",
                                    "scale = max(0.,ph_low(i,k,j)*(1./(flux_out(i,k,j)+eps)))", 1))
rc, out = run(os.path.join(TOOLS, "check_verbatim.py"), tampered)
check(rc == 1 and "not a verbatim copy" in out, "check_verbatim: an edited copy fails", out)

# ---- workbook: the real workbook passes; a ticked task without commit/log fails
rc, out = run(os.path.join(TOOLS, "workbook.py"), "check")
check(rc == 0, "workbook: port/agent/WORKBOOK.md and kernels.csv are consistent", out)
import shutil
wb = os.path.join(PORT, "agent", "WORKBOOK.md")
saved = open(wb).read()
try:
    open(wb, "w").write(saved.replace("- [ ] H0.1 Toolchain", "- [x] H0.1 Toolchain", 1))
    rc, out = run(os.path.join(TOOLS, "workbook.py"), "check")
    check(rc == 1 and "H0.1" in out and "commit" in out, "workbook: a ticked task without commit and log fails", out)
finally:
    open(wb, "w").write(saved)

# ---- gen_island on a routine with a TYPE(domain) dummy and OPTIONAL arrays
rc, out = run(os.path.join(TOOLS, "gen_island.py"), os.path.join(REPO, "WRF", "dyn_em", "module_first_rk_step_part1.F"),
              "first_rk_step_part1")
check(rc == 0 and "gpu_upd_dev_all(grid)" in out and "IF (PRESENT(" in out,
      "gen_island: whole-state update for grid, PRESENT() for optional arrays", out[:2000])

# ---- check_case / T-GATE namelists
rc, out = run(os.path.join(PORT, "check_case.py"), os.path.join(REPO, "cases", "eaton_20250108", "namelist.input"))
check(rc == 0, "check_case: the reference case is inside the envelope", out)
rc, out = run(os.path.join(PORT, "tests", "gate", "run_check_case.py"))
check(rc == 0, "T-GATE namelists: check_case.py agrees with expected.txt", out)

print("RESULT:", "PASS" if bad == 0 else f"FAIL ({bad})")
sys.exit(1 if bad else 0)
