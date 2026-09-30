# `port/`: tools, tests and scripts of the GPU port

The plan is [../plan.md](../plan.md); the design is [../explain-wrf.md](../explain-wrf.md). This directory holds
everything that is not WRF source: Python tools, standalone tests, the container definition, and the scripts that
run the Phase 0 steps on CCR and on the GPU nodes. Results go into [RESULTS.md](RESULTS.md), the toolchain facts into
[ENVIRONMENT.md](ENVIRONMENT.md).

## Contents

| Path | Plan step | What |
|---|---|---|
| `manifest.py` | P0.3 | md5 manifest of case inputs and tables; `check` runs first in every run script |
| `rp_subst.py`, `rp_subst_files.txt` | P0.6 | rewrites transcendental calls and real powers to `rp_*` (`module_repro_math`) in the listed files |
| `ipow_scan.py` | P0.6 T-IPOW | lists the integer powers left in those files |
| `sym_audit.sh`, `sym_allow.txt` | P0.6 T-SYM | no math-library symbols in host objects, no MUFU transcendental approximations in device code |
| `bittrace_diff.py` | P0.7 | compares two bit-hash traces (`bittrace.d0N.txt`) and names the first difference |
| `compare_fields.py` | P0.12 | field-by-field comparison of netCDF files (`--bitwise` for acceptance) |
| `compare_fire.py` | P0.12 | burned-cell comparison per history frame (CSV, optional PNGs) |
| `perturb_input.py` | P0.14 | 1-ulp perturbation of one input value (experiment E1) |
| `gpu_mem_estimate.py` | P0.15, §3 | device-memory estimate from the Registry; `--check-rsl` validates against WRF's own count |
| `prof_cpu.py` | P0.15 | Prof-CPU table from a `-DBENCH` run |
| `make_dev_case.py` | P0.16 | development case `eaton_small`: cuts a 181×181 window out of the full `wrfinput_d02` |
| `nml.py` | helper | edits `namelist.input` entries |
| `container/` | P0.0 | Apptainer definition (NVHPC, OpenMPI, netCDF, gfortran, Python) |
| `ccr/` | P0.2, P0.9–P0.16 | build, run and check scripts for CCR (Slurm) and the GPU nodes |
| `tests/repro_math/` | P0.5 | host accuracy test (Python) and host-vs-device tests (T-FMA, T-IEEE, T-IPOW, T-RM-EXH, T-RM-POW, T-RM-D) |
| `tests/omp_features/` | P0.5b | OpenMP offload feature probes F-* |
| `tests/tools/` | – | self-test of the Python tools |

WRF source files added in Phase 0: `WRF/frame/module_repro_math.F` (P0.5), `module_bittrace.F` (P0.7),
`module_gpu_route.F` (P0.8), `module_gpu_scratch.F` (P1.6 pool, used from Phase 0). The i1 pool code comes from
`WRF/tools/gen_defs.c` (`i1_decl.inc`, `i1_assoc.inc`). The configure stanzas "NVHPC ... GPU port CPU-REF /
GPU-REPRO / GPU-DEBUG" are at the end of `WRF/arch/configure.defaults`.

## Phases 1–7 (H100 machine)

The coding agent's documents, scripts and gates: [../AGENTS.md](../AGENTS.md), [agent/README.md](agent/README.md),
`h100/` (container toolchain without root, builds, dev case, windows), `gates/` (static checks, T-AB, T-TRACE,
phase gates), `tests/pdlim`, `tests/kiss`, `tests/ozn`, `tests/templates` (reference tests with negative controls,
`tests/run_ref_tests.sh`).

## Phase 0 runbook

Everything below runs on CCR (CPU-REF) or on the A100/H100 nodes. Nothing here needs a GPU except step 4.

1. **Image** (P0.0). Build `container/wrf-gpu.def` with a pinned NVHPC tag, record the tag and the `.sif` sha256 in
   `ENVIRONMENT.md`. Copy `ccr/env.sh` to `ccr/env.local.sh` and fill in the paths and the Slurm account.
2. **Original build** (P0.2). `ccr/identify_build.sh <original run folder>` and copy the facts into
   `cases/eaton_20250108/README.md`.
3. **Inputs** (P0.3). `python3 manifest.py check <run folder> -m ../cases/eaton_20250108/manifest.md5`
   (the table md5s are those of this repository's `WRF/run/`; if CCR's differ, find out why before anything else).
4. **Compiler checks** (P0.5, P0.5b), on an A100 node and on an H100 node, inside the image:
   ```sh
   cd port/tests/repro_math && make && ./run_tests.sh            # T-FMA first, then T-IEEE, T-IPOW, T-RM-*
   cd ../omp_features && ./run_probes.sh                         # F-* probes -> probes_<host>.md
   python3 ../repro_math/test_accuracy.py --exhaustive           # T-RM-ACC (host, all 2^32 floats)
   ```
   Copy the result files into `ENVIRONMENT.md` / `RESULTS.md`. **If T-FMA fails, stop** (plan.md §15).
5. **Builds** (P0.4, P0.9). `ccr/build.sh cpu-ref` (and `cpu-ref-bench` for step 12). Builds come from a
   commit; `BUILD_INFO` records the git sha, image digest and md5 of `wrf.exe`.
6. **Symbol audit** (T-SYM). `sym_audit.sh <cpu-ref build dir>`; later on GPU builds for the device part.
7. **Reproducibility of CPU-REF** (P0.10). `ccr/p0_tests.sh <build>`, `ccr/p0_txm_gpu.sh <build>` (T-XM on a GPU
   node host), then `ccr/p0_check.sh <build>`.
8. **Development case** (P0.16). `ccr/dev_case.sh make` (commit `cases/eaton_small/`), then
   `ccr/dev_case.sh submit <build>`; its run `$RUNROOT/dev_reference/<build>/rst0220` writes the 02:20 restart
   (fire active) that the windows below start from.
9. **Shared refactors change nothing** (P0.9a), before the reference run (`<rst0220>` is the run folder above):
   - `ccr/t_shared.sh build`, `ccr/t_shared.sh submit <rst0220>`, `ccr/t_shared.sh check`:
     unmodified v4.6.0 vs this commit (T-SHARED-1) and without vs with the pool (T-SHARED-POOL), REPRO_MATH off,
     vector math off, bitwise;
   - `ccr/t_uninit.sh build`, `ccr/t_uninit.sh submit <rst0220>`, `ccr/t_uninit.sh check`:
     NaN-initialized vs zero-initialized gfortran builds, identical traces (T-UNINIT).
10. **Reference** (P0.11). `ccr/reference_run.sh <build>` (17 h + the 02:20 restart run), then
    `ccr/archive_reference.sh <build>`.
11. **Experiments** (P0.13, P0.14). `ccr/e0_e1.sh e0 <build> <original run folder>`, `e1-submit`, `e1-compare`.
12. **Profile and memory** (P0.15). `ccr/prof_run.sh submit <cpu-ref-bench build>`, then `report` (Prof-CPU and the
    `gpu_mem_estimate.py --check-rsl` validation).

Gate G0 (plan.md §5) is passed when every item of its list is recorded in `RESULTS.md`.

## Local checks (no CCR, no GPU)

```sh
python3 port/tests/tools/test_tools.py                          # Python tools
python3 port/tests/repro_math/test_accuracy.py --quick          # rp_* accuracy (gfortran)
(cd port/tests/repro_math && make COMPILER=gnu && ALLOW_HOST=1 ./t_fma fma_cases.bin)
python3 port/rp_subst.py --check $(grep -v '^#' port/rp_subst_files.txt | sed 's|^|WRF/|')   # nothing left to rewrite
```
