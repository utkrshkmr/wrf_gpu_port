#!/bin/bash
# P0.2: identify the original CCR WRF build and run, for
# cases/eaton_20250108/README.md.  Run on a CCR login node.
#   identify_build.sh <original run folder> [WRF install dir]
rd=${1:?original run folder}
wd=${2:-}
echo "== module"
module show wrf/4.6.0-dmpar 2>&1 | head -40
if [ -z "$wd" ]; then
  wd=$(module show wrf/4.6.0-dmpar 2>&1 | grep -oE '/cvmfs/[^ ]*WRFV4\.6\.0' | head -1)
fi
echo "== WRF directory: $wd"
if [ -f "$wd/configure.wrf" ]; then
  grep -E '^(SFC|SCC|DM_FC|DM_CC|FCOPTIM|FCBASEOPTS_NO_G|FCDEBUG|ARCH_LOCAL|OMP|PROMOTION|CFLAGS_LOCAL|LDFLAGS_LOCAL)\s*=' "$wd/configure.wrf"
fi
[ -x "$wd/main/wrf.exe" ] && md5sum "$wd/main/wrf.exe"
echo "== run folder: $rd"
ls -la "$rd" | head -60
for f in wrfinput_d01 wrfinput_d02 wrfbdy_d01; do [ -e "$rd/$f" ] && md5sum "$rd/$f"; done
echo "== rsl header and decomposition"
r=$rd/rsl.error.0000
[ -f "$r" ] || r=$(ls "$rd"/rsl.error.* 2>/dev/null | head -1)
if [ -f "$r" ]; then
  head -40 "$r"
  grep -m2 -E "Ntasks in X|ntasks_x|nproc_x" "$r"
  echo "ranks: $(ls "$rd"/rsl.error.* | wc -l)"
  echo "== wall time per simulated hour (d01 steps, 'Timing for main')"
  grep "Timing for main" "$r" | awk '/domain +1:/{s+=$(NF-2); n++} END{if(n) printf "d01 steps %d, sum %.1f s, per simulated hour %.1f s\n", n, s, s/(n*3/3600)}'
  grep "Timing for main" "$r" | awk '/domain +2:/{s+=$(NF-2); n++} END{if(n) printf "d02 steps %d, sum %.1f s\n", n, s}'
fi
echo "== job script(s)"
ls "$rd"/*.sh "$rd"/*.slurm "$rd"/*.sbatch 2>/dev/null | head
