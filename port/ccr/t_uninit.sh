#!/bin/bash
# T-UNINIT (plan.md P0.10, added in Phase 0): does WRF read local variables
# or automatic arrays before writing them, on the paths this case runs?
#
# Builds the current commit twice with gfortran (GNU dmpar stanza, netCDF
# from /opt/netcdf-gnu in the image, no -DWRF_POOL, no -DREPRO_MATH):
#   nan : -finit-real=snan -finit-integer=-8388607 -finit-logical=true
#   zero: -finit-real=zero -finit-integer=0        -finit-logical=false
# and runs the development case with each (1 rank, level-2 trace):
#   window A: the first 3 d01 steps from t = 0 (27 d02 steps, nest start)
#   window B: 20 d02 steps from the dev case's 02:20 restart (fire active)
# The two builds must give identical traces.  A difference names the first
# field that depends on uninitialized memory; fix it (define the value) in
# both builds before the reference run.
#
#   t_uninit.sh build
#   t_uninit.sh submit <dev reference dir with wrfrst_d0*_2025-01-08_02:20:00>
#   t_uninit.sh check
set -eu
source "$(dirname "$0")/common.sh"
T=$WORKROOT/t_uninit/$(git -C "$PORT_REPO" rev-parse --short=12 HEAD)
D=$WORKROOT/cases/eaton_small
case ${1:?build|submit|check} in
  build)
    for v in nan zero; do
      b=$T/build_$v; mkdir -p "$b"
      git -C "$PORT_REPO" archive HEAD WRF | tar -x -C "$b" --strip-components=1
      cd "$b"
      opt=$(inimg bash -c "NETCDF=/opt/netcdf-gnu ./configure < /dev/null 2>/dev/null" | grep "GNU (gfortran/gcc)" | head -1 | sed -E 's/.*[^0-9]([0-9]+)\. \(dmpar\).*/\1/')
      inimg bash -c "export NETCDF=/opt/netcdf-gnu; printf '%s\n1\n' $opt | ./configure > configure.log 2>&1"
      if [ $v = nan ]; then fl="-finit-real=snan -finit-integer=-8388607 -finit-logical=true"
      else fl="-finit-real=zero -finit-integer=0 -finit-logical=false"; fi
      sed -i "s/^\(FCBASEOPTS_NO_G *=.*\)$/\1 $fl/" configure.wrf
      inimg bash -c "export NETCDF=/opt/netcdf-gnu; ./compile -j 8 em_real > compile.log 2>&1" || true
      [ -x main/wrf.exe ] || die "gfortran build $v failed ($b/compile.log)"
    done ;;
  submit)
    R=${2:?dev reference run dir}
    for v in nan zero; do
      for w in A B; do
        rd=$T/run_${v}_$w
        CASE_REPO=$PORT_REPO/cases/eaton_small
        setup_run "$rd" "$T/build_$v" "$CASE_REPO/namelist.input" "$D"
        if [ $w = A ]; then
          nml_set namelist.input run_hours=0 run_minutes=0 run_seconds=9 "end_hour=00, 00" "end_minute=00, 00" \
            "end_second=9, 9" "restart_interval=100000" "history_interval=-1, -1"
        else
          ln -sf "$R"/wrfrst_d01_2025-01-08_02:20:00 .; ln -sf "$R"/wrfrst_d02_2025-01-08_02:20:00 .
          nml_set namelist.input "restart=.true." "start_hour=02, 02" "start_minute=20, 20" "run_hours=0" \
            "run_minutes=0" "run_seconds=21" "end_hour=02, 02" "end_minute=20, 20" "end_second=21, 21" \
            "restart_interval=100000" "history_interval=-1, -1"
        fi
        sbatch -A "$SLURM_ACCOUNT" -p "$SLURM_PARTITION_CPU" ${SLURM_QOS_CPU:+-q $SLURM_QOS_CPU} -N 1 -n 1 \
          -t 12:00:00 --export=ALL,WRF_BITTRACE=2 "$PORT_TOOLS/ccr/run_wrf.sbatch"
      done
    done ;;
  check)
    for w in A B; do
      echo "== window $w"
      python3 "$PORT_TOOLS/bittrace_diff.py" --dir "$T/run_nan_$w" "$T/run_zero_$w"
    done ;;
esac
