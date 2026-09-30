#!/bin/bash
# The CPU view is unchanged (fast T-DRIFT, plan.md rule 3): CPU-REF built from
# the working tree gives bit-identical results to CPU-REF of the CPU-view base
# commit on windows W-T0 and W-20 (level-1 traces, i.e. every prognostic field
# at the end of every step, and all output files).  Level 1 because level-2
# checkpoints may be added in the working tree (plan.md P0.7) and would not
# exist in the base build.
#   t_cpu_view.sh [windows...]    default: W-T0 W-20
set -uo pipefail
source "$(dirname "$0")/lib.sh"
wins=("$@"); [ ${#wins[@]} -gt 0 ] || wins=(W-T0 W-20)
bb=$(base_build) || { result t_cpu_view FAIL "base build failed"; gate_end t_cpu_view; }
hb=$(build_for cpu-ref) || { result t_cpu_view FAIL "worktree cpu-ref build failed"; gate_end t_cpu_view; }
for w in "${wins[@]}"; do
  a=$(window "$bb" "$w" WRF_BITTRACE=1); b=$(window "$hb" "$w" WRF_BITTRACE=1)
  if [ -z "$a" ] || [ -z "$b" ] || ! run_ok "$a" || ! run_ok "$b"; then result "cpu_view:$w" FAIL "a run failed ($a / $b)"; continue; fi
  out=$("$H100/compare.sh" "$a" "$b" 2>&1); rc=$?
  echo "$out" > "$GATE_DIR/cpu_view_$w.txt"
  result "cpu_view:$w" "$([ $rc = 0 ] && echo PASS || echo FAIL)" "base vs worktree CPU-REF ($GATE_DIR/cpu_view_$w.txt)"
done
gate_end t_cpu_view
