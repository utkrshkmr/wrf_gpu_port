#!/usr/bin/env python3
"""Arithmetic guard for the GPU port (plan.md 0, rule 1 and rule 2).

Checks every changed Fortran file under WRF/ against a base commit:

 1. CPU view (all WRF_GPU* macros undefined), which is what CPU-REF compiles.
    It must equal the base statement for statement (comments, blank lines and
    OpenMP/OpenACC directive lines are ignored).  Allowed additions only:
      - USE of the port modules (module_gpu_*, module_bittrace, omp_lib,
        iso_c_binding)
      - CALL gpu_...(...), CALL bt_...(...), CALL wrf_nvtx_...(...)
      - #include of "gpu_*.inc" / "island_*.inc" files
      - IF (.NOT. gpu_on(R_...)) THEN / IF (gpu_on(R_...)) THEN blocks and
        their END IF
    Anything else (a changed, deleted or added statement) is a violation:
    the reference build would no longer compute what the archived reference
    computed.  Deliberate shared refactors (plan.md P0.9a, P1.7) are done by
    moving the base: see port/agent/WORKFLOW.md, "Shared refactors".

 2. GPU view (WRF_GPU defined): statements that exist only in the GPU view
    (the GPU restructurings of plan.md 7-9) are checked for arithmetic:
      - no intrinsic transcendental call and no real power that should be an
        rp_* call (the same rules as port/rp_subst.py)
      - every assignment that computes something must reuse an arithmetic
        "skeleton" that already occurs in the base version of the same file:
        variable names and array subscripts are ignored, operators, literals,
        parentheses and function names must match.  A pure copy (x = y) or a
        literal assignment (x = 0.) is always allowed.
    A statement with a new skeleton is reported; if it is correct (for
    example a hoisted loop bound), add it with a reason to
    port/agent/arith_exceptions.txt, where the reviewer will check it.

Usage:
  arith_guard.py [--base SHA] [file ...]     default base: port/agent/cpu_view_base
                                             default files: WRF/**/*.F|F90 changed vs base
  arith_guard.py --self-test
Exit status 0 = no violation.
"""

import argparse
import difflib
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(REPO, "port"))
import ftn  # noqa: E402

BASE_FILE = os.path.join(REPO, "port", "agent", "cpu_view_base")
EXC_FILE = os.path.join(REPO, "port", "agent", "arith_exceptions.txt")

ALLOWED_CPU = [
    re.compile(r"^use(,intrinsic::|::)?(module_gpu_\w+|module_bittrace|omp_lib|iso_c_binding)\b"),
    re.compile(r"^call(gpu_|bt_|wrf_nvtx_)\w*(\(.*\))?$"),
    re.compile(r"^#\s*include\s*[\"<](gpu_|island_)[\w.]+[\">]$"),
]
ALLOWED_IF = re.compile(r"^if\((\.not\.)?gpu_on\(r_\w+\)\)then$")
ENDIF = re.compile(r"^end\s*if$")

INTRINSIC_FUNCS = {
    "max", "min", "abs", "sign", "sqrt", "real", "int", "nint", "mod", "float", "dble", "amax1", "amin1",
    "merge", "epsilon", "huge", "tiny", "floor", "ceiling", "aint", "anint", "dim", "sum", "product",
    "maxval", "minval", "transfer", "iand", "ior", "ieor", "ishft", "btest", "size", "lbound", "ubound",
}
TRANSCENDENTAL = {"exp", "alog", "log", "log10", "alog10", "sin", "cos", "tan", "asin", "acos", "atan", "atan2",
                  "sinh", "cosh", "tanh", "dexp", "dlog", "dlog10", "dsin", "dcos", "dtan", "dasin", "dacos",
                  "datan", "datan2", "dsinh", "dcosh", "dtanh", "amod", "dmod", "erf", "erfc", "gamma", "hypot",
                  "asinh", "acosh", "atanh", "cbrt"}

def git(*args):
    return subprocess.run(["git", "-C", REPO] + list(args), capture_output=True, text=True, check=True).stdout


def base_sha():
    if os.path.exists(BASE_FILE):
        for line in open(BASE_FILE):
            line = line.split("#")[0].strip()
            if line:
                return line
    return "HEAD"


def changed_files(base):
    out = git("diff", "--name-only", base, "--", "WRF")
    files = [f for f in out.split() if f.endswith((".F", ".F90", ".f90"))]
    return [f for f in files if os.path.exists(os.path.join(REPO, f))]


def norm_statements(text, gpu):
    lines = text.split("\n")
    view = ftn.cpp_view(lines, gpu)
    out = []
    for n, s, is_dir in ftn.statements(view):
        if is_dir:
            continue
        ns = ftn.normalize(s)
        if ns:
            out.append((n, ns))
    return out


def _matching_paren(s, i):
    depth, q = 0, None
    for k in range(i, len(s)):
        c = s[k]
        if q:
            if c == q:
                q = None
            continue
        if c in "'\"":
            q = c
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return k
    return -1


def _top_level(s, chars):
    """Positions of the given characters outside parentheses and strings."""
    depth, q, pos = 0, None, []
    for k, c in enumerate(s):
        if q:
            if c == q:
                q = None
            continue
        if c in "'\"":
            q = c
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        elif depth == 0 and c in chars:
            pos.append(k)
    return pos


def split_assignment(ns):
    """(lhs, rhs) if the normalized statement is an assignment, else None.
    Declarations ('::'), DO loops ('doi=1,n') and PARAMETER/DATA are not."""
    if "::" in ns or re.match(r"^(parameter|data)\(", ns):
        return None
    s = ns
    m = re.match(r"^(else)?(if|where)\(", s)
    if m:
        k = _matching_paren(s, m.end() - 1)
        if k < 0:
            return None
        s = s[k + 1:]
        if not s or s.startswith("then"):
            return None
    for k in _top_level(s, "="):
        prv, nxt = s[k - 1:k], s[k + 1:k + 2]
        if nxt in ("=", ">") or prv in ("/", "<", ">", "="):
            continue
        lhs, rhs = s[:k], s[k + 1:]
        if _top_level(rhs, ","):
            return None
        if re.match(r"^[a-z_]\w*(\(.*\))?(%[a-z_]\w*(\(.*\))?)*$", lhs):
            return lhs, rhs
        return None
    return None


def skeleton(expr):
    """Operators, literals, parentheses and function names of an expression;
    variable names and array subscripts are replaced by 'v'."""
    toks = ftn.tokens(expr)
    out = []
    i = 0
    while i < len(toks):
        t = toks[i]
        if re.match(r"^[a-z_]\w*$", t):
            is_func = t in INTRINSIC_FUNCS or t in TRANSCENDENTAL or t.startswith("rp_")
            if i + 1 < len(toks) and toks[i + 1] == "(" and not is_func:
                depth = 0
                j = i + 1
                while j < len(toks):
                    if toks[j] == "(":
                        depth += 1
                    elif toks[j] == ")":
                        depth -= 1
                        if depth == 0:
                            break
                    j += 1
                i = j + 1
                out.append("v")
                while i < len(toks) and toks[i] == "%":
                    i += 2
                    if i < len(toks) and toks[i] == "(":
                        depth = 0
                        while i < len(toks):
                            if toks[i] == "(":
                                depth += 1
                            elif toks[i] == ")":
                                depth -= 1
                                if depth == 0:
                                    break
                            i += 1
                        i += 1
                continue
            out.append(t if is_func else "v")
            i += 1
            while i < len(toks) and toks[i] == "%":
                i += 2
            continue
        out.append(t)
        i += 1
    return " ".join(out)


def trivial(rhs):
    sk = skeleton(rhs)
    return sk == "v" or re.fullmatch(r"-?\s?[\d.][\w.+-]*", sk.replace(" ", "")) is not None or \
        re.fullmatch(r"-?\s?v", sk) is not None or sk in (".true.", ".false.")


def load_exceptions():
    exc = set()
    if os.path.exists(EXC_FILE):
        for line in open(EXC_FILE):
            if line.strip() and not line.startswith("#"):
                parts = line.rstrip("\n").split("|")
                if len(parts) >= 3 and parts[2].strip():
                    exc.add((parts[0].strip(), parts[1].strip()))
    return exc


def math_problems(ns, declared=()):
    """rp_subst rules applied to one normalized statement."""
    probs = []
    for t in set(re.findall(r"\b([a-z_]\w*)\s*\(", ns)):
        if t in TRANSCENDENTAL and t not in declared:
            probs.append(f"intrinsic {t.upper()} (use rp_{t.lstrip('ad') if t not in ('amod','dmod') else 'mod'})")
    try:
        import rp_subst
        rep = []
        rp_subst.rewrite_powers(ns, lambda k, m: rep.append((k, m)))
        if any(k == "pow" for k, _ in rep):
            probs.append("real power (use rp_pow, see port/rp_subst.py)")
    except Exception:
        pass
    return probs


def repo_rel(path):
    """Path relative to the repository; a copy elsewhere (for example a git
    worktree) is mapped by its WRF/... part."""
    rel = os.path.relpath(path, REPO)
    if rel.startswith("..") and "/WRF/" in path:
        rel = path[path.index("/WRF/") + 1:]
    return rel


def declared_names(stmts):
    """Names declared as variables in the file (so that an array called
    GAMMA is not taken for the intrinsic)."""
    names = set()
    for _, s in stmts:
        if "::" in s:
            ents = s.split("::", 1)[1]
            for k in [-1] + _top_level(ents, ","):
                m = re.match(r"([a-z_]\w*)", ents[k + 1:])
                if m:
                    names.add(m.group(1))
    return names


def check_file(path, base, exceptions):
    rel = repo_rel(path)
    try:
        base_text = git("show", f"{base}:{rel}")
    except subprocess.CalledProcessError:
        base_text = ""
    head_text = open(path, errors="replace").read()
    viol = []

    # 1. CPU view
    b = norm_statements(base_text, False)
    h = norm_statements(head_text, False)
    sm = difflib.SequenceMatcher(None, [s for _, s in b], [s for _, s in h], autojunk=False)
    openers = 0
    inserted_endifs = []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal":
            continue
        if tag in ("delete", "replace"):
            for n, s in b[i1:i2]:
                viol.append(f"{rel}: CPU view: base statement removed or changed (base line {n}): {s[:120]}")
        if tag in ("insert", "replace"):
            for n, s in h[j1:j2]:
                if tag == "replace":
                    viol.append(f"{rel}:{n}: CPU view: statement changed: {s[:120]}")
                    continue
                if any(p.match(s) for p in ALLOWED_CPU):
                    continue
                if ALLOWED_IF.match(s):
                    openers += 1
                    continue
                if ENDIF.match(s):
                    inserted_endifs.append((n, s))
                    continue
                viol.append(f"{rel}:{n}: CPU view: statement added: {s[:120]}")
    for n, s in inserted_endifs[openers:]:
        viol.append(f"{rel}:{n}: CPU view: END IF added without a gpu_on(...) IF: {s}")

    # 2. GPU-only statements
    g = norm_statements(head_text, True)
    declared = declared_names(g) | declared_names(b)
    sm2 = difflib.SequenceMatcher(None, [s for _, s in h], [s for _, s in g], autojunk=False)
    base_sk = set()
    for _, s in b:
        a = split_assignment(s)
        if a:
            base_sk.add(skeleton(a[1]))
    for tag, i1, i2, j1, j2 in sm2.get_opcodes():
        if tag not in ("insert", "replace"):
            continue
        for n, s in g[j1:j2]:
            probs = math_problems(s, declared)
            for p in probs:
                viol.append(f"{rel}:{n}: GPU view: {p}: {s[:120]}")
            if probs:
                continue
            a = split_assignment(s)
            if not a or trivial(a[1]):
                continue
            sk = skeleton(a[1])
            if sk in base_sk or (rel, s) in exceptions:
                continue
            viol.append(f"{rel}:{n}: GPU view: new arithmetic (skeleton not in the base file): {s[:120]}"
                        f"\n      skeleton: {sk[:160]}")
    return viol


def self_test():
    import tempfile
    ok = True

    def expect(cond, msg):
        nonlocal ok
        print(("ok    " if cond else "FAIL  ") + msg)
        ok = ok and cond

    base = """      SUBROUTINE s(a, b, n)
      REAL :: a(n), b(n)
      DO i = 1, n
         a(i) = b(i)*2.0 + a(i)/(b(i) + 1.0)
      END DO
      END SUBROUTINE s
"""
    head_ok = """      SUBROUTINE s(a, b, n)
      USE module_gpu_route, ONLY : gpu_on, R_ZERO_TEND
      REAL :: a(n), b(n)
!$omp target teams loop if(target: gpu_on(R_ZERO_TEND)) default(none) shared(a,b) firstprivate(n)
      DO i = 1, n
         a(i) = b(i)*2.0 + a(i)/(b(i) + 1.0)   ! unchanged
      END DO
      IF (.NOT. gpu_on(R_ZERO_TEND)) THEN
#include "island_in_s.inc"
      END IF
#ifdef WRF_GPU
      DO i = 1, n
         tmp = b(i)*2.0 + a(i)/(b(i) + 1.0)
         a(i) = tmp
      END DO
#else
      CALL gpu_noop()
#endif
      END SUBROUTINE s
"""
    head_bad = base.replace("a(i)/(b(i) + 1.0)", "a(i)/b(i) + 1.0").replace("*2.0", "*2.0 ")
    head_gpu_bad = head_ok.replace("tmp = b(i)*2.0 + a(i)/(b(i) + 1.0)", "tmp = (b(i)*2.0 + a(i))/(b(i) + 1.0)")
    head_gpu_exp = head_ok.replace("a(i) = tmp", "a(i) = exp(tmp)")
    import types
    for name, head, n_expected in (("directives + island + GPU copy", head_ok, 0),
                                   ("changed CPU arithmetic", head_bad, 2),
                                   ("new GPU arithmetic", head_gpu_bad, 1),
                                   ("intrinsic EXP in GPU code", head_gpu_exp, 1)):
        d = tempfile.mkdtemp()
        f = os.path.join(d, "x.F")
        open(f, "w").write(head)
        global git
        real_git = git
        git = lambda *a: base  # noqa: E731
        try:
            v = check_file(f, "BASE", set())
        finally:
            git = real_git
        expect(len(v) == n_expected, f"{name}: {len(v)} violation(s), expected {n_expected}")
        if len(v) != n_expected:
            print("\n".join(v))
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="*")
    ap.add_argument("--base")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    base = args.base or base_sha()
    files = [os.path.abspath(f) for f in args.files] if args.files else \
        [os.path.join(REPO, f) for f in changed_files(base)]
    exceptions = load_exceptions()
    total = []
    for f in files:
        v = check_file(f, base, exceptions)
        print(f"{repo_rel(f)}: {'OK' if not v else str(len(v)) + ' violation(s)'}")
        total += v
    if total:
        print("\n" + "\n".join(total))
    print(f"arith_guard (base {base[:12]}): {'PASS' if not total else 'FAIL'} ({len(files)} files)")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
