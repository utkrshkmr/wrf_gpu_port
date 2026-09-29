#!/bin/bash
# Generic WRF job (plan.md P0.10, P0.11): runs wrf.exe in the current run
# folder inside the image.  Submit from the run folder, e.g.
#   sbatch -A $SLURM_ACCOUNT -p $SLURM_PARTITION_CPU -N 1 -n 64 -t 24:00:00 \
#          --export=ALL,WRF_BITTRACE=1 $PORT_REPO/port/ccr/run_wrf.sbatch
# Set GPU=1 in the environment for GPU runs (adds --nv).
#SBATCH --job-name=wrf-gpu-port
#SBATCH --output=slurm-%j.out
set -u
source "$PORT_REPO/port/ccr/common.sh"
cd "${SLURM_SUBMIT_DIR:-.}"
python3 "$PORT_TOOLS/manifest.py" check . -m manifest.md5 || { echo "manifest check failed"; exit 1; }
n=${SLURM_NTASKS:-1}
echo "host $(hostname)  ranks $n  start $(date)" > run_info.txt
env | grep -E '^WRF_|^OMP_' >> run_info.txt
if [ "${GPU:-0}" = 1 ]; then run=inimg_gpu; else run=inimg; fi
if [ "$n" -gt 1 ]; then
  $run $MPIRUN -np "$n" ./wrf.exe
else
  $run ./wrf.exe > rsl.out.0000 2> rsl.error.0000
fi
rc=$?
echo "end $(date) rc=$rc" >> run_info.txt
tail -1 rsl.error.0000 >> run_info.txt 2>/dev/null
exit $rc
