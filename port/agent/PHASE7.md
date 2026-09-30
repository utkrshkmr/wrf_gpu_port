# Phase 7 — other fires

Plan: [plan.md §12](../../plan.md).

## P7.1 Regression script `port/regress.sh` (new file)

Runs, in order, and prints one PASS/FAIL line each plus a summary: `port/gates/static.sh`, `port/gates/ref_tests.sh`,
`port/gates/t_reg20.sh`, `port/gates/t_trace.sh W-100`, `port/gates/t_trace.sh W-RAD`, and (with `--long`)
`t_fire.sh W-IGN W-FIRE` and `t_drift.sh`. It is the command to run after any change to `WRF/`.

## P7.2 Onboarding guide for a new case

Write `cases/README.md`: for a new fire case, `port/manifest.py write`, `port/check_case.py namelist.input
--wrfinput ...` (envelope, KMAX/NLAYMAX, fuel categories, memory estimate), `port/gpu_mem_estimate.py`, the short
acceptance window T-CASE-1H (CPU-REF vs GPU-REPRO, 1 h around ignition from a CPU-REF restart), and when a full run
is needed. Try it on the dev case as if it were new, and record the output.
