#!/usr/bin/env python3
"""Directive rules for GPU kernels (plan.md 7.0, port/agent/CODING_STANDARD.md).

For every OpenMP construct that launches a kernel ('!$omp target teams ...',
'!$omp target parallel ...', '!$omp target loop ...') in the given files:

  E1  if(target: gpu_on(R_<ROUTE>)) is present and R_<ROUTE> exists in
      WRF/frame/module_gpu_route.F
  E2  default(none) is present
  E3  no data movement in the kernel: map(to|from|tofrom:...) is not allowed
      (state is resident on the device, plan.md P1.2); map(present,...) and
      map(alloc:...) are allowed
  E4  collapse(n): the next n statements are DO loops (perfect nest)
  E5  the loop body contains no I/O or messages (WRITE, PRINT, READ,
      wrf_message, wrf_debug, wrf_error_fatal, STOP), no grid% and no
      config_flags% reference
  E6  the loop body contains no intrinsic transcendental call and no real
      power that port/rp_subst.py would rewrite
  E7  a DO loop label or GOTO inside the body (not supported by the tools)
  W1  'teams loop' whose body calls a procedure (use 'teams distribute
      parallel do', Template D, unless probe F-CALLS showed otherwise)
  W2  a procedure called in the body has no '!$omp declare target' in its
      definition (searched under WRF/)
  E8  a file with kernels does not USE module_gpu_route
  E9  a route used by a kernel has no island in the file: gpu_island(R_<ROUTE>)
      (port/tools/gen_island.py), or a comment '! island of R_<ROUTE> in <routine>'
      naming the routine (in another file) whose island covers it

Usage: kernel_lint.py [file ...]      default: WRF files changed vs port/agent/cpu_view_base
       kernel_lint.py --self-test
Exit status 1 if any E* finding.  W* findings are printed and should be
fixed or explained in the commit message.
"""

import argparse
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(REPO, "port"))
import ftn  # noqa: E402

ROUTE_FILE = os.path.join(REPO, "WRF", "frame", "module_gpu_route.F")
KERNEL = re.compile(r"^!\$omp\s+target\s+(teams|parallel|loop|simd)", re.I)
IO = re.compile(r"^(write\s*\(|print\b|read\s*\(|stop\b|call\s+wrf_(message|debug|error_fatal))", re.I)
TRANSC = {"exp", "alog", "log", "log10", "alog10", "sin", "cos", "tan", "asin", "acos", "atan", "atan2", "sinh",
          "cosh", "tanh", "dexp", "dlog", "dsin", "dcos", "dtan", "datan", "datan2", "dsinh", "dcosh", "dtanh",
          "amod", "dmod", "erf", "erfc", "hypot", "asinh", "acosh", "atanh"}
_DECLARE_CACHE = {}


def is_do(ns):
    """Normalized statement is a DO loop header ('doi=1,n', 'outer:doj=1,m',
    'dowhile(...)'), not an assignment such as 'dose=1'."""
    ns = re.sub(r"^[a-z_]\w*:", "", ns)
    if ns == "do" or ns.startswith("dowhile("):
        return True
    m = re.match(r"^do([a-z_]\w*)=(.*)$", ns)
    if not m:
        return False
    depth = 0
    for c in m.group(2):
        depth += c == "("
        depth -= c == ")"
        if c == "," and depth == 0:
            return True
    return False


def is_enddo(ns):
    return re.match(r"^enddo([a-z_]\w*)?$", ns) is not None


def route_names():
    names = set()
    if os.path.exists(ROUTE_FILE):
        for m in re.finditer(r"\b(R_[A-Z0-9_]+)\s*=", open(ROUTE_FILE).read()):
            names.add(m.group(1).lower())
    return names


def has_declare_target(name):
    name = name.lower()
    if name in _DECLARE_CACHE:
        return _DECLARE_CACHE[name]
    found = None
    try:
        out = subprocess.run(["grep", "-rilE", rf"^\s*(.*\b)?(subroutine|function)\s+{name}\b",
                              os.path.join(REPO, "WRF"), "--include=*.F", "--include=*.F90"],
                             capture_output=True, text=True).stdout.split()
    except Exception:
        out = []
    for f in out:
        lines = open(f, errors="replace").read().split("\n")
        for i, l in enumerate(lines):
            if re.match(rf"^\s*(\w+\s+)*(subroutine|function)\s+{name}\b", l, re.I):
                window = "\n".join(lines[i:i + 60])
                found = bool(re.search(r"!\$omp\s+declare\s+target", window, re.I))
                if found:
                    break
        if found:
            break
    _DECLARE_CACHE[name] = found
    return found


def lint_file(path, routes):
    text = open(path, errors="replace").read()
    lines = text.split("\n")
    rel = os.path.relpath(path, REPO) if not os.path.relpath(path, REPO).startswith("..") else path
    stmts = list(ftn.statements(list(enumerate(lines, 1))))
    findings = []
    n_kernels = 0
    used_routes = {}
    for idx, (n, s, is_dir) in enumerate(stmts):
        if not is_dir:
            continue
        d = ftn.normalize(s)
        if not KERNEL.match(s.strip()) and not re.match(r"^!\$omptarget(teams|parallel|loop|simd)", d):
            continue
        n_kernels += 1
        m = re.search(r"if\(target:gpu_on\((r_\w+)\)\)", d)
        if not m:
            findings.append(("E1", n, "missing if(target: gpu_on(R_<ROUTE>))"))
        elif routes and m.group(1) not in routes:
            findings.append(("E1", n, f"unknown route {m.group(1).upper()} (see module_gpu_route.F)"))
        if m:
            used_routes.setdefault(m.group(1), n)
        if "default(none)" not in d:
            findings.append(("E2", n, "missing default(none)"))
        for mm in re.finditer(r"map\(([a-z,]*):", d):
            kinds = mm.group(1).split(",")
            if any(k in ("to", "from", "tofrom") for k in kinds) and "present" not in kinds:
                findings.append(("E3", n, f"data movement in a kernel: map({mm.group(1)}:...)"))
        coll = re.search(r"collapse\((\d+)\)", d)
        ncoll = int(coll.group(1)) if coll else 1
        # body: from the first DO statement after the directive to its END DO
        j = idx + 1
        while j < len(stmts) and stmts[j][2]:
            j += 1
        nest = 0
        k = j
        while k < len(stmts) and nest < ncoll:
            if stmts[k][2]:
                k += 1
                continue
            if is_do(ftn.normalize(stmts[k][1])):
                nest += 1
                k += 1
                continue
            break
        if nest < ncoll:
            findings.append(("E4", n, f"collapse({ncoll}) but only {nest} perfectly nested DO statement(s) follow"))
        depth = 0
        calls = set()
        teams_loop = bool(re.match(r"^!\$omptargetteamsloop", d))
        for k in range(j, len(stmts)):
            kn, ks, kd = stmts[k]
            if kd:
                continue
            sk = ftn.normalize(ks)
            body = re.sub(r"^[a-z_]\w*:", "", sk)
            if re.match(r"^do\d", body):
                findings.append(("E7", kn, "labelled DO loop inside a kernel"))
            if is_do(sk):
                depth += 1
            elif is_enddo(body):
                depth -= 1
                if depth <= 0:
                    break
            if k == j:
                continue
            if IO.match(ks.strip()):
                findings.append(("E5", kn, f"I/O or message in a kernel: {ks.strip()[:60]}"))
            if "grid%" in sk or "config_flags%" in sk:
                findings.append(("E5", kn, f"grid%/config_flags% reference in a kernel: {ks.strip()[:60]}"))
            if re.search(r"\bgo\s*to\b", ks, re.I):
                findings.append(("E7", kn, "GOTO inside a kernel"))
            for t in set(re.findall(r"(?<![\w%])([a-z_]\w*)\(", sk)):
                if t in TRANSC:
                    findings.append(("E6", kn, f"intrinsic {t.upper()} in a kernel (use rp_*)"))
            try:
                import rp_subst
                rep = []
                rp_subst.rewrite_powers(sk, lambda kk, mm_: rep.append(kk))
                if "pow" in rep:
                    findings.append(("E6", kn, "real power in a kernel (use rp_pow)"))
            except Exception:
                pass
            mc = re.match(r"^call([a-z_]\w*)", sk)
            if mc:
                calls.add(mc.group(1))
        if calls and teams_loop:
            findings.append(("W1", n, f"'teams loop' around calls to {', '.join(sorted(calls))} (Template D)"))
        for c in sorted(calls):
            if has_declare_target(c) is False:
                findings.append(("W2", n, f"called procedure {c} has no '!$omp declare target'"))
    if n_kernels and not re.search(r"^\s*use\s+module_gpu_route\b", text, re.I | re.M):
        findings.append(("E8", 1, "file has kernels but does not USE module_gpu_route"))
    for r, n in used_routes.items():
        if not re.search(r"gpu_island\s*\(\s*" + r + r"\s*\)", text, re.I) and \
                not re.search(r"!\s*island\s+of\s+" + r + r"\s+in\s+\w+", text, re.I):
            findings.append(("E9", n, f"route {r.upper()} has no island (port/tools/gen_island.py)"))
    return rel, n_kernels, findings


def changed_files():
    base = "HEAD"
    bf = os.path.join(REPO, "port", "agent", "cpu_view_base")
    if os.path.exists(bf):
        base = [l.split("#")[0].strip() for l in open(bf) if l.split("#")[0].strip()][0]
    out = subprocess.run(["git", "-C", REPO, "diff", "--name-only", base, "--", "WRF"],
                         capture_output=True, text=True).stdout.split()
    return [os.path.join(REPO, f) for f in out if f.endswith((".F", ".F90")) and os.path.exists(os.path.join(REPO, f))]


SELF_TEST_SRC = """      SUBROUTINE k(a, b, n, m, grid)
      USE module_gpu_route, ONLY : gpu_on, R_ZERO_TEND
      REAL :: a(n,m), b(n,m)
!$omp target teams loop collapse(2) if(target: gpu_on(R_ZERO_TEND)) default(none) &
!$omp& shared(a,b) firstprivate(n,m)
      DO j = 1, m
      DO i = 1, n
         a(i,j) = b(i,j)*2.
      END DO
      END DO
!$omp target teams loop collapse(2) map(tofrom: a)
      DO j = 1, m
         a(1,j) = exp(b(1,j)) + b(1,j)**0.5
         WRITE(*,*) a(1,j)
         a(2,j) = grid%dt
      END DO
      END SUBROUTINE k
"""


def self_test():
    import tempfile
    f = os.path.join(tempfile.mkdtemp(), "k.F")
    open(f, "w").write(SELF_TEST_SRC)
    _, nk, fnd = lint_file(f, {"r_zero_tend"})
    codes = sorted(c for c, _, _ in fnd)
    expected = sorted(["E1", "E2", "E3", "E4", "E5", "E5", "E6", "E6", "E9"])
    ok = nk == 2 and codes == expected
    print(("ok    " if ok else "FAIL  ") + f"self-test: {nk} kernels, findings {codes} (expected {expected})")
    if not ok:
        for c, n, msg in fnd:
            print(f"  {c} line {n}: {msg}")
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="*")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    routes = route_names()
    files = [os.path.abspath(f) for f in args.files] if args.files else changed_files()
    errors = warnings = kernels = 0
    for f in files:
        rel, nk, fnd = lint_file(f, routes)
        kernels += nk
        for c, n, msg in fnd:
            print(f"{rel}:{n}: {c}: {msg}")
            if c.startswith("E"):
                errors += 1
            else:
                warnings += 1
    print(f"kernel_lint: {kernels} kernels in {len(files)} files, {errors} errors, {warnings} warnings: "
          f"{'PASS' if errors == 0 else 'FAIL'}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
