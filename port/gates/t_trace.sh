#!/bin/bash
# T-TRACE (plan.md 7.0): GPU-REPRO equals CPU-REF bit for bit on a window,
# both built from the working tree, restart-vs-restart.
#   t_trace.sh [window=W-100]    (T-TRACE-100 = W-100, T-TRACE-RAD = W-RAD,
#                                 T-TRACE-TKE = W-TKE, G1 = W-20 and W-T0)
set -uo pipefail
source "$(dirname "$0")/lib.sh"
w=${1:-W-100}
cb=$(build_for cpu-ref) || { result "T-TRACE:$w" FAIL "cpu-ref build failed"; gate_end "T-TRACE:$w"; }
gb=$(build_for gpu-repro) || { result "T-TRACE:$w" FAIL "gpu-repro build failed"; gate_end "T-TRACE:$w"; }
a=$(window "$cb" "$w"); b=$(window "$gb" "$w")
if [ -z "$a" ] || [ -z "$b" ] || ! run_ok "$a" || ! run_ok "$b"; then
  result "T-TRACE:$w" FAIL "a run failed ($a / $b)"
else
  out=$("$H100/compare.sh" "$a" "$b" 2>&1); rc=$?
  echo "$out" > "$GATE_DIR/T-TRACE-$w.txt"
  result "T-TRACE:$w" "$([ $rc = 0 ] && echo PASS || echo FAIL)" "CPU-REF vs GPU-REPRO ($GATE_DIR/T-TRACE-$w.txt)"
  [ $rc = 0 ] || echo "$out" | head -30
  grep -h "wall_s" "$a/window.info" "$b/window.info" | sed 's/^/    /'
fi
gate_end "T-TRACE:$w"
