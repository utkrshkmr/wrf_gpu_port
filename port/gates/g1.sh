#!/bin/bash
# Gate G1 (plan.md 6, port/agent/PHASE1.md): GPU infrastructure with all
# compute still on the host.  Runs every item and prints a PASS/FAIL table
# (T-DEC: CPU-REF on 1 rank equals CPU-REF on $CPU_RANKS ranks).
set -uo pipefail
source "$(dirname "$0")/lib.sh"
G=$PORT_REPO/port/gates
run() { bash "$G/$1" "${@:2}" > "$GATE_DIR/log_$1_${2:-}.txt" 2>&1; local rc=$?; result "${1%.sh} ${*:2}" "$([ $rc = 0 ] && echo PASS || echo FAIL)" "$GATE_DIR/log_$1_${2:-}.txt"; }
run static.sh
run t_gate.sh
run t_selftest.sh T-MAP T-TAB T-POOL T-WORK
run t_upd.sh
run t_trace.sh W-T0
run t_trace.sh W-20
run t_cpu_view.sh W-T0 W-20
run t_dec.sh
run t_mem.sh 55
gate_end G1
