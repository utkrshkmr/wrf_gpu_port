"""Negative controls for the standalone reference tests (port/tests/*/).

A mutant is a plausible porting mistake applied to the GPU version inside a
test source (one text replacement).  The test must FAIL on every mutant; if
it passes, the test cannot see that kind of mistake.  Used by each test
directory's mutants.py:

    python3 port/tests/<dir>/mutants.py [gnu|nvhpc]
"""
import os
import subprocess
import sys
import tempfile

FLAGS = {
    "gnu": ["gfortran", "-O2", "-ffp-contract=off", "-fno-fast-math", "-ffree-line-length-none", "-fopenmp",
            "-fwrapv"],
    "nvhpc": ["nvfortran", "-O2", "-Kieee", "-Mnofma", "-Mnoflushz", "-Mnodaz", "-Mvect=noassoc", "-tp=haswell",
              "-mp=gpu", "-gpu=cc80,cc90,nofma,noflushz"],
}


def run(test_file, mutants, after, args=("20",), extra_env=None):
    """mutants: {name: (old, new)}; the replacement is applied once, in the
    text after the first occurrence of `after` (the GPU version)."""
    comp = sys.argv[1] if len(sys.argv) > 1 else "gnu"
    tc = os.environ.get("TC", "").split()     # e.g. "bash port/h100/x.sh": compile and run in the container
    src = open(test_file).read()
    head, sep, tail = src.partition(after)
    assert sep, f"marker {after!r} not found in {test_file}"
    bad = 0
    for name, (old, new) in mutants.items():
        if old not in tail:
            print(f"FAIL  mutant '{name}': text not found (update mutants.py)")
            bad += 1
            continue
        d = tempfile.mkdtemp()
        f = os.path.join(d, os.path.basename(test_file))
        open(f, "w").write(head + sep + tail.replace(old, new, 1))
        extra = os.environ.get("MUTANT_EXTRA_FLAGS", "").split()   # e.g. -DTMPL_NO_STMTFN (run_ref_tests.sh)
        c = subprocess.run(tc + FLAGS[comp] + extra + ["-o", os.path.join(d, "m"), f], capture_output=True, text=True,
                           cwd=d)
        if c.returncode != 0:
            print(f"FAIL  mutant '{name}' does not compile:\n{c.stderr[-2000:]}")
            bad += 1
            continue
        env = dict(os.environ, ALLOW_HOST="1", **(extra_env or {}))
        r = subprocess.run(tc + [os.path.join(d, "m")] + list(args), capture_output=True, text=True, cwd=d, env=env)
        caught = r.returncode == 1 and "FAIL" in r.stdout
        print(("ok    caught: " if caught else "FAIL  missed: ") + name)
        bad += not caught
    print(f"mutants of {os.path.basename(test_file)}:", "PASS" if not bad else f"FAIL ({bad})")
    return 1 if bad else 0
