#!/usr/bin/env python3
"""Register WRF source files with the build (port/agent/BUILD_SYSTEM.md).

  add_to_build.py <WRF/dir/new_file.F>          a new file: its directory's Makefile (MODULES list),
                                               CMakeLists.txt, and an entry in main/depend.common with
                                               the WRF modules it USEs
  add_to_build.py --deps <WRF/dir/file.F> ...    an existing file: add to its depend.common entry the
                                               WRF modules (frame, share, phys, dyn_em, main) it USEs now
                                               but not in the CPU-view base version

Idempotent: what is already there is left alone.  Prints every change.  Then run
port/tools/check_deps.py, and build with --clean after adding a file.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import check_deps as cd  # noqa: E402

WRF = cd.WRF
DEPEND = os.path.join(WRF, "main", "depend.common")


def rel_of(path):
    rel = os.path.relpath(os.path.abspath(path), WRF)
    if rel.startswith("..") or not os.path.exists(os.path.join(WRF, rel)):
        raise SystemExit(f"add_to_build: {path} is not a file under WRF/")
    return rel


SRC_DIRS = ("frame", "share", "phys", "dyn_em", "main")


def wanted_deps(rel, idx, only_new=False):
    """depend.common names of the WRF source modules (frame, share, phys, dyn_em, main) the file USEs;
    only_new: only the USEs that the CPU-view base version of the file does not have"""
    d = os.path.dirname(rel)
    text = open(os.path.join(WRF, rel), errors="replace").read()
    mine = {m for m, p in idx.items() if p == rel}
    used = cd.uses(text)
    if only_new:
        old = cd.subprocess.run(["git", "-C", cd.REPO, "show", f"{cd.base_rev()}:WRF/{rel}"], capture_output=True,
                                text=True)
        if old.returncode == 0:
            used -= cd.uses(old.stdout)
    out = []
    for m in sorted(used):
        if m in cd.EXTERNAL_MODULES or m in mine or m not in idx or cd.topdir(idx[m]) not in SRC_DIRS:
            continue
        p = idx[m]
        if cd.topdir(p) in cd.ORDER and cd.topdir(rel) in cd.ORDER and \
                cd.ORDER.index(cd.topdir(p)) > cd.ORDER.index(cd.topdir(rel)):
            print(f"warning: {rel} USEs {m} from {p}, compiled later: use an external subroutine instead")
            continue
        out.append(cd.dep_name(d, p))
    return out


def add_entry_deps(obj, deps):
    text = open(DEPEND).read()
    lines = text.split("\n")
    start = next((i for i, l in enumerate(lines) if re.match(r"^" + re.escape(obj) + r"\s*:", l)), None)
    if start is None:
        body = f"{obj}: \\\n" + " \\\n".join(f"\t{x}" for x in deps) + " \n" if deps else f"{obj}:\n"
        text = text.rstrip("\n") + "\n\n" + body
        open(DEPEND, "w").write(text)
        print(f"main/depend.common: new entry {obj}: {' '.join(deps)}")
        return
    end = start
    while lines[end].rstrip().endswith("\\"):
        end += 1
    have = set(re.sub(r"\\", " ", " ".join(lines[start:end + 1])).split(":", 1)[1].split())
    missing = [x for x in deps if x not in have]
    if not missing:
        return
    first = lines[start]
    if first.rstrip().endswith("\\"):
        ins = [f"\t{x} \\" for x in missing]
        lines[start + 1:start + 1] = ins
    else:
        lines[start] = first.rstrip() + " \\"
        ins = [f"\t{x} \\" for x in missing[:-1]] + [f"\t{missing[-1]}"]
        lines[start + 1:start + 1] = ins
    open(DEPEND, "w").write("\n".join(lines))
    print(f"main/depend.common: {obj} += {' '.join(missing)}")


def add_makefile(rel):
    d = os.path.dirname(rel)
    obj = re.sub(r"\.(F|F90)$", ".o", os.path.basename(rel))
    p = os.path.join(WRF, d, "Makefile")
    lines = open(p).read().split("\n")
    if any(re.search(r"(?<![\w.])" + re.escape(obj) + r"(?![\w.])", l) for l in lines):
        return
    i = next((k for k, l in enumerate(lines) if re.match(r"^(MODULES|MODULES1)\s*=", l)), None)
    if i is None:
        raise SystemExit(f"add_to_build: no MODULES list in {d}/Makefile; add {obj} by hand")
    if not lines[i].rstrip().endswith("\\"):
        raise SystemExit(f"add_to_build: unexpected MODULES line in {d}/Makefile; add {obj} by hand")
    lines.insert(i + 1, f"                {obj:<27s}\\")
    open(p, "w").write("\n".join(lines))
    print(f"{d}/Makefile: {obj} added to the {lines[i].split('=')[0].strip()} list")


def add_cmake(rel):
    d = os.path.dirname(rel)
    f = os.path.basename(rel)
    p = os.path.join(WRF, d, "CMakeLists.txt")
    if not os.path.exists(p):
        return
    lines = open(p).read().split("\n")
    if any(re.search(r"(?<![\w.])" + re.escape(f) + r"\b", l) for l in lines):
        return
    ts = next((k for k, l in enumerate(lines) if l.strip().startswith("target_sources(")), None)
    k = next((k for k in range(ts or 0, len(lines)) if re.match(r"^\s+[\w./]+\.(F|F90)\s*$", lines[k])), None)
    if k is None:
        raise SystemExit(f"add_to_build: cannot find the source list in {d}/CMakeLists.txt; add {f} by hand")
    indent = re.match(r"^(\s*)", lines[k]).group(1)
    lines.insert(k + 1, indent + f)
    open(p, "w").write("\n".join(lines))
    print(f"{d}/CMakeLists.txt: {f} added")


def main():
    a = sys.argv[1:]
    if not a or a[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    idx = cd.module_index()
    if a[0] == "--deps":
        for path in a[1:]:
            rel = rel_of(path)
            obj = re.sub(r"\.(F|F90)$", ".o", os.path.basename(rel))
            add_entry_deps(obj, wanted_deps(rel, idx, only_new=True))
        return 0
    for path in a:
        rel = rel_of(path)
        if cd.topdir(rel) not in ("frame", "share", "phys", "dyn_em", "main"):
            raise SystemExit(f"add_to_build: {rel}: only frame, share, phys, dyn_em, main are handled")
        add_makefile(rel)
        add_cmake(rel)
        obj = re.sub(r"\.(F|F90)$", ".o", os.path.basename(rel))
        add_entry_deps(obj, wanted_deps(rel, idx))
    return 0


if __name__ == "__main__":
    sys.exit(main())
