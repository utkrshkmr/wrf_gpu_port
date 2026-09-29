#!/usr/bin/env python3
"""T-IPOW scan (plan.md P0.6): list integer powers in the rewritten files.

Integer-literal exponents (x**2, x**3, ...) are left as they are by
rp_subst.py.  The host and device compilers expand them into multiplications
and may do so in different orders for exponents >= 3.  This script lists
every such exponent (and every rp_pow call, whose exponent may be an INTEGER
variable) so that port/tests/repro_math/t_ipow.F90 tests exactly the exponents
that occur.

Usage: ipow_scan.py [--files port/rp_subst_files.txt] [--wrf WRF]
"""

import argparse
import collections
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from rp_subst import split_comment  # noqa: E402

INT_POW = re.compile(r"\*\*\s*\(?\s*([+-]?\d+)(_\w+)?\s*\)?(?![\d.eEdD_])")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--files", default=os.path.join(HERE, "rp_subst_files.txt"))
    ap.add_argument("--wrf", default=os.path.join(HERE, "..", "WRF"))
    args = ap.parse_args()
    files = [l.strip() for l in open(args.files) if l.strip() and not l.startswith("#")]
    counts = collections.Counter()
    where = collections.defaultdict(list)
    rp_pow_calls = 0
    for rel in files:
        path = os.path.join(args.wrf, rel)
        with open(path, errors="replace") as f:
            for n, line in enumerate(f, 1):
                code, _ = split_comment(line)
                if code.lstrip().startswith("#"):
                    continue
                for m in INT_POW.finditer(code):
                    e = int(m.group(1))
                    counts[e] += 1
                    if len(where[e]) < 5:
                        where[e].append(f"{rel}:{n}")
                rp_pow_calls += code.lower().count("rp_pow(")
    print("integer-literal exponents (count, first uses):")
    for e in sorted(counts):
        flag = "  <- test host vs device (T-IPOW)" if abs(e) >= 3 or e < 0 else ""
        print(f"  **{e:<4d} {counts[e]:5d}   {', '.join(where[e])}{flag}")
    print(f"rp_pow calls (exponent may be an INTEGER variable): {rp_pow_calls}")
    print("exponents for t_ipow:", " ".join(str(e) for e in sorted(counts)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
