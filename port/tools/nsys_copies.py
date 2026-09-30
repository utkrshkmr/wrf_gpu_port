#!/usr/bin/env python3
"""Count host<->device copies in an Nsight Systems profile (plan.md T-NSYS,
T-NSYS-CLEAN).

Input: a CSV written by
    nsys stats --report cuda_gpu_trace --format csv --output <prefix> <report.nsys-rep>
(one row per GPU operation; memcpy rows are named like
'[CUDA memcpy Host-to-Device]' or '[CUDA memcpy HtoD]'), or by
    nsys stats --report cuda_gpu_mem_size_sum --format csv ...
(one row per operation kind).  Column names differ between nsys versions;
the parser looks for them by keyword.  Check the numbers against the nsys
GUI once, the first time you use it on a new nsys version.

Prints the number of copies and bytes per direction, and with the trace
report the 20 largest distinct copy sizes (a copy of a whole 3D field on d02
is 821*60*821*4 = 161.8 MB, see plan.md 3).

  --max-h2d N / --max-d2h N / --max-bytes MB   fail if exceeded (for gates)

Exit status 0 unless a limit is exceeded.
"""

import argparse
import collections
import csv
import re
import sys


def direction(name):
    n = name.lower()
    if "htod" in n or "host-to-device" in n:
        return "HtoD"
    if "dtoh" in n or "device-to-host" in n:
        return "DtoH"
    if "dtod" in n or "device-to-device" in n:
        return "DtoD"
    if "memset" in n:
        return "memset"
    return None


def find_col(header, *keys):
    for i, h in enumerate(header):
        hl = h.lower()
        if all(k in hl for k in keys):
            return i
    return None


def to_mb(val, header_name):
    v = float(str(val).replace(",", ""))
    h = header_name.lower()
    if "(b)" in h or h.strip() == "bytes":
        return v / 1e6
    if "(kb)" in h:
        return v / 1e3
    if "(gb)" in h:
        return v * 1e3
    return v   # MB


def parse(path):
    rows = list(csv.reader(open(path, newline="")))
    hi = next(i for i, r in enumerate(rows) if any("name" in c.lower() or "operation" in c.lower() for c in r))
    header, data = rows[hi], [r for r in rows[hi + 1:] if r]
    count = collections.Counter()
    mb = collections.Counter()
    sizes = collections.Counter()
    op = find_col(header, "operation")
    if op is not None and find_col(header, "count") is not None:          # *_mem_size_sum
        ci = find_col(header, "count")
        ti = find_col(header, "total")
        for r in data:
            d = direction(r[op])
            if d:
                count[d] += int(float(r[ci]))
                mb[d] += to_mb(r[ti], header[ti])
        return count, mb, sizes, "summary"
    ni = find_col(header, "name")
    bi = find_col(header, "bytes") if find_col(header, "bytes") is not None else find_col(header, "size")
    for r in data:
        if ni is None or ni >= len(r):
            continue
        d = direction(r[ni])
        if not d:
            continue
        count[d] += 1
        if bi is not None and bi < len(r) and r[bi].strip():
            m = to_mb(r[bi], header[bi])
            mb[d] += m
            sizes[(d, round(m, 3))] += 1
    return count, mb, sizes, "trace"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("csv")
    ap.add_argument("--max-h2d", type=int)
    ap.add_argument("--max-d2h", type=int)
    ap.add_argument("--max-bytes", type=float, help="MB, both directions")
    args = ap.parse_args()
    count, mb, sizes, kind = parse(args.csv)
    for d in ("HtoD", "DtoH", "DtoD", "memset"):
        if count[d]:
            print(f"{d:7s} {count[d]:10d} copies  {mb[d]:14.3f} MB")
    if sizes:
        print("largest distinct copy sizes (direction, MB, count):")
        for (d, m), c in sorted(sizes.items(), key=lambda x: -x[0][1])[:20]:
            print(f"   {d:5s} {m:12.3f} MB  x{c}")
    bad = []
    if args.max_h2d is not None and count["HtoD"] > args.max_h2d:
        bad.append(f"HtoD copies {count['HtoD']} > {args.max_h2d}")
    if args.max_d2h is not None and count["DtoH"] > args.max_d2h:
        bad.append(f"DtoH copies {count['DtoH']} > {args.max_d2h}")
    if args.max_bytes is not None and mb["HtoD"] + mb["DtoH"] > args.max_bytes:
        bad.append(f"copied {mb['HtoD'] + mb['DtoH']:.3f} MB > {args.max_bytes} MB")
    for b in bad:
        print("LIMIT EXCEEDED  " + b)
    print(f"nsys_copies ({kind} report): {'PASS' if not bad else 'FAIL'}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
