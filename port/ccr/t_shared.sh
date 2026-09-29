#!/bin/bash
# T-SHARED (plan.md P0.9a): the Phase 0 source changes (rp_* rewrite, zolri,
# YSU BEP guard, SNUPGRD, i1 pool) do not change any result.
#
# Three builds with the CPU-REF stanza, but without -DREPRO_MATH (every rp_*
# is then the intrinsic) and with -Mnovect instead of -Mvect=noassoc.  A
# vectorized loop may call vector variants of exp/log/pow whose results
# differ from the scalar functions; loops that call rp_* are never
# vectorized, so the comparison needs scalar math on both sides (the local
# gfortran check showed exactly this, see port/RESULTS.md):
#   base : WRF/ at $BASE_REF (unmodified v4.6.0), no pool
#   mod  : WRF/ at HEAD, no pool             -> T-SHARED-1    (base vs mod)
#   pool : WRF/ at HEAD, -DWRF_POOL          -> T-SHARED-POOL (mod vs pool)
# Runs of the development case, same rank count for all three:
#   window A: t = 0 to 9 s (3 d01 steps, 27 d02 steps), history every 3 s
#   window B: 02:20:00 to 02:21:00 from the dev reference's 02:20 restart
#             (fire active), history every 20 s
# Pass: all history files bitwise identical; mod and pool also give identical
# level-2 traces.  A difference in T-SHARED-1 is explained in RESULTS.md
# (plan.md P0.9a) before the reference run.
#
#   t_shared.sh build
#   t_shared.sh submit <dev reference dir with wrfrst_d0*_2025-01-08_02:20:00> [ranks=32]
#   t_shared.sh check
set -eu
source "$(dirname "$0")/common.sh"
BASE_REF=${BASE_REF:-99becf4}     # commit that imported WRF v4.6.0 unchanged
T=$WORKROOT/t_shared/$(git -C "$PORT_REPO" rev-parse --short=12 HEAD)
D=$WORKROOT/cases/eaton_small
case ${1:?build|submit|check} in
  build)
    for v in base mod pool; do
      b=$T/build_$v; mkdir -p "$b"
      if [ $v = base ]; then ref=$BASE_REF; else ref=HEAD; fi
      git -C "$PORT_REPO" archive "$ref" WRF | tar -x -C "$b" --strip-components=1
      # the GPU-port stanzas exist only in the port's configure.defaults
      git -C "$PORT_REPO" show HEAD:WRF/arch/configure.defaults > "$b/arch/configure.defaults"
      cd "$b"
      opt=$(inimg bash -c "./configure < /dev/null 2>/dev/null" | grep "GPU port CPU-REF" | head -1 | sed -E 's/.*[^0-9]([0-9]+)\. \(dmpar\).*/\1/')
      [ -n "$opt" ] || die "stanza 'GPU port CPU-REF' not offered by configure"
      inimg bash -c "printf '%s\n1\n' $opt | ./configure > configure.log 2>&1"
      sed -i -e 's/ -DREPRO_MATH//' -e 's/ -DWRF_POOL//' -e 's/-Mvect=noassoc/-Mnovect/' configure.wrf
      [ $v = pool ] && sed -i 's/^\(ARCH_LOCAL *=.*\)$/\1 -DWRF_POOL/' configure.wrf
      grep -E "^(ARCH_LOCAL|FCOPTIM)" configure.wrf
      inimg bash -c "./compile -j 8 em_real > compile.log 2>&1" || true
      [ -x main/wrf.exe ] || die "build $v failed ($b/compile.log)"
    done ;;
  submit)
    R=${2:?dev reference run dir}; n=${3:-32}
    read -r px py < <(decomp "$n")
    for v in base mod pool; do
      for w in A B; do
        rd=$T/run_${v}_$w
        CASE_REPO=$PORT_REPO/cases/eaton_small
        setup_run "$rd" "$T/build_$v" "$CASE_REPO/namelist.input" "$D"
        python3 "$PORT_TOOLS/nml.py" namelist.input set --group=domains "nproc_x=$px" "nproc_y=$py"
        nml_set namelist.input "history_interval=0, 0" "frames_per_outfile=1000, 1000" "restart_interval=100000"
        if [ $w = A ]; then
          nml_set namelist.input run_hours=0 run_minutes=0 run_seconds=9 "end_hour=00, 00" "end_minute=00, 00" \
            "end_second=9, 9" "history_interval_s=3, 3"
        else
          ln -sf "$R"/wrfrst_d01_2025-01-08_02:20:00 .; ln -sf "$R"/wrfrst_d02_2025-01-08_02:20:00 .
          nml_set namelist.input "restart=.true." "start_hour=02, 02" "start_minute=20, 20" "run_hours=0" \
            "run_minutes=1" "run_seconds=0" "end_hour=02, 02" "end_minute=21, 21" "end_second=0, 0" \
            "history_interval_s=20, 20"
        fi
        sbatch -A "$SLURM_ACCOUNT" -p "$SLURM_PARTITION_CPU" ${SLURM_QOS_CPU:+-q $SLURM_QOS_CPU} -N 1 -n "$n" \
          -t 12:00:00 --export=ALL,WRF_BITTRACE=2 "$PORT_TOOLS/ccr/run_wrf.sbatch"
      done
    done ;;
  check)
    rc=0
    for w in A B; do
      echo "== window $w: T-SHARED-1 (base vs mod)"
      python3 "$PORT_TOOLS/compare_fields.py" --dirs "$T/run_base_$w" "$T/run_mod_$w" --pattern 'wrfout_d0*' --bitwise || rc=1
      echo "== window $w: T-SHARED-POOL (mod vs pool)"
      python3 "$PORT_TOOLS/compare_fields.py" --dirs "$T/run_mod_$w" "$T/run_pool_$w" --pattern 'wrfout_d0*' --bitwise || rc=1
      python3 "$PORT_TOOLS/bittrace_diff.py" --dir "$T/run_mod_$w" "$T/run_pool_$w" || rc=1
    done
    echo "T-SHARED: $([ $rc -eq 0 ] && echo PASS || echo 'DIFFERENT (explain in port/RESULTS.md)')"
    exit $rc ;;
esac
