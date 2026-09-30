#!/bin/bash
# T-AB-<route> (plan.md P0.8): the device version of one routine equals its
# host execution on real data.  GPU-REPRO (working tree) runs the window twice,
# with WRF_GPU_OFF=<route> and with everything on; the level-2 traces and the
# output files must be identical.
#   t_ab.sh <route> [window=W-20]     route names: WRF/frame/module_gpu_route.F
# Use W-20 while developing, W-100 (radiation: W-RAD) for the sub-phase gates.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
r=${1:?usage: t_ab.sh <route> [window]}; w=${2:-W-20}
grep -qi "'$r  *'" "$PORT_REPO/WRF/frame/module_gpu_route.F" || { result "T-AB-$r" FAIL "unknown route $r"; gate_end "T-AB-$r"; }
gb=$(build_for gpu-repro) || { result "T-AB-$r" FAIL "gpu-repro build failed"; gate_end "T-AB-$r"; }
on=$(window "$gb" "$w"); off=$(window "$gb" "$w" "WRF_GPU_OFF=$r")
if [ -z "$on" ] || [ -z "$off" ] || ! run_ok "$on" || ! run_ok "$off"; then
  result "T-AB-$r:$w" FAIL "a run failed ($on / $off)"
else
  out=$("$H100/compare.sh" "$off" "$on" 2>&1); rc=$?
  echo "$out" > "$GATE_DIR/T-AB-$r-$w.txt"
  result "T-AB-$r:$w" "$([ $rc = 0 ] && echo PASS || echo FAIL)" "off vs on ($GATE_DIR/T-AB-$r-$w.txt)"
  [ $rc = 0 ] || echo "$out" | head -30
fi
gate_end "T-AB-$r"
