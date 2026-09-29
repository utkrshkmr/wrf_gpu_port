#!/usr/bin/env python3
"""Device-memory estimate for a WRF case on one GPU (plan.md 3, P0.15).

Parses the Registry (includes, "ifdef NAME=VAL" blocks, dimspecs, rconfig
defaults, packages) and evaluates it for a namelist.input, the way WRF
decides what alloc_space_field allocates:

  state        every Registry state field in use for the domain's options
               (fields listed in packages are allocated only if one of their
               packages is active); 4D arrays with their active members;
               boundary arrays of fields with the 'b' flag; fire-grid fields
               on the refined mesh
  i1 pool      the solve_em scratch arrays (plan.md P1.6), sized for the
               largest domain
  work arrays  large automatic arrays moved to persistent work arrays
               (plan.md P1.7), approximated as 18 3D arrays of the largest
               domain plus 12 fire-grid arrays
  RRTMG batch  WRF_RRTMG_BATCH columns x about 2500 words x NLAYERS
  local memory per-thread column-physics stack x resident threads
  context      CUDA context, runtime pool, fragmentation

Memory dimensions for one MPI rank: (e_we+2h) x e_vert x (e_sn+2h) with the
RSL halo h = 5; fire mesh (e_we+2h)*sr_x x (e_sn+2h)*sr_y.

Usage:
  gpu_mem_estimate.py namelist.input [--registry WRF/Registry] [--gpu-gb 80]
                      [--check-rsl rsl.error.0000 ...] [--halo 5]

--check-rsl compares the state estimate with the "alloc_space_field: domain
N, B bytes allocated" lines WRF prints (sum them over all rsl files of a
multi-rank run; pass them all).  P0.15 requires agreement within 5 %.
"""

import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_REGISTRY = os.path.join(HERE, "..", "WRF", "Registry")
DEFINES = {"EM_CORE": "1", "NMM_CORE": "0", "DA_CORE": "0", "WRFPLUS": "0", "BUILD_CHEM": "0",
           "BUILD_RRTMG_FAST": "0", "BUILD_RRTMK": "0", "BUILD_SBM_FAST": "1", "WRF_HYDRO": "0"}
TYPE_BYTES = {"real": 4, "integer": 4, "logical": 4, "doubleprecision": 8, "character": 1}


# ----------------------------------------------------------------------------
# Registry
# ----------------------------------------------------------------------------

def read_registry(path, defines, seen=None):
    """Return the list of logical lines after includes, ifdefs and continuations."""
    seen = seen or set()
    out = []
    base = os.path.dirname(path)
    stack = []
    with open(path, errors="replace") as f:
        raw = f.read().split("\n")
    buf = ""
    for line in raw:
        line = line.split("#", 1)[0].rstrip() if not line.lstrip().startswith("#") else ""
        if line.endswith("\\"):
            buf += line[:-1] + " "
            continue
        line = buf + line
        buf = ""
        s = line.strip()
        if not s:
            continue
        tok = s.split()
        kw = tok[0].lower()
        if kw in ("ifdef", "ifndef"):
            cond = tok[1] if len(tok) > 1 else ""
            if "=" in cond:
                name, val = cond.split("=", 1)
                ok = defines.get(name) == val
            else:
                ok = cond in defines
            if kw == "ifndef":
                ok = not ok
            stack.append(ok)
            continue
        if kw == "endif":
            if stack:
                stack.pop()
            continue
        if kw == "else":
            if stack:
                stack[-1] = not stack[-1]
            continue
        if not all(stack):
            continue
        if kw == "include":
            inc = os.path.join(base, tok[1])
            if inc not in seen and os.path.exists(inc):
                seen.add(inc)
                out.extend(read_registry(inc, defines, seen))
            continue
        out.append(s)
    return out


def split_fields(line):
    """Split a Registry line into tokens, keeping quoted strings together."""
    return re.findall(r'"[^"]*"|\S+', line)


class Registry:
    def __init__(self, lines):
        self.dimspecs = {}      # name -> (how, axis)
        self.states = []        # dicts
        self.i1 = []
        self.rconfig = {}       # name -> default string
        self.packages = []      # (name, var, value, {kind: [names]})
        for s in lines:
            t = split_fields(s)
            kw = t[0].lower()
            if kw == "dimspec" and len(t) >= 5:
                self.dimspecs[t[1]] = (t[3], t[4])
            elif kw in ("state", "i1") and len(t) >= 7:
                d = {"type": t[1].lower(), "name": t[2].lower(), "dims": t[3], "use": t[4].lower(),
                     "ntl": int(t[5]) if t[5].isdigit() else 1}
                (self.states if kw == "state" else self.i1).append(d)
            elif kw == "rconfig" and len(t) >= 6:
                self.rconfig[t[2].lower()] = t[5]
            elif kw == "package" and len(t) >= 5:
                m = re.match(r"(\w+)==(\S+)", t[2])
                lists = {}
                for part in t[4].split(";"):
                    if ":" in part:
                        k, v = part.split(":", 1)
                        lists.setdefault(k.lower(), []).extend(x.lower() for x in v.split(",") if x)
                if m:
                    self.packages.append((t[1].lower(), m.group(1).lower(), m.group(2), lists))


def parse_dims(dims):
    """'ikj' / '*i*j' / 'i{snly}j' / 'ikjftb' -> list of (dim, refined), flags."""
    out = []
    flags = set()
    i = 0
    refined = False
    while i < len(dims):
        c = dims[i]
        if c == "{":
            j = dims.index("}", i)
            out.append((dims[i + 1:j], refined))
            refined = False
            i = j + 1
            continue
        if c == "*":
            refined = True
            i += 1
            continue
        lc = c.lower()
        if lc in ("b", "f", "t"):
            flags.add(lc)
        elif c != "-":
            out.append((c, refined))
            refined = False
        i += 1
    return out, flags


# ----------------------------------------------------------------------------
# namelist
# ----------------------------------------------------------------------------

def read_namelist(path):
    vals = {}
    for line in open(path):
        line = line.split("!", 1)[0]
        m = re.match(r"\s*(\w+)\s*=\s*(.*)$", line)
        if m:
            vals[m.group(1).lower()] = [v.strip() for v in m.group(2).split(",") if v.strip()]
    return vals


def apply_check_a_mundo(nml):
    """Dimensions WRF derives at run time (share/module_check_a_mundo.F)."""
    lw = str(nml.get("ra_lw_physics", ["0"])[0])
    sw = str(nml.get("ra_sw_physics", ["0"])[0])
    if lw in ("4", "14", "24") or sw in ("4", "14", "24"):
        nml.setdefault("levsiz", ["59"])
        nml.setdefault("alevsiz", ["12"])
        nml.setdefault("no_src_types", ["6"])
    if lw == "3" or sw == "3":
        nml.setdefault("paerlev", ["29"])
        nml.setdefault("levsiz", ["59"])
        nml.setdefault("cam_abs_dim1", ["4"])
        nml.setdefault("cam_abs_dim2", [nml.get("e_vert", ["1"])[0]])


def nml_value(nml, reg, name, dom):
    name = name.lower()
    if name in nml:
        v = nml[name]
        return v[dom] if dom < len(v) else v[0]
    return reg.rconfig.get(name)


def as_num(s):
    try:
        return int(s)
    except (TypeError, ValueError):
        try:
            return float(str(s).replace("d", "e").replace("D", "e"))
        except (TypeError, ValueError):
            return str(s).strip(".").lower() if s is not None else None


def dim_size(reg, nml, dom, d, refined, mem):
    how, axis = reg.dimspecs.get(d, ("?", "?"))
    if how == "standard_domain":
        n = {"x": mem[0], "y": mem[2], "z": mem[1]}.get(axis, 1)
    elif how.startswith("namelist="):
        v = as_num(nml_value(nml, reg, how.split("=", 1)[1], dom))
        n = int(v) if isinstance(v, (int, float)) else 1
    elif how.startswith("constant="):
        c = how.split("=", 1)[1]
        m = re.match(r"\((-?\d+):(-?\d+)\)", c)
        n = int(m.group(2)) - int(m.group(1)) + 1 if m else int(c)
    else:
        n = 1
    if refined:
        sr = int(as_num(nml_value(nml, reg, "sr_x" if axis == "x" else "sr_y", dom)) or 1)
        n *= max(sr, 1)
    return max(n, 1)


def estimate_domain(reg, nml, dom, halo):
    e_we = int(nml_value(nml, reg, "e_we", dom))
    e_sn = int(nml_value(nml, reg, "e_sn", dom))
    e_vert = int(nml_value(nml, reg, "e_vert", dom))
    mem = (e_we + 2*halo, e_vert, e_sn + 2*halo)
    sbw = int(as_num(nml_value(nml, reg, "spec_bdy_width", dom)) or 5)

    active_members = {}          # 4D name -> set(members)
    pkg_fields = {}              # field -> list of package active flags
    for pname, var, val, lists in reg.packages:
        v = as_num(nml_value(nml, reg, var, dom))
        on = (v == as_num(val)) if v is not None else False
        for kind, names in lists.items():
            for nm in names:
                if kind == "state":
                    pkg_fields.setdefault(nm, []).append(on)
                else:
                    pkg_fields.setdefault(kind + ":" + nm, []).append(on)
                    if on:
                        active_members.setdefault(kind, set()).add(nm)

    tot = {"3d": 0, "2d": 0, "4d": 0, "fire": 0, "bdy": 0, "other": 0}
    four_d = {}                  # 4D name -> (bytes per member, flags)
    for f in reg.states:
        dims, flags = parse_dims(f["dims"])
        if not dims:
            continue
        size = 1
        fire = False
        for d, refined in dims:
            size *= dim_size(reg, nml, dom, d, refined, mem)
            fire = fire or refined
        nbytes = size*TYPE_BYTES.get(f["type"], 4)
        if "f" in flags:
            # member of a 4D array named in the use column
            key = f["use"] + ":" + f["name"]
            if f["use"] in active_members and f["name"] in active_members[f["use"]]:
                four_d.setdefault(f["use"], [nbytes, 0, "b" in flags, mem])
                four_d[f["use"]][1] += f["ntl"]
            continue
        if f["name"] in pkg_fields and not any(pkg_fields[f["name"]]):
            continue
        nbytes *= f["ntl"]
        cat = "fire" if fire else ("3d" if len(dims) >= 3 else ("2d" if len(dims) == 2 else "other"))
        tot[cat] += nbytes
        if "b" in flags:
            # 4 edges x (value + tendency) x spec_bdy_width x (other horizontal dim) x k
            k = mem[1] if any(reg.dimspecs.get(d, ("", ""))[1] == "z" for d, _ in dims) else 1
            tot["bdy"] += 8*sbw*max(mem[0], mem[2])*k*4*f["ntl"]
    for name, (per, n, bdy, m) in four_d.items():
        # index 1 is unused (PARAM_FIRST_SCALAR = 2)
        tot["4d"] += per*(n + 1)
        if bdy:
            tot["bdy"] += 8*sbw*max(m[0], m[2])*m[1]*4*(n + 1)
    return mem, tot, sum(tot.values()), active_members


def i1_pool_bytes(reg, nml, dom, halo, active_members):
    e_we = int(nml_value(nml, reg, "e_we", dom))
    e_sn = int(nml_value(nml, reg, "e_sn", dom))
    e_vert = int(nml_value(nml, reg, "e_vert", dom))
    mem = (e_we + 2*halo, e_vert, e_sn + 2*halo)
    b = 0
    for f in reg.i1:
        if f["type"] != "real":
            continue
        dims, _ = parse_dims(f["dims"])
        size = 1
        for d, refined in dims:
            size *= dim_size(reg, nml, dom, d, refined, mem)
        b += size*4
    nm = len(active_members.get("moist", ())) + 1
    b += 2*nm*mem[0]*mem[1]*mem[2]*4          # moist_tend, moist_old
    return b


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("namelist")
    ap.add_argument("--registry", default=DEFAULT_REGISTRY)
    ap.add_argument("--top", default="Registry.EM")
    ap.add_argument("--halo", type=int, default=5)
    ap.add_argument("--gpu-gb", type=float, default=80.0)
    ap.add_argument("--rrtmg-batch", type=int, default=4096)
    ap.add_argument("--stack-kb", type=float, default=30.0, help="per-thread column-physics stack")
    ap.add_argument("--threads", type=int, default=270000, help="max resident threads (H100 ~270k, A100 ~221k)")
    ap.add_argument("--check-rsl", nargs="*")
    args = ap.parse_args()

    reg = Registry(read_registry(os.path.join(args.registry, args.top), DEFINES))
    nml = read_namelist(args.namelist)
    apply_check_a_mundo(nml)
    ndom = int(nml.get("max_dom", ["1"])[0])
    GB = 1e9
    print(f"Registry: {len(reg.states)} state, {len(reg.i1)} i1, {len(reg.packages)} packages, "
          f"{len(reg.dimspecs)} dimspecs")
    total = 0.0
    state = {}
    largest3d = 0
    largest_fire = 0
    pool = 0
    for dom in range(ndom):
        mem, tot, s, active = estimate_domain(reg, nml, dom, args.halo)
        state[dom + 1] = s
        total += s
        pts = mem[0]*mem[1]*mem[2]
        largest3d = max(largest3d, pts)
        sr = int(as_num(nml_value(nml, reg, "sr_x", dom)) or 0)
        if sr > 0 and int(as_num(nml_value(nml, reg, "ifire", dom)) or 0) > 0:
            largest_fire = max(largest_fire, mem[0]*sr*mem[2]*sr)
        pool = max(pool, i1_pool_bytes(reg, nml, dom, args.halo, active))
        print(f"d{dom + 1:02d}: memory {mem[0]} x {mem[1]} x {mem[2]}  state {s/GB:7.2f} GB "
              f"(3D {tot['3d']/GB:.2f}, 2D {tot['2d']/GB:.2f}, 4D {tot['4d']/GB:.2f}, "
              f"fire {tot['fire']/GB:.2f}, bdy {tot['bdy']/GB:.2f}, other {tot['other']/GB:.2f})  "
              f"moist members {sorted(active.get('moist', []))}")
    work = 18*largest3d*4 + 12*largest_fire*4
    nlay = int(nml_value(nml, reg, "e_vert", 0)) + 50
    rrtmg = args.rrtmg_batch*2500*nlay*4
    local = args.stack_kb*1024*args.threads
    ctx = 1.5e9
    grand = total + pool + work + rrtmg + local + ctx
    print(f"i1 scratch pool          {pool/GB:7.2f} GB")
    print(f"work arrays (approx.)    {work/GB:7.2f} GB")
    print(f"RRTMG batch ({args.rrtmg_batch} cols) {rrtmg/GB:7.2f} GB")
    print(f"local memory             {local/GB:7.2f} GB")
    print(f"context etc.             {ctx/GB:7.2f} GB")
    print(f"TOTAL                    {grand/GB:7.2f} GB   (limit for a {args.gpu_gb:.0f} GB GPU: "
          f"{0.875*args.gpu_gb:.0f} GB)  -> {'fits' if grand/GB <= 0.875*args.gpu_gb else 'DOES NOT FIT'}")

    status = 0
    if args.check_rsl:
        measured = {}
        for p in args.check_rsl:
            for line in open(p, errors="replace"):
                m = re.search(r"alloc_space_field: domain\s+(\d+)\s*,\s*(\d+)\s+bytes allocated", line)
                if m:
                    measured[int(m.group(1))] = measured.get(int(m.group(1)), 0) + int(m.group(2))
        for dom, b in sorted(measured.items()):
            if dom in state:
                err = (state[dom] - b)/b
                ok = abs(err) <= 0.05
                status |= 0 if ok else 1
                print(f"check d{dom:02d}: estimated {state[dom]/GB:.3f} GB, WRF allocated {b/GB:.3f} GB, "
                      f"error {100*err:+.1f} %  {'OK' if ok else 'OUTSIDE 5 %'}")
    return status


if __name__ == "__main__":
    sys.exit(main())
