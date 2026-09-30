#!/bin/bash
# T-GATE (plan.md P1.8, G1): the startup gate gpu_check_config rejects every
# namelist of port/tests/gate/bad_*.input, naming the option listed in
# expected.txt, and accepts ok_*.input.  Also checks that port/check_case.py
# agrees (run_check_case.py).
# Contract of gpu_check_config (port/agent/PHASE1.md, P1.8): it prints one line
#   gpu_check_config: VIOLATION <option>(d0N) = <value> ...
# per violation and then calls wrf_error_fatal, or prints
#   gpu_check_config: PASS
# With WRF_GPU_CHECK_ONLY=1 wrf.exe stops right after the check (no inputs needed).
set -uo pipefail
source "$(dirname "$0")/lib.sh"
G=$PORT_REPO/port/tests/gate
out=$(python3 "$G/run_check_case.py" 2>&1); rc=$?
result check_case "$([ $rc = 0 ] && echo PASS || echo FAIL)" "$(echo "$out" | tail -1)"
gb=$(build_for gpu-repro) || { result T-GATE FAIL "gpu-repro build failed"; gate_end T-GATE; }
while read -r f want; do
  [ -n "$f" ] || continue
  rd=$GATE_DIR/t_gate/${f%.input}; rm -rf "${rd:?}"; mkdir -p "$rd"; cd "$rd"
  cp "$G/$f" namelist.input
  ln -sf "$gb/main/wrf.exe" wrf.exe
  WRF_GPU_CHECK_ONLY=1 CUDA_VISIBLE_DEVICES=$GPU_ID x $MPIRUN -np 1 ./wrf.exe > wrf.stdout 2>&1
  log=$(cat rsl.error.0000 wrf.stdout 2>/dev/null)
  if [ "$want" = PASS ]; then
    if echo "$log" | grep -q "gpu_check_config: PASS" && ! echo "$log" | grep -q "gpu_check_config: VIOLATION"; then
      result "T-GATE:$f" PASS "accepted"
    else result "T-GATE:$f" FAIL "not accepted (see $rd)"; fi
  else
    if echo "$log" | grep "gpu_check_config: VIOLATION" | grep -qi "$want"; then
      result "T-GATE:$f" PASS "rejected, names $want"
    else result "T-GATE:$f" FAIL "not rejected with '$want' (see $rd)"; fi
  fi
done < <(grep -v '^#' "$G/expected.txt")
gate_end T-GATE
