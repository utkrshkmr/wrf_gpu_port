#!/bin/bash
# Fast per-routine check: seconds to a few minutes instead of a W-20 run
# (port/agent/DEBUGGING.md, "Fast checks").  Infrastructure (fixable as a tool fix).
#
#   harness.sh <WRF file> <routine> [--route NAME] [--builds DIR1,DIR2] [--namelist FILE]
#              [--domain D] [--grid NX,NY,NZ] [--set k=v] [--range k=lo:hi] [--shape k=b,...] [--use MODULE]
#
# The working-tree version of <WRF file> (e.g. WRF/dyn_em/module_big_step_utilities_em.F)
# is compiled against existing builds, with each build's own commands
# (port/h100/build_cmds.py; nothing in the builds is changed), and linked with a
# generated driver (port/h100/gen_harness.py) that calls <routine> once on
# pseudo-random inputs and writes its outputs.  Default builds: the worktree
# builds of cpu-ref and gpu-repro ($WORK/builds/<mode>/worktree; build them once
# with build.sh; afterwards only the one file is recompiled here).  Compared bit for bit
# (port/tools/harness_diff.py):
#   HOST vs DEVICE   GPU build, WRF_GPU_OFF=<route> vs route on   (what T-AB checks)
#   CPU vs DEVICE    CPU-REF build (CPU view) vs GPU build        (what T-TRACE checks)
# With a gnu test build only HOST vs DEVICE runs (both on the host: a determinism check).
#
# --route: the route of the routine (default: the routine name).  --namelist: the
# namelist the driver reads its config_flags from (default $DEV_CASE/namelist.input).
# The other options go to gen_harness.py (see its --help): scalars the driver
# cannot know are printed as "harness default: ..." lines; set the ones that
# select a code path (e.g. --set rk_step=3) to test that path.
#
# PASS is a quick pre-check on random data, not the acceptance test: a routine is
# done only after t_ab.sh and t_trace.sh on W-20 (WORKFLOW.md "Done").
set -uo pipefail
source "$(dirname "$0")/common.sh"
file=${1:?usage: harness.sh <WRF file> <routine> [options]}; routine=${2:?routine}; shift 2
route=$routine; builds=; nml=${DEV_CASE}/namelist.input; gen=()
while [ $# -gt 0 ]; do
  case $1 in
    --route) route=${2:?}; shift ;;
    --builds) builds=${2:?}; shift ;;
    --namelist) nml=${2:?}; shift ;;
    --domain|--grid|--set|--range|--shape|--use) gen+=("$1" "${2:?}"); shift ;;
    *) die "unknown option $1" ;;
  esac
  shift
done
rel=${file#*WRF/}; [ -f "$PORT_REPO/WRF/$rel" ] || die "no $PORT_REPO/WRF/$rel"
[ -f "$nml" ] || die "no namelist $nml (--namelist FILE)"
if [ -z "$builds" ]; then builds="$WORK/builds/cpu-ref/worktree,$WORK/builds/gpu-repro/worktree"; fi
root=$WORK/harness/$routine
mkdir -p "$root"
declare -A out
fail=0
for b in ${builds//,/ }; do
  b=$(cd "$b" 2>/dev/null && pwd) || die "no build $b (build.sh <mode> --worktree first)"
  mode=$(build_mode "$b"); [ -n "$mode" ] || die "no BUILD_INFO in $b"
  case $mode in gpu-*) gmode=gpu ;; *) gmode=cpu ;; esac
  t=$root/$mode; rm -rf "${t:?}"; mkdir -p "$t/run"
  [ -f "$b/compile_cmds.json" ] || python3 "$HERE_H100/build_cmds.py" update "$b" >/dev/null
  python3 "$HERE_H100/build_cmds.py" script "$b" "$rel" "$PORT_REPO/WRF/$rel" "$t" > "$t/compile.sh" || die "no compile commands"
  python3 "$HERE_H100/gen_harness.py" "$PORT_REPO/WRF/$rel" "$routine" --mode $gmode "${gen[@]}" \
    > "$t/harness_driver.f90" 2> "$t/gen.log" || { cat "$t/gen.log" >&2; die "gen_harness failed"; }
  python3 "$HERE_H100/build_cmds.py" fc "$b" "$(dirname "$rel")" "$t/harness_driver.f90" "$t" > "$t/fc.sh"
  base=$(basename "${rel%.*}")
  python3 "$HERE_H100/build_cmds.py" link "$b" "$t/harness.exe" "$t/harness_driver.o" "$t/$base.o" > "$t/link.sh"
  note "$mode: compiling $rel and the driver ($t)"
  (cd "$t" && x bash compile.sh) > "$t/compile.log" 2>&1 || { grep -i -m 20 -E "error|severe" "$t/compile.log" >&2; die "$rel does not compile ($t/compile.log)"; }
  (cd "$t" && x bash fc.sh) > "$t/fc.log" 2>&1 || { grep -i -m 20 -E "error|severe" "$t/fc.log" >&2; die "driver does not compile ($t/fc.log)"; }
  (cd "$b/main" && x bash "$t/link.sh") > "$t/link.log" 2>&1 || { tail -20 "$t/link.log" >&2; die "link failed ($t/link.log)"; }
  cp "$nml" "$t/run/namelist.input"
  runs=(cpu); [ $gmode = gpu ] && runs=(host dev); [ "$mode" = gnu ] && runs=(host dev)
  for r in "${runs[@]}"; do
    (
      cd "$t/run"; rm -f harness_out.bin
      unset WRF_GPU_OFF WRF_GPU_ONLY
      [ "$r" = host ] && export WRF_GPU_OFF=$route
      if [ $gmode = gpu ]; then export CUDA_VISIBLE_DEVICES=$GPU_ID OMP_TARGET_OFFLOAD=MANDATORY; fi
      if [ "$mode" = gnu ]; then x ../harness.exe; else x $MPIRUN -np 1 ../harness.exe; fi
    ) > "$t/run_$r.log" 2>&1
    if [ -f "$t/run/harness_out.bin" ]; then mv "$t/run/harness_out.bin" "$t/out_$r.bin"; out[$mode:$r]=$t/out_$r.bin
    else tail -15 "$t/run_$r.log" >&2; note "$mode $r run failed ($t/run_$r.log)"; fail=1; fi
    grep -h "harness default" "$t/run_$r.log" | sort -u | sed 's/^/    /' >&2 || true
  done
done
res() { printf '%-5s %s\n' "$1" "$2"; }
for m in $(printf '%s\n' "${!out[@]}" | cut -d: -f1 | sort -u); do
  if [ -n "${out[$m:host]:-}" ] && [ -n "${out[$m:dev]:-}" ]; then
    if python3 "$PORT_TOOLS/tools/harness_diff.py" "${out[$m:host]}" "${out[$m:dev]}" --label "$m host vs device" > "$root/diff_$m.txt"; then
      res PASS "HOST vs DEVICE ($m): $routine"; grep -h "warning" "$root/diff_$m.txt" | sed 's/^ */      /' | head -5
    else res FAIL "HOST vs DEVICE ($m): $routine ($root/diff_$m.txt)"; grep DIFFERENT "$root/diff_$m.txt" | head; fail=1; fi
  fi
done
cpu=$(printf '%s\n' "${!out[@]}" | grep ':cpu$' | head -1); dev=$(printf '%s\n' "${!out[@]}" | grep -E '^gpu-.*:dev$' | head -1)
if [ -n "$cpu" ] && [ -n "$dev" ]; then
  if python3 "$PORT_TOOLS/tools/harness_diff.py" "${out[$cpu]}" "${out[$dev]}" --label "CPU view vs device" > "$root/diff_cpu_dev.txt"; then
    res PASS "CPU vs DEVICE: $routine"; grep -h "warning" "$root/diff_cpu_dev.txt" | sed 's/^ */      /' | head -5
  else res FAIL "CPU vs DEVICE: $routine ($root/diff_cpu_dev.txt)"; grep DIFFERENT "$root/diff_cpu_dev.txt" | head; fail=1; fi
fi
echo "harness $routine: $([ $fail = 0 ] && echo PASS || echo FAIL)  (files: $root)"
exit $fail
