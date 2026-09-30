#!/bin/bash
# Smoke case: the em_fire ideal case with the Eaton physics suite and fire
# options (WSM6, RRTMG LW o3input=2 ghg_input=1, Dudhia SW, sfclayrev, Noah,
# YSU, km_opt=4, fire_upwinding=9, level-set reinit, z-coupling, feedback),
# 103x103x51, dx 50 m, dt 0.5 s, ignition at 120 s.  It needs no case inputs
# and runs in a minute on one core.  Used for the local T-SHARED checks of
# Phase 0 and for quick CPU-view checks; NOT a GPU acceptance case: it has open
# lateral boundaries, one domain and fire tracers, which are outside the
# envelope that gpu_check_config accepts.
#
#   smoke_case.sh namelist <build dir> <run dir> <seconds> <history seconds>
#     writes namelist.input and input_sounding into <run dir>
set -euo pipefail
source "$(dirname "$0")/common.sh"
[ "${1:-}" = namelist ] || die "usage: smoke_case.sh namelist <build dir> <run dir> <seconds> <history seconds>"
B=$2; R=$3; S=$4; H=$5
cp "$B/test/em_fire/input_sounding" "$R/"
m=$((S / 60)); s=$((S % 60))
sed -e "s/^ *run_minutes .*/ run_minutes = 0,\n run_seconds = $S,/" \
    -e 's/^ *run_seconds .*//' \
    -e 's/^ *start_year .*/ start_year = 2025, 2025, 2025,/' \
    -e 's/^ *start_month .*/ start_month = 01, 01, 01,/' \
    -e 's/^ *start_day .*/ start_day = 08, 08, 08,/' \
    -e 's/^ *start_hour .*/ start_hour = 20, 20, 20,/' \
    -e 's/^ *end_year .*/ end_year = 2025, 2025, 2025,/' \
    -e 's/^ *end_month .*/ end_month = 01, 01, 01,/' \
    -e 's/^ *end_day .*/ end_day = 08, 08, 08,/' \
    -e 's/^ *end_hour .*/ end_hour = 20, 20, 20,/' \
    -e "s/^ *end_minute .*/ end_minute = $m, 00, 00,/" \
    -e "s/^ *end_second .*/ end_second = $s, 00, 00,/" \
    -e "s/^ *history_interval_s .*/ history_interval_s = $H, 120, 120,/" \
    -e 's/^ *frames_per_outfile .*/ frames_per_outfile = 1000, 1, 1,/' \
    -e 's/^ *mp_physics .*/ mp_physics = 6, 0, 0,/' \
    -e 's/^ *ra_lw_physics .*/ ra_lw_physics = 4, 0, 0,\n radt = 0.5, 0.5, 0.5,\n o3input = 2,\n ghg_input = 1,\n icloud = 1,/' \
    -e 's/^ *ra_sw_physics .*/ ra_sw_physics = 1, 0, 0,/' \
    -e 's/^ *sf_sfclay_physics .*/ sf_sfclay_physics = 1, 0, 0,\n isfflx = 1,/' \
    -e 's/^ *sf_surface_physics .*/ sf_surface_physics = 2, 0, 0,\n num_soil_layers = 4,/' \
    -e 's/^ *bl_pbl_physics .*/ bl_pbl_physics = 1, 0, 0,/' \
    -e 's/^ *fire_print_msg .*/ fire_print_msg = 0,/' \
    "$B/test/em_fire/namelist.input" | sed -e "/^ *radt  *= *30/d" -e "s/^ *km_opt .*/ km_opt = 4, 2, 2,/" \
    > "$R/namelist.input"
sed -i 's#^ *fire_wind_height = 1.,.*# fire_wind_height = 1.,\n fire_upwinding = 9,\n fire_lsm_reinit = .true.,\n fire_lsm_reinit_iter = 1,\n fire_upwinding_reinit = 4,\n fire_lsm_zcoupling = .true.,\n fire_lsm_zcoupling_ref = 60.0,\n fire_atm_feedback = 1.0,\n sfc_full_init = .true.,\n fire_lat_init = 34.18604,\n fire_lon_init = -118.09325,\n sfc_lu_index = 7,\n sfc_ivgtyp = 7,\n sfc_isltyp = 3,#' "$R/namelist.input"
grep -q "run_seconds = $S" "$R/namelist.input" || die "smoke namelist: run_seconds not set"
