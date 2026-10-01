#!/bin/bash
# T-CALLCHECK (port/agent/DEBUGGING.md 0b): the island call check finds a
# device-only difference on its first call, names the element, restores the
# inputs (the scalar counter counts each call once), and passes a correct
# routine.  Called by port/tests/run_ref_tests.sh.
#   run_callcheck.sh [nvhpc|gnu]      TC: prefix for compiler/run commands
set -u
comp=${1:-nvhpc}
cd "$(dirname "$0")"
say() { printf '%-6s %s\n' "$1" "$2"; }
python3 make_mock.py > /dev/null || { say FAIL "T-CALLCHECK: make_mock.py"; exit 1; }
make -s COMPILER=$comp clean > /dev/null 2>&1
${TC:-} make -s COMPILER=$comp > build.log 2>&1 || { say FAIL "T-CALLCHECK: build (port/tests/callcheck/build.log)"; exit 1; }
export OMP_NUM_THREADS=2
ok=$(WRF_GPU_CALLCHECK=calc_alt:2 ${TC:-} ./t_cc_ok 2>&1)
bug=$(WRF_GPU_CALLCHECK=calc_alt:2 ${TC:-} ./t_cc_bug 2>&1)
quiet=$(${TC:-} ./t_cc_bug 2>&1)
fail=0
chk() { if eval "$2"; then :; else say FAIL "T-CALLCHECK: $1"; fail=1; fi; }
chk "correct routine: call 1 PASS" 'echo "$ok" | grep -q "gpu_callcheck: calc_alt call 1: PASS (1 arrays, 1 scalars"'
chk "correct routine: call 2 PASS" 'echo "$ok" | grep -q "gpu_callcheck: calc_alt call 2: PASS"'
chk "only the first 2 calls checked" '! echo "$ok" | grep -q "call 3"'
chk "inputs restored (scalar counted once per call)" 'echo "$ok" | grep -q "^ncall=3$" && echo "$bug" | grep -q "^ncall=3$"'
chk "device-only bug: DIFF names alt(2,3,4)" 'echo "$bug" | grep -q "DIFF alt(2,3,4) host .* device .*, 1 of [0-9]* values differ"'
chk "device-only bug: call 1 FAIL" 'echo "$bug" | grep -q "calc_alt call 1: FAIL (1 of 2 arguments differ)"'
chk "no check without WRF_GPU_CALLCHECK" '! echo "$quiet" | grep -q gpu_callcheck'
if [ $fail = 0 ]; then say PASS "T-CALLCHECK (island call check: device-only difference found at its element, inputs restored)"
else echo "--- correct:"; echo "$ok" | tail -6; echo "--- with bug:"; echo "$bug" | tail -6; fi
exit $fail
