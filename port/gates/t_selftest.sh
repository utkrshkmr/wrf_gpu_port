#!/bin/bash
# In-model self tests of Phase 1 (plan.md P1.2-P1.7, G1): T-MAP, T-TAB,
# T-POOL, T-WORK.  GPU-REPRO runs W-20 with WRF_GPU_SELFTEST=1; the port's
# code (port/agent/PHASE1.md, "Self-test output contract") prints lines
#   gpu_selftest: T-MAP  PASS <details>      (or FAIL <details>)
# to rsl.error.0000.  Every test named on the command line must report PASS.
#   t_selftest.sh [tests...]     default: T-MAP T-TAB T-POOL T-WORK
set -uo pipefail
source "$(dirname "$0")/lib.sh"
tests=("$@"); [ ${#tests[@]} -gt 0 ] || tests=(T-MAP T-TAB T-POOL T-WORK)
gb=$(build_for gpu-repro) || { result selftest FAIL "gpu-repro build failed"; gate_end selftest; }
rd=$(window "$gb" W-20 WRF_GPU_SELFTEST=1)
if [ -z "$rd" ] || ! run_ok "$rd"; then result selftest FAIL "run failed ($rd)"; gate_end selftest; fi
for t in "${tests[@]}"; do
  line=$(grep -h "gpu_selftest: $t " "$rd"/rsl.error.0000 | tail -1)
  if [ -z "$line" ]; then result "$t" FAIL "no 'gpu_selftest: $t' line in $rd/rsl.error.0000"
  elif echo "$line" | grep -q " PASS"; then result "$t" PASS "${line#*$t }"
  else result "$t" FAIL "${line#*$t }"; fi
done
gate_end selftest
