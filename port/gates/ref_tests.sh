#!/bin/bash
# Standalone reference tests on the GPU (port/tests/run_ref_tests.sh):
# T-PDLIM, T-KISS, T-OZN, templates B/C/G, their mutants, check_verbatim.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
# Python (mutants, check_verbatim) runs on the host; compilers and test programs in the container
out=$(CUDA_VISIBLE_DEVICES=$GPU_ID TC="bash $H100/x.sh" bash "$PORT_REPO/port/tests/run_ref_tests.sh" nvhpc 2>&1); rc=$?
echo "$out" > "$GATE_DIR/ref_tests.log"
echo "$out" | grep -E '^(PASS|FAIL)' | while read -r s rest; do result "ref:${rest%% *}" "$s" "${rest#* }"; done
result ref_tests "$([ $rc = 0 ] && echo PASS || echo FAIL)" "log: $GATE_DIR/ref_tests.log"
[ $rc = 0 ] || GATE_FAIL=1
gate_end ref_tests
