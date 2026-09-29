#!/bin/bash
# P0.11: archive the reference run (history, restarts, traces, logs,
# namelists, manifest) with an md5 list of every file.
set -eu
source "$(dirname "$0")/common.sh"
B=${1:?cpu-ref build dir}
R=$RUNROOT/reference/$(basename "$B")
A=$REFROOT/eaton_20250108/$(basename "$B")
mkdir -p "$A"
cd "$R/full"
cp -p wrfout_d02_* wrfrst_d0* bittrace.d0*.txt rsl.* namelist.* manifest.md5 wrf.exe.md5 run_info.txt "$A"/ 2>/dev/null || true
cp -p "$R"/rst0220/wrfrst_d0*_2025-01-08_02:20:00 "$A"/ 2>/dev/null || true
cp -p "$B/BUILD_INFO" "$A"/
( cd "$A" && md5sum * > ARCHIVE.md5 )
echo "archived to $A ($(ls "$A" | wc -l) files)"
