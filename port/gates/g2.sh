#!/bin/bash
# Gate G2 (plan.md 7, port/agent/PHASE2.md): all dynamics on the device.
# T-AB on W-100 for every Phase 2 route that has kernels, T-TRACE-100,
# T-TRACE-TKE, the reference tests (T-PDLIM, templates), T-NSYS, T-DRIFT.
#   g2.sh [--quick]    --quick: T-AB on W-20 instead of W-100
set -uo pipefail
source "$(dirname "$0")/lib.sh"
G=$PORT_REPO/port/gates
w=W-100; [ "${1:-}" = --quick ] && w=W-20
run() { local log="$GATE_DIR/log_$(echo "$*" | tr ' /' '__').txt"; bash "$G/$1" "${@:2}" > "$log" 2>&1; local rc=$?; result "${1%.sh} ${*:2}" "$([ $rc = 0 ] && echo PASS || echo FAIL)" "$log"; }
run static.sh
run ref_tests.sh
missing=()
for r in $(routes_for_phase 2); do
  if grep -rqi "gpu_on *( *R_$r *)" "$PORT_REPO/WRF" --include='*.F' --include='*.F90' --include='*.inc'; then run t_ab.sh "$r" "$w"
  else missing+=("$r"); fi
done
[ ${#missing[@]} -eq 0 ] && result "routes ported" PASS "all Phase 2 routes have kernels" \
  || result "routes ported" FAIL "no kernel yet: ${missing[*]}"
run t_trace.sh W-100
run t_trace.sh W-TKE
run t_cpu_view.sh W-T0 W-20
run t_drift.sh
run t_nsys.sh W-20
gate_end G2
