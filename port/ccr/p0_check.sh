#!/bin/bash
# Evaluate the P0.10 tests set up by p0_tests.sh and append a summary to
# $RUNROOT/p0/<build>/P0_RESULTS.md (copy it into port/RESULTS.md).
set -u
source "$(dirname "$0")/common.sh"
B=${1:?cpu-ref build dir}
T=$RUNROOT/p0/$(basename "$B")
out=$T/P0_RESULTS.md
bt() { python3 "$PORT_TOOLS/bittrace_diff.py" --dir "$1" "$2" | tail -1 | awk '{print $2}'; }
cf() { python3 "$PORT_TOOLS/compare_fields.py" --dirs "$1" "$2" --pattern "$3" | tail -1 | awk '{print $2}'; }
{
echo "## P0.10 CPU-REF reproducibility ($(basename "$B"), $(date))"
echo
echo "| Test | Comparison | Result |"
echo "|---|---|---|"
echo "| T-DEC-A | 1 vs 64 ranks, 27 d02 steps, level 2 trace | $(bt $T/tdec_a_1 $T/tdec_a_64) |"
echo "| T-DEC-B | 64 vs 128 ranks, 30 min | $(bt $T/tdec_b_64 $T/tdec_b_128) |"
echo "| T-DEC-B | 64 vs 144 ranks, 30 min | $(bt $T/tdec_b_64 $T/tdec_b_144) |"
echo "| T-DET | two identical 1 h runs | $(bt $T/tdet_1 $T/tdet_2) |"
echo "| T-RST | restart 02:00 vs continuous, 03:00 restart files | $(cf $T/trst_cont $T/trst_rst 'wrfrst_d0*_2025-01-08_03:00:00') |"
if [ -d "$T/txm_gpuhost" ]; then
echo "| T-XM | CCR node vs GPU-node host, 27 d02 steps | $(bt $T/txm_ccr $T/txm_gpuhost) |"
fi
echo
echo "Details: python3 port/bittrace_diff.py --dir <A> <B> in $T"
} | tee -a "$out"
