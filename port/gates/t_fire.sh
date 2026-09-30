#!/bin/bash
# Fire windows of Phase 4 (plan.md 9.1): T-FIRE-IGN (W-IGN, 02:00-02:35) and
# T-FIRE-WIN (W-FIRE, 02:20-03:00), GPU-REPRO vs CPU-REF, level-1 traces with
# all fire arrays, history frames bitwise, and compare_fire.py: 0 differing
# burned cells in every frame.
#   t_fire.sh [W-IGN|W-FIRE ...]     default: both
set -uo pipefail
source "$(dirname "$0")/lib.sh"
wins=("$@"); [ ${#wins[@]} -gt 0 ] || wins=(W-IGN W-FIRE)
cb=$(build_for cpu-ref) || { result t_fire FAIL "cpu-ref build failed"; gate_end t_fire; }
gb=$(build_for gpu-repro) || { result t_fire FAIL "gpu-repro build failed"; gate_end t_fire; }
for w in "${wins[@]}"; do
  a=$(window "$cb" "$w"); b=$(window "$gb" "$w")
  if [ -z "$a" ] || [ -z "$b" ] || ! run_ok "$a" || ! run_ok "$b"; then result "fire:$w" FAIL "a run failed"; continue; fi
  out=$("$H100/compare.sh" "$a" "$b" 2>&1); rc=$?
  echo "$out" > "$GATE_DIR/fire_$w.txt"
  result "trace+files:$w" "$([ $rc = 0 ] && echo PASS || echo FAIL)" "$GATE_DIR/fire_$w.txt"
  out=$(python3 "$PORT_TOOLS/compare_fire.py" "$a" "$b" --csv "$GATE_DIR/fire_$w.csv" 2>&1); rc=$?
  echo "$out" >> "$GATE_DIR/fire_$w.txt"
  result "compare_fire:$w" "$([ $rc = 0 ] && echo PASS || echo FAIL)" "$(echo "$out" | tail -1)"
done
gate_end t_fire
