#!/bin/bash
# The development case eaton_small (plan.md P0.16) and its CPU-REF references
# on the H100 machine.
#
#   dev_case.sh make
#       checks the Eaton inputs in $CASE_INPUTS against the case manifest,
#       cuts d02 to 181x181 around the ignition (port/make_dev_case.py) and
#       writes $DEV_CASE (wrfinput_d02, namelist.input, README.md, links to
#       wrfinput_d01 and wrfbdy_d01)
#   dev_case.sh reference [<cpu-ref build dir>]
#       default build: CPU-REF of the CPU-view base commit
#       (port/agent/cpu_view_base).  Runs with $CPU_RANKS ranks:
#         $DEV_REF/run0220  00:00 -> 02:20 from wrfinput, restarts at 02:00 and
#                           02:20 (the starting points of every window),
#                           level-1 trace
#         $DEV_REF/win1h    02:00 -> 03:00 from the 02:00 restart, level-1
#                           trace (the reference of T-DRIFT)
#       Takes hours; run it under nohup.  Records BUILD_INFO in $DEV_REF.
#   dev_case.sh status
set -euo pipefail
source "$(dirname "$0")/common.sh"
case ${1:?make|reference|status} in
  make)
    for f in wrfinput_d01 wrfinput_d02 wrfbdy_d01; do [ -f "$CASE_INPUTS/$f" ] || die "missing $CASE_INPUTS/$f"; done
    note "checking the md5 of the inputs (cases/eaton_20250108/manifest.md5)"
    python3 - "$CASE_INPUTS" "$PORT_REPO/cases/eaton_20250108/manifest.md5" <<'PY'
import hashlib, os, sys
d, m = sys.argv[1], sys.argv[2]
want = {l.split()[1].lstrip("*"): l.split()[0] for l in open(m) if l.strip() and not l.startswith("#")}
bad = 0
for f in ("wrfinput_d01", "wrfinput_d02", "wrfbdy_d01"):
    h = hashlib.md5()
    with open(os.path.join(d, f), "rb") as fh:
        for b in iter(lambda: fh.read(1 << 24), b""):
            h.update(b)
    ok = h.hexdigest() == want[f]
    print(("ok    " if ok else "WRONG ") + f + " " + h.hexdigest())
    bad += not ok
sys.exit(1 if bad else 0)
PY
    mkdir -p "$DEV_CASE"
    python3 "$PORT_TOOLS/make_dev_case.py" --case-dir "$CASE_INPUTS" \
      --namelist "$PORT_REPO/cases/eaton_20250108/namelist.input" --out "$DEV_CASE"
    ln -sf "$CASE_INPUTS/wrfinput_d01" "$DEV_CASE/wrfinput_d01"
    ln -sf "$CASE_INPUTS/wrfbdy_d01" "$DEV_CASE/wrfbdy_d01"
    md5sum "$DEV_CASE/wrfinput_d02" > "$DEV_CASE/wrfinput_d02.md5"
    note "dev case written to $DEV_CASE"
    ;;
  reference)
    b=${2:-}
    if [ -z "$b" ]; then
      b=$("$HERE_H100/build.sh" cpu-ref --commit "$(cpu_view_base)" | tail -1)
    fi
    [ "$(build_mode "$b")" = cpu-ref ] || die "$b is not a cpu-ref build"
    [ -f "$DEV_CASE/namelist.input" ] || die "run dev_case.sh make first"
    mkdir -p "$DEV_REF"
    cp "$b/BUILD_INFO" "$DEV_REF/BUILD_INFO"
    read -r px py < <(decomp "$CPU_RANKS")
    mpiflags=${MPIRUN_FLAGS:-}
        run_ref() {   # run_ref <dir> <namelist settings...>
      local r=$1; shift
      if run_ok "$r"; then note "exists: $r"; return 0; fi
      rm -rf "${r:?}"; mkdir -p "$r"; cd "$r"
      ln -sf "$b/main/wrf.exe" wrf.exe
      for t in $TABLES; do ln -sf "$b/run/$t" "$t"; done
      ln -sf "$b/run/CAMtr_volume_mixing_ratio.SSP245" CAMtr_volume_mixing_ratio
      for f in wrfinput_d01 wrfinput_d02 wrfbdy_d01; do ln -sf "$DEV_CASE/$f" "$f"; done
      cp "$DEV_CASE/namelist.input" namelist.input
      nml_set namelist.input "$@"
      python3 "$PORT_TOOLS/nml.py" namelist.input set --group=domains "nproc_x=$px" "nproc_y=$py"
      note "running $r ($CPU_RANKS ranks)"
      WRF_BITTRACE=1 x $MPIRUN $mpiflags -np "$CPU_RANKS" ./wrf.exe > wrf.stdout 2>&1 || true
      run_ok "$r" || die "reference run failed in $r"
    }
    run_ref "$DEV_REF/run0220" run_days=0 run_hours=2 run_minutes=20 run_seconds=0 \
      "end_hour=02, 02" "end_minute=20, 20" "restart_interval=20" "history_interval=0, 0" \
      "history_interval_m=20, 20" "frames_per_outfile=1000, 1000"
    for t in 00:20 00:40 01:00 01:20 01:40; do rm -f "$DEV_REF/run0220"/wrfrst_d0?_2025-01-08_$t:00; done
    r1=$DEV_REF/win1h
    mkdir -p "$r1"
    for d in 1 2; do ln -sf "$DEV_REF/run0220/wrfrst_d0${d}_2025-01-08_02:00:00" "$r1/"; done
    run_ref "$r1" "restart=.true." "start_hour=02, 02" run_days=0 run_hours=1 run_minutes=0 run_seconds=0 \
      "end_hour=03, 03" "end_minute=00, 00" "restart_interval=100000" "history_interval=0, 0" \
      "history_interval_m=15, 15" "frames_per_outfile=1000, 1000"
    note "dev references done in $DEV_REF"
    ;;
  status)
    echo "dev case:      $DEV_CASE $( [ -f "$DEV_CASE/namelist.input" ] && echo OK || echo MISSING)"
    for r in run0220 win1h; do
      echo "reference $r: $(run_ok "$DEV_REF/$r" && echo OK || echo MISSING)"
    done
    ls "$DEV_REF"/run0220/wrfrst_d0* 2>/dev/null || true
    ;;
  *) die "usage: dev_case.sh make|reference|status" ;;
esac
