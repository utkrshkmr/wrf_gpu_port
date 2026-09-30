#!/usr/bin/env python3
"""Write the checksums of the port's own files in two tiers (AGENTS.md rule 3):

  port/agent/protected.md5  LOCKED: what decides pass or fail and what the
      results are compared with: tests, checkers, gates, comparison tools, the
      window table, the reproducible-math module, the case contract, the agent
      guides.  The coding agent never changes these; static.sh checks them with
      md5sum -c.
  port/agent/infra.md5  INFRASTRUCTURE: scripts that build, run and set up
      (port/h100 apart from compare.sh and windows.txt, the container files,
      the dev-case cutter).  They have never met the real machine, so the agent
      may fix them, but only through the "tool fix" protocol of WORKFLOW.md:
      static.sh requires every changed infrastructure file to be named in
      port/agent/TOOL_FIXES.md.

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
OUT_INFRA = os.path.join(REPO, "port", "agent", "infra.md5")
INCLUDE = ["port/tests/*", "port/tools/*", "port/gates/*", "port/h100/*", "port/*.py", "port/*.sh",
           "port/config_envelope.txt", "port/rp_subst_files.txt", "port/sym_allow.txt", "port/ccr/*",
           "port/container/*", "WRF/frame/module_repro_math.F", "cases/eaton_20250108/*", "AGENTS.md",
           "port/agent/*.md"]
EXCLUDE = ["port/h100/env.sh", "port/agent/WORKBOOK.md", "port/agent/BLOCKERS.md", "port/agent/REFACTORS.md",
           "port/agent/KERNEL_REFS.md", "port/agent/ROUTES.md", "port/agent/TOOL_FIXES.md"]
# infrastructure: fixable through a logged tool fix (everything else in INCLUDE is locked)
INFRA = ["port/h100/build.sh", "port/h100/common.sh", "port/h100/dev_case.sh", "port/h100/in_container.sh",
         "port/h100/setup_toolchain.sh", "port/h100/smoke_case.sh", "port/h100/sync_tree.py",
         "port/h100/window.sh", "port/h100/x.sh", "port/container/*", "port/make_dev_case.py", "port/nml.py"]


def files():
    tracked = subprocess.run(["git", "-C", REPO, "ls-files"], capture_output=True, text=True).stdout.split()
    locked, infra = [], []
    for f in tracked:
        if any(fnmatch.fnmatch(f, p) for p in INCLUDE) and not any(fnmatch.fnmatch(f, p) for p in EXCLUDE):
            if os.path.isfile(os.path.join(REPO, f)):
                (infra if any(fnmatch.fnmatch(f, p) for p in INFRA) else locked).append(f)
    return sorted(locked), sorted(infra)


def write(out, fl):
    lines = []
    for f in fl:
        h = hashlib.md5(open(os.path.join(REPO, f), "rb").read()).hexdigest()
        lines.append(f"{h}  {os.path.relpath(os.path.join(REPO, f), os.path.dirname(out))}")
    open(out, "w").write("\n".join(lines) + "\n")


def main():
    locked, infra = files()
    if "--list" in sys.argv:
        print("\n".join(f"locked  {f}" for f in locked))
        print("\n".join(f"infra   {f}" for f in infra))
        return 0
    write(OUT, locked)
    write(OUT_INFRA, infra)
    print(f"{len(locked)} locked files -> {os.path.relpath(OUT, REPO)}; "
          f"{len(infra)} infrastructure files -> {os.path.relpath(OUT_INFRA, REPO)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
