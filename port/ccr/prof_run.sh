#!/bin/bash
# P0.15: 1 h CPU-REF run built with -DBENCH, then the Prof-CPU table.
#   prof_run.sh submit <cpu-ref-bench build> [ranks=128]
#   prof_run.sh report <cpu-ref-bench build>
set -eu
source "$(dirname "$0")/common.sh"
B=${2:?cpu-ref-bench build}; R=$RUNROOT/prof/$(basename "$B")
case ${1:?submit|report} in
  submit)
    n=${3:-128}; read px py <<< "$(decomp "$n")"
    setup_run "$R" "$B" "$CASE_REPO/namelist.input"
    nml_set namelist.input "run_hours=1" "end_hour=01, 01" "restart_interval=100000"
    python3 "$PORT_TOOLS/nml.py" namelist.input set --group=domains "nproc_x=$px" "nproc_y=$py"
    sbatch -A "$SLURM_ACCOUNT" -p "$SLURM_PARTITION_CPU" ${SLURM_QOS_CPU:+-q $SLURM_QOS_CPU} \
      -N $(( (n + CORES_PER_NODE - 1) / CORES_PER_NODE )) -n $n -t 24:00:00 "$PORT_TOOLS/ccr/run_wrf.sbatch" ;;
  report)
    python3 "$PORT_TOOLS/prof_cpu.py" "$R/rsl.error.0000" --markdown | tee "$R/PROF_CPU.md"
    python3 "$PORT_TOOLS/gpu_mem_estimate.py" "$R/namelist.input" --check-rsl "$R"/rsl.error.* | tee "$R/MEM_CHECK.txt" ;;
esac
