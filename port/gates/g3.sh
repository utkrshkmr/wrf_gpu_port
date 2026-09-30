#!/bin/bash
# Gate G3 (plan.md 8, port/agent/PHASE3.md): all physics on the device.
# T-AB (W-100; radiation routes W-RAD) for every Phase 3 route, T-TRACE-100,
# T-TRACE-RAD, the reference tests (T-KISS, T-OZN, column harnesses), T-NSYS, T-DRIFT, G-MEM 70 GB.
#   g2.sh [--quick]    --quick: T-AB on W-20 instead of W-100
set -uo pipefail
source "$(dirname "$0")/lib.sh"
G=$PORT_REPO/port/gates
w=W-100; [ "${1:-}" = --quick ] && w=W-20
run() { local log="$GATE_DIR/log_$(echo "$*" | tr ' /' '__').txt"; bash "$G/$1" "${@:2}" > "$log" 2>&1; local rc=$?; result "${1%.sh} ${*:2}" "$([ $rc = 0 ] && echo PASS || echo FAIL)" "$log"; }
run static.sh
run ref_tests.sh
missing=()
for r in $(routes_for_phase 3); do
  if grep -rqi "gpu_on *( *R_$r *)" "$PORT_REPO/WRF" --include='*.F' --include='*.F90' --include='*.inc'; then case $r in radiation_driver|rrtmg_lwrad|swrad|cal_cldfra1|ozn_time_int|ozn_p_int|calc_coszen) run t_ab.sh "$r" W-RAD ;; *) run t_ab.sh "$r" "$w" ;; esac
  else missing+=("$r"); fi
done
[ ${#missing[@]} -eq 0 ] && result "routes ported" PASS "all Phase 3 routes have kernels" \
  || result "routes ported" FAIL "no kernel yet: ${missing[*]}"
run t_trace.sh W-100
run t_trace.sh W-RAD
run t_mem.sh 70
for h in "$PORT_REPO"/port/tests/columns/run_*.sh; do [ -e "$h" ] && run ../tests/columns/$(basename "$h"); done
run t_cpu_view.sh W-T0 W-20
run t_drift.sh
run t_nsys.sh W-20
gate_end G3
