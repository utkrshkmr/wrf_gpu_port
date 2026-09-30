#!/usr/bin/env python3
"""Build-system checks for the WRF files you changed (port/agent/BUILD_SYSTEM.md).

WRF's make knows the order of compilation only from WRF/main/depend.common
(which object needs which module) and each directory's Makefile (which objects
exist).  A missing entry does not always fail at once: with parallel make the
build may pass or fail depending on timing, or use a stale module file.
For every .F/.F90 file under WRF/ changed since the CPU-view base (or new):

  D1  every module USEd in the file that is not USEd in the base version is
      listed as a dependency of the file's object in main/depend.common
      (e.g. solve_em.o: ../frame/module_gpu_updates.o)
  D2  compile order: a file must not USE a module of a directory compiled
      after its own (frame -> share -> phys -> dyn_em -> main); call an external
      subroutine instead (BUILD_SYSTEM.md "Build order")
  D3  a new file is listed in its directory's Makefile (<name>.o) and
      CMakeLists.txt (<name>.F), and a new module has an entry in depend.common

  check_deps.py [files...]        default: WRF .F/.F90 files changed vs port/agent/cpu_view_base
  (port/tools/add_to_build.py registers a new file in all three places.)
Exit status 0 if all checks pass.
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
WRF = os.path.join(REPO, "WRF")
ORDER = ["external", "tools", "frame", "share", "phys", "chem", "dyn_em", "main"]
EXTERNAL_MODULES = {"omp_lib", "iso_c_binding", "iso_fortran_env", "ieee_arithmetic", "ieee_exceptions", "mpi",
                    "netcdf", "openacc", "cudafor", "module_state_description", "esmf", "esmf_mod"}
USE = re.compile(r"^\s*use\s*(?:,\s*(?:intrinsic|non_intrinsic)\s*::)?\s*(\w+)", re.I)


def git(*a):
    return subprocess.run(["git", "-C", REPO] + list(a), capture_output=True, text=True).stdout


def base_rev():
    for line in open(os.path.join(REPO, "port", "agent", "cpu_view_base")):
        line = line.split("#")[0].strip()
        if line:
            return line
    return "HEAD"


def uses(text):
    out = set()
    for l in text.split("\n"):
        if l.lstrip().startswith("!"):
            continue
        m = USE.match(l)
        if m:
            out.add(m.group(1).lower())
    return out


def module_index():
    """module name -> WRF-relative path of the file that defines it"""
    idx = {}
    out = git("grep", "-i", "-n", "-E", r"^\s*module\s+[a-z_0-9]+\s*$", "--", "WRF/*.F", "WRF/*.F90", "WRF/*.f90")
    for line in out.split("\n"):
        m = re.match(r"^WRF/([^:]+):\d+:\s*module\s+(\w+)\s*$", line, re.I)
        if m and m.group(2).lower() != "procedure":
            idx.setdefault(m.group(2).lower(), m.group(1))
    # new, not yet committed files
    for d in ("frame", "share", "phys", "dyn_em", "main"):
        if not os.path.isdir(os.path.join(WRF, d)):
            continue
        for f in os.listdir(os.path.join(WRF, d)):
            if f.endswith((".F", ".F90")):
                try:
                    for l in open(os.path.join(WRF, d, f), errors="replace"):
                        m = re.match(r"^\s*module\s+(\w+)\s*$", l, re.I)
                        if m and m.group(1).lower() != "procedure":
                            idx.setdefault(m.group(1).lower(), f"{d}/{f}")
                except OSError:
                    pass
    return idx


def depend_entries():
    """object (as written, e.g. 'solve_em.o') -> set of dependencies (as written)"""
    text = open(os.path.join(WRF, "main", "depend.common"), errors="replace").read()
    text = re.sub(r"\\\s*\n", " ", text)
    ent = {}
    for l in text.split("\n"):
        m = re.match(r"^\s*([\w./]+\.o)\s*:(.*)$", l)
        if m:
            ent.setdefault(m.group(1), set()).update(m.group(2).split())
    return ent


def dep_name(of_dir, mod_file):
    d, f = os.path.split(mod_file)
    o = re.sub(r"\.(F|F90|f90)$", ".o", f)
    return o if d == of_dir else f"../{d}/{o}"


def topdir(rel):
    return rel.split("/")[0]


def main():
    args = sys.argv[1:]
    if args and args[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    base = base_rev()
    if args:
        files = [os.path.relpath(os.path.abspath(a), WRF) for a in args]
    else:
        files = [f[4:] for f in git("diff", "--name-only", base, "--", "WRF").split()
                 + git("ls-files", "--others", "--exclude-standard", "--", "WRF").split()]
    files = [f for f in files if f.endswith((".F", ".F90")) and os.path.exists(os.path.join(WRF, f))
             and topdir(f) in ("frame", "share", "phys", "dyn_em", "main")]
    idx = module_index()
    deps = depend_entries()
    errs = []
    for rel in files:
        d = os.path.dirname(rel)
        name = re.sub(r"\.(F|F90)$", "", os.path.basename(rel))
        obj = name + ".o"
        text = open(os.path.join(WRF, rel), errors="replace").read()
        old = subprocess.run(["git", "-C", REPO, "show", f"{base}:WRF/{rel}"], capture_output=True, text=True)
        is_new = old.returncode != 0
        new_uses = uses(text) - (set() if is_new else uses(old.stdout))
        mine = {m for m, p in idx.items() if p == rel}
        for m in sorted(new_uses):
            if m in EXTERNAL_MODULES or m in mine:
                continue
            p = idx.get(m)
            if p is None or topdir(p) not in ("frame", "share", "phys", "dyn_em", "main"):
                continue                       # generated, or built before the model (external/, tools/)
            if ORDER.index(topdir(p)) > ORDER.index(topdir(rel)) if topdir(p) in ORDER and topdir(rel) in ORDER else False:
                errs.append(f"D2 {rel}: USE {m} ({p}) - {topdir(p)}/ is compiled after {topdir(rel)}/; "
                            f"call an external subroutine instead")
                continue
            want = dep_name(d, p)
            if obj not in deps:
                errs.append(f"D1 {rel}: USE {m}, but main/depend.common has no entry '{obj}:' "
                            f"(add '{obj}: \\' with '{want}'; or port/tools/add_to_build.py)")
            elif want not in deps[obj]:
                errs.append(f"D1 {rel}: USE {m}, but '{want}' is not a dependency of '{obj}' in main/depend.common")
        if is_new:
            mk = open(os.path.join(WRF, d, "Makefile"), errors="replace").read()
            if not re.search(r"(?<![\w.])" + re.escape(obj) + r"(?![\w.])", mk):
                errs.append(f"D3 {rel}: new file not in {d}/Makefile ('{obj}' in the MODULES list)")
            cm = os.path.join(WRF, d, "CMakeLists.txt")
            if os.path.exists(cm) and not re.search(r"(?<![\w.])" + re.escape(os.path.basename(rel)) + r"\b",
                                                    open(cm, errors="replace").read()):
                errs.append(f"D3 {rel}: new file not in {d}/CMakeLists.txt ('{os.path.basename(rel)}')")
            if mine and obj not in deps:
                errs.append(f"D3 {rel}: new module ({', '.join(sorted(mine))}) without an entry '{obj}:' "
                            f"in main/depend.common")
    for e in errs:
        print("  " + e)
    print(f"check_deps: {len(files)} file(s), {'PASS' if not errs else 'FAIL (' + str(len(errs)) + ')'}")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
