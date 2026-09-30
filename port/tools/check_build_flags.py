#!/usr/bin/env python3
"""Check that the floating-point semantics of the port's builds are intact
(plan.md 4; AGENTS.md rule 1).  LOCKED: the build scripts and the configure
stanzas may be fixed (tool fixes, compile problems), these flags may not.

  check_build_flags.py                 the three "GPU port" stanzas in WRF/arch/configure.defaults
  check_build_flags.py --build <dir>   the configure.wrf of a build made by port/h100/build.sh
                                       (mode from its BUILD_INFO; gnu test builds are skipped)

Rules, for every stanza / NVHPC build:
  FCOPTIM  contains  -O2 -Kieee -Mnofma -Mnoflushz -Mnodaz -Mvect=noassoc -tp=haswell
  FCNOOPT  contains  -Kieee -Mnofma -Mnoflushz -Mnodaz -tp=haswell
  FCOPTIM and FCNOOPT are the same in CPU-REF, GPU-REPRO and GPU-DEBUG (stanza check)
  no flag that changes arithmetic: -fast, -Ofast, -O3, -O4, -Mfma, -Mflushz, -Mdaz, -Mvect=assoc(iate),
      -Mfprelaxed, -Kieee absent, -gpu=...fastmath, -gpu=...fma (other than nofma), -gpu=...flushz
      (other than noflushz), --fast-math
  ARCH_LOCAL defines REPRO_MATH and WRF_POOL; GPU-REPRO/GPU-DEBUG also WRF_GPU; CPU-REF not WRF_GPU
  GPU-REPRO/GPU-DEBUG: OMP contains -mp=gpu and a -gpu= list with nofma and noflushz; CPU-REF: OMP empty
Exit status 0 if all rules hold.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
STANZAS = {"cpu-ref": "GPU port CPU-REF", "gpu-repro": "GPU port GPU-REPRO", "gpu-debug": "GPU port GPU-DEBUG"}
NEED_OPT = ["-O2", "-Kieee", "-Mnofma", "-Mnoflushz", "-Mnodaz", "-Mvect=noassoc", "-tp=haswell"]
NEED_NOOPT = ["-Kieee", "-Mnofma", "-Mnoflushz", "-Mnodaz", "-tp=haswell"]
FORBID = re.compile(r"(?:^|\s)(-fast|-Ofast|-O3|-O4|-Mfma|-Mflushz|-Mdaz|-Mvect=assoc\w*|-Mfprelaxed\S*|"
                    r"--fast-math|-ffast-math|-Knoieee)(?=\s|$)")


def parse_vars(lines):
    """VAR = value lines (make syntax) -> dict (last one wins)."""
    v = {}
    for l in lines:
        m = re.match(r"^([A-Z_]+)\s*=\s*(.*?)\s*$", l)
        if m:
            v[m.group(1)] = m.group(2)
    return v


def stanza_vars(text, name):
    lines = text.split("\n")
    start = None
    for i, l in enumerate(lines):
        if l.startswith("#ARCH") and name in l:
            start = i
            break
    if start is None:
        return None
    end = len(lines)
    for i in range(start + 1, len(lines)):
        if lines[i].startswith("#ARCH"):
            end = i
            break
    return parse_vars(lines[start + 1:end])


def gpu_opts(omp):
    opts = []
    for m in re.finditer(r"-gpu=(\S+)", omp):
        opts += m.group(1).split(",")
    return opts


def check(mode, v, where):
    errs = []
    fo, fn = v.get("FCOPTIM", ""), v.get("FCNOOPT", "")
    for f in NEED_OPT:
        if f not in fo.split():
            errs.append(f"{where}: FCOPTIM lacks {f}")
    for f in NEED_NOOPT:
        if f not in fn.split():
            errs.append(f"{where}: FCNOOPT lacks {f}")
    for var in ("FCOPTIM", "FCNOOPT", "FCREDUCEDOPT", "FCBASEOPTS_NO_G", "FCBASEOPTS", "FCDEBUG", "OMP",
                "ARCH_LOCAL", "CFLAGS_LOCAL", "LDFLAGS_LOCAL"):
        m = FORBID.search(" " + v.get(var, "") + " ")
        if m:
            errs.append(f"{where}: {var} contains {m.group(1)}")
    omp = v.get("OMP", "")
    for o in gpu_opts(omp):
        if o in ("fastmath", "fma", "flushz") or o.startswith("fastmath"):
            errs.append(f"{where}: OMP contains -gpu={o}")
    al = v.get("ARCH_LOCAL", "").split()
    for d in ("-DREPRO_MATH", "-DWRF_POOL"):
        if d not in al:
            errs.append(f"{where}: ARCH_LOCAL lacks {d}")
    if mode == "cpu-ref":
        if "-DWRF_GPU" in al:
            errs.append(f"{where}: CPU-REF defines WRF_GPU")
        if omp.strip():
            errs.append(f"{where}: CPU-REF has OMP = {omp}")
    else:
        if "-DWRF_GPU" not in al:
            errs.append(f"{where}: ARCH_LOCAL lacks -DWRF_GPU")
        if "-mp=gpu" not in omp.split():
            errs.append(f"{where}: OMP lacks -mp=gpu")
        go = gpu_opts(omp)
        for o in ("nofma", "noflushz"):
            if o not in go:
                errs.append(f"{where}: OMP lacks -gpu=...{o}")
    return errs


def main():
    args = sys.argv[1:]
    errs = []
    if args[:1] == ["--build"]:
        b = args[1]
        info = open(os.path.join(b, "BUILD_INFO")).read() if os.path.exists(os.path.join(b, "BUILD_INFO")) else ""
        m = re.search(r"^mode:\s*(\S+)", info, re.M)
        mode = m.group(1) if m else ""
        if mode.endswith("-fine"):
            mode = mode[:-5]
        if mode == "gnu":
            print("check_build_flags: gnu test build, skipped")
            return 0
        if mode not in STANZAS:
            print(f"check_build_flags: FAIL: unknown build mode '{mode}' in {b}/BUILD_INFO")
            return 1
        v = parse_vars(open(os.path.join(b, "configure.wrf"), errors="replace").read().split("\n"))
        errs = check(mode, v, f"{b}/configure.wrf ({mode})")
    else:
        text = open(os.path.join(REPO, "WRF", "arch", "configure.defaults"), errors="replace").read()
        vals = {}
        for mode, name in STANZAS.items():
            v = stanza_vars(text, name)
            if v is None:
                errs.append(f"configure.defaults: no stanza '{name}'")
                continue
            vals[mode] = v
            errs += check(mode, v, f"stanza {name}")
        for var in ("FCOPTIM", "FCNOOPT"):
            got = {m: vals[m].get(var, "") for m in vals}
            if len(set(got.values())) > 1:
                errs.append(f"configure.defaults: {var} differs between the stanzas: {got}")
    for e in errs:
        print("  " + e)
    print(f"check_build_flags: {'PASS' if not errs else 'FAIL (' + str(len(errs)) + ')'}")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
