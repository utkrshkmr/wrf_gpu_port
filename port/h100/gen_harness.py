#!/usr/bin/env python3
"""Generate the driver of the per-routine harness (port/h100/harness.sh;
port/agent/DEBUGGING.md "Fast checks").  Infrastructure: fix it as a tool
fix if it cannot handle a routine's declarations.

The driver calls ONE WRF routine on deterministic pseudo-random inputs and
writes every output (non-INTENT(IN) array and scalar) to harness_out.bin:

  - config_flags (TYPE(grid_config_rec_type)) come from namelist.input in the
    run directory (initial_config, as wrf.exe does), domain --domain;
  - the WRF dimension arguments (ids..kte, ims..kme, ips..kpe, its..kte) describe
    one tile covering an NX x NY x NZ domain with a halo of 5 (--grid);
  - other INTEGER/REAL/LOGICAL scalars: --set name=value, else 1 / 0.75 / .FALSE.
    (the driver prints every default it used: check them against the call site);
  - REAL arrays: values built from random bits (exact, identical in every build),
    positive 0.5..4 by default, symmetric -4..4 for names that look like winds,
    fluxes or tendencies; --range name=lo:hi changes it; INTEGER arrays 0..3;
    INTENT(OUT) arrays start from a sentinel (-9999.5, -99, .FALSE.).
  - GPU builds: every array is mapped (target enter data map(alloc)) before the
    call; the routine's island moves the data, as in wrf.exe.

  gen_harness.py <WRF file> <routine> --mode gpu|cpu [--grid NX,NY,NZ] [--domain D]
                 [--set name=value ...] [--range name=lo:hi ...] [--shape name=b1,b2,...]
                 [--use module ...] > harness_driver.f90

Limits: assumed-shape or assumed-size dummies need --shape; TYPE(domain) and other
derived-type dummies are not supported (use T-AB on W-20); data the routine reads
that are not arguments (module arrays) are whatever the library holds.
"""
import argparse
import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "tools"))
import ftn  # noqa: E402

TYPES = r"(real\s*(?:\*\s*\d+|\([^)]*\))?|integer\s*(?:\*\s*\d+|\([^)]*\))?|logical\s*(?:\([^)]*\))?|" \
        r"double\s*precision|character\s*(?:\*\s*\(?[^)]*\)?|\([^)]*\))?|type\s*\(\s*\w+\s*\))"
DECL = re.compile(r"^\s*" + TYPES + r"(?!\w)\s*(.*)$", re.I)
DIMNAME = re.compile(r"^[ijk][dmpt][se]$")
SYM = re.compile(r"^(u|v|w|u_\w*|v_\w*|w_\w*|ww\w*|ru\w*|rv\w*|rw\w*|\w*tend\w*|\w*flux\w*|fq\w*|\w*_save)$", re.I)


def split_top(s, sep=","):
    out, depth, cur, q = [], 0, "", None
    for c in s:
        if q:
            cur += c
            if c == q:
                q = None
            continue
        if c in "'\"":
            q = c
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        if c == sep and depth == 0:
            out.append(cur)
            cur = ""
        else:
            cur += c
    if cur.strip():
        out.append(cur)
    return [x.strip() for x in out]


def parse(path, name):
    lines = open(path, errors="replace").read().split("\n")
    stmts = [(n, s) for n, s, d in ftn.statements(list(enumerate(lines, 1))) if not d and not s.lstrip().startswith("#")]
    module = None
    start = None
    for i, (n, s) in enumerate(stmts):
        mm = re.match(r"^\s*module\s+(\w+)\s*$", s, re.I)
        if mm and not re.match(r"^\s*module\s+procedure", s, re.I):
            module = mm.group(1)
        if re.match(r"^\s*end\s*module\b", s, re.I):
            module = None
        if re.match(r"^\s*(recursive\s+|pure\s+|elemental\s+)*subroutine\s+" + re.escape(name) + r"\b", s, re.I):
            start = i
            break
    if start is None:
        raise SystemExit(f"gen_harness: SUBROUTINE {name} not found in {path}")
    m = re.search(r"\((.*)\)", stmts[start][1])
    dummies = [d.strip().lower() for d in (m.group(1).split(",") if m else []) if d.strip()]
    info = {d: dict(tspec=None, shape=None, intent=None, optional=False) for d in dummies}
    for n, s in stmts[start + 1:]:
        low = s.strip().lower()
        if re.match(r"^(end\s*subroutine|contains)\b", low):
            break
        md = DECL.match(s)
        if md and not re.match(r"^\s*(real|integer|logical)\s*function\b", s, re.I):
            tspec = re.sub(r"\s+", " ", md.group(1).strip())
            rest = md.group(2)
            if "::" in s:
                attrs, names = s.split("::", 1)
                al = split_top(attrs)[1:]          # [0] is the type spec
            else:
                names, al = rest, []
            dim = None
            intent = None
            opt = False
            for a in al:
                a2 = a.strip()
                mm = re.match(r"dimension\s*\((.*)\)\s*$", a2, re.I)
                if mm:
                    dim = mm.group(1)
                mm = re.match(r"intent\s*\(\s*(in|out|inout|in\s+out)\s*\)", a2, re.I)
                if mm:
                    intent = mm.group(1).lower().replace(" ", "")
                if a2.lower() == "optional":
                    opt = True
            for ent in split_top(names):
                nm = re.match(r"(\w+)\s*(\((.*)\))?", ent)
                if not nm:
                    continue
                v = nm.group(1).lower()
                if v not in info:
                    continue
                d = info[v]
                d["tspec"] = tspec
                d["shape"] = nm.group(3) if nm.group(2) else (dim or d["shape"])
                d["intent"] = intent or d["intent"]
                d["optional"] = d["optional"] or opt
            continue
        mm = re.match(r"^\s*intent\s*\(\s*(in|out|inout|in\s+out)\s*\)\s*(::)?\s*(.*)$", s, re.I)
        if mm:
            for ent in split_top(mm.group(3)):
                v = ent.strip().lower()
                if v in info:
                    info[v]["intent"] = mm.group(1).lower().replace(" ", "")
            continue
        mm = re.match(r"^\s*dimension\s*(::)?\s*(.*)$", s, re.I)
        if mm:
            for ent in split_top(mm.group(2)):
                nm = re.match(r"(\w+)\s*\((.*)\)", ent)
                if nm and nm.group(1).lower() in info:
                    info[nm.group(1).lower()]["shape"] = nm.group(2)
    for d, x in info.items():
        if x["tspec"] is None:
            raise SystemExit(f"gen_harness: no declaration found for dummy {d} of {name} (implicit typing?)")
    return module, dummies, info


def pre(name):
    """driver variable of a dummy: prefixed, so that module names (t0, p0, c2 of module_model_constants) never clash"""
    return "h_" + name


def pre_expr(expr, dummies):
    """rename the dummies in a bound expression"""
    return re.sub(r"\b([A-Za-z_]\w*)\b", lambda m: pre(m.group(1).lower()) if m.group(1).lower() in dummies
                  else m.group(1), expr)


def kind_of(tspec):
    t = tspec.lower()
    if t.startswith("real"):
        if re.search(r"\*\s*8|kind\s*=\s*8|\(\s*8\s*\)|kind\s*=\s*r8|kind_phys|dp\b", t):
            return "r8"
        return "r4"
    if t.startswith("double"):
        return "r8"
    if t.startswith("integer"):
        return "i8" if re.search(r"\*\s*8|kind\s*=\s*8|\(\s*8\s*\)", t) else "i4"
    if t.startswith("logical"):
        return "l"
    if t.startswith("character"):
        return "c"
    if t.startswith("type"):
        return "t:" + re.sub(r"\s", "", t)[5:-1]
    return "?"


def exps(lo, hi):
    """(sym, emin, emax): values sign*2**e*(1+f), e in [emin, emax]"""
    sym = lo < 0 < hi
    if sym:
        top = max(abs(lo), abs(hi))
        return 1, int(math.floor(math.log2(top))) - 3, int(math.floor(math.log2(top)))
    lo = max(lo, 1e-30)
    return 0, int(math.floor(math.log2(lo))), int(math.floor(math.log2(max(hi, lo))))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("file")
    ap.add_argument("routine")
    ap.add_argument("--mode", choices=["gpu", "cpu"], required=True)
    ap.add_argument("--grid", default="40,36,20")
    ap.add_argument("--domain", type=int, default=1)
    ap.add_argument("--set", action="append", default=[])
    ap.add_argument("--range", action="append", default=[])
    ap.add_argument("--shape", action="append", default=[])
    ap.add_argument("--use", action="append", default=[])
    a = ap.parse_args()
    nx, ny, nz = [int(x) for x in a.grid.split(",")]
    sets = dict(x.split("=", 1) for x in a.set)
    sets = {k.lower(): v for k, v in sets.items()}
    ranges = {}
    for x in a.range:
        k, v = x.split("=", 1)
        lo, hi = v.split(":")
        ranges[k.lower()] = (float(lo), float(hi))
    shapes = {k.lower(): v for k, v in (x.split("=", 1) for x in a.shape)}
    module, dummies, info = parse(a.file, a.routine)
    r = a.routine.lower()

    decl, init, fills, outs, maps, notes = [], [], [], [], [], []
    dims = {"ids": "1", "ide": str(nx), "jds": "1", "jde": str(ny), "kds": "1", "kde": str(nz),
            "ims": "-4", "ime": str(nx + 5), "jms": "-4", "jme": str(ny + 5), "kms": "1", "kme": str(nz),
            "ips": "1", "ipe": str(nx), "jps": "1", "jpe": str(ny), "kps": "1", "kpe": str(nz),
            "its": "1", "ite": str(nx), "jts": "1", "jte": str(ny), "kts": "1", "kte": str(nz)}
    config = None
    for d in dummies:
        x = info[d]
        k = kind_of(x["tspec"])
        shape = shapes.get(d, x["shape"])
        if k.startswith("t:"):
            if k[2:].lower() != "grid_config_rec_type":
                raise SystemExit(f"gen_harness: dummy {d} is TYPE({k[2:]}): not supported (use t_ab.sh on W-20)")
            decl.append(f"   TYPE(grid_config_rec_type) :: {pre(d)}")
            config = pre(d)
            continue
        if k == "?":
            raise SystemExit(f"gen_harness: dummy {d}: unknown type {x['tspec']}")
        if shape is not None:
            parts = split_top(shape)
            if any(p.strip() in ("*", ":") or p.strip().endswith(":") for p in parts):
                raise SystemExit(f"gen_harness: dummy {d} has assumed shape/size ({shape}): give --shape {d}=lo:hi,...")
            rank = len(parts)
            base = {"r4": "REAL(4)", "r8": "REAL(8)", "i4": "INTEGER(4)", "i8": "INTEGER(8)", "l": "LOGICAL",
                    "c": "CHARACTER(LEN=64)"}[k]
            if k == "c":
                raise SystemExit(f"gen_harness: CHARACTER array dummy {d} not supported")
            decl.append(f"   {base}, ALLOCATABLE :: {pre(d)}({','.join([':'] * rank)})")
            init.append(("alloc", f"   ALLOCATE({pre(d)}({pre_expr(shape, info)}))"))
            maps.append(pre(d))
            seed = sum((i + 1) * ord(c) for i, c in enumerate(d)) + 7919
            out = x["intent"] in ("out",)
            if k in ("r4", "r8"):
                if out:
                    fills.append(f"   {pre(d)} = -9999.5")
                else:
                    lo, hi = ranges.get(d, (-4.0, 4.0) if SYM.match(d) else (0.5, 4.0))
                    s, e0, e1 = exps(lo, hi)
                    fills.append(f"   CALL hfill_{k}({pre(d)}, SIZE({pre(d)}), {seed}_8, {s}, {e0}, {e1})")
            elif k in ("i4", "i8"):
                if out:
                    fills.append(f"   {pre(d)} = -99")
                else:
                    lo, hi = ranges.get(d, (0, 3))
                    fills.append(f"   CALL hfill_int({pre(d)}, SIZE({pre(d)}), {seed}_8, {int(lo)}, {int(hi)})")
            elif k == "l":
                fills.append(f"   {pre(d)} = .FALSE." if out else f"   CALL hfill_log({pre(d)}, SIZE({pre(d)}), {seed}_8)")
            if x["intent"] != "in":
                outs.append((d, k, rank, True))
        else:
            base = {"r4": "REAL(4)", "r8": "REAL(8)", "i4": "INTEGER(4)", "i8": "INTEGER(8)", "l": "LOGICAL",
                    "c": "CHARACTER(LEN=256)"}[k]
            decl.append(f"   {base} :: {pre(d)}")
            if d in sets:
                val = sets[d]
            elif d in dims:
                val = dims[d]
            elif k in ("i4", "i8"):
                val = "1"
                notes.append(f"{d}=1 (INTEGER default)")
            elif k in ("r4", "r8"):
                val = "0.75"
                notes.append(f"{d}=0.75 (REAL default)")
            elif k == "l":
                val = ".FALSE."
                notes.append(f"{d}=.FALSE. (LOGICAL default)")
            else:
                val = "' '"
                notes.append(f"{d}=' ' (CHARACTER default)")
            init.append(("scalar", f"   {pre(d)} = {pre_expr(val, info)}"))
            if x["intent"] not in ("in",) and k != "c":
                outs.append((d, k, 0, False))
    uses = [f"   USE {module}, ONLY : {r}"] if module else []
    uses += ["   USE module_configure, ONLY : grid_config_rec_type, model_config_rec, model_to_grid_config_rec, "
             "initial_config",
             "   USE module_gpu_route, ONLY : gpu_route_init",
             "   USE module_wrf_top, ONLY : set_derived_rconfigs",
             "   USE module_check_a_mundo, ONLY : setup_physics_suite, check_nml_consistency, set_physics_rconfigs",
             "   USE module_utility, ONLY : WRFU_Initialize, WRFU_CAL_GREGORIAN",
             "   USE module_state_description",
             "   USE module_model_constants"] + [f"   USE {u}" for u in a.use]
    ext = [] if module else [f"   EXTERNAL {r}"]
    out = []
    w = out.append
    w(f"! generated by port/h100/gen_harness.py for {r} in {os.path.relpath(a.file)} (mode {a.mode})")
    w(f"PROGRAM harness_{r}"[:63])
    out.extend(uses)
    w("   IMPLICIT NONE")
    out.extend(ext)
    out.extend(decl)
    if config is None:
        w("   TYPE(grid_config_rec_type) :: h_config_flags")
    w("   INTEGER :: hu")
    w("   CALL init_modules(1)")
    w("   CALL WRFU_Initialize(defaultCalKind=WRFU_CAL_GREGORIAN)")
    w("   CALL init_modules(2)")
    w("   CALL gpu_route_init()")
    w("   CALL initial_config")
    w("   CALL setup_physics_suite")
    w("   CALL set_derived_rconfigs")
    w("   CALL check_nml_consistency")
    w("   CALL set_physics_rconfigs")
    w(f"   CALL model_to_grid_config_rec({a.domain}, model_config_rec, {config or 'h_config_flags'})")
    for kind, l in init:
        if kind == "scalar":
            w(l)
    for kind, l in init:
        if kind == "alloc":
            w(l)
    out.extend(fills)
    for n in notes:
        w(f"   PRINT '(a)', 'harness default: {n}'")
    def omp_list(head, names):
        chunks = [", ".join(names[i:i + 6]) for i in range(0, len(names), 6)]
        return f"!$omp {head}(" + ", &\n!$omp& ".join(chunks) + ")"

    if a.mode == "gpu" and maps:
        w(omp_list("target enter data map(alloc:", maps).replace("(alloc:(", "(alloc: "))
    args = [pre(d) for d in dummies]
    w(f"   CALL {r}( &\n        " + ", &\n        ".join(args) + " )")
    if a.mode == "gpu" and maps:
        w(omp_list("target exit data map(delete:", maps).replace("(delete:(", "(delete: "))
    w("   OPEN (NEWUNIT=hu, FILE='harness_out.bin', ACCESS='STREAM', FORM='UNFORMATTED', STATUS='REPLACE')")
    for d, k, rank, isarr in outs:
        if isarr:
            w(f"   CALL hdump_{k}(hu, '{d}', {pre(d)}, SIZE({pre(d)}), {rank}, LBOUND({pre(d)}), UBOUND({pre(d)}))")
        else:
            w(f"   CALL hdump_{k}(hu, '{d}', (/ {pre(d)} /), 1, 0, (/ 1 /), (/ 1 /))")
    w("   CLOSE (hu)")
    w(f"   PRINT '(a,i0,a)', 'harness: {r} done, ', {len(outs)}, ' outputs in harness_out.bin'")
    w("   CALL wrf_shutdown")
    w("CONTAINS")
    out.extend(HELPERS.split("\n"))
    w(f"END PROGRAM harness_{r}"[:67])
    print("\n".join(out))
    for n in notes:
        print(f"note: {n}", file=sys.stderr)
    return 0


HELPERS = """
   ! random values built from bits: sign * 2**e * (1 + f), identical in every build
   SUBROUTINE hnext(s)
      INTEGER(8), INTENT(INOUT) :: s
      s = IEOR(s, ISHFT(s, 13))
      s = IEOR(s, ISHFT(s, -7))
      s = IEOR(s, ISHFT(s, 17))
   END SUBROUTINE hnext
   SUBROUTINE hfill_r4(a, n, seed, sym, e0, e1)
      INTEGER, INTENT(IN) :: n, sym, e0, e1
      REAL(4), INTENT(OUT) :: a(n)
      INTEGER(8), INTENT(IN) :: seed
      INTEGER(8) :: s
      INTEGER(4) :: b, e, sg
      INTEGER :: i
      s = seed
      DO i = 1, n
         CALL hnext(s)
         e = e0 + INT(MOD(IAND(ISHFT(s, -40), 65535_8), INT(e1 - e0 + 1, 8)))
         sg = 0
         IF (sym == 1 .AND. BTEST(s, 50)) sg = 1
         b = IOR(ISHFT(sg, 31), IOR(ISHFT(127 + e, 23), INT(IAND(s, 8388607_8), 4)))
         a(i) = TRANSFER(b, a(i))
      END DO
   END SUBROUTINE hfill_r4
   SUBROUTINE hfill_r8(a, n, seed, sym, e0, e1)
      INTEGER, INTENT(IN) :: n, sym, e0, e1
      REAL(8), INTENT(OUT) :: a(n)
      INTEGER(8), INTENT(IN) :: seed
      INTEGER(8) :: s, b, e, sg
      INTEGER :: i
      s = seed
      DO i = 1, n
         CALL hnext(s)
         e = e0 + MOD(IAND(ISHFT(s, -40), 65535_8), INT(e1 - e0 + 1, 8))
         sg = 0
         IF (sym == 1 .AND. BTEST(s, 58)) sg = 1
         CALL hnext(s)
         b = IOR(ISHFT(sg, 63), IOR(ISHFT(1023_8 + e, 52), IAND(s, 4503599627370495_8)))
         a(i) = TRANSFER(b, a(i))
      END DO
   END SUBROUTINE hfill_r8
   SUBROUTINE hfill_int(a, n, seed, lo, hi)
      INTEGER, INTENT(IN) :: n, lo, hi
      INTEGER, INTENT(OUT) :: a(n)
      INTEGER(8), INTENT(IN) :: seed
      INTEGER(8) :: s
      INTEGER :: i
      s = seed
      DO i = 1, n
         CALL hnext(s)
         a(i) = lo + INT(MOD(IAND(s, 1048575_8), INT(hi - lo + 1, 8)))
      END DO
   END SUBROUTINE hfill_int
   SUBROUTINE hfill_log(a, n, seed)
      INTEGER, INTENT(IN) :: n
      LOGICAL, INTENT(OUT) :: a(n)
      INTEGER(8), INTENT(IN) :: seed
      INTEGER(8) :: s
      INTEGER :: i
      s = seed
      DO i = 1, n
         CALL hnext(s)
         a(i) = BTEST(s, 20)
      END DO
   END SUBROUTINE hfill_log
   ! record: name(32) kind(4) rank lb(4) ub(4) nbytes data
   SUBROUTINE hhead(u, nm, kd, n, nb, rank, lb, ub)
      INTEGER, INTENT(IN) :: u, n, nb, rank, lb(:), ub(:)
      CHARACTER(LEN=*), INTENT(IN) :: nm, kd
      CHARACTER(LEN=32) :: c32
      CHARACTER(LEN=4) :: c4
      INTEGER :: l4(4), u4(4), r
      c32 = nm
      c4 = kd
      l4 = 1
      u4 = 1
      DO r = 1, MIN(rank, 4)
         l4(r) = lb(r)
         u4(r) = ub(r)
      END DO
      WRITE (u) c32, c4, rank, l4, u4, INT(n, 8) * nb
   END SUBROUTINE hhead
   SUBROUTINE hdump_r4(u, nm, a, n, rank, lb, ub)
      INTEGER, INTENT(IN) :: u, n, rank, lb(:), ub(:)
      CHARACTER(LEN=*), INTENT(IN) :: nm
      REAL(4), INTENT(IN) :: a(n)
      CALL hhead(u, nm, 'r4', n, 4, rank, lb, ub)
      WRITE (u) a
   END SUBROUTINE hdump_r4
   SUBROUTINE hdump_r8(u, nm, a, n, rank, lb, ub)
      INTEGER, INTENT(IN) :: u, n, rank, lb(:), ub(:)
      CHARACTER(LEN=*), INTENT(IN) :: nm
      REAL(8), INTENT(IN) :: a(n)
      CALL hhead(u, nm, 'r8', n, 8, rank, lb, ub)
      WRITE (u) a
   END SUBROUTINE hdump_r8
   SUBROUTINE hdump_i4(u, nm, a, n, rank, lb, ub)
      INTEGER, INTENT(IN) :: u, n, rank, lb(:), ub(:)
      CHARACTER(LEN=*), INTENT(IN) :: nm
      INTEGER(4), INTENT(IN) :: a(n)
      CALL hhead(u, nm, 'i4', n, 4, rank, lb, ub)
      WRITE (u) a
   END SUBROUTINE hdump_i4
   SUBROUTINE hdump_i8(u, nm, a, n, rank, lb, ub)
      INTEGER, INTENT(IN) :: u, n, rank, lb(:), ub(:)
      CHARACTER(LEN=*), INTENT(IN) :: nm
      INTEGER(8), INTENT(IN) :: a(n)
      CALL hhead(u, nm, 'i8', n, 8, rank, lb, ub)
      WRITE (u) a
   END SUBROUTINE hdump_i8
   SUBROUTINE hdump_l(u, nm, a, n, rank, lb, ub)
      INTEGER, INTENT(IN) :: u, n, rank, lb(:), ub(:)
      CHARACTER(LEN=*), INTENT(IN) :: nm
      LOGICAL, INTENT(IN) :: a(n)
      INTEGER(4) :: v(n)
      v = MERGE(1, 0, a)
      CALL hhead(u, nm, 'l', n, 4, rank, lb, ub)
      WRITE (u) v
   END SUBROUTINE hdump_l"""

if __name__ == "__main__":
    sys.exit(main())
