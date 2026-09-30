# Workbook of the GPU port

The coding agent keeps this file current, so that anyone (a person or another agent) can take over mid-way.
Rules: [WORKFLOW.md](WORKFLOW.md), section "Workbook". Checked by `python3 port/tools/workbook.py check`, which is
part of `port/gates/static.sh` (run before every commit). Kernel-level progress lives in the status columns of
[kernels.csv](kernels.csv) (`python3 port/tools/workbook.py set ...`; overview: `workbook.py status`).

How to update, after every task (and at the end of every work session, even if the task is unfinished):
1. Overwrite **Current state** (keep the `- Key: value` lines; every key must have a value).
2. Tick the task in **Task checklist** when its "Done when" (in the phase card) holds:
   `- [x] P1.2 Device residency of all state — commit 1a2b3c4 — tests check_generated C1-C3 PASS, T-MAP PASS`
3. Append a **Log** entry (newest last) with the heading `### YYYY-MM-DD <task id> <title>`.
4. For kernels: `python3 port/tools/workbook.py set K-ADVU-Y1 done --commit <sha> --tests "T-AB-advect_u W-20 PASS; T-TRACE W-20 PASS"`.

## Current state

- Phase: H0 (entry tasks on the H100 machine)
- Current task: H0.1
- Last commit: (none yet by the agent; handoff package on branch claude/wrf-gpu-port-cpu-7doq8n)
- Last gate passed: G0, local part only (CPU, gfortran; see port/RESULTS.md)
- Builds: none yet on the H100 machine
- Dev references: not made yet (no Eaton inputs; smoke case S-3M until they arrive)
- Blockers: B1 open — ticking H0.1 makes the locked workbook self-test a no-op (static.sh tools FAIL). H0.1 itself passed.
- Next step: H0.2 — in port/tests/repro_math, `make fma_cases.bin` on the host, then `x make` and `CUDA_VISIBLE_DEVICES=$GPU_ID x ./run_tests.sh` (T-FMA first). If T-FMA fails, stop and write BLOCKERS.md.
- Pending the case data: H0.6; H0.7; H0.8 on W-20; t_trace.sh W-T0; t_trace.sh W-20; t_upd.sh; t_selftest.sh; t_nsys.sh W-20; t_mem.sh 55; g1.sh

### Owner decisions (override the cards)
- No Eaton inputs on this machine. Use smoke window S-3M (port/h100/smoke_case.sh: em_fire ideal, Eaton physics and fire options, one domain, no inputs). H0.6 and H0.7 wait. H0.8 is two CPU-REF S-3M runs compared with compare.sh, plus t_cpu_view.sh S-3M and static.sh. Builds once with --fire-ideal: cpu-ref --commit <cpu_view_base>, cpu-ref --worktree, gpu-repro --worktree. Later builds keep main/ideal_fire.exe.
- Substitutes: T-TRACE is t_trace.sh S-3M (if it fails, rerun CPU-REF with --ranks 1). Self tests: window.sh gpu-repro worktree S-3M WRF_GPU_SELFTEST=1, then grep gpu_selftest: in rsl.error.0000. T-UPD: GPU-REPRO S-3M with WRF_GPU_UPD_EVERY_STEP=1 vs the CPU-REF S-3M run. NVTX: t_nsys.sh S-3M. Timing and memory: grep the S-3M rsl.error.0000. T-GATE: t_gate.sh, which needs no inputs. After P1.8, export WRF_GPU_CHECK=warn for smoke runs only and unset it before t_gate.sh.
- Smoke has no nest, no boundary file and no restart start, so S2, S2', S5, S6 and the S1 path after a restart read are written but not verified.
- Do not tick a task whose Done when names a W-* window, the dev case, or the full case. Write "(smoke: what passed)" next to it.
- P1.2 maps every field as a component (!$omp target enter data map(to:grid%<field>)). If it does not compile, fails at run time, or T-MAP reports fields not present: no workaround (no whole-grid map, no renaming). After at most three attempts, BLOCKERS.md, mark P1.2 blocked, and continue with P1.4, P1.6, P1.7, P1.8, P1.10-P1.12. P1.3's steps and P1.5+P1.9 need P1.2.
- P1.7: postpone the work arrays to the phase that ports each routine. In Phase 1 write only WRF/frame/module_gpu_work.F with an empty list. T-WORK prints "gpu_selftest: T-WORK PASS 0 work arrays (postponed to Phases 2-4)".
- Time limits: start window.sh and harness.sh with timeout 1h; a gate or build.sh with timeout 4h. If a timeout stops a run, find leftover wrf.exe or harness (nvidia-smi, ps -u $USER) and kill that PID, never pkill -f. Write every timeout in the log.
- port/RESULTS.md rows marked CCR, and everything under port/ccr/, are not tasks here.

## Task checklist

### H0 — entry tasks on the H100 machine (PHASE1.md §0)
- [ ] H0.1 Toolchain installed and checked (setup_toolchain.sh check), versions in port/ENVIRONMENT.md
- [ ] H0.2 Reproducible-math checks on the H100 (T-FMA first, T-IEEE, T-IPOW, T-RM-EXH, T-RM-POW, T-RM-D)
- [ ] H0.3 OpenMP feature probes F-* run, decisions recorded in port/ENVIRONMENT.md
- [ ] H0.4 Reference tests on the GPU (port/gates/ref_tests.sh)
- [ ] H0.5 CPU-REF builds (base commit and worktree), T-SYM on the CPU-REF objects
- [ ] H0.6 Eaton inputs checked, dev case made (dev_case.sh make)
- [ ] H0.7 Dev references made (dev_case.sh reference)
- [ ] H0.8 Harness smoke check: CPU-REF determinism on W-20, t_cpu_view.sh PASS

### Phase 1 — GPU infrastructure (PHASE1.md)
- [ ] P1.1 First GPU-REPRO build compiles and runs W-20 on the host path
- [ ] P1.2 Device residency of all state (gen_allocs.c), T-MAP
- [ ] P1.3 Generated update lists (gen_gpu.c), gpu_upd_host_stream
- [ ] P1.4 Module tables on the device (gpu_update_tables), T-TAB
- [ ] P1.5 Sync points S1-S6, in one step with P1.9 (T-TRACE W-T0 and W-20, T-UPD)
- [ ] P1.6 Scratch pool on the device, T-POOL
- [ ] P1.7 Work arrays (shared refactor protocol), T-WORK
- [ ] P1.8 Startup gate gpu_check_config, T-GATE
- [ ] P1.9 Whole-solve_em bracket, in one step with P1.5 (tick both with the same commit)
- [ ] P1.10 NVTX ranges
- [ ] P1.11 Timing log
- [ ] P1.12 Memory log
- [ ] G1 Phase 1 gate (port/gates/g1.sh)

### Phase 2 — dynamics kernels (PHASE2.md; kernels.csv sections 7.1-7.7)
- [ ] P2.A RK preparation and physical BCs (G2.A)
- [ ] P2.B Large-step tendencies (G2.B)
- [ ] P2.C Tendency combination and lateral BCs (G2.C)
- [ ] P2.D Acoustic loop (G2.D)
- [ ] P2.E Scalar transport (G2.E)
- [ ] P2.F End of step (G2.F)
- [ ] P2.G Turbulence and LES (G2.G)
- [ ] G2 Phase 2 gate (port/gates/g2.sh)

### Phase 3 — physics kernels (PHASE3.md; kernels.csv sections 8.1-8.5)
- [ ] P3.0 Column-physics infrastructure (gpu_col.h, fixed sizes, stack size CP-5)
- [ ] P3.A Physics glue (G3.A)
- [ ] P3.B WSM6 (G3.B)
- [ ] P3.C Surface: surface_driver, sfclayrev, Noah, sea ice, diagnostics (G3.C)
- [ ] P3.D YSU PBL (G3.D)
- [ ] P3.E Radiation: RRTMG LW, Dudhia SW, radiation driver (G3.E)
- [ ] G3 Phase 3 gate (port/gates/g3.sh)

### Phase 4 — WRF-Fire kernels (PHASE4.md; kernels.csv section 9.1)
- [ ] P4.0 Fire shared refactors (plan.md 9.0; shared refactor protocol)
- [ ] P4.1 Fire kernels, atmosphere-to-fire interpolation
- [ ] P4.2 Fire kernels, level-set propagation and reinitialization
- [ ] P4.3 Fire kernels, ignition, fuel, heat fluxes, fire_tendency
- [ ] G4 Phase 4 gate (port/gates/g4.sh)

### Phase 5 — nest forcing and sync points (PHASE5.md)
- [ ] P5.1 couple_or_uncouple_em on the device
- [ ] P5.2 med_force_domain rewiring (T-FORCE, T-SLAB, T-O3)
- [ ] P5.3 Remove the whole-solve_em island (T-NSYS-CLEAN)
- [ ] P5.4 Output and input sync verification (T-OUT, T-BDY)
- [ ] G5-H100 Phase 5 gate, H100 part (port/gates/g5.sh)

### Phase 6 — performance (PHASE6.md)
- [ ] P6.1 Metrics and profile of the correct build (port/PERF.md)
- [ ] P6.2 Optimizations O1-O11, one commit each, each bitwise
- [ ] G6 Phase 6 gate, H100 part

### Phase 7 — other fires (PHASE7.md)
- [ ] P7.1 Regression script port/regress.sh
- [ ] P7.2 Onboarding guide for a new case

## Log

### 2026-09-30 H0.1 checkbox left open (B1)
- Commit 78611a4 ticked H0.1. static.sh then failed: test_agent_tools.py only detects a bad tick by rewriting the still-open `- [ ] H0.1` line. The box is open again so static.sh passes. The check itself passed; see BLOCKERS.md B1.

### 2026-09-30 H0.1 toolchain check PASS
- `setup_toolchain.sh check` printed `toolchain: PASS`. nvfortran 25.1-0, netCDF-Fortran 4.6.1 built with nvfortran, tcsh 6.24.13, four H100 80 GB, driver 570.211.01. Versions are in port/ENVIRONMENT.md.
- The libraries were ready before that check: `deps` then called `bash "$0" check` after `cd $DEPS/src` and exited 127. Tool fix uses `$PORT_REPO/port/h100/setup_toolchain.sh`.
- No timeout. Eaton inputs still absent (0/3).

### 2026-09-30 H0.1 Toolchain image and HDF5 URL
- Image `nvcr.io/nvidia/nvhpc:25.1-devel-cuda12.6-ubuntu22.04` pulled to `$WORK/images/nvhpc.sif` (6.4 GB). `x nvidia-smi -L` shows four H100 80 GB; `x nvfortran --version` is 25.1-0. Host Python env has numpy 2.5.3, netCDF4 1.7.4, mpmath.
- Apptainer is a user-space 1.5.4 binary. Ubuntu 24.04 AppArmor blocks user namespaces, so `~/.local/bin/apptainer` runs the real binary inside `/usr/bin/rootlesskit`. Not a repo change.
- `setup_toolchain.sh deps` built ncurses 6.4 and tcsh 6.24.13, then died: HDF5 download 404. Tool fix: tag `hdf5_1.14.4.3`. Rerun of deps is in `$WORK/deps_build.log`.
- No timeout. Eaton inputs still absent.

### 2026-09-30 SETUP Reading
- The 11 rules: never change arithmetic; GPU code only under WRF_GPU; never edit locked tests, checkers or gates; one routine per commit (WIP allowed); static.sh before every commit and T-AB plus T-TRACE before done; keep the workbook current; push only to agent/phase-N and never force-push; port the lines ref.py shows; no root, so the toolchain runs in the container through x; after three honest attempts write BLOCKERS.md and move on; stay inside the context budget and checkpoint.
- CPU view and arith_guard: with WRF_GPU undefined a file must match the cpu_view_base commit, except allowed additions (USE of port modules, CALL gpu_*, island includes, route tests, directive lines). arith_guard rejects a new arithmetic skeleton and any other CPU-view drift. Shared refactors that must change both views follow WORKFLOW.md and need bitwise evidence before the base moves.
- Islands and gpu_world_host: the flag is true while the current values live in host memory. An island copies a routine's array arguments to where that routine runs, flips the flag for nested routes, and copies non-INTENT(IN) arrays back. Through Phase 4 the flag stays true because the solve_em bracket keeps the host copy current.
- P1.5 and P1.9 are one step because each half is what makes the other safe. The bracket downloads the state at the start of solve_em and uploads it at the end. The sync points upload host changes between steps and download before host code reads. Doing only one overwrites fresh data with a stale copy.
- Task loop: workbook.py next, the phase-card section, ref.py, write under WRF_GPU with a generated island, static.sh, compile_one.sh and harness.sh, then the worktree build, t_ab and t_trace, commit, workbook update, push.
- When a test fails: compare.sh names the first differing domain, step, tag and field; WRF_GPU_OFF checks whether that route is the cause; then compare the kernel to its CPU lines and check the island. Never change the CPU side, loosen a comparison, or leave a route off. Three attempts, then BLOCKERS.md.
- Context: never open a whole WRF source, plan.md, KERNEL_REFS.md, kernels.csv or a log. Use ref.py, index.py, sed ranges of at most about 300 lines, and grep | head. At about 60% of context, and after every task: static.sh, commit, an exact Next step, push, then stop.

### 2026-09-30 HANDOFF Package for the coding agent
- Commit(s): see `git log` on branch claude/wrf-gpu-port-cpu-7doq8n (Phase 0 and the agent package)
- Changed: Phase 0 done locally (port/RESULTS.md); guard tools, reference tests, H100 scripts, gates, phase cards.
- Tests run: port/tests/tools/test_agent_tools.py PASS; port/tests/run_ref_tests.sh gnu PASS (host only).
- Notes: nothing has run on NVHPC or a GPU yet. Start with H0.1.

### 2026-09-30 P1.3 Update lists written at handoff (not ticked: NVHPC check pending)
- Commit(s): the handoff commit that adds WRF/tools/gen_gpu.c (`git log -- WRF/tools/gen_gpu.c`)
- Changed: WRF/tools/gen_gpu.c (new; called from registry.c after gen_dealloc; protos.h, tools/Makefile,
  tools/CMakeLists.txt) writes inc/gpu_upd_dev_all.inc, gpu_upd_host_all.inc, gpu_upd_dev_bdy.inc;
  WRF/frame/module_gpu_updates.F (new: gpu_upd_dev_all/host_all/dev_bdy, gpu_upd_host_stream = whole state through
  Phase 4) in frame/Makefile, frame/CMakeLists.txt, main/depend.common (with the future callers depending on it);
  check_generated.py C7 now requires the guard to name the updated field and exempts boundary arrays.
- Tests run: gfortran worktree build --clean: the three lists are generated (2579 updates in each whole-state list,
  104 in the boundary list); check_generated.py --only C4,C5,C7 PASS; module_gpu_updates.F compiles without
  WRF_GPU (in the build) and with -DWRF_GPU -fopenmp (gfortran); static.sh PASS; test_agent_tools.py PASS.
- Notes: to do on the H100 (PHASE1.md P1.3 "Your steps"): gpu-repro --clean build, C4/C5/C7, nvfortran accepts
  `target update` of `grid%` components (fallback described there), T-TRACE W-20. Then tick P1.3.

### 2026-09-30 HANDOFF Tool fixes allowed for infrastructure; fine tracing and kernel_off (owner changes)
- Commit(s): the handoff commit that adds port/agent/TOOL_FIXES.md (`git log -- port/agent/TOOL_FIXES.md`)
- Changed (protection, AGENTS.md rule 3, WORKFLOW.md §8): two tiers. Locked (protected.md5): tests, checkers,
  gates, compare.sh, the new window table port/h100/windows.txt, comparison tools. Infrastructure (infra.md5):
  port/h100 build/run/setup scripts, port/container, make_dev_case.py, nml.py: fixable as a logged "tool fix"
  (row in TOOL_FIXES.md, checked by check_tool_fixes.py in static.sh). New locked checks: check_build_flags.py
  (arithmetic flags of the stanzas in static.sh and of every build in the gates), window.info must show
  OMP_TARGET_OFFLOAD=MANDATORY for GPU runs and the trace level of windows.txt (lib.sh). Template B reference test
  falls back to module functions if nvfortran rejects statement functions in device code (run_ref_tests.sh NOTE).
- Changed (debugging, DEBUGGING.md §1b/§2): build.sh --fine (-DWRF_TRACE_FINE, both builds), WRF_BITTRACE=3 with
  a checkpoint after every routine called by solve_em, first_rk_step_part1/2 and rk_tendency (#ifdef
  WRF_TRACE_FINE only; CPU view unchanged), bt_fine2/3/f for checkpoints inside routines, filters
  WRF_BITTRACE_DOMAIN/FIELDS, port/gates/t_fine.sh, port/tools/kernel_off.py (one kernel on the host,
  temporary; static.sh refuses KOFF-TEMP edits). GPU-DEBUG stanza macro renamed WRF_GPU_TRACE_FINE -> WRF_TRACE_FINE.
- Tests run (gfortran, no GPU): static PASS; tool tests PASS; ref tests PASS (also template B module-function
  form). Smoke case S-3M: normal build of this tree = earlier build, bitwise (189000 trace records, output file);
  --fine build at trace level 2 = normal build, bitwise; at level 3 (steps 100-101) the 1050 level-2 records are
  unchanged and 64394 fine records appear (p1:, p2:, rkt: tags). (8 fine checkpoints first sat inside continued CALL
  statements and broke --fine builds: fixed in 2917d94.)
- Notes: nothing of this has run on NVHPC or a GPU yet.

### 2026-09-30 HANDOFF Fast per-routine harness and build-system tools (owner changes)
- Commit(s): the handoff commit that adds port/h100/harness.sh (`git log -- port/h100/harness.sh`)
- Changed (iteration speed, DEBUGGING.md §0): port/h100/harness.sh + gen_harness.py (driver calling one routine on
  random-bit inputs, config_flags from the namelist) + build_cmds.py (exact per-file compile commands, recorded by
  build.sh after every build) + port/tools/harness_diff.py (locked comparison): HOST vs DEVICE and CPU vs DEVICE for
  one routine in about a minute. port/h100/compile_one.sh: one file against a build in seconds (--minfo).
  WORKFLOW.md task loop step 6, PHASE2.md, CODING_STANDARD checklist use them.
- Changed (build system): port/agent/BUILD_SYSTEM.md (build order, flags, the 4 compile steps incl. what
  standard.exe does, Registry, depend.common, errors); port/tools/check_deps.py (static.sh "deps": new USE ->
  depend.common, compile order, new files in Makefile/CMakeLists) and port/tools/add_to_build.py. check_deps found
  3 missing depend.common entries from the fine-trace USEs (module_em, first_rk_step_part1/2): added. All of
  port/h100 except compare.sh and windows.txt is now infrastructure (fixable as a tool fix).
- Tests run (gfortran worktree build, no GPU): harness PASS on calc_ww_cp, advance_w, advance_uv, calc_p_rho_phi,
  rk_update_scalar (11 s each incl. compile); a regrouped product in calc_ww_cp is caught (12537 of 46000 ww values
  differ); compile_one.sh 3 s on module_small_step_em.F and reports a planted syntax error; a GPU-mode driver
  compiles with gfortran -fopenmp; tool tests (check_deps/add_to_build on a scratch repo, harness_diff, gen_harness)
  PASS; static PASS.
- Notes: not run with NVHPC or on a GPU. First use on the H100: build cpu-ref and gpu-repro --worktree once
  (build.sh records the compile commands), then harness.sh calc_alt / calc_ww_cp as a check of the harness itself.

### 2026-09-30 HANDOFF Context budget of 250k tokens (owner changes)
- Changed: AGENTS.md (reading tiers: first session about 35k tokens, later sessions about 10k; rule 11), WORKFLOW.md
  §11 (budget, reading/editing/output rules, checkpoint at 60%, WIP commits, split of the 18 routines above 500
  lines), CHEATSHEET.md (resume read), PROMPTS.md (first/resume/next-phase prompts), context notes in PHASE2-4.
- New tools: port/tools/ref.py (a kernel's/route's/routine's base-commit code, paged), port/tools/index.py (map
  of a file), workbook.py resume (about 60 lines) and archive; workbook check limits WORKBOOK.md to 40000
  characters and log entries to 25 lines.
- Tests run: tool tests PASS (ref.py, index.py, resume/archive/limits on a scratch copy); static PASS.

