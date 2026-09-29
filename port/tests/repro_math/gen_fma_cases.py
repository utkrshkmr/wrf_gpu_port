#!/usr/bin/env python3
"""Write fma_cases.bin for t_fma (plan.md T-FMA).

Each record is four little-endian 32-bit words: bits of a, b, c and of the
unfused REAL(4) result round(round(a*b) + c).  All records are chosen so the
fused result round(a*b + c) differs from the unfused one (checked exactly with
rational arithmetic).  The first record is the tie case a = b = 1+2**-12,
c = -1.

Usage: gen_fma_cases.py [-n 1000000] [-o fma_cases.bin]
"""

import argparse
from fractions import Fraction

import numpy as np


def fused(a, b, c):
    """Correctly rounded float32 of the exact a*b+c (via exact rationals)."""
    exact = Fraction(float(a)) * Fraction(float(b)) + Fraction(float(c))
    # round to float32: start from the double nearest the exact value, then fix
    # the float32 rounding by comparing with the neighbours exactly
    d = float(exact)
    cand = np.float32(d)
    best = None
    for x in (np.nextafter(cand, np.float32(-np.inf)), cand, np.nextafter(cand, np.float32(np.inf))):
        if not np.isfinite(x):
            continue
        err = abs(Fraction(float(x)) - exact)
        if best is None or err < best[0] or (err == best[0] and (int(x.view(np.uint32)) & 1) == 0):
            best = (err, x)
    return best[1]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-n", type=int, default=1_000_000)
    ap.add_argument("-o", default="fma_cases.bin")
    ap.add_argument("--seed", type=int, default=7)
    args = ap.parse_args()
    rng = np.random.default_rng(args.seed)

    a0 = np.float32(1 + 2.0**-12)
    recs = [(a0, a0, np.float32(-1.0))]
    while len(recs) < args.n:
        m = 200_000
        a = rng.uniform(0.5, 2.0, m).astype(np.float32) * np.float32(2.0) ** rng.integers(-20, 20, m).astype(np.float32)
        b = rng.uniform(0.5, 2.0, m).astype(np.float32) * np.where(rng.integers(0, 2, m) == 1, 1, -1).astype(np.float32)
        prod = (a.astype(np.float64) * b.astype(np.float64))  # exact
        # c close to -a*b so that the rounding of a*b matters
        c = (-prod * (1 + rng.uniform(-1e-3, 1e-3, m))).astype(np.float32)
        unf = (a * b).astype(np.float32) + c
        est = (prod + c.astype(np.float64)).astype(np.float32)
        pick = np.nonzero(unf != est)[0]
        for i in pick:
            if fused(a[i], b[i], c[i]) != unf[i]:
                recs.append((a[i], b[i], c[i]))
                if len(recs) >= args.n:
                    break
    arr = np.array([[r[0], r[1], r[2], np.float32(r[0] * r[1]) + r[2]] for r in recs], np.float32)
    with open(args.o, "wb") as f:
        np.array([arr.shape[0]], np.int64).tofile(f)
        arr.view(np.uint32).tofile(f)
    print(f"wrote {arr.shape[0]} records to {args.o}")
    print("tie case: unfused %08x" % arr[0, 3].view(np.uint32))


if __name__ == "__main__":
    main()
