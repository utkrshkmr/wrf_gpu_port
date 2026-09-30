#!/bin/bash
# Gate G5, the part that runs on the H100 machine (plan.md 10,
# port/agent/PHASE5.md).  The full 17 h acceptance runs (G5 items 1-9) are
# done later on CCR/A100/H100 by the project owner.
#   T-AB for the Phase 5 routes, T-FORCE (W-FORCE), T-SLAB and T-O3 (self
#   tests of the GPU-DEBUG build), T-NSYS-CLEAN (200 d02 steps), T-OUT/T-BDY
#   (history, restart and a boundary read inside W-1H), T-DRIFT, G-MEM 70 GB.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
G=$PORT_REPO/port/gates
run() { local log="$GATE_DIR/log_$(echo "$*" | tr ' /' '__').txt"; bash "$G/$1" "${@:2}" > "$log" 2>&1; local rc=$?; result "${1%.sh} ${*:2}" "$([ $rc = 0 ] && echo PASS || echo FAIL)" "$log"; }
run static.sh
run ref_tests.sh
for r in $(routes_for_phase 5); do run t_ab.sh "$r" W-FORCE; done
run t_trace.sh W-FORCE
run t_trace.sh W-100
run t_trace.sh W-RAD
run t_selftest.sh T-SLAB T-O3
run t_nsys.sh W-100
run t_trace.sh W-1H
run t_fire.sh W-IGN W-FIRE
run t_drift.sh
run t_mem.sh 70
gate_end G5-H100
