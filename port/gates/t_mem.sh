#!/bin/bash
# G-MEM (plan.md 3): peak device memory on the FULL case (811x811 nest).
# GPU-REPRO runs the full case from wrfinput for one d01 step (3 s, the first
# step includes a radiation call on both domains) with the memory log of P1.12,
# which prints lines
#   gpu_mem: <where> used <X> GB free <Y> GB total <Z> GB peak <P> GB
# (port/agent/PHASE1.md, P1.12).  Pass: the last peak <= the limit.
#   t_mem.sh <limit GB: 55 at G1, 70 at G3 and G5>
set -uo pipefail
source "$(dirname "$0")/lib.sh"
lim=${1:?usage: t_mem.sh <limit GB>}
gb=$(build_for gpu-repro) || { result G-MEM FAIL "gpu-repro build failed"; gate_end G-MEM; }
rd=$WORK/runs/$(build_id "$gb")/FULL-3S
if ! run_ok "$rd"; then
  rm -rf "${rd:?}"; mkdir -p "$rd"; cd "$rd"
  ln -sf "$gb/main/wrf.exe" wrf.exe
  for t in $TABLES; do ln -sf "$gb/run/$t" "$t"; done
  ln -sf "$gb/run/CAMtr_volume_mixing_ratio.SSP245" CAMtr_volume_mixing_ratio
  for f in wrfinput_d01 wrfinput_d02 wrfbdy_d01; do ln -sf "$CASE_INPUTS/$f" "$f"; done
  cp "$PORT_REPO/cases/eaton_20250108/namelist.input" namelist.input
  nml_set namelist.input run_days=0 run_hours=0 run_minutes=0 run_seconds=3 "end_hour=00, 00" "end_second=03, 03" \
    "history_interval=0, 0" "history_interval_s=100000, 100000" "restart_interval=100000"
  python3 "$PORT_TOOLS/nml.py" namelist.input set --group=domains "nproc_x=1" "nproc_y=1"
  note "full case, one d01 step with the GPU build (the host part runs on one core: this takes long in Phases 1-2)"
  CUDA_VISIBLE_DEVICES=$GPU_ID OMP_TARGET_OFFLOAD=MANDATORY x $MPIRUN -np 1 ./wrf.exe > wrf.stdout 2>&1
fi
peak=$(grep -h "gpu_mem:" "$rd"/rsl.error.0000 2>/dev/null | sed -n 's/.* peak \([0-9.]*\) GB.*/\1/p' | tail -1)
if [ -z "$peak" ]; then result G-MEM FAIL "no 'gpu_mem: ... peak X GB' line in $rd/rsl.error.0000"
else
  ok=$(python3 -c "print(1 if float('$peak') <= float('$lim') else 0)")
  result G-MEM "$([ "$ok" = 1 ] && echo PASS || echo FAIL)" "peak $peak GB (limit $lim GB) run ok: $(run_ok "$rd" && echo yes || echo no)"
fi
gate_end G-MEM
