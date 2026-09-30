#!/usr/bin/env python3
"""Write port/agent/protected.md5: the checksums of the files the coding agent
must not change (AGENTS.md rule 3): tests, tools, gate and run scripts, the
reproducible-math module, the case contract, and the agent guides.
port/gates/static.sh checks them with md5sum -c.

Usage (project owner only): protect.py [--list]
"""
import fnmatch
import hashlib
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
OUT = os.path.join(REPO, "port", "agent", "protected.md5")
INCLUDE = ["port/tests/*", "port/tools/*", "port/gates/*", "port/h100/*", "port/*.py", "port/*.sh",
           "port/config_envelope.txt", "port/rp_subst_files.txt", "port/sym_allow.txt", "port/ccr/*",
           "port/container/*", "WRF/frame/module_repro_math.F", "cases/eaton_20250108/*", "AGENTS.md",
           "port/agent/*.md"]
EXCLUDE = ["port/h100/env.sh", "port/agent/WORKBOOK.md", "port/agent/BLOCKERS.md", "port/agent/REFACTORS.md",
           "port/agent/KERNEL_REFS.md", "port/agent/ROUTES.md"]


def files():
    tracked = subprocess.run(["git", "-C", REPO, "ls-files"], capture_output=True, text=True).stdout.split()
    out = []
    for f in tracked:
        if any(fnmatch.fnmatch(f, p) for p in INCLUDE) and not any(fnmatch.fnmatch(f, p) for p in EXCLUDE):
            if os.path.isfile(os.path.join(REPO, f)):
                out.append(f)
    return sorted(out)


def main():
    fl = files()
    if "--list" in sys.argv:
        print("\n".join(fl))
        return 0
    lines = []
    for f in fl:
        h = hashlib.md5(open(os.path.join(REPO, f), "rb").read()).hexdigest()
        lines.append(f"{h}  {os.path.relpath(os.path.join(REPO, f), os.path.dirname(OUT))}")
    open(OUT, "w").write("\n".join(lines) + "\n")
    print(f"{len(lines)} protected files -> {os.path.relpath(OUT, REPO)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
