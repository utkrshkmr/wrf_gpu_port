# Phase 1 — entry tasks on the H100 machine, and the GPU infrastructure

Plan: [plan.md §6](../../plan.md) (P1.1–P1.12, G1). Line numbers below are in the **CPU-view base commit**
(`port/agent/cpu_view_base`); view with `git show $(sed 's/#.*//' port/agent/cpu_view_base | awk 'NF{print $1;exit}'):<file> | sed -n 'a,bp'`,
or find the current line with `python3 port/tools/locate.py <file> <v4.6.0 line>` (plan.md cites v4.6.0 lines).
Every task: do it, run its "Done when", commit, tick it in the workbook with the commit and tests, write a log
entry. All compiler, make, MPI and `wrf.exe` commands run in the container (`x ...`, see ENV_H100.md).

**Build order (applies to every new file).** WRF compiles `frame/` first, then `share/`, then `phys/`, then
`dyn_em/`, then `main/`. A module can only be USEd by code compiled after it. New port files therefore go where
their dependencies are: update lists and pool/work modules in `WRF/frame/` (they need only `module_domain` and
`module_configure`), table uploads in `WRF/phys/` (they USE the physics modules). Code in `frame/` (e.g.
`module_integrate.F`, `module_domain.F`) calls routines that live in later directories as **external subroutines**
without a USE: write such entry points outside any module (`SUBROUTINE gpu_update_tables()` at the end of the file,
after `END MODULE`). `CALL gpu_*` lines are allowed in the CPU view. Every new file must be added to its directory's
`Makefile` (module list) and to `WRF/main/depend.common` (who depends on it), as was done for
`module_gpu_route.o` and `module_gpu_updates.o`: `python3 port/tools/add_to_build.py WRF/<dir>/<file>.F` does all
three (Makefile, CMakeLists.txt, depend.common); after adding `USE` lines to an existing file,
`add_to_build.py --deps <file>`. `static.sh` runs `check_deps.py`. Build with `--clean` after adding files.
[BUILD_SYSTEM.md](BUILD_SYSTEM.md) explains the build and its errors; `port/h100/compile_one.sh` compiles one file
in seconds.

---

## §0. Entry tasks H0 (the H100 machine)

The setup, build and run scripts have not run on this machine before. When one of them fails for a reason in the
script itself (a container option, an MPI launcher flag, a configure prompt, an attribute of the real inputs), fix it
as a **tool fix** (WORKFLOW.md §8: one commit, a row in TOOL_FIXES.md). When a **test or checker** seems wrong, do not
touch it: BLOCKERS.md.

### H0.1 Toolchain
Follow [ENV_H100.md](ENV_H100.md) §1–2. **Done when** `bash port/h100/setup_toolchain.sh check` ends with
`toolchain: PASS`; the image tag/digest, driver, `nvfortran --version`, netCDF versions are in `port/ENVIRONMENT.md`.

### H0.2 Reproducible-math checks on the H100 (plan.md P0.5)
```sh
source port/h100/common.sh
cd port/tests/repro_math && make fma_cases.bin          # on the host (Python)
x make && CUDA_VISIBLE_DEVICES=$GPU_ID x ./run_tests.sh      # in the container; T-FMA first
```
**Done when** every test prints PASS; the results file is copied into `port/RESULTS.md` (G0 checklist rows "T-FMA …
T-RM-D", column "H100"). **If T-FMA fails, stop** and write BLOCKERS.md: no kernel work is possible (plan.md §15).
If T-IEEE reports a host/device difference for `MAX`/`MIN`/`SIGN`, write it into the workbook and BLOCKERS.md
(plan.md P0.5 says to add `rp_max`/`rp_min`/`rp_sign`; the project owner decides).

### H0.3 OpenMP feature probes (plan.md P0.5b)
```sh
cd port/tests/omp_features && CUDA_VISIBLE_DEVICES=$GPU_ID x ./run_probes.sh
```
**Done when** the `probes_<host>_<date>.md` table is pasted into `port/ENVIRONMENT.md` with a decision per probe
(table "Compiler feature probes"). These must pass, else BLOCKERS.md (the owner decides; plan.md P0.5b):
- F-IFTARGET, F-PRESENT, F-DECLMOD;
- **F-COMPMAP-ADDR**: the state is mapped by address, the way the generated code of P1.2/P1.3 does it.

Record:
- whether to use `defaultmap(present: aggregate)` (F-DEFMAP);
- whether statement functions and internal procedures work in device code (F-STMTFN, F-INTPROC);
- the stack-limit mechanism (F-STACK).

These are information for later phases:
- **F-COMPMAP-MEMBER**: the structure-member form `map(to:grid%f)`, which the port does not use. A build failure
  there is expected.
- **F-EQUIV**, **F-DATA**: for Phase 3. A build failure or FAIL of F-EQUIV (gfortran rejects EQUIVALENCE with
  declare target) means the RRTMG table flattening is required. F-DATA FAIL means DATA tables become PARAMETERs.
  See PHASE3.md "Shared refactors".

### H0.4 Reference tests on the GPU
`bash port/gates/ref_tests.sh` → `== ref_tests: PASS`. It runs:
- T-PDLIM, T-KISS, T-OZN;
- templates B/C/G and **CP** (column physics, Phase 3) and their mutants;
- **T-CALLCHECK**, the call check every island carries (DEBUGGING.md §0b).

If T-KISS fails, the KISS rewrite of plan.md P0.9a item 9 becomes a Phase 3 shared refactor; note it.

If it prints `NOTE templates: statement functions rejected in device code`, templates B and CP were built in their
module-function form. Record that in port/ENVIRONMENT.md: it decides the form of `flux5` and the like in Phase 2
(CODING_STANDARD.md §5.4) and of the statement functions of WSM6 in Phase 3.

If T-TMPL-CP fails to build or run, write BLOCKERS.md and continue Phases 1–2: it shows a compiler limitation for
column physics, which matters only in Phase 3.

A failure in a build or run script (not in a test) is an infrastructure bug: fix it as a tool fix (WORKFLOW.md §8).

### H0.5 CPU-REF builds and T-SYM
```sh
bash port/h100/build.sh cpu-ref --commit "$(sed 's/#.*//' port/agent/cpu_view_base | awk 'NF{print $1;exit}')" --fire-ideal
bash port/h100/build.sh cpu-ref --worktree --fire-ideal
source port/h100/common.sh; x bash port/sym_audit.sh $WORK/builds/cpu-ref/worktree
```
**Done when** both builds exist (BUILD_INFO) and T-SYM passes on the host objects (the device part of T-SYM runs on
GPU builds in P1.1). Record the build time. (`--fire-ideal` also builds the smoke case's `ideal_fire.exe`, which
later builds of the same directory keep.)

### H0.6 Inputs and dev case
(Without the Eaton inputs on the machine, skip H0.6 and H0.7 and work on the smoke case: section "Without the case
data" below.)
Copy the inputs (ENV_H100.md §3), then `bash port/h100/dev_case.sh make`. **Done when** the md5 check prints `ok`
for the three inputs and `$WORK/cases/eaton_small/namelist.input` exists (d02 is 181×181). Copy
`$WORK/cases/eaton_small/{namelist.input,README.md}` to `cases/eaton_small/` in the repository and commit them
(the cut is deterministic; the files document it).

### H0.7 Dev references
`nohup bash port/h100/dev_case.sh reference > $WORK/dev_reference.log 2>&1 &` (hours). **Done when**
`dev_case.sh status` shows `run0220 OK`, `win1h OK` and the restart files `wrfrst_d0{1,2}_2025-01-08_0{2:00,2:20}:00`.

### H0.8 Harness check
```sh
b=$WORK/builds/cpu-ref/worktree
bash port/h100/window.sh $b W-20 --tag a; bash port/h100/window.sh $b W-20 --tag b
bash port/h100/compare.sh $WORK/runs/cpu-ref-*/W-20-a $WORK/runs/cpu-ref-*/W-20-b     # determinism
bash port/gates/t_cpu_view.sh                                                          # base vs worktree
bash port/gates/t_dec.sh                                                               # 1 rank vs $CPU_RANKS
bash port/gates/static.sh
```
**Done when** all four print PASS. Record the wall times of W-T0/W-20 (CPU-REF) in the log.

T-DEC (plan.md P0.10) matters because the GPU build runs 1 rank and every T-TRACE compares it with CPU-REF on
`$CPU_RANKS` ranks. If T-DEC fails:
- write BLOCKERS.md with the first differing field (`compare.sh` names it);
- set `CPU_RANKS=1` in `env.local.sh` meanwhile. That is slower, but a valid reference for the GPU build.

Every window run has a time limit: `window.sh` stops `wrf.exe` after `RUN_TIMEOUT` seconds (default: the larger
of 3600 and 20 × the simulated seconds) and writes `TIMEOUT` in `window.info`.

### H0.9 T-UNINIT (once, before the first work-array refactor)
T-UNINIT checks that WRF never reads memory it did not write. It is the evidence that replacing automatic arrays
by zero-filled work arrays (P1.7, done in Phases 2–4) cannot change results.

1. `bash port/h100/setup_toolchain.sh deps-gnu`. This builds the gfortran netCDF; it needs gfortran in the image. If
   there is none, write that in the log and skip this task.
2. `bash port/gates/t_uninit.sh`. With the dev case it runs W-T0 and W-20; without it, S-3M. It builds WRF twice
   with gfortran: once with every local variable starting as NaN, once with every local variable starting as zero.
   The two runs must give identical traces. The two builds take about 10 GB; delete them after a PASS
   (`$WORK/builds/gnu/worktree-uninit-*`).

A FAIL names a field that depends on uninitialized memory. Write it into BLOCKERS.md; the owner decides.

---

**Order of work in Phase 1:** P1.1, P1.2, P1.3, P1.4, P1.6, then **P1.5 and P1.9 together as one step**, then P1.7,
P1.8, P1.10–P1.12. P1.5 (sync points) and P1.9 (the `solve_em` bracket) cannot be done one after the other; see the
section "P1.5 + P1.9" for why.

## Without the case data (smoke case)

While the Eaton inputs (`wrfinput_d01`, `wrfinput_d02`, `wrfbdy_d01`) are not on the machine, skip H0.6 and H0.7.
The dev case, the dev references and every `W-*` window then cannot run. Work on the **smoke case** instead.

**What the smoke case is.** Window `S-3M` (`port/h100/smoke_case.sh`): the em_fire ideal case with the Eaton
physics and fire options. It has one domain, needs no input files, and runs in about a minute on one core.

**Builds.** It needs builds made once with `--fire-ideal`: H0.5 does it for CPU-REF, P1.2 step 2 for GPU-REPRO. Later
builds of the same directory keep `main/ideal_fire.exe`.

**Substitute checks:**

| Check | Without the case data |
|---|---|
| H0.8 | two CPU-REF `S-3M` runs (`window.sh <build> S-3M --tag a`, then `--tag b`) compared with `compare.sh`; `t_cpu_view.sh S-3M`; `t_dec.sh S-3M`; `static.sh` |
| T-TRACE | `bash port/gates/t_trace.sh S-3M` |
| self tests | `rd=$(bash port/h100/window.sh $WORK/builds/gpu-repro/worktree S-3M WRF_GPU_SELFTEST=1 \| tail -1); grep 'gpu_selftest:' $rd/rsl.error.0000` |
| T-UPD | a GPU-REPRO `S-3M` run with `WRF_GPU_UPD_EVERY_STEP=1`, `compare.sh` against the CPU-REF `S-3M` run |
| T-NSYS (P1.10) | `bash port/gates/t_nsys.sh S-3M` |
| P1.11, P1.12 | the `gpu_timing:` / `gpu_mem:` lines of an `S-3M` run |
| T-GATE | needs no inputs: `bash port/gates/t_gate.sh` is the real test |
| T-UNINIT (H0.9) | `bash port/gates/t_uninit.sh` (uses `S-3M` by itself) |

**After P1.8.** The smoke case is outside the supported envelope: one domain, open boundaries, fire tracers. Export
`WRF_GPU_CHECK=warn` for smoke runs only, and unset it before `t_gate.sh` and every gate of the real case.

**What it does not test.** The smoke case has no nest, no boundary file and no restart start. So S2, S2', S5, S6
and the S1 path after a restart read are written but not yet verified.

**Bookkeeping.**
- Do not tick a task whose "Done when" names a `W-*` window, the dev case or the full case. Write
  `(smoke: <what passed>)` next to it in the checklist.
- Keep a list "Pending the case data" in the workbook's Current state, with the exact commands still owed: H0.6,
  H0.7, H0.8 on W-20, `t_dec.sh`, `t_trace.sh W-T0`, `t_trace.sh W-20`, `t_upd.sh`, `t_selftest.sh`,
  `t_nsys.sh W-20`, `t_mem.sh 55`, `g1.sh`.
- G1 cannot run without the data. Stop when every Phase 1 task is written and smoke-checked, or blocked, and report
  the Pending list.

## P1.1 First GPU-REPRO build

`bash port/h100/build.sh gpu-repro --worktree`. Fix compile errors **without changing executable statements**
(put GPU-only workarounds under `#ifdef WRF_GPU`; a real compiler limitation → BLOCKERS.md). Keep the `-Minfo=mp`
output: `compile.log` of the build. Then run `bash port/h100/window.sh <gpu build> W-20` (at this point there are no
kernels, everything runs on the host through the GPU binary).

**Done when** the build succeeds, W-20 runs to `SUCCESS COMPLETE WRF`, and `bash port/gates/t_trace.sh W-20` passes
(GPU binary without kernels = CPU-REF). Also `x bash port/sym_audit.sh <gpu build>` (device part: no MUFU
approximations). Tick P1.1.

If this T-TRACE fails, first check whether CPU-REF itself depends on the MPI decomposition (the GPU build runs one
rank, CPU-REF `$CPU_RANKS`): run the CPU-REF build with `--ranks 1` on W-20 (`window.sh <cpu-ref build> W-20 --ranks 1
--tag r1`) and compare with the N-rank run. A difference there is a T-DEC failure of plan.md P0.10 (CPU-REF must be
decomposition-independent before any kernel work): localize it with the traces, write BLOCKERS.md, and use
`CPU_RANKS=1` for CPU-REF windows meanwhile (slower, but a valid reference for the GPU build).

## P1.2 Device residency of all state (`WRF/tools/gen_allocs.c`) (provided)

**This code is already written and wired** (handoff commit "gaps 7-12", see the workbook log); your task is to build
it with NVHPC, check it and write the self test T-MAP. The fields are mapped **by address**:

1. `WRF/frame/module_gpu_map.F`: `gpu_map_r` / `_d` / `_i` / `_l` (REAL / DOUBLE PRECISION / INTEGER / LOGICAL
   fields) `(a, n, op)` with an assumed-size dummy `a(*)`; `op` = `GPU_MAP_ENTER` (`target enter data
   map(to: a(1:n))`), `GPU_MAP_EXIT` (`exit data map(delete: a(1:n))`), `GPU_UPD_TO`, `GPU_UPD_FROM` (`target
   update`). Why: the fields are ALLOCATABLE components of `TYPE(domain)` (`-DUSE_ALLOCATABLES`,
   `arch/postamble`). Naming them in a clause, `map(to: grid%u_2)`, is a structure-member map: gfortran 13 rejects
   it ("List item 'grid' with allocatable components is not permitted in map clause") and compilers differ on it.
   Every kernel and island receives fields as explicit-shape dummies and finds the device copy by address, so
   mapping the storage by address is all that is needed. Probe F-COMPMAP-ADDR (H0.3) checks this form on the H100.
   This replaces the `map(to:grid%x)` form written in plan.md P1.2/P1.3 (owner decision, workbook log 2026-10-01).
2. `gen_alloc2` writes, under `#ifdef WRF_GPU`, right after each `ALLOCATE` and its initial value (in-use arrays,
   the `(1,1,1)` dummies of unused fields, and each of the four arrays of a boundary field):
   ```fortran
   #ifdef WRF_GPU
     IF (.NOT. grid%is_intermediate) &
     CALL gpu_map_r(grid%u_2, &
       SIZE(grid%u_2,KIND=8), GPU_MAP_ENTER)
   #endif
   ```
   and `gen_dealloc2` the same with `GPU_MAP_EXIT` before each `DEALLOCATE`. The emitting function is
   `gpu_map_call` in `WRF/tools/gen_gpu.c` (shared with the P1.3 update lists). `frame/module_alloc_space.h` and
   `frame/module_domain.F` `USE module_gpu_map` under `#ifdef WRF_GPU`; the module is in `frame/Makefile`,
   `frame/CMakeLists.txt` and `main/depend.common`.
3. Intermediate grids (allocated every parent step for nest forcing) stay on the host because of the guard.

Checked before handoff (gfortran, no GPU): the Registry writes 5158 enter calls into `allocs.inc` and 2579 exit calls
into `deallocs.inc`; `check_generated.py --only C1,C2,C3` passes; the ten `module_alloc_space_N.F`,
`module_domain.F` and `module_gpu_updates.F` compile with `-DWRF_GPU -fopenmp`; the CPU-view build is unchanged.
**Not** checked: NVHPC and the GPU.

**Your steps:**

1. H0.3 printed `PROBE F-COMPMAP-ADDR PASS` (if not: BLOCKERS.md and stop; it is the basis of all data movement).
2. `bash port/h100/build.sh gpu-repro --worktree --clean --fire-ideal` (the Registry must run again; `--fire-ideal`
   for the smoke case), then `python3 port/tools/check_generated.py $WORK/builds/gpu-repro/worktree --only
   C1,C2,C3` → PASS.
3. Write the self test T-MAP (below) and run it.

**Self test T-MAP** (contract used by `port/gates/t_selftest.sh`): write `WRF/phys/module_gpu_selftest.F` (phys, so
that later self tests can USE the table modules) with an external `SUBROUTINE gpu_selftest_map(grid)`, called when the environment variable `WRF_GPU_SELFTEST=1`
right after `CALL med_initialdata_input` in `WRF/main/module_wrf_top.F:418` and after `CALL med_nest_initial` in
`WRF/frame/module_integrate.F:351` (the places of S1 and S2; the self test only reads, so it is safe to wire before
step "P1.5 + P1.9").
It walks `grid%head_statevars` (type `fieldlist`, `WRF/frame/module_domain_type.F:41-115`; pointers
`rfield_1d … rfield_4d`, `Ndim`, `VarName`), and for every allocated field calls
`omp_target_is_present(c_loc(<first element>), omp_get_default_device())`. It prints exactly one line per domain via
`wrf_message`:
```
gpu_selftest: T-MAP PASS d01 812 fields present
gpu_selftest: T-MAP FAIL d01 3 of 812 fields not present: <first names>
```
**Done when** C1–C3 pass, `bash port/gates/t_selftest.sh T-MAP` passes, `t_trace.sh W-20` still passes (without the
case data: the smoke versions, section "Without the case data").

## P1.3 Update lists: `WRF/tools/gen_gpu.c` and `WRF/frame/module_gpu_updates.F` (provided)

**This code is already written and wired** (handoff commit, see the workbook log); your task is to verify it with
NVHPC on the H100 and fix what the compiler rejects. What exists:

1. `WRF/tools/gen_gpu.c`: `int gen_gpu(char *dirname)`, called from `WRF/tools/registry.c` right after
   `gen_dealloc` (prototype in `protos.h`, object in `WRF/tools/Makefile`, source in `WRF/tools/CMakeLists.txt`).
   It walks the fields exactly as `gen_alloc2` does (`Domain.fields`, arrays and boundary arrays of kind `FIELD` or
   `FOURD`, every time level `p->ntl`, `_4d_bdy_array_`, the four boundary arrays with `bdy_indicator`, components
   of derived types) and writes into `inc/`, all inside `#ifdef WRF_GPU`:
   - `gpu_upd_dev_all.inc` / `gpu_upd_host_all.inc` (`GPU_UPD_TO` / `GPU_UPD_FROM`, by address as in P1.2): for
     every non-boundary array
     ```fortran
     IF (in_use_for_config(grid%id,'u_2')) THEN
       CALL gpu_map_r(grid%u_2, &
         SIZE(grid%u_2,KIND=8), GPU_UPD_TO)
     ENDIF
     ```
     (the same `in_use_for_config` name as `allocs.inc`; a derived-type component uses `'fdob%varobs'`), and for
     every boundary array an unguarded call for `grid%u_bxs` (… `_bxe`, `_bys`, `_bye`, `_btxs`, …):
     `allocs.inc` allocates boundary arrays unconditionally (`IF(.TRUE.)`), so they are always full size. Fields
     that are not in use are `(1,1,1)` dummies and are not moved.
   - `gpu_upd_dev_bdy.inc`: only the boundary arrays.
   - The Phase 5 lists (`gpu_upd_host_force_slab.inc`, `gpu_pack_force_strips.inc`, `gpu_upd_dev_force_full.inc`)
     are **not** written yet; they belong to P5.2 (PHASE5.md).
2. `WRF/frame/module_gpu_updates.F`: `MODULE module_gpu_updates` with `gpu_upd_dev_all(grid)`,
   `gpu_upd_host_all(grid)`, `gpu_upd_dev_bdy(grid)` (each includes its list under `#ifdef WRF_GPU`, returns at once
   for an intermediate grid, and is empty without `WRF_GPU`) and `gpu_upd_host_stream(grid, stream)`, which in
   Phases 1–4 copies the **whole state** (`gpu_upd_host_all`): correct at S3/S4, only slower than a per-stream walk
   of `grid%head_statevars` (that walk is optional, not needed for any gate). The module is in `frame/Makefile`,
   `frame/CMakeLists.txt` and `main/depend.common`, and the files that will call it in step "P1.5 + P1.9"
   (`module_integrate.o`, `mediation_integrate.o`, `mediation_force_domain.o`, `module_wrf_top.o`, `solve_em.o`)
   already depend on it there; you only add the `USE module_gpu_updates, ONLY: ...` lines and the calls.
3. Nothing calls the lists yet. The debug switch `WRF_GPU_UPD_EVERY_STEP=1` (T-UPD) is implemented with the bracket,
   in step "P1.5 + P1.9".

Checked before handoff (gfortran worktree build, no GPU): the Registry writes the three files (2579 updates in each
of the two whole-state lists, 104 in the boundary list); `check_generated.py --only C4,C5,C7` passes on them;
`module_gpu_updates.o` is compiled without optimization (`arch/noopt_exceptions*`, like `module_domain.o` and the
`module_alloc_space_N.o`: at `-O2` gfortran needed over 20 minutes for it, at `-O0` 6 s; it only moves data); `module_gpu_updates.F` compiles with and without `-DWRF_GPU` (gfortran
`-fopenmp`); the CPU view of every Fortran file is unchanged (static.sh). **Not** checked: NVHPC.

**Your steps:**

1. `bash port/h100/build.sh gpu-repro --worktree --clean` (the Registry must run again), then
   `python3 port/tools/check_generated.py $WORK/builds/gpu-repro/worktree --only C4,C5,C7` → PASS.
2. Look at `module_gpu_updates` in `compile.log`: no errors (the updates are calls of `module_gpu_map`, P1.2).
3. `bash port/gates/t_trace.sh W-20` still passes (nothing calls the lists yet).

**Done when** steps 1–3 pass. T-UPD is checked in step "P1.5 + P1.9".

## P1.4 Module tables on the device: `WRF/phys/module_gpu_tables.F` (new)

In `phys/` because it USEs the physics modules; the entry point `SUBROUTINE gpu_update_tables()` is an external
subroutine (outside the module) so that `frame/module_integrate.F` can call it. It does `!$omp target update to(...)`
of module variables declared `!$omp declare target(<names>)` in their own module, next to the declarations (an
allocatable table: `target enter data map(to:...)`).

**The Phase 1 list is fixed** (later phases add theirs: RRTMG tables after the P3.E hoist and flattening, the
fire flags after the P4.0 `set_flags` hoist). Exactly these 120 variables:

| Module (file) | Variables |
|---|---|
| `module_ra_sw` (`phys/module_ra_sw.F:6`) | `CSSCA` (set by `swinit`) |
| `sf_sfclayrev` (`phys/physics_mmm/sf_sfclayrev.F90:22`) | `psim_stab`, `psim_unstab`, `psih_stab`, `psih_unstab` |
| `module_sf_noahlsm` (`phys/module_sf_noahlsm.F:24-63`) | `LUCATS`, `BARE`, `NATURAL`, `NROTBL`, `SNUPTBL`, `RSTBL`, `RGLTBL`, `HSTBL`, `SHDTBL`, `MAXALB`, `EMISSMINTBL`, `EMISSMAXTBL`, `LAIMINTBL`, `LAIMAXTBL`, `Z0MINTBL`, `Z0MAXTBL`, `ALBEDOMINTBL`, `ALBEDOMAXTBL`, `ZTOPVTBL`, `ZBOTVTBL`, `TOPT_DATA`, `CMCMAX_DATA`, `CFACTR_DATA`, `RSMAX_DATA`, `SLCATS`, `BB`, `DRYSMC`, `F11`, `MAXSMC`, `REFSMC`, `SATPSI`, `SATDK`, `SATDW`, `WLTSMC`, `QTZ`, `SLPCATS`, `SLOPE_DATA`, `SBETA_DATA`, `FXEXP_DATA`, `CSOIL_DATA`, `SALP_DATA`, `REFDK_DATA`, `REFKDT_DATA`, `FRZK_DATA`, `ZBOT_DATA`, `SMLOW_DATA`, `SMHIGH_DATA`, `CZIL_DATA`, `LVCOEF_DATA` (not `LUTYPE`/`SLTYPE`/`iloc`/`jloc`: Phase 3 refactors) |
| `mp_wsm6` (`phys/physics_mmm/mp_wsm6.F90:46-64`) | the 64 SAVE scalars of lines 46-63 (`qc0` ... `rslopeg3max`) and `pidn0s`, `pidnc` |

(1 + 4 + 49 + 66 = 120 names; T-TAB prints how many it checked, so a missing one shows.) The species indices `P_QV` ... of `module_state_description` are **not**
uploaded: kernels copy them to local scalars (CODING_STANDARD.md §6).

Self test T-TAB (`gpu_selftest_tab`, when `WRF_GPU_SELFTEST=1`, after the upload): for each uploaded variable
compute an integer bit-sum on the host and in a kernel on the device; print
`gpu_selftest: T-TAB PASS 120 tables` or `gpu_selftest: T-TAB FAIL <names>`.

Call `gpu_update_tables()` now at the places of S1 and S2 (after `med_initialdata_input` and after
`med_nest_initial`). It only uploads, which is harmless before the bracket of step "P1.5 + P1.9" exists; that step
then adds the state uploads next to it.


**Done when** `t_selftest.sh T-TAB` passes and T-TRACE W-20 passes.

## P1.5 + P1.9 Sync points and the whole-`solve_em` bracket (one step)

**Why one step.** Through Phase 4 the model computes on the host inside `solve_em`, and the device holds a copy of the
state between steps (the copy Phase 5 will compute on). Two rules keep the two copies consistent, and each needs the
other half of this step:

1. The bracket **downloads** the whole state at the top of `solve_em` (`gpu_upd_host_all`). That is only correct if
   every change made on the host between steps was **uploaded** first: the initial state (S1), a nest start (S2), a
   boundary read (S5) and nest forcing (S6 after). Without them the download overwrites the new host values with old
   device values (e.g. the boundary data read at t = 0, or the nest boundaries written by forcing).
2. The sync points **download** before host code reads the state between steps (S2' before a nest start, S3 before
   history output, S4 before restart output, S6 before nest forcing). That is only correct if the device copy is
   current, which the bracket guarantees by **uploading** the whole state at the end of `solve_em`
   (`gpu_upd_dev_all`). Without it the downloads overwrite the current host state with stale device values.

So after this step, at every moment between two `solve_em` calls, host and device copies are equal. Wire all of it,
then test; do not commit a half.

**The bracket** (was P1.9). In `WRF/dyn_em/solve_em.F`: after `#include "bench_solve_em_init.h"` (`:276`) insert
`CALL gpu_bracket_begin(grid)`; before `END SUBROUTINE solve_em` (`:5040`, and before any `RETURN` of the routine)
`CALL gpu_bracket_end(grid)`. Implement both in `WRF/frame/module_gpu_updates.F`:

- `gpu_bracket_begin(grid)`: `CALL gpu_upd_host_all(grid)`; `gpu_world_host = .TRUE.`
- `gpu_bracket_end(grid)`: if `WRF_GPU_UPD_EVERY_STEP=1` (read once): `CALL gpu_upd_dev_all(grid)` then
  `CALL gpu_upd_host_all(grid)` — a round trip host → device → host of the whole state (T-UPD: with complete, exact
  lists nothing changes; `check_generated.py` C4 checks completeness statically); then, always,
  `CALL gpu_upd_dev_all(grid)`.

The world flag (`module_gpu_route`) stays `.TRUE.` through Phase 4: whenever a route runs (inside `solve_em`, during
init, during the S6 forcing) the host copy is current (CODING_STANDARD.md §3).

**The sync points** (was P1.5):

| # | Where (base commit) | Insert |
|---|---|---|
| S1 | `WRF/main/module_wrf_top.F:418`, after `CALL med_initialdata_input( head_grid , config_flags )` | `CALL gpu_update_tables(); CALL gpu_upd_dev_all(head_grid)`; then the self tests if `WRF_GPU_SELFTEST=1` |
| S2', S2 | `WRF/frame/module_integrate.F:351` around `CALL med_nest_initial ( grid , new_nest , config_flags )` | before: `CALL gpu_upd_host_all(grid)`; after: `CALL gpu_update_tables(); CALL gpu_upd_dev_all(new_nest); CALL gpu_upd_dev_all(grid)` |
| S3 | first executable statement of `med_hist_out` (`WRF/share/mediation_integrate.F:1190`) | `CALL gpu_upd_host_stream(grid, <history stream of this call>)` (through Phase 4 it copies the whole state: correct, only slower) |
| S4 | first executable statement of `med_restart_out` (`:1124`) | `CALL gpu_upd_host_stream(grid, RESTART_STREAM)` (whole state, as S3) |
| S5 | inside `med_latbound_in` (`:1372-1531`), right after the boundary data were read (the read branch) | `CALL gpu_upd_dev_bdy(grid)` — inside the routine, so both call sites (`:86`, `:362`) are covered |
| S6 | `WRF/frame/module_integrate.F:416` around `CALL med_nest_force ( grid_ptr , grid_ptr%nests(kid)%ptr )` | before: `gpu_upd_host_all` of both grids; after: `gpu_upd_dev_all` of both (Phase 1–4 form; P5.2 replaces it) |

All inserted calls are `CALL gpu_*` (allowed in the CPU view) and do nothing without `WRF_GPU`. If you find another
place where host code changes the state between steps (an auxiliary input read, a moving nest — not used by this
case), it needs an upload too: write it into the workbook log.

**Done when**, with the bracket and all six sync points in place:
- T-TRACE on `W-T0` passes (`bash port/gates/t_trace.sh W-T0`: from t = 0 it covers the first boundary read, the nest
  start, nest forcing every d01 step, a history write every 3 s and a restart at 9 s; the history and restart files
  are compared too);
- T-TRACE on `W-20` passes (starts from a restart: S1 after a restart read);
- T-UPD passes (`bash port/gates/t_upd.sh`).

Tick both P1.5 and P1.9 in the workbook with the same commit(s).

## P1.6 Scratch pool on the device (`WRF/frame/module_gpu_scratch.F`)

In `gpu_scratch_reserve` (`module_gpu_scratch.F:38-51`), under `#ifdef WRF_GPU`: before `DEALLOCATE(gpu_pool)` a
`!$omp target exit data map(delete: gpu_pool)`; after the host zero fill `!$omp target enter data map(alloc:
gpu_pool)` and a device zero-fill kernel (`!$omp target teams distribute parallel do` over the pool). The pointers
of `i1_assoc.inc` are associated with parts of `gpu_pool`; probe F-PRESENT (H0.3) says whether the runtime finds them
present.

Self test T-POOL (`gpu_selftest_pool`, called once from `solve_em` after `i1_assoc.inc` when
`WRF_GPU_SELFTEST=1`): `omp_target_is_present` of `gpu_pool` and of 10 i1 pointers; print
`gpu_selftest: T-POOL PASS …` / `FAIL …`. **Done when** `t_selftest.sh T-POOL` and T-TRACE W-20 pass.

## P1.7 Work arrays (a shared refactor: WORKFLOW.md §6)

**Owner decision: the work arrays are done in the phase that ports each routine** (plan.md allows it; RESULTS.md
Phase 0 deviation 6), each as a shared refactor in its own commit (t_cpu_view W-T0/W-20/W-100 + T-DRIFT PASS, then
move the base; REFACTORS.md row). Run H0.9 (T-UNINIT) once before the first of them.

In Phase 1, write only the module and its self test:
- `WRF/frame/module_gpu_work.F`: the place for named `REAL, ALLOCATABLE, TARGET` work arrays (plan.md P1.7 table),
  allocated once for the largest domain, zero-filled, and under `WRF_GPU` mapped with `enter data map(alloc:)` + a
  device zero fill; the list is empty now. Each routine of plan.md P1.7 later replaces its automatic array by a
  `POINTER, CONTIGUOUS` with the **same bounds** remapped onto its work array (`a(ims:ime,kms:kme,jms:jme) =>
  work_x(1:n)`), in **both** builds.
- Self test T-WORK (`gpu_selftest_work`): `omp_target_is_present` of every work array; with the empty list it
  prints `gpu_selftest: T-WORK PASS 0 work arrays (postponed to Phases 2-4)`.

**Done when** the module builds in both views and `t_selftest.sh T-WORK` passes (no data: the smoke self test).

## P1.8 Startup gate `WRF/share/module_gpu_check.F` (new)

`SUBROUTINE gpu_check_config(id)`: the envelope of `port/config_envelope.txt` and plan.md P1.8, the same rules as
`port/check_case.py` (read it: options equal to the reference namelist except `free:` ones; `pinned:` values;
`sr_x = sr_y` even; `e_vert-1 ≤ WRF_KMAX = 64`; RRTMG `NLAYERS = e_vert + nint(p_top_requested/400.) - 1 ≤
WRF_NLAYMAX = 128`; `numtiles = 1`; one compute rank; for fire domains after input: `nfuel_cat` in 1..204 except
204). Generate the Fortran table of reference values from `cases/eaton_20250108/namelist.input` and
`config_envelope.txt` with a small script you add under `port/tools/` (new tools are allowed; existing ones are
protected), so the two stay in sync.

Output contract (checked by `port/gates/t_gate.sh`): one line per violation
`gpu_check_config: VIOLATION <option>(d0N) = <value> (allowed: <...>)`, then `CALL wrf_error_fatal('gpu_check_config:
N violations')`; or one line `gpu_check_config: PASS`. With `WRF_GPU_CHECK_ONLY=1`, stop right after the check (call
`wrf_error_fatal('gpu_check_config: check only')` after printing PASS is fine; t_gate.sh only reads the lines).
`WRF_KMAX` and `WRF_NLAYMAX` come from `WRF/inc/gpu_col.h` (`#include "gpu_col.h"`, the same limits the Phase 3
column kernels use). Put it in `WRF/share/module_gpu_check.F` with an external entry `SUBROUTINE gpu_check_config(id)`. Call it in
`WRF/main/module_wrf_top.F` after the namelist is read (`CALL initial_config`, `:213`/`:221`) and for each nest in
`alloc_and_configure_domain` (`WRF/frame/module_domain.F:520-988`, a `CALL gpu_check_config(domain_id)` without USE).
A development override `WRF_GPU_CHECK=warn` prints the violations without stopping (never used in gates).

**Done when** `bash port/gates/t_gate.sh` passes (all 10 namelists of `port/tests/gate/`).

## P1.10 NVTX ranges

C shim `WRF/frame/wrf_gpu_shim.c` (compiled in both builds; empty without `WRF_GPU`): `wrf_nvtx_push(const char*)`,
`wrf_nvtx_pop()` with the NVTX3 header-only API (`#include <nvtx3/nvToolsExt.h>`, find it with
`x find / -name nvToolsExt.h -path '*nvtx3*'`; link `-ldl`), and `wrf_gpu_mem_info(size_t *free, size_t *total)`
using the CUDA driver API through `dlopen("libcuda.so.1")` (`cuMemGetInfo_v2`; no link-time CUDA dependency; see
`port/tests/omp_features/stack_shim.c` for the stack limit, CP-5). Fortran `BIND(C)` interfaces in
`module_gpu_route.F`. Under `WRF_GPU`, redefine `BENCH_START/BENCH_END` (`WRF/inc/bench_solve_em_def.h`) to call them.
Add the object to `WRF/frame/Makefile`. **Done when** an nsys profile of W-20 (`t_nsys.sh`) shows the named ranges.

## P1.11 Timing log

`WRF_GPU_TIMING=1`: per simulated hour and domain print `gpu_timing: d0N hour H wall_s S range <name> <s> ...`
(host timers `omp_get_wtime` around the NVTX ranges, with a device synchronization only in timing mode).

## P1.12 Memory log

Through `wrf_gpu_mem_info`: print at startup, after each domain's init, after the first step of each domain and every
simulated hour: `gpu_mem: <where> used <X> GB free <Y> GB total <Z> GB peak <P> GB` (`peak` = the largest `used` so
far). `port/gates/t_mem.sh` reads the last `peak`. **Done when** the lines appear in a W-20 run.

## G1

`bash port/gates/g1.sh` → `== G1: PASS` (static, T-GATE, self tests, T-UPD, T-TRACE W-T0 and W-20, T-CPU-VIEW, T-DEC,
G-MEM ≤ 55 GB on the full case — the full-case step runs mostly on one host core and takes long; start it early in
the background: `bash port/gates/t_mem.sh 55`). Record the table in the workbook and in `port/RESULTS.md` ("Phase 1").
