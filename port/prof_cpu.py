#!/usr/bin/env python3
"""CPU profile of a WRF run built with -DBENCH (plan.md P0.15, table Prof-CPU).

Reads rsl.error.0000 (or the stdout of a serial run).  With -DBENCH,
solve_em prints "<timer>= <microseconds>" for every timer at the end of each
call; the "Timing for main: time ... on domain N" line that follows closes
the step and gives its wall time.  The script adds the timers per domain and
reports seconds per simulated hour for each timer and for the sections of
plan.md 11.1, plus I/O ("Timing for Writing ...") and the time outside
solve_em (nest forcing, I/O, driver).

Usage: prof_cpu.py rsl.error.0000 [--markdown]
"""

import argparse
import collections
import re
import sys
from datetime import datetime

SECTIONS = collections.OrderedDict([
    ("dynamics RK", ["step_prep_tim", "set_phys_bc_tim", "rk_tend_tim", "relax_bdy_dry_tim", "calc_p_rho_tim",
                     "bc_2d_tim", "calc_mu_uv_tim"]),
    ("acoustic", ["small_step_prep_tim", "set_phys_bc2_tim", "advance_uv_tim", "spec_bdy_uv_tim",
                  "advance_mu_t_tim", "spec_bdy_t_tim", "sumflux_tim", "advance_w_tim", "spec_bdynhyd_tim",
                  "cald_p_rho_tim", "phys_bc_tim", "small_step_finish_tim"]),
    ("scalar transport", ["rk_scalar_tend_tim", "rlx_bdy_scalar_tim", "update_scal_tim", "flow_depbdy_tim",
                          "tke_adv_tim", "chem_adv_tim", "tracer_adv_tim", "scal_adv_tim"]),
    ("turbulence", ["comp_diff_metrics_tim", "tke_diff_bc_tim", "deform_div_tim", "calc_tke_tim",
                    "tke_rhs_tim", "vert_diff_tim", "hor_diff_tim"]),
    ("physics prep/tend", ["init_zero_tend_tim", "phy_prep_tim", "cal_phy_tend", "update_phy_ten_tim",
                           "moist_physics_prep_tim", "moist_phys_end_tim", "microswap_1", "microswap_2"]),
    ("radiation", ["rad_driver_tim"]),
    ("surface", ["surf_driver_tim"]),
    ("PBL", ["pbl_driver_tim"]),
    ("microphysics", ["micro_driver_tim"]),
    ("cumulus/fdda", ["cu_driver_tim", "shcu_driver_tim", "fdda_driver_tim"]),
])

TIMER = re.compile(r"^\s*(\w+)=\s+(-?\d+)\s*$")
MAIN = re.compile(r"Timing for main: time (\S+) on domain\s+(\d+):\s+([\d.]+) elapsed seconds")
WRITE = re.compile(r"Timing for Writing (\S+) for domain\s+(\d+):\s+([\d.]+) elapsed seconds")


def parse_time(s):
    for fmt in ("%Y-%m-%d_%H:%M:%S", "%Y-%m-%d_%H:%M:%S.%f"):
        try:
            return datetime.strptime(s, fmt)
        except ValueError:
            pass
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("log")
    ap.add_argument("--markdown", action="store_true")
    args = ap.parse_args()

    pending = collections.Counter()
    timers = collections.defaultdict(collections.Counter)    # dom -> timer -> us
    wall = collections.Counter()
    steps = collections.Counter()
    first = {}
    last = {}
    io = collections.Counter()
    for line in open(args.log, errors="replace"):
        m = TIMER.match(line)
        if m:
            pending[m.group(1)] += int(m.group(2))
            continue
        m = MAIN.search(line)
        if m:
            dom = int(m.group(2))
            t = parse_time(m.group(1))
            wall[dom] += float(m.group(3))
            steps[dom] += 1
            first.setdefault(dom, t)
            last[dom] = t
            timers[dom].update(pending)
            pending.clear()
            continue
        m = WRITE.search(line)
        if m:
            io[int(m.group(2))] += float(m.group(3))

    if not steps:
        print("no 'Timing for main' lines found")
        return 1
    rows = []
    for dom in sorted(steps):
        # simulated time: steps x dt, dt from the time stamps
        sim = None
        if first[dom] and last[dom] and steps[dom] > 1:
            span = (last[dom] - first[dom]).total_seconds()
            sim = span*steps[dom]/(steps[dom] - 1)
        hours = (sim or 3600.0)/3600.0
        tsolve = timers[dom].get("solve_tim", 0)/1e6
        rows.append((dom, "wall (Timing for main)", wall[dom]/hours))
        if tsolve:
            rows.append((dom, "solve_em (solve_tim)", tsolve/hours))
            accounted = 0.0
            for sec, names in SECTIONS.items():
                v = sum(timers[dom].get(n, 0) for n in names)/1e6
                accounted += v
                rows.append((dom, "  " + sec, v/hours))
            rows.append((dom, "  other in solve_em (incl. fire, halos)", (tsolve - accounted)/hours))
            rows.append((dom, "outside solve_em (forcing, I/O, driver)", (wall[dom] - tsolve)/hours))
        rows.append((dom, "history/restart writes", io[dom]/hours))
        print(f"d{dom:02d}: {steps[dom]} steps, simulated {hours:.3f} h, wall {wall[dom]:.1f} s")
    if args.markdown:
        print("\n| Domain | Section | s per simulated hour |\n|---|---|---:|")
        for dom, name, v in rows:
            print(f"| d{dom:02d} | {name.strip()} | {v:.1f} |")
    else:
        for dom, name, v in rows:
            print(f"d{dom:02d}  {name:45s} {v:12.1f} s/h")
        print("\nall timers (s in total):")
        for dom in sorted(timers):
            for name, us in sorted(timers[dom].items(), key=lambda x: -x[1]):
                print(f"d{dom:02d}  {name:30s} {us/1e6:12.2f} s total")
    return 0


if __name__ == "__main__":
    sys.exit(main())
