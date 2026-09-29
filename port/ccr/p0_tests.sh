#!/bin/bash
# Set up and submit the CPU-REF reproducibility tests (plan.md P0.10):
#
#   T-DET    same binary, 64 ranks, run twice for 1 h                 -> bitwise
#   T-DEC-A  1 rank vs 64 ranks, first 3 d01 steps (27 d02), level 2   -> bitwise
#   T-DEC-B  64 vs 128 vs 144 ranks, 30 simulated minutes              -> bitwise
#   T-RST    continuous 00:00-03:00 vs restart at 02:00 -> 03:00       -> bitwise (or documented)
#   T-XM     1 rank, 3 d01 steps, CCR node vs GPU-node host            -> bitwise
#            (the GPU-node half is submitted by p0_txm_gpu.sh)
#
# Usage: p0_tests.sh <cpu-ref build dir>
# Then, after the jobs finish: p0_check.sh <same build dir>
set -eu
source "$(dirname "$0")/common.sh"
B=${1:?cpu-ref build dir}
[ -x "$B/main/wrf.exe" ] || die "no wrf.exe in $B"
T=$RUNROOT/p0/$(basename "$B")
mkdir -p "$T"
NL=$CASE_REPO/namelist.input
sub() {   # sub <run dir> <ranks> <time> [env...]
  local rd=$1 n=$2 t=$3; shift 3
  local nodes=$(( (n + CORES_PER_NODE - 1) / CORES_PER_NODE ))
  ( cd "$rd" && sbatch -A "$SLURM_ACCOUNT" -p "$SLURM_PARTITION_CPU" ${SLURM_QOS_CPU:+-q $SLURM_QOS_CPU} \
      -N $nodes -n "$n" -t "$t" --export=ALL"${1:+,$1}" "$PORT_TOOLS/ccr/run_wrf.sbatch" | awk '{print $NF}' )
}
short() {   # short <run dir> <ranks> <minutes of d01 steps> ; run length in seconds
  local rd=$1 n=$2 secs=$3
  setup_run "$rd" "$B" "$NL"
  read px py <<< "$(decomp "$n")"
  # run length and output in &time_control, decomposition in &domains
  nml_set namelist.input run_hours=0 run_minutes=0 "run_seconds=$secs" \
    "end_hour=00, 00" "end_minute=00, 00" "end_second=$secs, $secs" "restart_interval=100000" \
    "history_interval=-1, -1"
  python3 "$PORT_TOOLS/nml.py" namelist.input set --group=domains "nproc_x=$px" "nproc_y=$py"
}

# T-DEC-A: 3 d01 steps = 9 s
for n in 1 64; do short "$T/tdec_a_$n" $n 9; done
j1=$(sub "$T/tdec_a_1" 1 04:00:00 WRF_BITTRACE=2)
j2=$(sub "$T/tdec_a_64" 64 01:00:00 WRF_BITTRACE=2)

# T-DEC-B: 30 minutes, level 1
for n in 64 128 144; do short "$T/tdec_b_$n" $n 1800; sub "$T/tdec_b_$n" $n 12:00:00 WRF_BITTRACE=1 >/dev/null; done

# T-DET: 1 hour, twice
for r in 1 2; do short "$T/tdet_$r" 64 3600; sub "$T/tdet_$r" 64 24:00:00 WRF_BITTRACE=1 >/dev/null; done

# T-RST: continuous 3 h with restarts every 60 min, then restart from 02:00 to 03:00
setup_run "$T/trst_cont" "$B" "$NL"
nml_set namelist.input "run_hours=3" "end_hour=03, 03" "restart_interval=60"
python3 "$PORT_TOOLS/nml.py" namelist.input set --group=domains "nproc_x=8" "nproc_y=8"
jc=$(sub "$T/trst_cont" 64 72:00:00 WRF_BITTRACE=1)
mkdir -p "$T/trst_rst"
cat > "$T/trst_rst/SETUP_AFTER_$jc.sh" <<EOS
# run after job $jc: restart from the 02:00 restart files of trst_cont
source "$PORT_TOOLS/ccr/common.sh"
setup_run "$T/trst_rst" "$B" "$NL"
ln -sf $T/trst_cont/wrfrst_d01_2025-01-08_02:00:00 .
ln -sf $T/trst_cont/wrfrst_d02_2025-01-08_02:00:00 .
nml_set namelist.input "restart=.true." "run_hours=1" "start_hour=02, 02" "end_hour=03, 03" "restart_interval=60"
python3 "$PORT_TOOLS/nml.py" namelist.input set --group=domains "nproc_x=8" "nproc_y=8"
EOS
( cd "$T/trst_rst" && sbatch -A "$SLURM_ACCOUNT" -p "$SLURM_PARTITION_CPU" ${SLURM_QOS_CPU:+-q $SLURM_QOS_CPU} \
    -N 2 -n 64 -t 36:00:00 --dependency=afterok:$jc --export=ALL,WRF_BITTRACE=1 \
    --wrap "bash SETUP_AFTER_$jc.sh && bash $PORT_TOOLS/ccr/run_wrf.sbatch" )

# T-XM (CCR half): 1 rank, 3 d01 steps from t=0
short "$T/txm_ccr" 1 9
sub "$T/txm_ccr" 1 04:00:00 WRF_BITTRACE=2 >/dev/null
echo "submitted; run directories under $T"
echo "the GPU-node half of T-XM: port/ccr/p0_txm_gpu.sh $B"
echo "when all jobs are done: port/ccr/p0_check.sh $B"
