#!/bin/bash
# T-DEC (plan.md P0.10) on the H100 machine: CPU-REF built from the working
# tree gives bit-identical results on 1 rank and on $CPU_RANKS ranks.  Every
# T-TRACE compares the GPU build (1 rank) with CPU-REF on $CPU_RANKS ranks, so
# a decomposition-dependent CPU-REF would make GPU work look wrong.  On a
# failure, compare.sh names the first differing field; run CPU-REF windows
# with CPU_RANKS=1 meanwhile and write BLOCKERS.md (PHASE1.md H0.8, P1.1).
#   t_dec.sh [window ...]    default: W-T0 W-20 with the dev case, S-3M without it
# S-3M needs a CPU-REF build made with --fire-ideal (PHASE1.md, "Without the case data").
set -uo pipefail
source "$(dirname "$0")/lib.sh"
wins=("$@")
if [ ${#wins[@]} -eq 0 ]; then
  if [ -f "$DEV_CASE/namelist.input" ]; then wins=(W-T0 W-20); else wins=(S-3M); fi
fi
[ "${CPU_RANKS:-1}" -gt 1 ] || { result T-DEC FAIL "CPU_RANKS=${CPU_RANKS:-} must be > 1 for this test"; gate_end T-DEC; }
cb=$(build_for cpu-ref) || { result T-DEC FAIL "cpu-ref build failed"; gate_end T-DEC; }
for w in "${wins[@]}"; do
  one=$(window "$cb" "$w" --ranks 1 --tag ranks1); many=$(window "$cb" "$w")
  if [ -z "$one" ] || [ -z "$many" ] || ! run_ok "$one" || ! run_ok "$many"; then
    result "T-DEC:$w" FAIL "a run failed ($one / $many)"; continue
  fi
  out=$("$H100/compare.sh" "$one" "$many" 2>&1); rc=$?
  echo "$out" > "$GATE_DIR/T-DEC-$w.txt"
  result "T-DEC:$w" "$([ $rc = 0 ] && echo PASS || echo FAIL)" "1 rank vs $CPU_RANKS ranks ($GATE_DIR/T-DEC-$w.txt)"
  [ $rc = 0 ] || echo "$out" | head -20
done
gate_end T-DEC
