#!/bin/bash
# T-NSYS (plan.md 7.0) / T-NSYS-CLEAN (P5.3): profile a GPU-REPRO window with
# Nsight Systems and count every host<->device copy.  Every copy must be
# explained by an island, a sync point or a bridge that still exists; write the
# explanation into the workbook entry of the gate.
#   t_nsys.sh [window=W-20] [nsys_copies options, e.g. --max-h2d 1000]
set -uo pipefail
source "$(dirname "$0")/lib.sh"
w=${1:-W-20}; shift || true
gb=$(build_for gpu-repro) || { result "T-NSYS:$w" FAIL "gpu-repro build failed"; gate_end "T-NSYS:$w"; }
rd=$WORK/runs/$(build_id "$gb")/$w-nsys
RUN_WRAPPER="nsys profile --force-overwrite=true -t cuda,nvtx,openmp -o $rd/profile" \
  "$H100/window.sh" "$gb" "$w" --dir "$rd" --force >/dev/null || { result "T-NSYS:$w" FAIL "profiled run failed ($rd)"; gate_end "T-NSYS:$w"; }
x nsys stats --report cuda_gpu_trace --format csv --output "$rd/trace" "$rd/profile.nsys-rep" >/dev/null 2>&1
csv=$(ls "$rd"/trace*cuda_gpu_trace*.csv 2>/dev/null | head -1)
[ -n "$csv" ] || { result "T-NSYS:$w" FAIL "nsys stats wrote no CSV in $rd"; gate_end "T-NSYS:$w"; }
out=$(python3 "$PORT_TOOLS/tools/nsys_copies.py" "$csv" "$@" 2>&1); rc=$?
echo "$out" > "$GATE_DIR/T-NSYS-$w.txt"; echo "$out"
result "T-NSYS:$w" "$([ $rc = 0 ] && echo PASS || echo FAIL)" "copies listed in $GATE_DIR/T-NSYS-$w.txt (explain them in the workbook)"
gate_end "T-NSYS:$w"
