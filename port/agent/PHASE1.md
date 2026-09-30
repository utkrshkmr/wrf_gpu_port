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
`Makefile` (module list) and to `WRF/main/depend.common` (who depends on it), as Phase 0 did for
`module_gpu_route.o` (`frame/Makefile:21-23`, `depend.common:215-223`). Build with `--clean` after adding files.

---

## §0. Entry tasks H0 (the H100 machine)

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
(table "Compiler feature probes"): F-IFTARGET, F-PRESENT and F-DECLMOD must pass (else BLOCKERS.md: the fallbacks of
plan.md P0.5b need the owner's decision). Record: whether to use `defaultmap(present: aggregate)` (F-DEFMAP), whether
statement functions/internal procedures work in device code (F-STMTFN, F-INTPROC), the stack-limit mechanism
(F-STACK).

### H0.4 Reference tests on the GPU
`bash port/gates/ref_tests.sh` → `== ref_tests: PASS` (T-PDLIM, T-KISS, T-OZN, templates B/C/G and their mutants).
If T-KISS fails, the KISS rewrite of plan.md P0.9a item 9 becomes a Phase 3 shared refactor; note it.

### H0.5 CPU-REF builds and T-SYM
```sh
bash port/h100/build.sh cpu-ref --commit "$(sed 's/#.*//' port/agent/cpu_view_base | awk 'NF{print $1;exit}')"
bash port/h100/build.sh cpu-ref --worktree
source port/h100/common.sh; x bash port/sym_audit.sh $WORK/builds/cpu-ref/worktree
```
**Done when** both builds exist (BUILD_INFO) and T-SYM passes on the host objects (the device part of T-SYM runs on
GPU builds in P1.1). Record the build time.

### H0.6 Inputs and dev case
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
bash port/gates/static.sh
```
**Done when** all three print PASS. Record the wall times of W-T0/W-20 (CPU-REF) in the log.

---

**Order of work in Phase 1:** P1.1, P1.2, P1.3, P1.4, P1.6, then **P1.5 and P1.9 together as one step**, then P1.7,
P1.8, P1.10–P1.12. P1.5 (sync points) and P1.9 (the `solve_em` bracket) cannot be done one after the other; see the
section "P1.5 + P1.9" for why.

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

## P1.2 Device residency of all state (`WRF/tools/gen_allocs.c`)

The Registry generator writes `inc/allocs.inc` / `inc/deallocs.inc` (`WRF/tools/registry.c:244-246` calls
`gen_alloc`, `gen_dealloc`). Change `gen_alloc2` (`WRF/tools/gen_allocs.c:80-497`) and `gen_dealloc2` (`:604-690`):

1. In-use branch: at the end of the `THEN` part, immediately **before** `fprintf(fp,"ELSE\n") ;` (`:465`), emit for
   the array (boundary arrays: for each `bdy = 1..4` with `bdy_indicator(bdy)`, as the ALLOCATE above does), only when
   `sw == 1`:
   ```c
   fprintf(fp,"#ifdef WRF_GPU\n  IF (.NOT. grid%%is_intermediate) THEN\n"
              "!$omp target enter data map(to:%s%s%s)\n  ENDIF\n#endif\n", structname, fname, bdy_indicator(bdy));
   ```
   (non-boundary arrays: the same without `bdy_indicator`). This is after the initial value (`:287-297`) and after
   the statevars list code.
2. Not-in-use branch: after the dummy `ALLOCATE(...(1,1,1))` `fprintf`s (`:467-480`), **before**
   `fprintf(fp,"ENDIF\n") ;` (`:482`), the same enter-data lines for the dummies.
3. `gen_dealloc2`: before each `DEALLOCATE` `fprintf` (`:637-639` boundary, `:659-661` others), inside the same
   `IF ( ASSOCIATED / ALLOCATED ...)`, emit
   `#ifdef WRF_GPU\n  IF (.NOT. grid%%is_intermediate) THEN\n!$omp target exit data map(delete:%s%s%s)\n  ENDIF\n#endif\n`.
4. Rebuild **clean** (`build.sh gpu-repro --worktree --clean`) and run
   `python3 port/tools/check_generated.py $WORK/builds/gpu-repro/worktree --only C1,C2,C3`.

Intermediate grids (allocated every parent step for nest forcing) stay on the host because of the guard.

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
**Done when** C1–C3 pass, `bash port/gates/t_selftest.sh T-MAP` passes, `t_trace.sh W-20` still passes.

## P1.3 Update lists: `WRF/tools/gen_gpu.c` (new) and `gpu_upd_host_stream`

1. New file `WRF/tools/gen_gpu.c` with `int gen_gpu(char *dirname)`, called from `registry.c` after `gen_dealloc`
   (`:246`); add it to `WRF/tools/Makefile` (object list and dependencies, like `gen_allocs.o`). Walk the fields as
   `gen_alloc2` does (`Domain.fields`, the 4D members, `p->ntl` time levels, boundary arrays with `bdy_indicator`)
   and write into `inc/`:
   - `gpu_upd_dev_all.inc` / `gpu_upd_host_all.inc`: for every field that `allocs.inc` allocates (same names, same
     `in_use_for_config(id,'<name>')` test with `grid%id`), a block
     ```fortran
     IF (in_use_for_config(grid%id,'u_2')) THEN
     !$omp target update to(grid%u_2)
     ENDIF
     ```
     (`from` for the host version). Boundary arrays: every `_bxs … _btye`. Fields allocated as `(1,1,1)` dummies need
     no update.
   - `gpu_upd_dev_bdy.inc`: only the boundary arrays.
   - (Phase 5, may be written now) `gpu_upd_host_force_slab.inc`, `gpu_pack_force_strips.inc`,
     `gpu_upd_dev_force_full.inc` as plan.md P1.3 describes.
2. New module `WRF/frame/module_gpu_updates.F` (port infrastructure; frame because `module_integrate.F` calls it) with `SUBROUTINE gpu_upd_dev_all(grid)`,
   `gpu_upd_host_all(grid)`, `gpu_upd_dev_bdy(grid)` that `#include` the lists under `#ifdef WRF_GPU` (empty
   otherwise), plus `gpu_upd_host_stream(grid, stream)`: walk `grid%head_statevars` and `target update from` every
   field whose `streams` mask contains the stream (history: `streams(HISTORY_STREAM)`-style bit test as
   `module_io_domain` uses; restart: the `restart` flag). A 4D array: update the whole array if any member is on the
   stream. Add the module to `WRF/frame/Makefile` and its dependencies to `WRF/main/depend.common`.
3. The debug switch `WRF_GPU_UPD_EVERY_STEP=1` (T-UPD) is implemented with the bracket, in step "P1.5 + P1.9".

**Done when** `check_generated.py … --only C4,C5,C7` passes and T-TRACE W-20 still passes (nothing calls the lists
yet). T-UPD is checked in step "P1.5 + P1.9".

## P1.4 Module tables on the device: `WRF/phys/module_gpu_tables.F` (new)

In `phys/` because it USEs the physics modules; the entry point `SUBROUTINE gpu_update_tables()` is an external
subroutine (outside the module) so that `frame/module_integrate.F` can call it. It does `!$omp target update to(...)` (allocatables: `target enter data map(to:...)`) for
the module data of plan.md P1.4 (table there; add `!$omp declare target(<names>)` in each module next to the
declarations). Modules whose data are set only in later phases (RRTMG tables after the P3 hoist) are added in those
phases; for Phase 1 at least: `module_state_description` species indices used by kernels (or pass them as scalars),
`module_ra_sw` tables, `sf_sfclayrev` psi tables, `module_sf_noahlsm` parameters, `mp_wsm6` SAVE scalars,
`module_fr_fire_util` flags (after the set_flags hoist of P4.0, else skip now).

Call `gpu_update_tables()` now at the places of S1 and S2 (after `med_initialdata_input` and after
`med_nest_initial`). It only uploads, which is harmless before the bracket of step "P1.5 + P1.9" exists; that step
then adds the state uploads next to it.

Self test T-TAB (`gpu_selftest_tab`, when `WRF_GPU_SELFTEST=1`, after the upload): for each uploaded table compute
an integer bit-sum on the host and in a kernel on the device; print
`gpu_selftest: T-TAB PASS 17 tables` or `gpu_selftest: T-TAB FAIL <table names>`.

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
| S3 | first executable statement of `med_hist_out` (`WRF/share/mediation_integrate.F:1190`) | `CALL gpu_upd_host_stream(grid, <history stream of this call>)` (in Phase 1 it may simply call `gpu_upd_host_all(grid)`: correct, only slower) |
| S4 | first executable statement of `med_restart_out` (`:1124`) | `CALL gpu_upd_host_stream(grid, RESTART_STREAM)` (or `gpu_upd_host_all(grid)`) |
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

New module `WRF/frame/module_gpu_work.F`: named `REAL, ALLOCATABLE, TARGET` arrays for the large automatic arrays of
plan.md P1.7 (table there), allocated once for the largest domain, zero-filled, and (under `WRF_GPU`) mapped with
`enter data map(alloc:)` + device zero fill. In each routine of the table, replace the automatic array by a
`POINTER, CONTIGUOUS` with the **same bounds** remapped onto the work array (`a(ims:ime,kms:kme,jms:jme) =>
work_x(1:n)`), in **both** builds (the refactor is shared: CPU-REF must run the same code). Do this routine by
routine as each routine is ported in Phases 2–4 if you prefer (plan.md allows it; RESULTS.md deviation 6), but each
change follows the shared-refactor protocol (t_cpu_view W-T0/W-20/W-100 + T-DRIFT PASS, then move the base).

Self test T-WORK: as T-POOL for the work arrays (`gpu_selftest: T-WORK PASS …`). **Done when** the protocol's tests
pass, the base is moved (REFACTORS.md row), and `t_selftest.sh T-WORK` passes.

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
Put it in `WRF/share/module_gpu_check.F` with an external entry `SUBROUTINE gpu_check_config(id)`. Call it in
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

`bash port/gates/g1.sh` → `== G1: PASS` (static, T-GATE, self tests, T-UPD, T-TRACE W-T0 and W-20, T-CPU-VIEW,
G-MEM ≤ 55 GB on the full case — the full-case step runs mostly on one host core and takes long; start it early in
the background: `bash port/gates/t_mem.sh 55`). Record the table in the workbook and in `port/RESULTS.md` ("Phase 1").
