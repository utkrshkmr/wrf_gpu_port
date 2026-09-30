#!/usr/bin/env python3
"""T-GATE, Python side: port/check_case.py must accept ok_*.input and reject
each bad_*.input naming the expected option (port/tests/gate/expected.txt).
The Fortran startup gate is tested with the same files by
port/gates/t_gate.sh on the GPU machine."""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
bad = 0
for line in open(os.path.join(HERE, "expected.txt")):
    if line.startswith("#") or not line.strip():
        continue
    f, want = line.split()
    out = subprocess.run([sys.executable, os.path.join(HERE, "..", "..", "check_case.py"), os.path.join(HERE, f)],
                         capture_output=True, text=True).stdout
    passed = "check_case: PASS" in out
    ok = passed if want == "PASS" else (not passed and want.lower() in out.lower())
    print(("ok    " if ok else "FAIL  ") + f"{f}: expected {want}; got {'PASS' if passed else 'FAIL'}")
    if not ok:
        print(out)
    bad += not ok
print("T-GATE (check_case.py):", "PASS" if not bad else f"FAIL ({bad})")
sys.exit(1 if bad else 0)
