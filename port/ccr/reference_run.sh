#!/bin/bash
# P0.11: the CPU-REF reference run of the full case, and the extra 02:00->02:20
# restart run that makes the 02:20 restart files (fire active) used by the
# windows.  Archive with archive_reference.sh when both are done.
#   reference_run.sh <cpu-ref build dir> [ranks=128]
set -eu
source "$(dirname "$0")/common.sh"
B=${1:?cpu-ref build dir}; n=${2:-128}
R=$RUNROOT/reference/$(basename "$B")
read px py <<< "$(decomp "$n")"
nodes=$(( (n + CORES_PER_NODE - 1) / CORES_PER_NODE ))
setup_run "$R/full" "$B" "$CASE_REPO/namelist.input"
python3 "$PORT_TOOLS/nml.py" namelist.input set --group=domains "nproc_x=$px" "nproc_y=$py"
j=$(sbatch -A "$SLURM_ACCOUNT" -p "$SLURM_PARTITION_CPU" ${SLURM_QOS_CPU:+-q $SLURM_QOS_CPU} -N $nodes -n $n \
      -t 72:00:00 --export=ALL,WRF_BITTRACE=1 "$PORT_TOOLS/ccr/run_wrf.sbatch" | awk '{print $NF}')
echo "reference job $j in $R/full"
mkdir -p "$R/rst0220"
cat > "$R/rst0220/setup.sh" <<EOS
source "$PORT_TOOLS/ccr/common.sh"
setup_run "$R/rst0220" "$B" "$CASE_REPO/namelist.input"
ln -sf $R/full/wrfrst_d01_2025-01-08_02:00:00 .
ln -sf $R/full/wrfrst_d02_2025-01-08_02:00:00 .
nml_set namelist.input "restart=.true." "start_hour=02, 02" "end_hour=02, 02" "end_minute=20, 20" \
  "run_hours=0" "run_minutes=20" "restart_interval=20" "history_interval=-1, -1"
python3 "$PORT_TOOLS/nml.py" namelist.input set --group=domains "nproc_x=$px" "nproc_y=$py"
EOS
( cd "$R/rst0220" && sbatch -A "$SLURM_ACCOUNT" -p "$SLURM_PARTITION_CPU" ${SLURM_QOS_CPU:+-q $SLURM_QOS_CPU} \
    -N $nodes -n $n -t 12:00:00 --dependency=afterok:$j --export=ALL,WRF_BITTRACE=1 \
    --wrap "bash setup.sh && bash $PORT_TOOLS/ccr/run_wrf.sbatch" )
echo "then: port/ccr/archive_reference.sh $B"
