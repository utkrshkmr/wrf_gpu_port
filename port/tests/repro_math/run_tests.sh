#!/bin/bash
# Run the reproducible-math tests in order (plan.md P0.5) on an A100 or H100
# node and write results_<host>_<date>.txt.  T-FMA runs first: if the device
# fuses a*b+c nothing else is meaningful (plan.md 15, risk register).
#
# Usage: ./run_tests.sh [quick]
#   quick: 2**24 random values per test and 4 of 64 blocks in T-RM-EXH
set -u
cd "$(dirname "$0")"
out="results_$(hostname -s)_$(date +%Y%m%d_%H%M%S).txt"
{
  echo "host: $(hostname)"; date
  nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv 2>/dev/null
  nvfortran --version 2>/dev/null | head -2
} | tee "$out"

if [ "${1:-}" = quick ]; then LG=24; NCH=4; else LG=30; NCH=64; fi
status=0
run() { echo "== $*" | tee -a "$out"; "$@" 2>&1 | tee -a "$out"; rc=${PIPESTATUS[0]}; [ $rc -ne 0 ] && status=1; return $rc; }

run ./t_fma fma_cases.bin || { echo "T-FMA failed: stop (plan.md 15)" | tee -a "$out"; exit 1; }
run ./t_ieee $LG
run ./t_ipow $((LG - 4))
run ./t_rm_exh 1 12 $NCH
run ./t_rm_pow $LG
run ./t_rm_d $LG
echo "overall: $([ $status -eq 0 ] && echo PASS || echo FAIL)" | tee -a "$out"
exit $status
