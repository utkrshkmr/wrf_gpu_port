#!/usr/bin/env python3
"""Generate the island code of a ported routine (port/agent/CODING_STANDARD.md,
"Islands").

An island moves a routine's array arguments between host and device when the
routine runs where the current data are not (module_gpu_route: gpu_island(r),
gpu_world_host).  It is the same code in every phase:
  - Phases 1-4 (host world, the whole-solve_em bracket): a route that is ON
    copies its arrays to the device, runs there and copies the results back;
  - Phase 5 on (device world): a route that is OFF copies its arrays to the
    host, runs there and copies the results back (this is what T-AB uses).

The island is generated from the routine's dummy arguments:
  entry: every array dummy (all intents: an INTENT(OUT) array is only partly
         written by most WRF routines, so the rest must be current too)
  exit:  every array dummy that is not INTENT(IN)
  TYPE(domain) dummies use the generated whole-state updates
  (gpu_upd_dev_all / gpu_upd_host_all, plan.md P1.3); OPTIONAL dummies are
  updated under IF (PRESENT(x)); scalars, CHARACTER and other derived types
  are not moved (kernels take scalars as firstprivate).

The island also carries the CALL CHECK (module_gpu_callcheck,
DEBUGGING.md section 0b): with WRF_GPU_CALLCHECK=<route> a call runs twice,
on the device and then on the host with the same inputs, and every argument
the routine may change (arrays and scalars that are not INTENT(IN)) is
compared bit for bit.  It needs a statement label on the entry (the host pass
jumps back to it): the generator picks one that the routine does not use.
Routines with TYPE(domain) dummies get no call check (--no-check also omits it).

Usage:
  gen_island.py <WRF source file> <routine> [--route R_NAME] [--no-check]
Prints the declarations, the entry block and the exit block, the line of the
first executable statement (put the entry block there, at the top level of the
routine, after early RETURNs that do no work) and every RETURN of the routine
(put the exit block before each RETURN that follows the entry, and before END
SUBROUTINE).  Warnings name dummies that cannot be moved (assumed-size arrays)
and must be handled by hand.
"""

import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ftn  # noqa: E402

TYPES = r"(real|integer|logical|double\s*precision|complex|character|type\s*\(\s*\w+\s*\)|class\s*\(\s*\w+\s*\))"
DECL = re.compile(r"^\s*" + TYPES + r"(?!\w)(.*)$", re.I)


def split_top(s, sep=","):
    out, depth, cur, q = [], 0, "", None
    for c in s:
        if q:
            cur += c
            if c == q:
                q = None
            continue
        if c in "'\"":
            q = c
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        if c == sep and depth == 0:
            out.append(cur)
            cur = ""
        else:
            cur += c
    if cur.strip():
        out.append(cur)
    return [x.strip() for x in out]


def parse(path, name):
    lines = open(path, errors="replace").read().split("\n")
    stmts = [(n, s) for n, s, d in ftn.statements(list(enumerate(lines, 1))) if not d and not s.lstrip().startswith("#")]
    start = None
    for i, (n, s) in enumerate(stmts):
        if re.match(r"^\s*(recursive\s+|pure\s+|elemental\s+)*subroutine\s+" + re.escape(name) + r"\b", s, re.I):
            start = i
            break
    if start is None:
        raise SystemExit(f"SUBROUTINE {name} not found in {path}")
    m = re.search(r"\((.*)\)", stmts[start][1])
    dummies = [d.strip().lower() for d in (m.group(1).split(",") if m else []) if d.strip()]
    info = {d: dict(array=False, intent=None, optional=False, dtype=None, char=False, assumed_size=False, base=None)
            for d in dummies}
    first_exec, returns, end_line = None, [], None
    in_contains = False
    for n, s in stmts[start + 1:]:
        low = s.strip().lower()
        if re.match(r"^end\s*subroutine\b", low) or low == "end":
            if not in_contains:
                end_line = n
                break
            continue
        if low == "contains":
            in_contains = True
            if first_exec is None:
                first_exec = n
            continue
        if in_contains:
            if re.match(r"^end\s*subroutine\s+" + re.escape(name.lower()) + r"\b", low):
                end_line = n
                break
            continue
        md = DECL.match(s)
        if md and ("::" in s or re.match(r"^\s*" + TYPES + r"\s*(\*\s*\d+)?\s+\w", s, re.I)) \
                and not re.match(r"^\s*(real|integer|logical)\s*function\b", s, re.I):
            tspec = md.group(1).lower()
            rest = md.group(2)
            if "::" in s:
                attrs, names = s.split("::", 1)
            else:
                attrs, names = s[:md.end(1)], rest
            al = attrs.lower()
            dim = re.search(r"dimension\s*\(", al)
            intent = re.search(r"intent\s*\(\s*(in|out|inout|in\s+out)\s*\)", al)
            for ent in split_top(names):
                nm = re.match(r"(\w+)\s*(\(.*\))?", ent)
                if not nm:
                    continue
                v = nm.group(1).lower()
                if v not in info:
                    continue
                d = info[v]
                if dim or nm.group(2):
                    d["array"] = True
                    shape = nm.group(2) or al[dim.end() - 1:]
                    if re.search(r"\*\s*\)", shape.split("::")[0] if shape else ""):
                        d["assumed_size"] = True
                if intent:
                    d["intent"] = intent.group(1).replace(" ", "")
                if "optional" in al:
                    d["optional"] = True
                if tspec.startswith("type") or tspec.startswith("class"):
                    d["dtype"] = re.sub(r"\s", "", tspec)
                if tspec.startswith("character"):
                    d["char"] = True
                d["base"] = base_type(tspec, attrs)
                if "pointer" in al or "allocatable" in al:
                    d["array"] = d["array"] or "dimension" in al
            continue
        for kw, key in (("intent", "intent"), ("optional", "optional"), ("dimension", "dim")):
            mm = re.match(r"^\s*" + kw + r"\s*(\(\s*(\w+)\s*\))?\s*(::)?\s*(.*)$", s, re.I)
            if mm and (kw != "intent" or mm.group(2)):
                for ent in split_top(mm.group(4)):
                    v = re.match(r"(\w+)", ent)
                    if v and v.group(1).lower() in info:
                        d = info[v.group(1).lower()]
                        if kw == "intent":
                            d["intent"] = mm.group(2).lower()
                        elif kw == "optional":
                            d["optional"] = True
                        else:
                            d["array"] = True
                break
        else:
            if re.match(r"^\s*(implicit|use|parameter|save|data|external|intrinsic|equivalence|common|namelist|"
                        r"include|private|public)\b", s, re.I):
                continue
            if first_exec is None:
                first_exec = n
            if re.match(r"^\s*(if\s*\(.*\)\s*)?return\b", s, re.I):
                returns.append(n)
    labels = set()
    if start is not None:
        lo = stmts[start][0]
        hi = end_line or len(lines)
        for ln in lines[lo:hi]:
            m = re.match(r"^\s*(\d+)\s", ln)
            if m:
                labels.add(int(m.group(1)))
    return dummies, info, first_exec, returns, end_line, labels


def base_type(tspec, attrs):
    """'r', 'd', 'i', 'l' for the call-check routines, None for others"""
    t = re.sub(r"\s", "", tspec.lower())
    a = re.sub(r"\s", "", attrs.lower())
    if t.startswith("doubleprecision") or re.match(r"^real(\*8|\((kind=)?(8|r8|kind_r8|selected_real_kind\(1[2-5]))", a):
        return "d"
    if t.startswith("real"):
        return "r"
    if t.startswith("integer") and not re.match(r"^integer(\*8|\((kind=)?8)", a):
        return "i"
    if t.startswith("logical"):
        return "l"
    return None


def directive(clause, names, indent="        "):
    out, cur = [], f"!$omp target update {clause}("
    for i, v in enumerate(names):
        piece = v + (", " if i < len(names) - 1 else ")")
        if len(cur) + len(piece) > 100:
            out.append(cur + "&")
            cur = "!$omp&   "
        cur += piece
    out.append(cur)
    return out


def block(arrays, opt, grids, to_dev_first, flip_first):
    """to_dev_first: in the host world, copy to the device (entry) or from it (exit)."""
    a, b = ("to", "from") if to_dev_first else ("from", "to")
    g1, g2 = ("gpu_upd_dev_all", "gpu_upd_host_all") if to_dev_first else ("gpu_upd_host_all", "gpu_upd_dev_all")
    L = []
    if flip_first:
        L.append("        gpu_world_host = .NOT. gpu_world_host")
    L.append("        IF (gpu_world_host) THEN")
    if arrays:
        L += directive(a, arrays)
    for o in opt:
        L += [f"          IF (PRESENT({o})) THEN"] + directive(a, [o], "          ") + ["          END IF"]
    for g in grids:
        L.append(f"          CALL {g1}({g})")
    L.append("        ELSE")
    if arrays:
        L += directive(b, arrays)
    for o in opt:
        L += [f"          IF (PRESENT({o})) THEN"] + directive(b, [o], "          ") + ["          END IF"]
    for g in grids:
        L.append(f"          CALL {g2}({g})")
    L.append("        END IF")
    if not flip_first:
        L.append("        gpu_world_host = .NOT. gpu_world_host")
    return L


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("file")
    ap.add_argument("routine")
    ap.add_argument("--route", help="R_<NAME> (default: R_<ROUTINE>)")
    ap.add_argument("--no-check", action="store_true", help="omit the call-check code")
    args = ap.parse_args()
    route = args.route or "R_" + args.routine.upper()
    dummies, info, first_exec, returns, end_line, labels = parse(args.file, args.routine)
    ent_arr, ent_opt, ex_arr, ex_opt, grids, warn = [], [], [], [], [], []
    for d in dummies:
        x = info[d]
        if x["dtype"] == "type(domain)":
            grids.append(d)
            continue
        if not x["array"] or x["char"] or x["dtype"]:
            continue
        if x["assumed_size"]:
            warn.append(f"{d}: assumed-size array (*): cannot be moved by name; move the actual argument in the caller")
            continue
        (ent_opt if x["optional"] else ent_arr).append(d)
        if x["intent"] != "in":
            (ex_opt if x["optional"] else ex_arr).append(d)
        if x["intent"] is None:
            warn.append(f"{d}: no INTENT; treated as INOUT")
    # call check: every argument the routine may change (not INTENT(IN))
    chk, cwarn = [], []
    for d in dummies:
        x = info[d]
        if x["intent"] == "in" or x["char"] or x["dtype"] or x["assumed_size"]:
            continue
        if x["base"] is None:
            cwarn.append(f"{d}: type not handled by the call check; it is not compared")
            continue
        chk.append((d, x))
    check = not args.no_check and not grids
    label = next(n for n in range(99901, 99999) if n not in labels)
    rel = os.path.relpath(os.path.abspath(args.file), os.path.dirname(os.path.dirname(HERE)))
    print(f"! island of {args.routine} ({rel}), route {route}; generated by port/tools/gen_island.py")
    print(f"! {len(ent_arr) + len(ent_opt)} arrays in, {len(ex_arr) + len(ex_opt)} out"
          + (f", whole state of {', '.join(grids)}" if grids else "")
          + (f"; call check of {len(chk)} arguments, entry label {label}" if check else "; no call check"))
    print("\n! (1) add to the USE statements:")
    print(f"      USE module_gpu_route, ONLY : gpu_on, gpu_island, gpu_world_host, {route}")
    if check:
        print("      USE module_gpu_callcheck")
    print("\n! (2) add to the declarations:")
    print("#ifdef WRF_GPU\n      LOGICAL :: gpu_isl\n#endif")
    print(f"\n! (3) entry: at the first executable statement (line {first_exec}), at the top level of the routine,"
          " after early RETURNs that do no work:")
    print("#ifdef WRF_GPU")
    if check:
        print(f"{label} CONTINUE")
        print(f"      IF (gpu_cc_start({route})) THEN")
        for k, (d, x) in enumerate(chk, 1):
            call = (f"CALL gpu_cc_save_{x['base']}({k}, {d}, SIZE({d},KIND=8))" if x["array"]
                    else f"CALL gpu_cc_save_{x['base']}0({k}, {d})")
            print(f"        IF (PRESENT({d})) {call}" if x["optional"] else f"        {call}")
        print("      END IF")
    print(f"      gpu_isl = gpu_island({route})")
    print("      IF (gpu_isl) THEN")
    print("\n".join(block(ent_arr, ent_opt, grids, True, False)))
    print("      END IF\n#endif")
    print(f"\n! (4) exit: before END SUBROUTINE (line {end_line})"
          + (f" and before each RETURN after the entry (RETURN lines: {', '.join(map(str, returns))})" if returns else "")
          + ":")
    print("#ifdef WRF_GPU")
    print("      IF (gpu_isl) THEN")
    print("\n".join(block(ex_arr, ex_opt, grids, False, True)))
    print("      END IF")
    if check:
        print(f"      IF (gpu_cc_active({route})) THEN")
        for k, (d, x) in enumerate(chk, 1):
            if x["array"]:
                call = (f"CALL gpu_cc_done_{x['base']}({k}, {d}, SIZE({d},KIND=8), '{d}', &\n"
                        f"          LBOUND({d}), UBOUND({d}))")
            else:
                call = f"CALL gpu_cc_done_{x['base']}0({k}, {d}, '{d}')"
            print(f"        IF (PRESENT({d})) {call}" if x["optional"] else f"        {call}")
        print(f"        IF (gpu_cc_next({route})) GOTO {label}")
        print("      END IF")
    print("#endif")
    for w in warn + (cwarn if check else []):
        print(f"! WARNING {w}")
    if grids and not args.no_check:
        print("! NOTE no call check: TYPE(domain) dummies (use t_ab.sh and t_fine.sh)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
