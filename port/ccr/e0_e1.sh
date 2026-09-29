#!/bin/bash
# P0.13 E0: compare the CPU-REF reference with the original CCR run.
# P0.14 E1: 1-ulp perturbation of T at the ignition point, 17 h CPU-REF run,
#           compared with the reference (submitted here; compare when done).
#   e0_e1.sh e0 <cpu-ref build dir> <original run folder>
#   e0_e1.sh e1-submit <cpu-ref build dir> [ranks=128]
#   e0_e1.sh e1-compare <cpu-ref build dir>
set -eu
source "$(dirname "$0")/common.sh"
what=${1:?e0|e1-submit|e1-compare}; B=${2:?build}
A=$REFROOT/eaton_20250108/$(basename "$B")
case $what in
  e0)
    orig=${3:?original run folder}
    python3 "$PORT_TOOLS/compare_fire.py" "$A" "$orig" --csv "$A/E0_fire.csv" --png "$A/E0_png" | tee "$A/E0.txt"
    python3 "$PORT_TOOLS/compare_fields.py" --dirs "$A" "$orig" --pattern 'wrfout_d02_2025-01-08_17:00:00' | tee -a "$A/E0.txt" ;;
  e1-submit)
    n=${3:-128}; read px py <<< "$(decomp "$n")"
    E=$RUNROOT/e1/$(basename "$B"); mkdir -p "$E/inputs"
    python3 "$PORT_TOOLS/perturb_input.py" "$CASE_INPUTS/wrfinput_d02" "$E/inputs/wrfinput_d02" | tee "$E/perturbation.txt"
    ln -sf "$CASE_INPUTS/wrfinput_d01" "$E/inputs/"; ln -sf "$CASE_INPUTS/wrfbdy_d01" "$E/inputs/"
    # the manifest check would reject the perturbed input: use a manifest without it
    setup_run "$E/run" "$B" "$CASE_REPO/namelist.input" "$CASE_INPUTS"
    ln -sf "$E/inputs/wrfinput_d02" wrfinput_d02
    grep -v wrfinput_d02 manifest.md5 > m && mv m manifest.md5
    python3 "$PORT_TOOLS/nml.py" namelist.input set --group=domains "nproc_x=$px" "nproc_y=$py"
    sbatch -A "$SLURM_ACCOUNT" -p "$SLURM_PARTITION_CPU" ${SLURM_QOS_CPU:+-q $SLURM_QOS_CPU} \
      -N $(( (n + CORES_PER_NODE - 1) / CORES_PER_NODE )) -n $n -t 72:00:00 --export=ALL,WRF_BITTRACE=1 \
      "$PORT_TOOLS/ccr/run_wrf.sbatch" ;;
  e1-compare)
    E=$RUNROOT/e1/$(basename "$B")/run
    python3 "$PORT_TOOLS/compare_fire.py" "$A" "$E" --csv "$A/E1_fire.csv" --png "$A/E1_png" | tee "$A/E1.txt" ;;
esac
