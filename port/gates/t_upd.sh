#!/bin/bash
# T-UPD (plan.md P1.3, G1; PHASE1.md step "P1.5 + P1.9"): with
# WRF_GPU_UPD_EVERY_STEP=1 the end of the solve_em bracket copies the whole
# state host->device->host once more (gpu_upd_dev_all then gpu_upd_host_all)
# before its final upload; results stay bit-identical to CPU-REF on W-20.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
cb=$(build_for cpu-ref) || { result T-UPD FAIL "cpu-ref build failed"; gate_end T-UPD; }
gb=$(build_for gpu-repro) || { result T-UPD FAIL "gpu-repro build failed"; gate_end T-UPD; }
a=$(window "$cb" W-20); b=$(window "$gb" W-20 WRF_GPU_UPD_EVERY_STEP=1)
if [ -z "$a" ] || [ -z "$b" ] || ! run_ok "$a" || ! run_ok "$b"; then result T-UPD FAIL "a run failed"; else
  out=$("$H100/compare.sh" "$a" "$b" 2>&1); rc=$?
  echo "$out" > "$GATE_DIR/T-UPD.txt"
  result T-UPD "$([ $rc = 0 ] && echo PASS || echo FAIL)" "$GATE_DIR/T-UPD.txt"
fi
gate_end T-UPD
