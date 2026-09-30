#!/usr/bin/env python3
"""The exact commands WRF's build uses for one source file, taken from a
build's compile.log (port/agent/BUILD_SYSTEM.md).  Infrastructure: fix it as a
tool fix if the log format of your compiler differs.

WRF compiles every .F file in four steps (arch/postamble, rule .F.o):
  sed      delete comment lines that contain an apostrophe        x.F  -> x.G
  cpp      preprocess with the build's -D flags and -I<build>/inc  x.G  -> x.bb
  std      tools/standard.exe, then cpp -traditional again         x.bb -> x.f90
  fc       compile                                                 x.f90 -> x.o
An incremental build's compile.log only shows the files it recompiled, so
`update` merges each log into <build>/compile_cmds.json (build.sh calls it
after every build); files never seen use the commands of another file of the
same directory with the name replaced.

  build_cmds.py update <build>                    merge compile.log into compile_cmds.json
  build_cmds.py show <build> <dir/file.F>         print the four commands (and whether they are exact)
  build_cmds.py script <build> <dir/file.F> <src> <outdir>
                        a shell script that preprocesses and compiles <src> (a .F file anywhere,
                        e.g. the working-tree version) into <outdir>/<file>.o, without writing
                        into the build tree (module files go to <outdir>)
  build_cmds.py fc <build> <dir> <src.f90> <outdir>
                        the compile command alone, for an already preprocessed file
  build_cmds.py link <build> <outdir>/<exe> <object> [<object> ...]
                        the link command of wrf.exe with wrf.o replaced by the objects (run it in <build>/main)
"""
import json
import os
import re
import shlex
import sys

STEP_RE = {
    "sed": re.compile(r"^sed -e .* (\S+)\.(F|F90) > \1\.G\s*$"),
    "cpp": re.compile(r"^\S*cpp .* (\S+)\.G\s+>\s*\1\.bb\s*$"),
    "std": re.compile(r"^\S*standard\.exe (\S+)\.bb \| .* > \1\.f90\s*$"),
    "fc": re.compile(r"^\S+ -o (\S+)\.o -c .* \1\.f90\s*$"),
}
ENTER = re.compile(r"make\[\d+\]: Entering directory '([^']+)'")
LEAVE = re.compile(r"make\[\d+\]: Leaving directory '([^']+)'")
LINK = re.compile(r"^\S+ -o wrf\.exe .*\bwrf\.o\b.*libwrflib\.a")


def load(build):
    p = os.path.join(build, "compile_cmds.json")
    if os.path.exists(p):
        return json.load(open(p))
    return {"files": {}, "link": None}


def update(build):
    db = load(build)
    log = os.path.join(build, "compile.log")
    if not os.path.exists(log):
        print(f"build_cmds: no {log}")
        return 1
    stack = [build]
    found = {}
    for line in open(log, errors="replace"):
        line = line.rstrip("\n")
        m = ENTER.search(line)
        if m:
            stack.append(m.group(1))
            continue
        m = LEAVE.search(line)
        if m:
            if len(stack) > 1:
                stack.pop()
            continue
        cwd = stack[-1]
        rel = os.path.relpath(cwd, build)
        if rel.startswith(".."):
            continue
        if LINK.match(line) and rel == "main":
            db["link"] = {"cwd": rel, "cmd": line}
            continue
        for step, rx in STEP_RE.items():
            m = rx.match(line)
            if m:
                key = f"{rel}/{m.group(1)}"
                ent = found.setdefault(key, {"dir": rel, "base": m.group(1)})
                ent[step] = line
                if step == "sed":
                    ent["ext"] = m.group(2)
    n = 0
    for key, ent in found.items():
        if all(s in ent for s in STEP_RE):
            db["files"][key] = ent
            n += 1
    json.dump(db, open(os.path.join(build, "compile_cmds.json"), "w"), indent=1)
    print(f"build_cmds: {n} files from compile.log merged, {len(db['files'])} known, "
          f"link {'known' if db['link'] else 'unknown'} ({os.path.join(build, 'compile_cmds.json')})")
    return 0


def subst_base(text, old, new):
    return re.sub(r"(?<![\w/.])" + re.escape(old) + r"(?=\.(F90|F|G|bb|f90|o)\b)", new, text)


def entry(build, relfile):
    db = load(build)
    d, f = os.path.split(relfile)
    base = re.sub(r"\.(F|F90)$", "", f)
    key = f"{d}/{base}"
    if key in db["files"]:
        return db["files"][key], True
    same = [e for e in db["files"].values() if e["dir"] == d]
    if not same:
        raise SystemExit(f"build_cmds: no compile command of any file in {d}/ known for {build} "
                         f"(run: build_cmds.py update {build}; or rebuild with --clean)")
    # the most common fc flags of the directory (files with special flags, e.g. noopt, are the minority)
    def flags(e):
        return subst_base(e["fc"], e["base"], "{b}")
    counts = {}
    for e in same:
        counts[flags(e)] = counts.get(flags(e), 0) + 1
    best = max(counts, key=counts.get)
    tmpl = next(e for e in same if flags(e) == best)
    ent = {"dir": d, "base": base, "ext": "F90" if f.endswith(".F90") else "F"}
    for s in STEP_RE:
        ent[s] = subst_base(tmpl[s], tmpl["base"], base)
    return ent, False


def absolutize(cmd, cwd, outdir):
    """relative -I/-module/-J paths -> absolute (relative to the build directory of the file);
    module output -> outdir; outdir first in the include path"""
    toks = shlex.split(cmd)
    out = []
    i = 0
    while i < len(toks):
        t = toks[i]
        if t in ("-module", "-J") and i + 1 < len(toks):
            out += [t, outdir]
            i += 2
            continue
        if t.startswith("-J") and len(t) > 2:
            out.append("-J" + outdir)
        elif t.startswith("-I") and len(t) > 2:
            p = t[2:]
            out.append("-I" + (p if os.path.isabs(p) else os.path.normpath(os.path.join(cwd, p))))
        elif t == "-I" and i + 1 < len(toks):
            p = toks[i + 1]
            out += ["-I", p if os.path.isabs(p) else os.path.normpath(os.path.join(cwd, p))]
            i += 2
            continue
        else:
            out.append(t)
        i += 1
    # outdir first among the include paths
    first_i = next((k for k, t in enumerate(out) if t.startswith("-I")), len(out))
    out.insert(first_i, "-I" + outdir)
    return " ".join(shlex.quote(t) for t in out)


def script(build, relfile, src, outdir):
    ent, exact = entry(build, relfile)
    cwd = os.path.join(build, ent["dir"])
    b = ent["base"]
    lines = ["set -e", f"cd {shlex.quote(outdir)}",
             f"# commands of {relfile} in {build} ({'exact' if exact else 'from another file of ' + ent['dir']})"]
    sed = re.sub(r"\S+\.(F|F90) > (\S+)\.G\s*$", f"{shlex.quote(os.path.abspath(src))} > {b}.G", ent["sed"])
    lines.append(sed)
    cpp = ent["cpp"].replace(" -I. ", f" -I{shlex.quote(cwd)} ")
    cpp = re.sub(r"(-I)(?!/)(\S+)", lambda m: "-I" + os.path.normpath(os.path.join(cwd, m.group(2))), cpp)
    lines.append(cpp)
    lines.append(ent["std"])
    lines.append(absolutize(ent["fc"], cwd, outdir))
    return "\n".join(lines) + "\n"


def fc(build, d, src, outdir):
    ents = [e for e in load(build)["files"].values() if e["dir"] == d]
    if not ents:
        raise SystemExit(f"build_cmds: no compile command of {d}/ known for {build}")
    e = ents[0]
    base = re.sub(r"\.f90$", "", os.path.basename(src))
    cmd = subst_base(e["fc"], e["base"], base)
    cmd = absolutize(cmd, os.path.join(build, d), outdir)
    return cmd.replace(f" {base}.f90", " " + shlex.quote(os.path.abspath(src)))


def link(build, exe, objs):
    db = load(build)
    if not db.get("link"):
        raise SystemExit(f"build_cmds: link command of wrf.exe unknown for {build} (rebuild; then update)")
    cmd = db["link"]["cmd"]
    cmd = re.sub(r"-o wrf\.exe\b", "-o " + shlex.quote(exe), cmd)
    cmd = re.sub(r"(?<![\w/.])wrf\.o\b", " ".join(shlex.quote(o) for o in objs), cmd, count=1)
    return cmd


def main():
    a = sys.argv[1:]
    if not a or a[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    if a[0] == "update":
        return update(a[1])
    if a[0] == "show":
        ent, exact = entry(a[1], a[2])
        print(f"# {a[2]}: {'exact commands from the build log' if exact else 'commands of another file of the directory'}")
        for s in STEP_RE:
            print(ent[s])
        return 0
    if a[0] == "script":
        sys.stdout.write(script(a[1], a[2], a[3], a[4]))
        return 0
    if a[0] == "fc":
        print(fc(a[1], a[2], a[3], a[4]))
        return 0
    if a[0] == "link":
        print(link(a[1], a[2], a[3:]))
        return 0
    raise SystemExit(f"build_cmds: unknown command {a[0]}")


if __name__ == "__main__":
    sys.exit(main())
