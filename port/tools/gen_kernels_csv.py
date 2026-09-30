#!/usr/bin/env python3
"""Generate port/agent/kernels.csv and port/agent/KERNEL_REFS.md from the
kernel tables of plan.md (sections 7.1-7.7, 8.1-8.5, 9.1, P5.1).

For every table row it records the WRF source references of the CPU
implementation the kernel ports:
  v460_refs   the file:line references as written in plan.md (WRF v4.6.0, commit 99becf4)
  base_refs   the same lines in the CPU-view base commit (port/agent/cpu_view_base),
              i.e. the exact lines of the current CPU code to port
  routines    the routines named in the row, with the lines of their
              SUBROUTINE ... END SUBROUTINE in the base commit
and the columns the agent keeps up to date (port/tools/workbook.py):
  status (todo | in-progress | done | blocked | n/a), commit, tests, notes.

Rerunning keeps the status columns of existing rows (matched by key).
Usage: gen_kernels_csv.py [--check]   (--check: exit 1 if the files would change)
"""

import csv
import io
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PORT = os.path.dirname(HERE)
REPO = os.path.dirname(PORT)
sys.path.insert(0, HERE)
from locate import ABBREV  # noqa: E402

V460 = "99becf4"
CSV = os.path.join(PORT, "agent", "kernels.csv")
MD = os.path.join(PORT, "agent", "KERNEL_REFS.md")
FIELDS = ["key", "phase", "section", "kernels", "routines", "route", "template", "base_refs", "v460_refs",
          "status", "commit", "tests", "notes"]
SECTION = re.compile(r"^###\s+(7\.[1-7]|8\.[1-5]|9\.1|P5\.1)\b\s*(.*)$")
PHASE_OF = {"7": 2, "8": 3, "9": 4, "P5": 5}
DONE_IN_P0 = ("UB fix", "OOB fix", "rp_*")
# routines whose kernels are switched by another route (module_gpu_route.F)
ALIAS = {"relax_bdy_scalar": "relax_bdytend_core", "spec_bdy_scalar": "spec_bdytend",
         "vertical_diffusion_u_2": "vertical_diffusion_2", "vertical_diffusion_v_2": "vertical_diffusion_2",
         "vertical_diffusion_w_2": "vertical_diffusion_2", "vertical_diffusion_s": "vertical_diffusion_2",
         "horizontal_diffusion_u_2": "horizontal_diffusion_2", "horizontal_diffusion_v_2": "horizontal_diffusion_2",
         "horizontal_diffusion_w_2": "horizontal_diffusion_2", "horizontal_diffusion_s": "horizontal_diffusion_2",
         "cal_titau_11_22_33": "cal_titau", "cal_titau_12_21": "cal_titau", "cal_titau_13_31": "cal_titau",
         "cal_titau_23_32": "cal_titau", "add_a2a": "update_phy_ten", "add_a2c_u": "update_phy_ten",
         "add_a2c_v": "update_phy_ten", "mp_wsm6_run": "wsm6", "vrec": "wsm6", "mp_wsm6_effectrad_run": "wsm6",
         "rrtmg_lwinit": "rrtmg_lwrad", "get_pblh": "ysu", "zolri": "sfclayrev", "sflx": "lsm"}
SECTION_ROUTE = {"8.2": "wsm6"}
# route of kernel families whose table rows name no routine
FAMILY_ROUTE = {"K-RAD": "radiation_driver", "K-SD": "surface_driver", "K-PBLD": "pbl_driver",
                "K-FSC": "fire_model", "K-NAN": "fire_model", "K-FM5": "fire_model", "K-FM6": "fire_model",
                "K-CPL": "couple_or_uncouple_em", "K-TIGN": "tign_update", "K-RI": "reinit_ls_rk3",
                "K-PLS": "prop_ls_rk3", "K-FT": "fire_tendency", "K-A2F": "interpolate_atm2fire"}


def base_rev():
    for line in open(os.path.join(PORT, "agent", "cpu_view_base")):
        s = line.split("#")[0].strip()
        if s:
            return s
    raise SystemExit("port/agent/cpu_view_base is empty")


def show(rev, path, cache={}):
    k = (rev, path)
    if k not in cache:
        r = subprocess.run(["git", "-C", REPO, "show", f"{rev}:{path}"], capture_output=True, text=True,
                           errors="replace")
        cache[k] = r.stdout.split("\n") if r.returncode == 0 else None
    return cache[k]


def line_map(path, base, cache={}):
    """v4.6.0 line -> base-commit line, from the hunks of git diff -U0 (fast).
    A line inside a changed hunk maps to the first line of the new hunk."""
    if path not in cache:
        d = subprocess.run(["git", "-C", REPO, "diff", "-U0", V460, base, "--", path],
                           capture_output=True, text=True, errors="replace").stdout
        hunks = []
        for m in re.finditer(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", d, re.M):
            a, na = int(m.group(1)), int(m.group(2) if m.group(2) is not None else 1)
            b, nb = int(m.group(3)), int(m.group(4) if m.group(4) is not None else 1)
            hunks.append((a, na, b, nb))
        cache[path] = hunks
    hunks = cache[path]

    class M:
        def get(self, n):
            off = 0
            for a, na, b, nb in hunks:
                start = a if na else a + 1          # na == 0: pure insertion after line a
                if n < start:
                    break
                if na and n < a + na:
                    return b if nb else b + 1
                off = (b + nb) - (a + na)
            return n + off
    return M()


def routine_lines(path, name, base):
    lines = show(base, path)
    if not lines:
        return None
    pat = re.compile(r"^\s*(?:recursive\s+|pure\s+|elemental\s+)*(subroutine|(?:real|integer|logical)?\s*function)\s+"
                     + re.escape(name) + r"\b", re.I)
    for i, l in enumerate(lines):
        if pat.match(l) and not l.lstrip().startswith("!"):
            endp = re.compile(r"^\s*end\s*(subroutine|function)\s+" + re.escape(name) + r"\b", re.I)
            for j in range(i + 1, len(lines)):
                if endp.match(lines[j]):
                    return i + 1, j + 1
            return i + 1, None
    return None


def find_routine(name, files, base, index={}):
    for f in files:
        r = routine_lines(f, name, base)
        if r:
            return f, r
    for f in files:   # a generic interface of that name (e.g. vrec in physics_mmm/module_libmassv.F90)
        lines = show(base, f) or []
        for i, l in enumerate(lines):
            if re.match(r"^\s*interface\s+" + re.escape(name) + r"\b", l, re.I):
                for j in range(i + 1, len(lines)):
                    if re.match(r"^\s*end\s*interface", lines[j], re.I):
                        return f, (i + 1, j + 1)
                return f, (i + 1, None)
    if not index:
        out = subprocess.run(["git", "-C", REPO, "grep", "-i", "-E", r"^\s*(recursive\s+)?subroutine\s+\w+", base,
                              "--", "WRF/dyn_em", "WRF/share", "WRF/phys", "WRF/frame"],
                             capture_output=True, text=True, errors="replace").stdout
        for l in out.split("\n"):
            m = re.match(r"[^:]+:([^:]+):\s*(?:recursive\s+)?subroutine\s+(\w+)", l, re.I)
            if m:
                index.setdefault(m.group(2).lower(), m.group(1))
        index["_"] = "_"
    f = index.get(name.lower())
    if f:
        r = routine_lines(f, name, base)
        if r:
            return f, r
    return None, None


def routes():
    src = open(os.path.join(REPO, "WRF", "frame", "module_gpu_route.F")).read()
    return set(re.findall(r"'([a-z0-9_]+)\s*'", src))


def parse_plan():
    rows, sec, sec_title, phase = [], None, "", None
    fam_file, last_file = {}, None
    for line in open(os.path.join(REPO, "plan.md")):
        m = SECTION.match(line)
        if m:
            sec, sec_title = m.group(1), m.group(2).strip()
            phase = PHASE_OF[sec.split(".")[0]]
            fam_file, last_file = {}, ("WRF/dyn_em/couple_or_uncouple_em.F" if sec == "P5.1" else None)
            continue
        if line.startswith("## ") or (line.startswith("### ") and not m):
            sec = None
            continue
        if not sec or not line.startswith("|") or line.startswith("|---"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 3 or cells[0] in ("Kernel", "Kernel / change"):
            continue
        kern, where, how = cells[0], cells[1], " | ".join(cells[2:])
        fam = re.match(r"K-[A-Z0-9]+", kern)
        fam = fam.group(0) if fam else None
        refs = []   # (path, a, b)
        for text in (where, how):
            for tok in re.finditer(r"\b([A-Za-z0-9]+):(\d+)(?:\s*[–-]\s*(\d+))?|(?<![\w.:])(\d{2,5})\s*[–-]\s*(\d{2,5})\b"
                                   r"|\((\d{2,5})\)", text):
                if tok.group(1):
                    ab = tok.group(1)
                    if ab not in ABBREV:
                        continue
                    last_file = ABBREV[ab]
                    if fam and fam not in fam_file:
                        fam_file[fam] = last_file
                    refs.append((last_file, int(tok.group(2)), int(tok.group(3) or tok.group(2))))
                else:
                    a = int(tok.group(4) or tok.group(6))
                    b = int(tok.group(5) or a)
                    f = fam_file.get(fam) or last_file
                    if f and b >= a:
                        refs.append((f, a, b))
        names = re.findall(r"`([A-Za-z_][A-Za-z0-9_]*)", where)
        rows.append(dict(phase=phase, section=sec, kern=kern, where=where, how=how, refs=refs, names=names))
    return rows


def main():
    check = "--check" in sys.argv
    base = base_rev()
    rset = routes()
    old = {}
    if os.path.exists(CSV):
        for r in csv.DictReader(open(CSV)):
            old[r["key"]] = r
    out, md = [], []
    seen = {}
    md.append("# Kernel references: where the CPU code of every kernel is\n")
    md.append(f"Generated by `port/tools/gen_kernels_csv.py` from the kernel tables of `plan.md`. Line numbers are in\n"
              f"the **CPU-view base commit** `{base[:12]}` (`port/agent/cpu_view_base`), i.e. the CPU implementation\n"
              f"you port; view them with `git show {base[:12]}:<file> | sed -n '<a>,<b>p'`, or map them to your working\n"
              f"tree with `python3 port/tools/locate.py <file> <line>` (which takes v4.6.0 lines). plan.md cites\n"
              f"WRF v4.6.0 lines (commit {V460}); both are listed. Status of each kernel: `port/agent/kernels.csv`\n"
              f"(`python3 port/tools/workbook.py status`).\n")
    cur = None
    fam_route, fam_rout = dict(FAMILY_ROUTE), {}
    for r in parse_plan():
        first = re.match(r"K-[A-Za-z0-9.-]+", r["kern"])
        slug = re.sub(r"[^A-Za-z0-9_*-]+", "-", r["kern"].replace("`", "").strip("* ")).strip("-")
        if r["kern"] == "—":
            slug = (r["names"] or ["caller"])[0]
        key = first.group(0).rstrip(".,") if first else f"{r['section']}:{slug}"
        n = seen.get(key, 0)
        seen[key] = n + 1
        if n:
            key = f"{key}#{n + 1}"
        files = []
        for pth in re.findall(r"`?((?:physics_mmm/|dyn_em/|share/|phys/|frame/)[\w/]+\.F(?:90)?)", r["where"]):
            f = pth if pth.startswith(("dyn_em/", "share/", "phys/", "frame/")) else "phys/" + pth
            files.append("WRF/" + f)
        for f, a, b in r["refs"]:
            if f not in files:
                files.append(f)
        rout = []
        for nm in r["names"]:
            f, lr = find_routine(nm, files, base)
            if lr:
                rout.append(f"{nm} {f}:{lr[0]}-{lr[1] or '?'}")
        route = next((nm.lower() for nm in r["names"] if nm.lower() in rset), "") or \
            next((ALIAS[nm.lower()] for nm in r["names"] if nm.lower() in ALIAS), "") or \
            next((ALIAS[nm.lower()] for nm in re.findall(r"`(\w+)", r["kern"]) if nm.lower() in ALIAS), "")
        fam = re.match(r"K-[A-Z0-9]+", r["kern"])
        fam = fam.group(0) if fam else None
        if fam:
            if route:
                fam_route.setdefault(fam, route)
            else:
                route = fam_route.get(fam, "")
            if rout:
                fam_rout.setdefault(fam, rout)
            else:
                rout = fam_rout.get(fam, [])
        if not route and r["kern"] not in ("—",):
            route = SECTION_ROUTE.get(r["section"], "")
        base_refs, v_refs = [], []
        for f, a, b in r["refs"]:
            lm = line_map(f, base)
            ca, cb = lm.get(a), lm.get(b)
            short = f.replace("WRF/", "")
            v_refs.append(f"{short}:{a}" + (f"-{b}" if b != a else ""))
            if ca:
                base_refs.append(f"{short}:{ca}" + (f"-{cb}" if cb and cb != ca else ""))
        tm = re.match(r"\**\s*(A|B|C|D|G)\b", r["how"])
        template = tm.group(1) if tm else ("CP" if "CP-" in r["how"][:12] else "")
        st = "done" if (r["kern"] in DONE_IN_P0 or r["kern"].strip("*") in DONE_IN_P0) else ("n/a" if r["kern"] in ("—", "host", "hoist") else "todo")
        if r["kern"] == "hoist":
            st = "todo"
        prev = old.get(key, {})
        row = dict(key=key, phase=r["phase"], section=r["section"], kernels=r["kern"],
                   routines="; ".join(rout), route=route, template=template,
                   base_refs="; ".join(base_refs), v460_refs="; ".join(v_refs),
                   status=prev.get("status") or st, commit=prev.get("commit", ""),
                   tests=prev.get("tests", ""), notes=prev.get("notes") or ("Phase 0" if st == "done" else ""))
        out.append(row)
        if cur != r["section"]:
            cur = r["section"]
            md.append(f"\n## {r['section']} (Phase {r['phase']})\n")
            md.append("| Key | Kernel(s) | Route | Routines (base commit) | CPU lines to port (base commit) | v4.6.0 (plan.md) |")
            md.append("|---|---|---|---|---|---|")
        md.append(f"| {key} | {r['kern']} | {route} | {row['routines'].replace('; ', '<br>')} | "
                  f"{row['base_refs'].replace('; ', '<br>')} | {row['v460_refs'].replace('; ', '<br>')} |")
    buf = io.StringIO()
    w = csv.DictWriter(buf, fieldnames=FIELDS, lineterminator="\n")
    w.writeheader()
    for row in out:
        w.writerow(row)
    new_csv, new_md = buf.getvalue(), "\n".join(md) + "\n"
    if check:
        same = os.path.exists(CSV) and open(CSV).read() == new_csv and os.path.exists(MD) and open(MD).read() == new_md
        print("kernels.csv/KERNEL_REFS.md up to date" if same else "kernels.csv/KERNEL_REFS.md out of date")
        return 0 if same else 1
    open(CSV, "w").write(new_csv)
    open(MD, "w").write(new_md)
    print(f"{len(out)} rows -> {os.path.relpath(CSV, REPO)}, {os.path.relpath(MD, REPO)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
