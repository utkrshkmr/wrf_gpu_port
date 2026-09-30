#!/bin/bash
# Localize a mismatch with fine tracing (port/agent/DEBUGGING.md).  A debugging
# tool, not a phase gate: it tells you WHERE two runs first differ.
#
#   t_fine.sh <window> [VAR=value ...]                CPU-REF vs GPU-REPRO, both built with --fine
#   t_fine.sh --ab <route> <window> [VAR=value ...]   GPU-REPRO --fine: route off vs on (a T-AB failure)
#
# Both builds come from the working tree with -DWRF_TRACE_FINE (build.sh --fine; the
# arithmetic flags are unchanged) and run with WRF_BITTRACE=3: besides the level-2
# checkpoints there is a checkpoint after every routine called by solve_em,
# first_rk_step_part1/2 and rk_tendency (tags like rk_tendency, p2:cal_deform_and_div,
# rkt:advect_u), and after every CALL bt_fine2/3/f you placed inside a routine.
# The first differing record names the checkpoint after which the runs first differ.
#
# Narrow the run to the step and domain the coarse comparison named (much faster):
#   t_fine.sh W-20 WRF_BITTRACE_FROM=4 WRF_BITTRACE_TO=4 WRF_BITTRACE_DOMAIN=2
#   ... WRF_BITTRACE_FIELDS=RU_TEND,U_2     (only these fields)
# GATE_BUILD_CPU_REF_FINE / GATE_BUILD_GPU_REPRO_FINE reuse builds.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ab=
if [ "${1:-}" = --ab ]; then ab=${2:?usage: t_fine.sh --ab <route> <window> [VAR=value ...]}; shift 2; fi
w=${1:?usage: t_fine.sh [--ab <route>] <window> [VAR=value ...]}; shift
envs=("WRF_BITTRACE=3" "$@")
name=T-FINE${ab:+-AB-$ab}:$w
gb=$(build_for gpu-repro-fine) || { result "$name" FAIL "gpu-repro --fine build failed"; gate_end "$name"; }
if [ -n "$ab" ]; then
  grep -qi "'$ab  *'" "$PORT_REPO/WRF/frame/module_gpu_route.F" || { result "$name" FAIL "unknown route $ab"; gate_end "$name"; }
  a=$(window "$gb" "$w" "${envs[@]}" "WRF_GPU_OFF=$ab"); b=$(window "$gb" "$w" "${envs[@]}")
  what="route $ab off vs on"
else
  cb=$(build_for cpu-ref-fine) || { result "$name" FAIL "cpu-ref --fine build failed"; gate_end "$name"; }
  a=$(window "$cb" "$w" "${envs[@]}"); b=$(window "$gb" "$w" "${envs[@]}")
  what="CPU-REF vs GPU-REPRO"
fi
if [ -z "$a" ] || [ -z "$b" ] || ! run_ok "$a" || ! run_ok "$b"; then
  result "$name" FAIL "a run failed ($a / $b)"
else
  out=$("$H100/compare.sh" "$a" "$b" --no-files 2>&1); rc=$?
  echo "$out" > "$GATE_DIR/$name.txt"
  result "$name" "$([ $rc = 0 ] && echo PASS || echo FAIL)" "$what, level-3 traces ($GATE_DIR/$name.txt)"
  echo "$out" | grep -E "FIRST DIFFERENCE|differing records|^     [A-Z]" | head -25
  echo "runs: $a  $b"
fi
gate_end "$name"
