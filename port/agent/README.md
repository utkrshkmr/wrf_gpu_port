# Agent documents and tools: the map

Everything the coding agent needs to implement Phases 1–7 of [plan.md](../../plan.md) on the H100 machine. Start
with [AGENTS.md](../../AGENTS.md) (the rules).

## Documents (read in this order)

| File | What |
|---|---|
| [ENV_H100.md](ENV_H100.md) | Set up the machine: toolchain, inputs, `env.local.sh`, first commands |
| [WORKFLOW.md](WORKFLOW.md) | The task loop, builds, windows, commits, the workbook, shared refactors, what to do when a test fails |
| [CODING_STANDARD.md](CODING_STANDARD.md) | How to write a kernel: templates A, B, C, D, G and column physics (CP), with tested worked examples |
| [PITFALLS.md](PITFALLS.md) | Everything that breaks bit-for-bit equality or compiles into something unexpected |
| [DEBUGGING.md](DEBUGGING.md) | From "T-AB FAIL" to the wrong statement: tracer, bisection, sanitizer, runtime logs |
| [PHASE1.md](PHASE1.md) | Entry tasks H0 on the H100 machine; Phase 1: device residency, update lists, tables, pool, work arrays, startup gate, NVTX, logs |
| [PHASE2.md](PHASE2.md) | Phase 2: dynamics kernels, sub-phases P2.A–P2.G |
| [PHASE3.md](PHASE3.md) | Phase 3: physics kernels (glue, WSM6, surface, YSU, radiation) |
| [PHASE4.md](PHASE4.md) | Phase 4: WRF-Fire kernels |
| [PHASE5.md](PHASE5.md) | Phase 5: nest forcing, sync points, removing the last island |
| [PHASE6.md](PHASE6.md) | Phase 6: performance (bit-neutral only) |
| [PHASE7.md](PHASE7.md) | Phase 7: regression script, other fires |
| [KERNEL_REFS.md](KERNEL_REFS.md) | Generated: for every kernel of plan.md, the exact CPU lines to port (file:line in the CPU-view base commit) and plan.md's v4.6.0 lines |
| [ROUTES.md](ROUTES.md) | Generated: for every route, its routines (definition file:lines) and every call site in the base commit |
| [WORKBOOK.md](WORKBOOK.md) | **Kept by the agent**: current state, task checklist, log |
| [kernels.csv](kernels.csv) | **Kept by the agent** (status columns): one row per kernel table row of plan.md |
| [BLOCKERS.md](BLOCKERS.md) | **Kept by the agent**: problems that need the project owner |
| [REFACTORS.md](REFACTORS.md) | **Kept by the agent**: shared refactors and moves of the CPU-view base, with evidence |
| `cpu_view_base` | The commit whose CPU view every build must reproduce (see WORKFLOW.md) |
| `protected.md5` | Checksums of the tests, tools, scripts and guides the agent must not change (written by `port/tools/protect.py`) |
| `arith_exceptions.txt` | Reviewed exceptions for arith_guard (WORKFLOW.md §8) |

## Scripts and tools

| Path | What |
|---|---|
| `port/h100/env.sh` → `env.local.sh` | Machine settings (paths, ranks, GPU); copy and edit |
| `port/h100/setup_toolchain.sh` | No root needed: `image` (pull the NVHPC container), `deps` (tcsh, m4, netCDF built in the container into `$WORK/deps`), `python`, `check`, `shell` |
| `port/h100/common.sh` (`x`) | Runs a command in the container (Apptainer, rootless Podman or Docker) with the port's environment (`in_container.sh`) |
| `port/h100/build.sh` | Builds: `cpu-ref`, `gpu-repro`, `gpu-debug`; `--commit REV` (clean) or `--worktree` (incremental) |
| `port/h100/dev_case.sh` | Make the dev case `eaton_small` and its CPU-REF references (restarts at 02:00 and 02:20) |
| `port/h100/window.sh` | Run a test window (W-T0, W-20, W-100, W-RAD, W-FORCE, W-TKE, W-IGN, W-FIRE, W-1H) with a build |
| `port/h100/compare.sh` | Compare two runs bit for bit (traces and output files) |
| `port/h100/smoke_case.sh` | The em_fire smoke case (CPU-view checks only; not a GPU case) |
| `port/gates/static.sh` | Guards before every commit (no GPU): tools, protected files, arith_guard, kernel_lint, rp_subst, workbook |
| `port/gates/t_ab.sh <route> [window]` | T-AB: a routine on the device vs on the host, same run otherwise |
| `port/gates/t_trace.sh [window]` | T-TRACE: GPU-REPRO vs CPU-REF |
| `port/gates/t_cpu_view.sh`, `t_drift.sh` | The CPU view is unchanged (fast / 1 h) |
| `port/gates/t_reg20.sh` | T-REG-20, the per-commit regression |
| `port/gates/t_selftest.sh`, `t_upd.sh`, `t_gate.sh`, `t_mem.sh`, `t_nsys.sh`, `t_fire.sh` | Phase-specific tests (see the cards) |
| `port/gates/g1.sh` … `g5.sh` | Phase gates: run everything, print a PASS/FAIL table |
| `port/gates/ref_tests.sh` | The standalone reference tests on the GPU (`port/tests/run_ref_tests.sh`) |
| `port/tools/workbook.py` | `status`, `next`, `set`, `check` for the workbook and kernels.csv |
| `port/tools/gen_island.py <file> <routine>` | Generates the island (entry/exit data movement) of a ported routine |
| `port/tools/gen_kernels_csv.py`, `gen_routes_md.py` | Regenerate KERNEL_REFS.md/kernels.csv and ROUTES.md after the CPU-view base moves (statuses are kept) |
| `port/tools/arith_guard.py` | CPU view unchanged; no new arithmetic in GPU code |
| `port/tools/kernel_lint.py` | Directive rules of every kernel |
| `port/tools/check_generated.py` | Checks the Registry-generated code of P1.2/P1.3 |
| `port/tools/locate.py` | plan.md's v4.6.0 line → the line in your working tree |
| `port/tools/nsys_copies.py` | Counts host↔device copies in an nsys report |
| `port/tools/check_verbatim.py` | The "original" code in the reference tests is the WRF source |
| `port/tools/gen_kernels_csv.py` | Regenerates KERNEL_REFS.md / kernels.csv (keeps the status columns) |
| `port/bittrace_diff.py`, `compare_fields.py`, `compare_fire.py` | Comparisons (traces, netCDF fields, burned cells) |

## Reference tests (verified; use them as worked examples)

| Test | Kernel(s) | What it proves |
|---|---|---|
| `port/tests/pdlim/` T-PDLIM | K-PD-L3a/b | the positive-definite limiter split into a cell kernel and face kernels is exact |
| `port/tests/kiss/` T-KISS | K-RRTMG-COL | RRTMG's random numbers are identical host vs device |
| `port/tests/ozn/` T-OZN | K-OZP | the ozone interpolation as one thread per j-row is exact |
| `port/tests/templates/` B, C, G | K-ADVU-Y1/Y2, K-PREP-5a/b, K-BC-3D | rolling-buffer split, column kernel with range guards, boundary strips |
| `port/tests/tools/calc_coef_w_gpu.inc` | K-CCW | a complete in-place port (Template C) that passes arith_guard and kernel_lint |
| `port/tests/repro_math/`, `port/tests/omp_features/` | – | compiler facts (T-FMA, T-IEEE, …, F-* probes) |

Each reference test has mutants (`mutants*.py`): plausible mistakes that the test must catch.
