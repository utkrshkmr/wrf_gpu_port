#!/usr/bin/env python3
"""Host accuracy test for WRF/frame/module_repro_math.F (plan.md T-RM-ACC).

Builds the module (with -DREPRO_MATH) and rm_capi.F90 into a shared library,
calls it through ctypes and checks the results:

  REAL(4) functions : against the correctly rounded result.  The reference is
      glibc's double function rounded to float; wherever it disagrees with
      ours, mpmath (high precision) decides which one is correctly rounded.
  REAL(8) functions : against glibc double; differences of more than 1 ulp are
      checked with mpmath (fdlibm guarantees < 1 ulp).
  rp_mod            : bit-exact against C fmod (fmod is exact).
  special values    : +-0, +-inf, NaN, subnormals, +-1, domain edges, same
      results as C99 (numpy), NaN results must be the canonical NaN.

Modes:
  --quick        sampled float inputs (a few minutes on 4 cores)
  --exhaustive   all 2**32 float inputs for every 1-argument function

The device side (host vs GPU bit equality) is tested separately by
t_rm_exh.F90 on the GPU nodes; together they give T-RM-ACC for both.
"""

import argparse
import ctypes
import os
import subprocess
import sys
import time

import numpy as np
import mpmath

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
MODULE_SRC = os.path.join(REPO, "WRF", "frame", "module_repro_math.F")

F1 = {1: "exp", 2: "log", 3: "log10", 4: "sin", 5: "cos", 6: "tan", 7: "asin", 8: "acos",
      9: "atan", 10: "sinh", 11: "cosh", 12: "tanh"}
F2 = {13: "atan2", 14: "pow", 15: "mod"}
NP = {"exp": np.exp, "log": np.log, "log10": np.log10, "sin": np.sin, "cos": np.cos, "tan": np.tan,
      "asin": np.arcsin, "acos": np.arccos, "atan": np.arctan, "sinh": np.sinh, "cosh": np.cosh,
      "tanh": np.tanh, "atan2": np.arctan2, "pow": np.power, "mod": np.fmod}
MP = {"exp": mpmath.exp, "log": mpmath.log, "log10": mpmath.log10, "sin": mpmath.sin,
      "cos": mpmath.cos, "tan": mpmath.tan, "asin": mpmath.asin, "acos": mpmath.acos,
      "atan": mpmath.atan, "sinh": mpmath.sinh, "cosh": mpmath.cosh, "tanh": mpmath.tanh,
      "atan2": mpmath.atan2, "pow": mpmath.power}
FID = {v: k for k, v in list(F1.items()) + list(F2.items())}

# Error bounds of the fdlibm double algorithms (ulp): < 1 for the core
# functions; fdlibm documents larger bounds for log10, sinh, cosh and tanh.
R8_BOUND = {"log10": 2.5, "sinh": 2.5, "cosh": 2.5, "tanh": 2.5}

NAN4 = np.uint32(0x7FC00000)
NAN8 = np.uint64(0x7FF8000000000000)


# ----------------------------------------------------------------------------
# build and load
# ----------------------------------------------------------------------------

def build(workdir, fc, fflags):
    os.makedirs(workdir, exist_ok=True)
    f90 = os.path.join(workdir, "module_repro_math.f90")
    with open(f90, "w") as out:
        subprocess.check_call(["cpp", "-P", "-traditional-cpp", "-DREPRO_MATH", MODULE_SRC], stdout=out)
    lib = os.path.join(workdir, "librm.so")
    cmd = [fc] + fflags.split() + ["-fPIC", "-shared", "-J", workdir, "-o", lib, f90,
                                   os.path.join(HERE, "rm_capi.F90")]
    print("build:", " ".join(cmd))
    subprocess.check_call(cmd)
    return lib


class Lib:
    def __init__(self, path):
        self.l = ctypes.CDLL(path)
        f32p = np.ctypeslib.ndpointer(np.float32, flags="C_CONTIGUOUS")
        f64p = np.ctypeslib.ndpointer(np.float64, flags="C_CONTIGUOUS")
        self.l.rm_eval_r4.argtypes = [ctypes.c_int, ctypes.c_int64, f32p, f32p, f32p]
        self.l.rm_eval_r8.argtypes = [ctypes.c_int, ctypes.c_int64, f64p, f64p, f64p]
        self.l.rm_sweep_r4.argtypes = [ctypes.c_int, ctypes.c_int64, ctypes.c_int64, f32p]

    def r4(self, name, a, b=None):
        a = np.ascontiguousarray(a, np.float32)
        b = np.zeros_like(a) if b is None else np.ascontiguousarray(b, np.float32)
        out = np.empty_like(a)
        self.l.rm_eval_r4(FID[name], a.size, a, b, out)
        return out

    def r8(self, name, a, b=None):
        a = np.ascontiguousarray(a, np.float64)
        b = np.zeros_like(a) if b is None else np.ascontiguousarray(b, np.float64)
        out = np.empty_like(a)
        self.l.rm_eval_r8(FID[name], a.size, a, b, out)
        return out

    def sweep(self, name, lo, hi):
        out = np.empty(hi - lo + 1, np.float32)
        self.l.rm_sweep_r4(FID[name], lo, hi, out)
        return out


# ----------------------------------------------------------------------------
# reference helpers
# ----------------------------------------------------------------------------

def same_bits(x, y):
    """Bitwise equality, with every NaN treated as equal (NaN bits checked separately)."""
    if x.dtype == np.float32:
        xb, yb = x.view(np.uint32), y.view(np.uint32)
    else:
        xb, yb = x.view(np.uint64), y.view(np.uint64)
    return (xb == yb) | (np.isnan(x) & np.isnan(y))


def ulp_distance_gt1(a, b):
    """True where finite doubles a and b are more than 1 ulp apart."""
    ia = a.view(np.int64)
    ib = b.view(np.int64)
    mag_a = ia & np.int64(0x7FFFFFFFFFFFFFFF)
    mag_b = ib & np.int64(0x7FFFFFFFFFFFFFFF)
    same_sign = (ia < 0) == (ib < 0)
    d_same = np.abs(mag_a - mag_b)             # no overflow: both in [0, 2**63)
    far_same = same_sign & (d_same > 1)
    # opposite signs: distance is mag_a + mag_b (through zero)
    far_opp = (~same_sign) & ((mag_a > 1) | (mag_b > 1) | (mag_a + mag_b > 1))
    return far_same | far_opp


def ref_value(name, args, prec):
    with mpmath.workprec(prec):
        mps = [mpmath.mpf(float(a)) for a in args]
        try:
            if name == "pow":
                x, y = mps
                if x == 0 and y < 0:
                    return None
                if x < 0 and y != mpmath.floor(y):
                    return None
                return mpmath.power(x, y)
            if name in ("log", "log10") and mps[0] <= 0:
                return None
            if name in ("asin", "acos") and abs(mps[0]) > 1:
                return None
            return MP[name](*mps)
        except (ValueError, ZeroDivisionError, OverflowError):
            return None


def correctly_rounded(v, dtype):
    """Correctly rounded (nearest-even) dtype value of the mpf v."""
    info = np.finfo(dtype)
    if v is None:
        return dtype(np.nan)
    if mpmath.isinf(v):
        return dtype(np.inf) if v > 0 else dtype(-np.inf)
    if v == 0:
        return dtype(0.0)
    with np.errstate(all="ignore"):
        c = dtype(float(v))
    if np.isinf(c):
        # overflow threshold: max + half ulp
        m = mpmath.mpf(float(info.max))
        half = mpmath.mpf(2) ** (info.maxexp - info.nmant - 2)
        if abs(v) < m + half:
            return dtype(info.max) if v > 0 else dtype(-info.max)
        return c
    cands = [np.nextafter(c, dtype(-np.inf)), c, np.nextafter(c, dtype(np.inf))]
    best, bestd = None, None
    for cand in cands:
        if np.isinf(cand):
            continue
        d = abs(mpmath.mpf(float(cand)) - v)
        if bestd is None or d < bestd:
            best, bestd = cand, d
        elif d == bestd:
            ib = best.view(np.uint32 if dtype == np.float32 else np.uint64)
            if int(ib) & 1:
                best = cand
    return best


def ulp_error(ours, v, dtype):
    """|ours - v| in ulps of the binade of v."""
    if v is None or mpmath.isinf(v) or np.isnan(ours) or np.isinf(ours):
        return 0.0 if (v is None and np.isnan(ours)) else float("inf")
    info = np.finfo(dtype)
    if v == 0:
        return 0.0 if ours == 0 else float("inf")
    e = max(int(mpmath.floor(mpmath.log(abs(v), 2))), info.minexp)
    ulp = mpmath.mpf(2) ** (e - info.nmant)
    return float(abs(mpmath.mpf(float(ours)) - v) / ulp)


# ----------------------------------------------------------------------------
# checks
# ----------------------------------------------------------------------------

class Report:
    def __init__(self):
        self.rows = []
        self.fail = False

    def add(self, **kw):
        self.rows.append(kw)
        if not kw.get("ok", True):
            self.fail = True
        print("  " + "  ".join(f"{k}={v}" for k, v in kw.items()), flush=True)


def check_nan_bits(out, rep, label):
    if out.dtype == np.float32:
        bad = np.isnan(out) & (out.view(np.uint32) != NAN4)
    else:
        bad = np.isnan(out) & (out.view(np.uint64) != NAN8)
    n = int(bad.sum())
    if n:
        rep.add(test=label + " canonical-NaN", ok=False, noncanonical=n)
    return n


def compare_r4(name, args, ours, rep, label, max_mp=20000):
    with np.errstate(all="ignore"):
        a64 = [np.asarray(a, np.float64) for a in args]
        ref = NP[name](*a64).astype(np.float32)
    eq = same_bits(ours, ref)
    check_nan_bits(ours, rep, label)
    idx = np.nonzero(~eq)[0]
    n_ours_bad = 0
    n_ref_bad = 0
    worst = 0.0
    worst_arg = None
    for i in idx[:max_mp]:
        argv = [args[k][i] for k in range(len(args))]
        v = ref_value(name, argv, 200)
        cr = correctly_rounded(v, np.float32)
        o = ours[i]
        if not same_bits(np.array([o]), np.array([cr]))[0]:
            n_ours_bad += 1
            err = ulp_error(o, v, np.float32)
            if err > worst:
                worst, worst_arg = err, [float(x) for x in argv]
        if not same_bits(np.array([ref[i]]), np.array([cr]))[0]:
            n_ref_bad += 1
    ok = worst <= 0.5000001 or (worst < 0.51)
    rep.add(test=label, fn=name, n=int(ours.size), differ_from_glibc=int(idx.size),
            ours_not_correctly_rounded=n_ours_bad, glibc_not_cr=n_ref_bad,
            max_ulp=round(worst, 4), worst_arg=worst_arg, checked=min(idx.size, max_mp), ok=ok)


def compare_r8(name, args, ours, rep, label, max_mp=5000):
    with np.errstate(all="ignore"):
        ref = NP[name](*[np.asarray(a, np.float64) for a in args])
    eq = same_bits(ours, ref)
    check_nan_bits(ours, rep, label)
    idx = np.nonzero(~eq)[0]
    # ulp distance to glibc
    both = np.isfinite(ours) & np.isfinite(ref)
    sel = idx[both[idx]]
    far = list(sel[ulp_distance_gt1(ours[sel], ref[sel])])
    nonfinite_mismatch = list(idx[~both[idx]])
    worst = 0.0
    worst_arg = None
    for i in (far + nonfinite_mismatch)[:max_mp]:
        argv = [args[k][i] for k in range(len(args))]
        v = ref_value(name, argv, 300)
        err = ulp_error(ours[i], v, np.float64)
        if err > worst:
            worst, worst_arg = err, [float(x) for x in argv]
    bound = R8_BOUND.get(name, 1.0)
    ok = worst < bound
    rep.add(test=label, fn=name, n=int(ours.size), bound_ulp=bound, differ_from_glibc=int(idx.size),
            over_1ulp_from_glibc=len(far), nonfinite_mismatch=len(nonfinite_mismatch),
            max_ulp_vs_exact=round(worst, 4), worst_arg=worst_arg, ok=ok)


def float_specials():
    s = [0.0, -0.0, np.inf, -np.inf, np.nan, 1.0, -1.0, 0.5, -0.5, 2.0, -2.0, 1e-45, -1e-45,
         1.17549435e-38, -1.17549435e-38, 3.4028235e38, -3.4028235e38, 88.72, 88.73, -103.97,
         -87.3, 1.5707964, -1.5707964, 3.1415927, 1e10, -1e10, 1e30, 0.9999999, 1.0000001]
    return np.array(s, np.float32)


def double_specials():
    s = [0.0, -0.0, np.inf, -np.inf, np.nan, 1.0, -1.0, 0.5, -0.5, 2.0, -2.0, 5e-324, -5e-324,
         2.2250738585072014e-308, 1.7976931348623157e308, -1.7976931348623157e308,
         709.782712893384, 709.79, -745.13, -745.14, 1.5707963267948966, 3.141592653589793,
         1e22, 1e300, -1e300, 0.9999999999999999, 1.0000000000000002, 710.4758600739439, 22.0]
    return np.array(s, np.float64)


def run_one_arg(lib, rep, quick, rng):
    for name in F1.values():
        t0 = time.time()
        # float32: random bit patterns plus domain-focused samples
        n = 2_000_000 if quick else 20_000_000
        bits = rng.integers(0, 2**32, size=n, dtype=np.uint64).astype(np.uint32)
        x = bits.view(np.float32)
        focus = {
            "exp": rng.uniform(-104, 89, n), "log": np.exp(rng.uniform(-100, 88, n)),
            "log10": np.exp(rng.uniform(-100, 88, n)), "sin": rng.uniform(-10, 10, n),
            "cos": rng.uniform(-10, 10, n), "tan": rng.uniform(-10, 10, n),
            "asin": rng.uniform(-1, 1, n), "acos": rng.uniform(-1, 1, n),
            "atan": rng.uniform(-50, 50, n), "sinh": rng.uniform(-90, 90, n),
            "cosh": rng.uniform(-90, 90, n), "tanh": rng.uniform(-10, 10, n)}[name]
        x = np.concatenate([x, focus.astype(np.float32), float_specials()])
        compare_r4(name, [x], lib.r4(name, x), rep, "r4-sample")
        # float64
        m = 200_000 if quick else 2_000_000
        xb = rng.integers(0, 2**63, size=m, dtype=np.uint64) | (rng.integers(0, 2, size=m, dtype=np.uint64) << np.uint64(63))
        xd = xb.view(np.float64)
        focus8 = {
            "exp": rng.uniform(-746, 710, m), "log": np.exp(rng.uniform(-700, 700, m)),
            "log10": np.exp(rng.uniform(-700, 700, m)), "sin": rng.uniform(-1e6, 1e6, m),
            "cos": rng.uniform(-1e6, 1e6, m), "tan": rng.uniform(-1e6, 1e6, m),
            "asin": rng.uniform(-1, 1, m), "acos": rng.uniform(-1, 1, m),
            "atan": rng.uniform(-100, 100, m), "sinh": rng.uniform(-711, 711, m),
            "cosh": rng.uniform(-711, 711, m), "tanh": rng.uniform(-20, 20, m)}[name]
        xd = np.concatenate([xd, focus8, rng.uniform(-10, 10, m), double_specials()])
        compare_r8(name, [xd], lib.r8(name, xd), rep, "r8-sample")
        print(f"  ({name}: {time.time() - t0:.1f} s)", flush=True)


def run_two_arg(lib, rep, quick, rng):
    n = 2_000_000 if quick else 20_000_000
    # atan2
    y = rng.uniform(-10, 10, n).astype(np.float32)
    x = rng.uniform(-10, 10, n).astype(np.float32)
    sp = float_specials()
    yy, xx = np.meshgrid(sp, sp)
    y = np.concatenate([y, yy.ravel()])
    x = np.concatenate([x, xx.ravel()])
    compare_r4("atan2", [y, x], lib.r4("atan2", y, x), rep, "r4-sample")
    yd = rng.uniform(-1e3, 1e3, n // 10)
    xd = rng.uniform(-1e3, 1e3, n // 10)
    spd = double_specials()
    yy, xx = np.meshgrid(spd, spd)
    yd = np.concatenate([yd, yy.ravel()])
    xd = np.concatenate([xd, xx.ravel()])
    compare_r8("atan2", [yd, xd], lib.r8("atan2", yd, xd), rep, "r8-sample")

    # pow: WRF-like exponents over positive bases, random pairs, negative bases with integer y
    exps = np.array([0.25, 0.33, 0.33333333, 1.0 / 3.0, 0.46, 0.49, 0.5, 0.635, 1.31, 1.33, 1.5,
                     7.0 / 3.0, 0.2857143, 0.28571428, 1.4, 1.40285, 0.712, 0.1, 0.16, 0.2, 0.75, 2.0,
                     2.5, 3.0, -0.3, -0.5, -1.0, -2.0, 0.19, 0.19026, 5.2559, 0.190284, 1.0 / 5.2559,
                     0.0001, 1.19, 1.5, 0.9, 1.1, 0.65, 0.6, 0.4, 0.3, 0.8, 1.6, 2.1, 4.0, 5.0, 10.0],
                    np.float32)
    base = np.exp(rng.uniform(np.log(1e-3), np.log(1e3), n // 20)).astype(np.float32)
    bx = np.repeat(base, exps.size)
    by = np.tile(exps, base.size)
    compare_r4("pow", [bx, by], lib.r4("pow", bx, by), rep, "r4-pow-wrf-exponents")
    px = np.exp(rng.uniform(-80, 80, n)).astype(np.float32)
    py = rng.uniform(-20, 20, n).astype(np.float32)
    nx = -np.exp(rng.uniform(-20, 20, n // 4)).astype(np.float32)
    ny = rng.integers(-30, 30, n // 4).astype(np.float32)
    ax = np.concatenate([px, nx, np.repeat(sp, sp.size)])
    ay = np.concatenate([py, ny, np.tile(sp, sp.size)])
    compare_r4("pow", [ax, ay], lib.r4("pow", ax, ay), rep, "r4-pow-random")
    dx = np.exp(rng.uniform(-700, 700, n // 10))
    dy = rng.uniform(-3, 3, n // 10)
    ex = np.exp(rng.uniform(-5, 5, n // 10))
    ey = rng.uniform(-100, 100, n // 10)
    ox = 1.0 + rng.uniform(-1e-6, 1e-6, n // 20)
    oy = rng.uniform(-1e9, 1e9, n // 20)
    gx = -np.exp(rng.uniform(-5, 5, n // 20))
    gy = rng.integers(-60, 60, n // 20).astype(np.float64)
    cx = np.concatenate([dx, ex, ox, gx, np.repeat(spd, spd.size)])
    cy = np.concatenate([dy, ey, oy, gy, np.tile(spd, spd.size)])
    compare_r8("pow", [cx, cy], lib.r8("pow", cx, cy), rep, "r8-pow-random")

    # mod: exact, must equal C fmod bit for bit
    ma = np.concatenate([rng.uniform(-1e4, 1e4, n), rng.uniform(0, 1e3, n), np.repeat(sp, sp.size)]).astype(np.float32)
    mb = np.concatenate([rng.uniform(-10, 10, n), np.ones(n), np.tile(sp, sp.size)]).astype(np.float32)
    ours = lib.r4("mod", ma, mb)
    with np.errstate(all="ignore"):
        ref = np.fmod(ma, mb)
    bad = int((~same_bits(ours, ref)).sum())
    check_nan_bits(ours, rep, "r4-mod")
    rep.add(test="r4-mod-exact", fn="mod", n=int(ma.size), differ_from_fmod=bad, ok=(bad == 0))
    da = np.concatenate([(rng.integers(0, 2**63, n // 10, dtype=np.uint64)).view(np.float64),
                         rng.uniform(-1e10, 1e10, n // 10), np.repeat(spd, spd.size)])
    db = np.concatenate([rng.uniform(-3, 3, n // 10) * np.exp(rng.uniform(-700, 700, n // 10)),
                         rng.uniform(-10, 10, n // 10), np.tile(spd, spd.size)])
    ours = lib.r8("mod", da, db)
    with np.errstate(all="ignore"):
        ref = np.fmod(da, db)
    bad = int((~same_bits(ours, ref)).sum())
    check_nan_bits(ours, rep, "r8-mod")
    rep.add(test="r8-mod-exact", fn="mod", n=int(da.size), differ_from_fmod=bad, ok=(bad == 0))


def run_exhaustive(lib, rep, chunk_bits=26, only=None):
    chunk = 1 << chunk_bits
    names = [n for n in F1.values() if only is None or n in only]
    for name in names:
        t0 = time.time()
        n_diff = n_bad = n_refbad = 0
        n_nan_bad = 0
        worst = 0.0
        worst_arg = None
        for lo in range(0, 1 << 32, chunk):
            hi = lo + chunk - 1
            ours = lib.sweep(name, lo, hi)
            x = np.arange(lo, hi + 1, dtype=np.uint64).astype(np.uint32).view(np.float32)
            with np.errstate(all="ignore"):
                ref = NP[name](x.astype(np.float64)).astype(np.float32)
            n_nan_bad += int((np.isnan(ours) & (ours.view(np.uint32) != NAN4)).sum())
            idx = np.nonzero(~same_bits(ours, ref))[0]
            n_diff += idx.size
            for i in idx:
                v = ref_value(name, [x[i]], 200)
                cr = correctly_rounded(v, np.float32)
                if not same_bits(np.array([ours[i]]), np.array([cr]))[0]:
                    n_bad += 1
                    err = ulp_error(ours[i], v, np.float32)
                    if err > worst:
                        worst, worst_arg = err, float(x[i])
                if not same_bits(np.array([ref[i]]), np.array([cr]))[0]:
                    n_refbad += 1
        ok = worst < 0.51 and n_nan_bad == 0
        rep.add(test="r4-exhaustive", fn=name, n=2**32, differ_from_glibc=n_diff,
                ours_not_correctly_rounded=n_bad, glibc_not_cr=n_refbad, max_ulp=round(worst, 4),
                worst_arg=worst_arg, noncanonical_nan=n_nan_bad, seconds=round(time.time() - t0), ok=ok)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--quick", action="store_true", help="sampled tests (default)")
    g.add_argument("--exhaustive", action="store_true", help="all 2**32 floats for 1-argument functions")
    ap.add_argument("--only", nargs="*", help="restrict the exhaustive sweep to these functions")
    ap.add_argument("--fc", default=os.environ.get("FC", "gfortran"))
    ap.add_argument("--fflags", default=os.environ.get("FFLAGS",
                    "-O2 -ffp-contract=off -fno-fast-math -ffree-line-length-none -fopenmp"))
    ap.add_argument("--workdir", default=os.path.join(os.environ.get("TMPDIR", "/tmp"), "repro_math_test"))
    ap.add_argument("--seed", type=int, default=20250108)
    args = ap.parse_args()

    lib = Lib(build(args.workdir, args.fc, args.fflags))
    rng = np.random.default_rng(args.seed)
    rep = Report()
    if args.exhaustive:
        run_exhaustive(lib, rep, only=args.only)
    else:
        run_one_arg(lib, rep, True, rng)
        run_two_arg(lib, rep, True, rng)
    print("RESULT:", "FAIL" if rep.fail else "PASS")
    return 1 if rep.fail else 0


if __name__ == "__main__":
    sys.exit(main())
