#!/bin/bash
# T-DRIFT (plan.md G2-G4): CPU-REF built from the working tree, run over the
# 1 h window W-1H (02:00-03:00, restart from 02:00), equals the dev reference
# $DEV_REF/win1h made with the CPU-view base commit: level-1 traces and the
# history frames bit-identical.  Proves no shared-source change slipped in.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ref=$DEV_REF/win1h
run_ok "$ref" || { result T-DRIFT FAIL "no dev reference $ref (port/h100/dev_case.sh reference)"; gate_end T-DRIFT; }
cb=$(build_for cpu-ref) || { result T-DRIFT FAIL "cpu-ref build failed"; gate_end T-DRIFT; }
b=$(window "$cb" W-1H)
if [ -z "$b" ] || ! run_ok "$b"; then result T-DRIFT FAIL "run failed ($b)"; gate_end T-DRIFT; fi
out=$("$H100/compare.sh" "$ref" "$b" 2>&1); rc=$?
echo "$out" > "$GATE_DIR/T-DRIFT.txt"
result T-DRIFT "$([ $rc = 0 ] && echo PASS || echo FAIL)" "dev reference vs worktree CPU-REF, W-1H ($GATE_DIR/T-DRIFT.txt)"
gate_end T-DRIFT
