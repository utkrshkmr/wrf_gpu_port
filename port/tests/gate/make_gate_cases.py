#!/usr/bin/env python3
"""Write the T-GATE namelists (plan.md P1.8, G1): each bad_*.input violates
exactly one rule of port/config_envelope.txt; ok_*.input changes only free
options.  expected.txt lists, per file, PASS or the option the startup gate
(gpu_check_config) and port/check_case.py must name.

Run: python3 port/tests/gate/make_gate_cases.py   (writes into this directory)
     python3 port/tests/gate/run_check_case.py    (checks port/check_case.py)
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", ".."))
import nml  # noqa: E402

REF = os.path.join(HERE, "..", "..", "..", "cases", "eaton_20250108", "namelist.input")
CASES = [
    ("bad_cu_physics", [("cu_physics", "1, 1")], "cu_physics"),
    ("bad_mp_physics", [("mp_physics", "8, 8")], "mp_physics"),
    ("bad_sr_odd", [("sr_x", "0, 3"), ("sr_y", "0, 3")], "sr_x"),
    ("bad_e_vert", [("e_vert", "80, 80")], "e_vert"),
    ("bad_fire_upwinding", [("fire_upwinding", "0, 3")], "fire_upwinding"),
    ("bad_nwp_diagnostics", [("nwp_diagnostics", "1")], "nwp_diagnostics"),
    ("bad_diff_opt", [("diff_opt", "1, 1")], "diff_opt"),
    ("bad_pbl_on_d02", [("bl_pbl_physics", "1, 1")], "bl_pbl_physics"),
    ("bad_nlayers", [("p_top_requested", "50000")], "NLAYERS"),
    ("ok_other_fire", [("start_month", "07, 07"), ("start_day", "15, 15"), ("end_month", "07, 07"),
                       ("end_day", "15, 15"), ("e_we", "450, 181"), ("e_sn", "450, 181"),
                       ("i_parent_start", "1, 200"), ("j_parent_start", "1, 210"),
                       ("fire_ignition_start_lat1", "0, 38.5"), ("fire_ignition_start_lon1", "0, -121.3")], "PASS"),
]


def main():
    text = open(REF).read()
    with open(os.path.join(HERE, "expected.txt"), "w") as exp:
        exp.write("# file  expected (PASS, or the option the gate must name)\n")
        for name, pairs, want in CASES:
            t = nml.set_values(text, pairs, group_for_new="physics" if name == "bad_nwp_diagnostics" else "domains")
            open(os.path.join(HERE, name + ".input"), "w").write(t)
            exp.write(f"{name}.input {want}\n")
    print(f"wrote {len(CASES)} namelists and expected.txt")


if __name__ == "__main__":
    main()
