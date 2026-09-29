#!/bin/bash
# T-XM, GPU-node half (plan.md P0.10): run the same CPU-REF binary on the host
# CPU of an A100/H100 node (1 rank, 3 d01 steps, level-2 trace).  Compare with
# p0_check.sh.  A difference means a host math library still reaches the state.
set -eu
source "$(dirname "$0")/common.sh"
B=${1:?cpu-ref build dir}
T=$RUNROOT/p0/$(basename "$B")
rd=$T/txm_gpuhost
setup_run "$rd" "$B" "$CASE_REPO/namelist.input"
nml_set namelist.input run_hours=0 run_minutes=0 run_seconds=9 "end_hour=00, 00" "end_minute=00, 00" \
  "end_second=9, 9" "restart_interval=100000" "history_interval=-1, -1"
sbatch -A "$SLURM_ACCOUNT" -p "$SLURM_PARTITION_GPU" ${SLURM_QOS_GPU:+-q $SLURM_QOS_GPU} -N 1 -n 1 \
  --gpus=1 -t 04:00:00 --export=ALL,WRF_BITTRACE=2 "$PORT_TOOLS/ccr/run_wrf.sbatch"
