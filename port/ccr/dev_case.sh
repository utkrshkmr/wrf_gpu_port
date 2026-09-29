#!/bin/bash
# P0.16: make the development case eaton_small and its CPU-REF references:
#   - inputs: full d01 and wrfbdy, d02 cut to 181x181 around the ignition
#   - a 17 h CPU-REF run (restarts every hour, level-1 trace)
#   - restart runs 02:00->02:20 (02:20 restart files) and a 1 h window
#     02:00->03:00 (continuous from the 02:00 restart, level-1 trace)
#   dev_case.sh make                      (writes $WORKROOT/cases/eaton_small)
#   dev_case.sh submit <cpu-ref build> [ranks=32]
set -eu
source "$(dirname "$0")/common.sh"
D=$WORKROOT/cases/eaton_small
case ${1:?make|submit} in
  make)
    mkdir -p "$D"
    python3 "$PORT_TOOLS/make_dev_case.py" --case-dir "$CASE_INPUTS" --namelist "$CASE_REPO/namelist.input" --out "$D"
    ln -sf "$CASE_INPUTS/wrfinput_d01" "$D/"; ln -sf "$CASE_INPUTS/wrfbdy_d01" "$D/"
    for t in $TABLES; do cp "$PORT_REPO/WRF/run/$t" "$D/" ; done
    cp "$PORT_REPO/WRF/run/CAMtr_volume_mixing_ratio.SSP245" "$D/CAMtr_volume_mixing_ratio"
    python3 "$PORT_TOOLS/manifest.py" write "$D" -o "$D/manifest.md5"
    mkdir -p "$PORT_REPO/cases/eaton_small"
    cp "$D/namelist.input" "$D/README.md" "$D/manifest.md5" "$PORT_REPO/cases/eaton_small/"
    echo "commit cases/eaton_small/ (namelist, README, manifest)" ;;
  submit)
    B=${2:?cpu-ref build}; n=${3:-32}; read px py <<< "$(decomp "$n")"
    R=$RUNROOT/dev_reference/$(basename "$B")
    CASE_REPO_SAVE=$CASE_REPO; CASE_REPO=$PORT_REPO/cases/eaton_small
    setup_run "$R/full" "$B" "$CASE_REPO/namelist.input" "$D"
    python3 "$PORT_TOOLS/nml.py" namelist.input set --group=domains "nproc_x=$px" "nproc_y=$py"
    j=$(sbatch -A "$SLURM_ACCOUNT" -p "$SLURM_PARTITION_CPU" ${SLURM_QOS_CPU:+-q $SLURM_QOS_CPU} -N 1 -n $n \
          -t 72:00:00 --export=ALL,WRF_BITTRACE=1 "$PORT_TOOLS/ccr/run_wrf.sbatch" | awk '{print $NF}')
    for w in rst0220 win0203; do
      mkdir -p "$R/$w"
      if [ $w = rst0220 ]; then extra='"end_minute=20, 20" "run_hours=0" "run_minutes=20" "restart_interval=20" "end_hour=02, 02"'
      else extra='"run_hours=1" "end_hour=03, 03" "restart_interval=60"'; fi
      cat > "$R/$w/setup.sh" <<EOS
source "$PORT_TOOLS/ccr/common.sh"
CASE_REPO=$PORT_REPO/cases/eaton_small
setup_run "$R/$w" "$B" "$CASE_REPO/namelist.input" "$D"
ln -sf $R/full/wrfrst_d01_2025-01-08_02:00:00 .
ln -sf $R/full/wrfrst_d02_2025-01-08_02:00:00 .
nml_set namelist.input "restart=.true." "start_hour=02, 02" $extra
python3 "$PORT_TOOLS/nml.py" namelist.input set --group=domains "nproc_x=$px" "nproc_y=$py"
EOS
      ( cd "$R/$w" && sbatch -A "$SLURM_ACCOUNT" -p "$SLURM_PARTITION_CPU" ${SLURM_QOS_CPU:+-q $SLURM_QOS_CPU} \
          -N 1 -n $n -t 12:00:00 --dependency=afterok:$j --export=ALL,WRF_BITTRACE=1 \
          --wrap "bash setup.sh && bash $PORT_TOOLS/ccr/run_wrf.sbatch" )
    done ;;
esac
