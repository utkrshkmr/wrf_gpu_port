#!/bin/bash
# T-UNINIT (plan.md P0.10, RESULTS.md Phase 0 deviation 7) on the H100
# machine: does WRF read memory it did not write, on the paths this case runs?
# Two gfortran builds of the working tree, one starting every local variable
# as signaling NaN and one as zero (build.sh gnu --uninit nan|zero), run the
# same windows serially; the traces and outputs must be bit-identical.  A
# difference names the first field that depends on uninitialized memory.
# Run it before a shared refactor that replaces automatic arrays by zero-filled
# work arrays (P1.7, WORKFLOW.md section 6): if it passes, that refactor
# cannot change results.  Needs gfortran in the image and the gfortran
# netCDF (bash port/h100/setup_toolchain.sh deps-gnu).
#   t_uninit.sh [window ...]   default: W-T0 W-20 with the dev case, S-3M without it
set -uo pipefail
source "$(dirname "$0")/lib.sh"
wins=("$@")
if [ ${#wins[@]} -eq 0 ]; then
  if [ -f "$DEV_CASE/namelist.input" ]; then wins=(W-T0 W-20); else wins=(S-3M); fi
fi
fire=; for w in "${wins[@]}"; do [ "$w" = S-3M ] && fire=--fire-ideal; done
bn=$("$H100/build.sh" gnu --worktree --uninit nan $fire | tail -1) && [ -x "$bn/main/wrf.exe" ] \
  || { result T-UNINIT FAIL "gfortran build (nan) failed: see setup_toolchain.sh deps-gnu"; gate_end T-UNINIT; }
bz=$("$H100/build.sh" gnu --worktree --uninit zero $fire | tail -1) && [ -x "$bz/main/wrf.exe" ] \
  || { result T-UNINIT FAIL "gfortran build (zero) failed"; gate_end T-UNINIT; }
for w in "${wins[@]}"; do
  a=$(window "$bn" "$w"); b=$(window "$bz" "$w")
  if [ -z "$a" ] || [ -z "$b" ] || ! run_ok "$a" || ! run_ok "$b"; then
    result "T-UNINIT:$w" FAIL "a run failed ($a / $b)"; continue
  fi
  out=$("$H100/compare.sh" "$a" "$b" 2>&1); rc=$?
  echo "$out" > "$GATE_DIR/T-UNINIT-$w.txt"
  result "T-UNINIT:$w" "$([ $rc = 0 ] && echo PASS || echo FAIL)" "locals NaN vs zero ($GATE_DIR/T-UNINIT-$w.txt)"
  [ $rc = 0 ] || echo "$out" | head -20
done
gate_end T-UNINIT
