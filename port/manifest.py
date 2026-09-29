#!/usr/bin/env python3
"""Input manifest for WRF GPU-port runs (plan.md P0.3).

A manifest is an md5sum-compatible text file:

    # comment lines start with '#'
    # require-absent: namelist.fire
    4a50bf559d1486b00b486287fdd3c567 *wrfinput_d01
    ...

Subcommands
-----------
write <rundir> [-o FILE] [--tables-only] [--allow-namelist-fire]
    Hash the case inputs (wrfinput_d0*, wrfbdy_d01) and the runtime tables
    found in <rundir> (symlinks are followed) and write a manifest.

check <rundir> [-m FILE]
    Verify every listed file in <rundir> against the manifest and verify that
    every "require-absent" file is missing.  Exit status 0 only if everything
    matches.  Every run script (CPU-REF and GPU) calls this first.
"""

import argparse
import glob
import hashlib
import os
import sys

# Runtime tables read by wrf.exe for the supported configuration (plan.md 2.1).
TABLES = [
    "LANDUSE.TBL",
    "VEGPARM.TBL",
    "SOILPARM.TBL",
    "GENPARM.TBL",
    "RRTMG_LW_DATA",
    "ozone.formatted",
    "ozone_lat.formatted",
    "ozone_plev.formatted",
    "CAMtr_volume_mixing_ratio",
]

REQUIRE_ABSENT_DEFAULT = ["namelist.fire"]


def md5_of(path, bufsize=1 << 22):
    h = hashlib.md5()
    with open(path, "rb") as f:
        while True:
            b = f.read(bufsize)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def case_inputs(rundir):
    names = sorted(os.path.basename(p) for p in glob.glob(os.path.join(rundir, "wrfinput_d0*")))
    if os.path.exists(os.path.join(rundir, "wrfbdy_d01")):
        names.append("wrfbdy_d01")
    return names


def read_manifest(path):
    entries = []          # (md5, name)
    absent = []
    with open(path) as f:
        for lineno, line in enumerate(f, 1):
            line = line.rstrip("\n")
            s = line.strip()
            if not s:
                continue
            if s.startswith("#"):
                body = s[1:].strip()
                if body.lower().startswith("require-absent:"):
                    absent.extend(body.split(":", 1)[1].split())
                continue
            parts = s.split(None, 1)
            if len(parts) != 2 or len(parts[0]) != 32:
                raise SystemExit(f"{path}:{lineno}: malformed line: {line!r}")
            name = parts[1].lstrip("*").strip()
            entries.append((parts[0].lower(), name))
    return entries, absent


def cmd_write(args):
    rundir = args.rundir
    names = [] if args.tables_only else case_inputs(rundir)
    missing = []
    for t in TABLES:
        if os.path.exists(os.path.join(rundir, t)):
            names.append(t)
        else:
            missing.append(t)
    if missing:
        print("warning: tables not found in run folder: " + ", ".join(missing), file=sys.stderr)
    lines = [
        "# WRF GPU-port input manifest (port/manifest.py)",
        f"# run folder: {os.path.abspath(rundir)}",
    ]
    if not args.allow_namelist_fire:
        lines.append("# require-absent: " + " ".join(REQUIRE_ABSENT_DEFAULT))
    for n in names:
        p = os.path.join(rundir, n)
        lines.append(f"{md5_of(p)} *{n}")
        print(f"hashed {n}", file=sys.stderr)
    text = "\n".join(lines) + "\n"
    if args.output == "-":
        sys.stdout.write(text)
    else:
        with open(args.output, "w") as f:
            f.write(text)
    return 0


def cmd_check(args):
    entries, absent = read_manifest(args.manifest)
    bad = 0
    for md5, name in entries:
        p = os.path.join(args.rundir, name)
        if not os.path.exists(p):
            print(f"MISSING  {name}")
            bad += 1
            continue
        got = md5_of(p)
        if got != md5:
            print(f"MISMATCH {name}: expected {md5}, found {got}")
            bad += 1
        else:
            print(f"ok       {name}")
    for name in absent:
        if os.path.lexists(os.path.join(args.rundir, name)):
            print(f"PRESENT  {name} (the manifest requires it to be absent)")
            bad += 1
        else:
            print(f"ok       {name} absent")
    if bad:
        print(f"manifest check FAILED: {bad} problem(s)")
        return 1
    print("manifest check passed")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    w = sub.add_parser("write", help="hash the inputs and tables of a run folder")
    w.add_argument("rundir")
    w.add_argument("-o", "--output", default="-", help="output file (default stdout)")
    w.add_argument("--tables-only", action="store_true", help="hash only the runtime tables")
    w.add_argument("--allow-namelist-fire", action="store_true",
                   help="do not require namelist.fire to be absent")
    c = sub.add_parser("check", help="verify a run folder against a manifest")
    c.add_argument("rundir")
    c.add_argument("-m", "--manifest", default=None, help="manifest file (default <rundir>/manifest.md5)")
    args = ap.parse_args(argv)
    if args.cmd == "write":
        return cmd_write(args)
    if args.manifest is None:
        args.manifest = os.path.join(args.rundir, "manifest.md5")
    return cmd_check(args)


if __name__ == "__main__":
    sys.exit(main())
