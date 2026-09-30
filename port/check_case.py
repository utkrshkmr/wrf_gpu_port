#!/usr/bin/env python3
"""Onboarding check for a new fire case (plan.md 12, step 2).

Checks a case's namelist (and, if given, its wrfinput_d0N files) against the
supported envelope (port/config_envelope.txt, plan.md 2.2/2.3/P1.8):

  - every option set in the reference namelist and not listed as 'free' has
    the reference value on every domain (a missing option falls back to its
    Registry default, which must equal the reference value)
  - pinned options have their pinned value
  - an option that the reference does not set and that is not free must be at
    its Registry default
  - sr_x = sr_y and even on fire domains
  - e_vert - 1 <= WRF_KMAX; RRTMG NLAYERS = e_vert + nint(p_top/400) - 1 <= WRF_NLAYMAX
  - NFUEL_CAT (wrfinput) only has categories the built-in table can map
    (1..204, not 204: ksb(204) = 54 > nfuelcats = 53)
  - device memory estimate (port/gpu_mem_estimate.py) <= GPU_MEM_GB

Usage:
  check_case.py <namelist.input> [--wrfinput wrfinput_d01 wrfinput_d02 ...]
                [--reference cases/eaton_20250108/namelist.input]
Exit status 0 = the case is inside the envelope.
"""

import argparse
import math
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, ".."))
sys.path.insert(0, HERE)
import gpu_mem_estimate as gme  # noqa: E402

ENVELOPE = os.path.join(HERE, "config_envelope.txt")
REFERENCE = os.path.join(REPO, "cases", "eaton_20250108", "namelist.input")
# fuel categories the built-in table (module_fr_fire_phys.F, ksb) maps to 1..53
MAPPED = set(range(1, 14)) | set(range(101, 110)) | set(range(121, 125)) | set(range(141, 150)) | \
    set(range(161, 166)) | set(range(181, 190)) | {201, 202, 203}


def read_envelope(path=ENVELOPE):
    free, pinned, limits = set(), {}, {}
    for line in open(path):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        kind, _, rest = line.partition(":")
        for item in rest.split():
            if kind == "free":
                free.add(item.lower())
            elif kind == "pinned":
                k, _, v = item.partition("=")
                pinned[k.lower()] = v
            elif kind == "limit":
                k, _, v = item.partition("=")
                limits[k] = float(v)
    return free, pinned, limits


def norm(v):
    if v is None:
        return None
    s = str(v).strip().strip("'\"").lower()
    if s in (".true.", "t", "true"):
        return True
    if s in (".false.", "f", "false"):
        return False
    try:
        x = float(s.replace("d", "e"))
        return x
    except ValueError:
        return s


def dom_value(nml, name, dom):
    v = nml.get(name)
    if v is None:
        return None
    return v[dom] if dom < len(v) else v[-1]


def check(namelist, reference, wrfinputs):
    free, pinned, limits = read_envelope()
    reg = gme.Registry(gme.read_registry(os.path.join(gme.DEFAULT_REGISTRY, "Registry.EM"), gme.DEFINES))
    new = gme.read_namelist(namelist)
    ref = gme.read_namelist(reference)
    ndom = int(norm(dom_value(new, "max_dom", 0)) or 1)
    problems = []

    def default(name):
        if reg is not None:
            return reg.rconfig.get(name)
        return None

    for name, vals in sorted(ref.items()):
        if name in free:
            continue
        for d in range(min(ndom, len(vals)) if vals else 1):
            want = norm(dom_value(ref, name, d))
            got = norm(dom_value(new, name, d))
            if got is None:
                got = norm(default(name))
            if got != want:
                problems.append(f"{name}(d0{d + 1}) = {dom_value(new, name, d)} but the envelope requires {want}")
    for name, want in pinned.items():
        if name in ref:
            continue
        for d in range(ndom):
            got = norm(dom_value(new, name, d))
            if got is None:
                continue
            if got != norm(want):
                problems.append(f"{name}(d0{d + 1}) = {dom_value(new, name, d)} but it is pinned to {want}")
    for name in sorted(new):
        if name in ref or name in free or name in pinned:
            continue
        dflt = default(name)
        for d in range(min(ndom, len(new[name]))):
            if dflt is not None and norm(dom_value(new, name, d)) != norm(dflt):
                problems.append(f"{name}(d0{d + 1}) = {dom_value(new, name, d)}: outside the envelope "
                                f"(the reference case uses the default {dflt})")
    # fire refinement
    for d in range(ndom):
        ifire = norm(dom_value(new, "ifire", d)) or 0
        if ifire:
            sx, sy = norm(dom_value(new, "sr_x", d)), norm(dom_value(new, "sr_y", d))
            if sx != sy or (sx or 0) % 2:
                problems.append(f"sr_x/sr_y(d0{d + 1}) = {sx}/{sy}: must be equal and even")
    # vertical limits
    kmax, laymax = limits.get("WRF_KMAX", 64), limits.get("WRF_NLAYMAX", 128)
    for d in range(ndom):
        ev = norm(dom_value(new, "e_vert", d))
        if ev is None:
            continue
        if ev - 1 > kmax:
            problems.append(f"e_vert(d0{d + 1}) = {int(ev)}: e_vert-1 > WRF_KMAX = {int(kmax)}")
        ptop = norm(dom_value(new, "p_top_requested", 0)) or 5000.0
        nlay = int(ev) + int(math.floor(ptop * 0.01 / 4.0 + 0.5)) - 1
        if nlay > laymax:
            problems.append(f"RRTMG NLAYERS = {nlay} (e_vert {int(ev)}, p_top {ptop:g} Pa) > WRF_NLAYMAX = {int(laymax)}")
    # fuel categories
    for path in wrfinputs or []:
        try:
            from netCDF4 import Dataset
            import numpy as np
            with Dataset(path) as nc:
                if "NFUEL_CAT" not in nc.variables:
                    continue
                cats = np.unique(np.asarray(nc["NFUEL_CAT"][:]).astype(int))
                bad = [int(c) for c in cats if c < 1 or c > 204 or c == 204]
                unmapped = [int(c) for c in cats if 1 <= c < 204 and c not in MAPPED]
                if bad:
                    problems.append(f"{os.path.basename(path)}: NFUEL_CAT has categories the fire model cannot "
                                    f"handle: {bad} (204 maps to 54 > nfuelcats = 53)")
                if unmapped:
                    print(f"note: {os.path.basename(path)}: categories {unmapped} map to 'no fuel' (14)")
        except ImportError:
            print("note: netCDF4 not available, fuel categories not checked")
    # memory
    try:
        out = subprocess.run([sys.executable, os.path.join(HERE, "gpu_mem_estimate.py"), namelist],
                             capture_output=True, text=True).stdout
        m = re.search(r"TOTAL\s+([\d.]+)\s*GB", out)
        if m and float(m.group(1)) > limits.get("GPU_MEM_GB", 70):
            problems.append(f"device memory estimate {m.group(1)} GB > {limits.get('GPU_MEM_GB', 70):g} GB")
        elif m:
            print(f"device memory estimate: {m.group(1)} GB")
    except Exception as e:  # pragma: no cover
        print(f"note: memory estimate failed: {e}")
    return problems


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("namelist")
    ap.add_argument("--wrfinput", nargs="*")
    ap.add_argument("--reference", default=REFERENCE)
    args = ap.parse_args()
    probs = check(args.namelist, args.reference, args.wrfinput)
    for p in probs:
        print("VIOLATION  " + p)
    print(f"check_case: {'PASS' if not probs else 'FAIL (' + str(len(probs)) + ')'}")
    return 1 if probs else 0


if __name__ == "__main__":
    sys.exit(main())
