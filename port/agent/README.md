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
| [DEBUGGING.md](DEBUGGING.md) | From "T-AB FAIL" to the wrong statement: fast harness, tracer, fine tracing, bisection, sanitizer |
| [BUILD_SYSTEM.md](BUILD_SYSTEM.md) | How WRF is built: build order, flags, the 4 compile steps, the Registry, depend.common, compile errors, fast iteration |
| [PHASE1.md](PHASE1.md) | Entry tasks H0 on the H100 machine; Phase 1: device residency, update lists, tables, pool, work arrays, startup gate, NVTX, logs |
| [PHASE2.md](PHASE2.md) | Phase 2: dynamics kernels, sub-phases P2.A–P2.G |
| [PHASE3.md](PHASE3.md) | Phase 3: physics kernels (glue, WSM6, surface, YSU, radiation) |
| [PHASE4.md](PHASE4.md) | Phase 4: WRF-Fire kernels |
| [PHASE5.md](PHASE5.md) | Phase 5: nest forcing, sync points, removing the last island |
| [PHASE6.md](PHASE6.md) | Phase 6: performance (bit-neutral only) |
| [PHASE7.md](PHASE7.md) | Phase 7: regression script, other fires |
| [KERNEL_REFS.md](KERNEL_REFS.md) | Generated: for every kernel of plan.md, the exact CPU lines to port (file:line in the CPU-view base commit) and plan.md's v4.6.0 lines. Read a row with `port/tools/ref.py <kernel id>`, not the whole file |
| [PROMPTS.md](PROMPTS.md) | For the project owner: the prompts that start a first, a resumed and a next-phase session |
| [CHEATSHEET.md](CHEATSHEET.md) | Rules, loop, templates, top pitfalls on two pages: read at the start of every session after the first |
| [ROUTES.md](ROUTES.md) | Generated: for every route, its routines (definition file:lines) and every call site in the base commit |
| [WORKBOOK.md](WORKBOOK.md) | **Kept by the agent**: current state, task checklist, log |
| [kernels.csv](kernels.csv) | **Kept by the agent** (status columns): one row per kernel table row of plan.md |
| [BLOCKERS.md](BLOCKERS.md) | **Kept by the agent**: problems that need the project owner |
| [REFACTORS.md](REFACTORS.md) | **Kept by the agent**: shared refactors and moves of the CPU-view base, with evidence |
| `cpu_view_base` | The commit whose CPU view every build must reproduce (see WORKFLOW.md) |
| `protected.md5` | Checksums of the **locked** files: tests, checkers, gates, windows, comparison tools, guides (written by `port/tools/protect.py`) |
| `infra.md5` | Checksums of the **infrastructure** scripts the agent may fix as a logged tool fix (WORKFLOW.md §8) |
| [TOOL_FIXES.md](TOOL_FIXES.md) | **Kept by the agent**: one row per fix of an infrastructure script |
| `arith_exceptions.txt` | Reviewed exceptions for arith_guard (WORKFLOW.md §8) |

## Scripts and tools

| Path | What |
|---|---|
| `port/h100/env.sh` → `env.local.sh` | Machine settings (paths, ranks, GPU); copy and edit |
| `port/h100/setup_toolchain.sh` | No root needed: `image` (pull the NVHPC container), `deps` (tcsh, m4, netCDF built in the container into `$WORK/deps`), `deps-gnu` (gfortran netCDF for T-UNINIT), `python`, `check`, `shell` |
| `port/h100/common.sh` (`x`) | Runs a command in the container (Apptainer, rootless Podman or Docker) with the port's environment (`in_container.sh`) |
| `port/h100/build.sh` | Builds: `cpu-ref`, `gpu-repro`, `gpu-debug`; `--commit REV` (clean) or `--worktree` (incremental); `--fire-ideal` (smoke case), `--fine`, `gnu --uninit nan\|zero` (T-UNINIT) |
| `port/h100/dev_case.sh` | Make the dev case `eaton_small` and its CPU-REF references (restarts at 02:00 and 02:20) |
| `port/h100/window.sh` | Run a test window (W-T0, W-20, W-100, W-RAD, W-FORCE, W-TKE, W-IGN, W-FIRE, W-1H; S-3M smoke) with a build; stops after `RUN_TIMEOUT` |
| `port/h100/compare.sh` | Compare two runs bit for bit (traces and output files) |
| `port/h100/smoke_case.sh` | The em_fire smoke case (window S-3M): no inputs needed; the stand-in while the case data are missing (PHASE1.md "Without the case data"), and the fast call-check case for physics |
| `port/gates/static.sh` | Guards before every commit (no GPU): tools, locked files, logged tool fixes, build flags, arith_guard, kernel_lint, rp_subst, workbook |
| `port/gates/t_ab.sh <route> [window]` | T-AB: a routine on the device vs on the host, same run otherwise |
| `port/gates/t_trace.sh [window]` | T-TRACE: GPU-REPRO vs CPU-REF |
| `port/gates/t_cpu_view.sh`, `t_drift.sh` | The CPU view is unchanged (fast / 1 h) |
| `port/gates/t_reg20.sh` | T-REG-20, the per-commit regression |
| `port/gates/t_selftest.sh`, `t_upd.sh`, `t_gate.sh`, `t_mem.sh`, `t_nsys.sh`, `t_fire.sh` | Phase-specific tests (see the cards) |
| `port/gates/t_dec.sh`, `t_uninit.sh` | T-DEC (CPU-REF 1 rank = N ranks), T-UNINIT (no read of uninitialized memory): PHASE1.md H0.8, H0.9 |
| `port/gates/g1.sh` … `g5.sh` | Phase gates: run everything, print a PASS/FAIL table |
| `port/gates/ref_tests.sh` | The standalone reference tests on the GPU (`port/tests/run_ref_tests.sh`) |
| `port/tools/workbook.py` | `status`, `next`, `set`, `check` for the workbook and kernels.csv |
| `port/tools/gen_island.py <file> <routine>` | Generates the island (entry/exit data movement) of a ported routine, with its call check (`WRF_GPU_CALLCHECK=<route>`, DEBUGGING.md §0b) |
| `WRF/frame/module_gpu_map.F` | By-address device mapping of the state (P1.2/P1.3 generated code calls it) |
| `WRF/frame/module_gpu_callcheck.F` | The in-model call check of the islands |
| `WRF/inc/gpu_col.h` | Fixed column sizes and declaration macros of the column-physics kernels (P3.0) |
| `port/tools/gen_kernels_csv.py`, `gen_routes_md.py` | Regenerate KERNEL_REFS.md/kernels.csv and ROUTES.md after the CPU-view base moves (statuses are kept) |
| `port/tools/arith_guard.py` | CPU view unchanged; no new arithmetic in GPU code |
| `port/tools/kernel_lint.py` | Directive rules of every kernel |
| `port/tools/check_generated.py` | Checks the Registry-generated code of P1.2/P1.3 |
| `port/tools/locate.py` | plan.md's v4.6.0 line → the line in your working tree |
| `port/tools/nsys_copies.py` | Counts host↔device copies in an nsys report |
| `port/tools/check_verbatim.py` | The "original" code in the reference tests is the WRF source |
| `port/h100/harness.sh <file> <routine>` | One routine on random inputs: host vs device and CPU view vs device, in about a minute (DEBUGGING.md §0) |
| `port/h100/compile_one.sh <mode> <file> [--minfo]` | Compiles one working-tree file against a build in seconds (BUILD_SYSTEM.md) |
| `port/h100/build_cmds.py show <build> <dir/file.F>` | The exact preprocess/compile commands of a file |
| `port/tools/add_to_build.py`, `port/tools/check_deps.py` | Register a new file with the build; check depend.common/Makefiles (static.sh) |
| `port/tools/ref.py <kernel id|route|routine>` | The CPU code to port, from the base commit, in pages (context budget) |
| `port/tools/index.py <file>` | Map of a file: modules and routines with line ranges |
| `port/tools/workbook.py resume` / `archive` | What a fresh session needs; keep WORKBOOK.md small |
| `port/tools/kernel_off.py` | Runs one kernel on the host, temporarily, to confirm a suspect (DEBUGGING.md §2) |
| `port/gates/t_fine.sh` | Fine tracing: CPU-REF vs GPU (or route off vs on) with a checkpoint after every routine (DEBUGGING.md §1b) |
| `port/tools/check_build_flags.py` | The arithmetic flags of the GPU-port stanzas (and of any build, `--build <dir>`) are intact |
| `port/tools/check_tool_fixes.py` | Every changed infrastructure script is logged in TOOL_FIXES.md |
| `port/tools/gen_kernels_csv.py` | Regenerates KERNEL_REFS.md / kernels.csv (keeps the status columns) |
| `port/bittrace_diff.py`, `compare_fields.py`, `compare_fire.py` | Comparisons (traces, netCDF fields, burned cells) |

## Reference tests (verified; use them as worked examples)

| Test | Kernel(s) | What it proves |
|---|---|---|
| `port/tests/pdlim/` T-PDLIM | K-PD-L3a/b | the positive-definite limiter split into a cell kernel and face kernels is exact |
| `port/tests/kiss/` T-KISS | K-RRTMG-COL | RRTMG's random numbers are identical host vs device |
| `port/tests/ozn/` T-OZN | K-OZP | the ozone interpolation as one thread per j-row is exact |
| `port/tests/templates/` B, C, G | K-ADVU-Y1/Y2, K-PREP-5a/b, K-BC-3D | rolling-buffer split, column kernel with range guards, boundary strips |
| `port/tests/templates/t_tmpl_cp.F90` T-TMPL-CP | K-WSM6 and the other CP kernels | column physics: slab wrapper → one thread per column, assumed-shape core, fixed-size locals, SAVE constants, errors |
| `port/tests/callcheck/` T-CALLCHECK | every island | the call check finds a device-only difference at its element and restores the inputs |
| `port/tests/tools/calc_coef_w_gpu.inc` | K-CCW | a complete in-place port (Template C) that passes arith_guard and kernel_lint |
| `port/tests/repro_math/`, `port/tests/omp_features/` | – | compiler facts (T-FMA, T-IEEE, …, F-* probes incl. F-COMPMAP, F-EQUIV, F-DATA) |

Each reference test has mutants (`mutants*.py`): plausible mistakes that the test must catch.
