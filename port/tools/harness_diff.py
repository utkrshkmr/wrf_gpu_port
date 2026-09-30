#!/usr/bin/env python3
"""Compare two outputs of the per-routine harness (port/h100/harness.sh)
bit for bit.  LOCKED (the comparison of the fast checks).

Each file holds records  name(32) kind(4) rank lb(4) ub(4) nbytes data  as
written by the generated driver (port/h100/gen_harness.py).  For every output
it prints the number of values whose bits differ and the first differing
index; both values NaN counts as equal but is reported (random inputs can
produce NaN, whose payload may differ between host and device).

  harness_diff.py A/harness_out.bin B/harness_out.bin [--label TEXT]
Exit status 0 if every output is bit-identical (NaN = NaN allowed).
"""
import argparse
import math
import struct
import sys

FMT = {"r4": ("f", "I", 4), "r8": ("d", "Q", 8), "i4": ("i", "I", 4), "i8": ("q", "Q", 8), "l": ("i", "I", 4)}


def read(path):
    """-> (order, {name: (kind, rank, lb, ub, body, endian)}).  WRF builds write unformatted
    files big-endian (-byteswapio, -fconvert=big-endian); the byte order is detected."""
    out = {}
    order = []
    data = open(path, "rb").read()
    e = "<"
    if len(data) >= 80:
        ok = {c: 0 <= struct.unpack_from(c + "i", data, 36)[0] <= 7
              and 0 <= struct.unpack_from(c + "q", data, 72)[0] <= len(data) - 80 for c in "<>"}
        e = "<" if ok["<"] else ">"
    p = 0
    while p < len(data):
        name = data[p:p + 32].decode().strip()
        kind = data[p + 32:p + 36].decode().strip()
        rank, = struct.unpack_from(e + "i", data, p + 36)
        lb = struct.unpack_from(e + "4i", data, p + 40)
        ub = struct.unpack_from(e + "4i", data, p + 56)
        nb, = struct.unpack_from(e + "q", data, p + 72)
        body = data[p + 80:p + 80 + nb]
        p += 80 + nb
        out[name] = (kind, rank, lb, ub, body, e)
        order.append(name)
    return order, out


def index_of(flat, rank, lb, ub):
    idx = []
    for r in range(max(rank, 1)):
        ext = ub[r] - lb[r] + 1
        idx.append(lb[r] + flat % ext)
        flat //= ext
    return "(" + ",".join(str(i) for i in idx) + ")"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("--label", default="")
    args = ap.parse_args()
    oa, a = read(args.a)
    ob, b = read(args.b)
    bad = 0
    print(f"== harness_diff {args.label}".rstrip())
    if oa != ob:
        print(f"   different outputs: A {oa} / B {ob}")
        bad += 1
    for name in oa:
        if name not in b:
            continue
        ka, ra, la, ua, da, ea = a[name]
        kb, rb, lb, ub, db, eb = b[name]
        if ea != eb:
            db = b"".join(db[i:i + FMT[kb][2]][::-1] for i in range(0, len(db), FMT[kb][2]))
        if (ka, ra, la, ua, len(da)) != (kb, rb, lb, ub, len(db)):
            print(f"   {name:16s} different shape or kind")
            bad += 1
            continue
        vf, uf, sz = FMT[ka]
        n = len(da) // sz
        va = struct.unpack(f"{ea}{n}{uf}", da)
        vb = struct.unpack(f"{ea}{n}{uf}", db)
        diff = [i for i in range(n) if va[i] != vb[i]]
        nan_eq = 0
        real_diff = []
        if diff and ka in ("r4", "r8"):
            fa = struct.unpack(f"{ea}{n}{vf}", da)
            fb = struct.unpack(f"{ea}{n}{vf}", db)
            for i in diff:
                if math.isnan(fa[i]) and math.isnan(fb[i]):
                    nan_eq += 1
                else:
                    real_diff.append(i)
        else:
            real_diff = diff
        if real_diff:
            i = real_diff[0]
            extra = ""
            if ka in ("r4", "r8"):
                fa = struct.unpack_from(f"{ea}{vf}", da, i * sz)[0]
                fb = struct.unpack_from(f"{ea}{vf}", db, i * sz)[0]
                extra = f"  A={fa!r} B={fb!r}"
            print(f"   {name:16s} DIFFERENT: {len(real_diff)} of {n} values, first at "
                  f"{index_of(i, ra, la, ua)}{extra}")
            bad += 1
        else:
            note = f"  ({nan_eq} NaN in both with different bits)" if nan_eq else ""
            print(f"   {name:16s} identical ({n} values){note}")
        if ka in ("r4", "r8") and n:
            nn = sum(1 for x in struct.unpack(f"{ea}{n}{vf}", da) if x != x)
            if nn > n // 100:
                print(f"   {'':16s} warning: {nn} of {n} values are NaN: the random inputs do not exercise this output"
                      f" well; give physical ranges (harness.sh --range name=lo:hi) for the inputs it depends on")
    print(f"   RESULT: {'IDENTICAL' if not bad else 'DIFFERENT'}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
