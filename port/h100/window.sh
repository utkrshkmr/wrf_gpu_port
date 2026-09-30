#!/bin/bash
# Run one test window of the development case (plan.md P0.16, 13) with a build.
#
#   window.sh <build dir> <window> [--dir RUN_DIR] [--ranks N] [--tag T] [--force] [VAR=value ...]
#
# Windows (defined in port/h100/windows.txt, which is locked; case eaton_small,
# dates 2025-01-08; restart windows start from the CPU-REF dev reference restarts
# in $DEV_REF/run0220, so a CPU-REF and a GPU run of the same window start from
# the same file: restart-vs-restart):
#   W-T0     00:00:00 + 9 s from wrfinput (3 d01 / 27 d02 steps, nest start),
#            history every 3 s, restart written at 9 s          trace 2
#   W-20     02:20:00 + 9 s    (3 d01 / 27 d02 steps)            trace 2
#   W-100    02:20:00 + 36 s   (12 d01 / 108 d02 steps)          trace 2
#   W-RAD    02:20:00 + 240 s  (80 d01 / 720 d02 steps, 4 radiation calls per domain)  trace 2
#   W-FORCE  02:20:00 + 60 s   (20 d01 steps, nest forcing)      trace 2
#   W-TKE    02:20:00 + 336 s  (1008 d02 steps, TKE, nba_mij)    trace 1
#   W-IGN    02:00:00 -> 02:35:00 (ignition 02:18-02:31:20)      trace 1
#   W-FIRE   02:20:00 -> 03:00:00 (free spread)                  trace 1
#   W-1H     02:00:00 -> 03:00:00 (T-DRIFT)                      trace 1
#   S-3M     smoke case (port/h100/smoke_case.sh), 0 -> 3 min   trace 2
# VAR=value pairs are exported for the run (WRF_GPU_OFF=..., WRF_BITTRACE=...,
# WRF_BITTRACE_FROM=...); they also name the default run directory
#   $WORK/runs/<mode>-<md5 of wrf.exe>/<window>[-<tag or VAR-value...>]
# A finished run with the same settings is reused unless --force.
# RUN_WRAPPER (environment) is put between the MPI launcher and wrf.exe, e.g.
# RUN_WRAPPER="nsys profile -o prof" or "compute-sanitizer --tool memcheck".
# GPU builds run 1 rank on GPU $GPU_ID with OMP_TARGET_OFFLOAD=MANDATORY;
# CPU-REF runs $CPU_RANKS ranks (--ranks), the gnu test build 1 serial process.
# Exit status 0 if wrf.exe printed SUCCESS COMPLETE WRF.  The last line
# printed is the run directory.
set -euo pipefail
source "$(dirname "$0")/common.sh"
B=${1:?usage: window.sh <build dir> <window> [options] [VAR=value ...]}; W=${2:?window}; shift 2
B=$(cd "$B" && pwd)
[ -x "$B/main/wrf.exe" ] || die "no wrf.exe in $B"
rd=; ranks=$CPU_RANKS; tag=; force=0; envs=()
while [ $# -gt 0 ]; do
  case $1 in
    --dir) rd=${2:?}; shift ;;
    --ranks) ranks=${2:?}; shift ;;
    --tag) tag=${2:?}; shift ;;
    --force) force=1 ;;
    *=*) envs+=("$1") ;;
    *) die "unknown argument $1" ;;
  esac
  shift
done
mode=$(build_mode "$B")
case $mode in gpu-*) gpu=1; ranks=1 ;; gnu|gnu-fine) gpu=0; ranks=0 ;; *) gpu=0 ;; esac

# the window definitions are in windows.txt (locked, part of the pass criteria)
wline=$(awk -v w="$W" '$1 == w {print; exit}' "$HERE_H100/windows.txt")
[ -n "$wline" ] || die "unknown window $W (see $HERE_H100/windows.txt)"
read -r _ case_ start dur hist rst trace rstint_s <<< "$wline"
[ "$rst" = - ] && rst=

if [ -z "$rd" ]; then
  suffix=$tag
  if [ -z "$suffix" ] && [ ${#envs[@]} -gt 0 ]; then
    suffix=$(printf '%s_' "${envs[@]}" | sed -e 's/_$//' -e 's/[^A-Za-z0-9._,-]/-/g' | cut -c1-120)
  fi
  rd=$WORK/runs/$(build_id "$B")/$W${suffix:+-$suffix}
fi
settings="build=$B window=$W ranks=$ranks env=${envs[*]:-}"
if [ $force = 0 ] && run_ok "$rd" && [ "$(sed -n 1p "$rd/window.info" 2>/dev/null)" = "$settings" ]; then
  note "cached: $W ($rd)"; echo "$rd"; exit 0
fi
rm -rf "${rd:?}"; mkdir -p "$rd"; cd "$rd"

ln -sf "$B/main/wrf.exe" wrf.exe
for t in $TABLES; do ln -sf "$B/run/$t" "$t"; done
ln -sf "$B/run/CAMtr_volume_mixing_ratio.SSP245" CAMtr_volume_mixing_ratio
if [ $case_ = smoke ]; then
  [ -x "$B/main/ideal_fire.exe" ] || die "S-3M needs a build with --fire-ideal"
  bash "$HERE_H100/smoke_case.sh" namelist "$B" "$rd" "$dur" "$hist"
  x "$B/main/ideal_fire.exe" > ideal.log 2>&1 || die "ideal.exe failed in $rd"
  ls rsl.* >/dev/null 2>&1 && mkdir -p ideal_rsl && mv rsl.* ideal_rsl/
else
  [ -f "$DEV_CASE/namelist.input" ] || die "no dev case in $DEV_CASE (run port/h100/dev_case.sh make)"
  for f in wrfinput_d01 wrfinput_d02 wrfbdy_d01; do ln -sf "$DEV_CASE/$f" "$f"; done
  cp "$DEV_CASE/namelist.input" namelist.input
  hh=${start%%:*}; mm=${start#*:}; mm=${mm%%:*}; ss=${start##*:}
  end=$(python3 -c "
import datetime as d
t=d.datetime(2025,1,8,$((10#$hh)),$((10#$mm)),$((10#$ss)))+d.timedelta(seconds=$dur)
print(t.strftime('%H %M %S'))")
  read -r eh em es <<< "$end"
  nml_set namelist.input "start_hour=$hh, $hh" "start_minute=$mm, $mm" "start_second=$ss, $ss" \
    "end_hour=$eh, $eh" "end_minute=$em, $em" "end_second=$es, $es" \
    run_days=0 run_hours=0 run_minutes=0 "run_seconds=$dur" \
    "history_interval=0, 0" "history_interval_s=$hist, $hist" "frames_per_outfile=1000, 1000"
  if [ -n "$rst" ]; then
    rdir=$DEV_REF/run0220
    for d in 1 2; do
      f=wrfrst_d0${d}_2025-01-08_${rst:0:2}:${rst:2:2}:00
      [ -f "$rdir/$f" ] || die "missing $rdir/$f (run port/h100/dev_case.sh reference)"
      ln -sf "$rdir/$f" "$f"
    done
    nml_set namelist.input "restart=.true." "restart_interval=100000"
  else
    nml_set namelist.input "restart=.false." "restart_interval=0" "restart_interval_s=$rstint_s"
  fi
fi
if [ "$ranks" -gt 0 ]; then
  read -r px py < <(decomp "$ranks")
  python3 "$PORT_TOOLS/nml.py" namelist.input set --group=domains "nproc_x=$px" "nproc_y=$py"
fi

# environment of the run
export WRF_BITTRACE=$trace
for e in "${envs[@]:-}"; do [ -n "$e" ] && export "$e"; done
if [ $gpu = 1 ]; then
  export CUDA_VISIBLE_DEVICES=$GPU_ID OMP_TARGET_OFFLOAD=MANDATORY
fi
{ echo "$settings"; echo "host $(hostname) start $(date -u +%FT%TZ)"; env | grep -E '^(WRF_|OMP_|CUDA_VISIBLE|NV_)' | sort; } > window.info
mpiflags=${MPIRUN_FLAGS:-}
t0=$(date +%s)
set +e
if [ "$ranks" -eq 0 ]; then
  x ./wrf.exe > rsl.out.0000 2> rsl.error.0000
elif [ $gpu = 1 ]; then
  x $MPIRUN $mpiflags -np 1 ${RUN_WRAPPER:-} ./wrf.exe > wrf.stdout 2>&1
else
  x $MPIRUN $mpiflags -np "$ranks" ${RUN_WRAPPER:-} ./wrf.exe > wrf.stdout 2>&1
fi
rc=$?
set -e
t1=$(date +%s)
[ "$ranks" -eq 0 ] && cat rsl.out.0000 >> rsl.error.0000
echo "end $(date -u +%FT%TZ) rc=$rc wall_s=$((t1 - t0))" >> window.info
if run_ok "$rd"; then
  note "$W with $mode: OK ($((t1 - t0)) s)"
  echo "$rd"
else
  note "$W with $mode: FAILED (rc=$rc); tail of $rd/rsl.error.0000:"
  tail -n 15 rsl.error.0000 >&2 2>/dev/null || true
  echo "$rd"
  exit 1
fi
