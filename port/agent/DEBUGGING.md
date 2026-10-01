# Debugging a mismatch

From "FAIL" to the statement that is wrong. Work top-down; write what you find into the workbook log as you go.

## 0. Fast checks (before and between the W-20 runs)

A W-20 run takes 10-20 minutes while most of the model still runs on one host core. Check one routine in about a
minute first:

```sh
bash port/h100/compile_one.sh gpu-repro WRF/dyn_em/module_big_step_utilities_em.F --minfo   # compiles? offloaded?
bash port/h100/harness.sh WRF/dyn_em/module_big_step_utilities_em.F calc_ww_cp              # bits equal?
```

`harness.sh` compiles the working-tree file against the existing `cpu-ref` and `gpu-repro` worktree builds (only
this file; the builds are not changed). A generated driver (`gen_harness.py`) then calls the routine once, on
pseudo-random inputs built from random bits, and writes its outputs. The comparisons, bit for bit (`harness_diff.py`):

- `HOST vs DEVICE`: GPU build, route off vs on. This is what T-AB checks: races, missing `private`, a missing island
  entry, uninitialized device data.
- `CPU vs DEVICE`: CPU-REF build (the CPU view of the file) vs GPU build. This is what T-TRACE checks: wrong range,
  reordered statement, a branch you did not port.

`DIFFERENT: n of N values, first at (i,k,j)` names the output and the first index.

Know the limits:
- The driver sets config_flags from the dev-case namelist and the WRF dimensions to one tile of 40×36×20 with a
  halo of 5 (`--grid`).
- Other scalars get defaults, printed as `harness default: ...`. Set the ones that choose a code path with
  `--set name=value`, e.g. `--set rk_step=3`, and run again for each path you ported.
- Random values are positive 0.5..4 (winds, fluxes, tendencies: ±4). Use `--range name=lo:hi` when a routine needs
  physical values.
- Module arrays the routine reads without arguments hold whatever the library holds.
- `TYPE(domain)` dummies are not supported: use T-AB for driver routines.

A PASS is a fast pre-check, not the acceptance test. The routine is done only after `t_ab.sh` and `t_trace.sh` on
W-20. A FAIL is always real: fix it before spending a W-20 run.

If `gen_harness.py` cannot handle a declaration, fix it as a tool fix (WORKFLOW.md §8). It is in `port/h100/`,
infrastructure.

The harness gives no physical inputs and initializes no physics tables. For the physics schemes (Phase 3: WSM6,
YSU, Noah, RRTMG, ...) it is of little use; it may even loop forever, which `HARNESS_TIMEOUT` (default 600 s)
stops. Use the call check (§0b) for physics.

## 0b. Call check: one routine, real data, inside the model

Every island carries a call check (`port/tools/gen_island.py`, `WRF/frame/module_gpu_callcheck.F`).

How a checked call runs:
1. The routine runs on the device. Its results are kept, and every argument it may change is restored to its input
   value: arrays and scalars that are not `INTENT(IN)`.
2. The routine runs again with every route on the host, as CPU-REF would.
3. Each argument is compared bit for bit with the device result.

```sh
b=$WORK/builds/gpu-repro/worktree
rd=$(bash port/h100/window.sh $b S-3M WRF_GPU_CALLCHECK=wsm6:3 | tail -1)    # first 3 calls; smoke case, ~2 min
grep gpu_callcheck: $rd/rsl.error.0000
```
```
gpu_callcheck: wsm6 call 1: DIFF qr(17,12,9) host 1.23456789E-004 (Z3901770D) device 1.23456804E-004 (Z3901770E), 3 of 98400 values differ
gpu_callcheck: wsm6 call 1: FAIL (1 of 9 arguments differ)
gpu_callcheck: wsm6 call 2: PASS (9 arrays, 0 scalars bit-identical)
```

Options:
- `WRF_GPU_CALLCHECK=<route>[:<n>|:all]` checks the first n calls (default 1). Any window works. `S-3M` needs no
  case data and has the full physics suite on one domain; W-20 covers both domains and the d02 LES routes.
- `WRF_GPU_CALLCHECK_STOP=1` stops the run after the last check.

What a result tells you:
- `DIFF <array>(i,k,j)` names the first differing element, in the bounds of the dummy argument. A difference with
  identical inputs is the kernel's own: a race, a missing `private`, a wrong range, a reordered statement, or data
  the island does not move.
- A PASS of every checked call does not replace T-AB and T-TRACE (other calls, both domains, whole steps), but a FAIL
  is always real.

Limits:
- Host world only: Phases 1–4.
- Routines with a `TYPE(domain)` dummy get no call check: use `t_ab.sh` and `t_fine.sh` for them.
- Arrays the routine changes that are not arguments (module arrays) are not restored. Add them to the island and to
  the check by hand: one `gpu_cc_save_*` call at entry, one `gpu_cc_done_*` call at exit.

## 1. Read the comparison

`port/h100/compare.sh A B` (called by every gate) prints, from `port/bittrace_diff.py`:

```
FIRST DIFFERENCE: itimestep 10 rk_stage 2 tag calc_p_rho_phi field LFN
1 differing records; first difference per field:
  LFN   itimestep 10 rk 2 tag calc_p_rho_phi
```

- `itimestep`, `rk_stage`: when. The first step of a window is `itimestep` of the restart + 1.
- `tag`: the checkpoint where the difference was first seen. Checkpoints are placed after the steps of plan.md §7.1
  (`port/RESULTS.md` and `WRF/frame/module_bittrace.F` list them; `grep -n "bt_checkpoint" WRF/dyn_em/solve_em.F`).
  The routine that caused the difference ran **between the previous tag and this tag** of the same domain.
- `field`: the first field that differs. The routine that writes it is the suspect.
- If only history/restart files differ but traces do not: the difference is in output-only diagnostics or in the
  sync points (P1.5, S3/S4).

Level-2 traces have about ten checkpoints per step. To get closer, use fine tracing (next section).

## 1b. Fine tracing: which routine, which kernel

Build both sides with `--fine` and compare level-3 traces. `-DWRF_TRACE_FINE` is only a preprocessor macro; the
arithmetic flags do not change (`check_build_flags.py` checks the builds), and the CPU-REF and GPU builds get the same
checkpoints:

```sh
bash port/gates/t_fine.sh W-20 WRF_BITTRACE_FROM=<step> WRF_BITTRACE_TO=<step> WRF_BITTRACE_DOMAIN=<d>
bash port/gates/t_fine.sh --ab <route> W-20 WRF_BITTRACE_FROM=<step> ...     # a T-AB failure: route off vs on
```

Take `<step>` and `<d>` from the coarse comparison (FIRST DIFFERENCE line, trace file `bittrace.d0<d>.txt`). A
one-step, one-domain fine run is fast; a full fine W-20 is slow. At level 3 you get:

- a checkpoint after **every routine** that `solve_em` calls (tag = routine names, e.g. `rk_tendency`,
  `advance_uv`, `small_step_prep+calc_p_rho+calc_coef_w`). Each one hashes the level-2 fields, the intermediate
  dynamics fields (`WW`, `ALT`, `PHP`, `MUTS`, `RU_M`, …), the turbulence fields (`DEFOR*`, `XK*`) and the scratch
  arrays of solve_em (`RW_TEND`, `T_TENDF`, `CQW`, `ALPHA`, `GAMMA`, `MOIST_TEND*`, …);
- a checkpoint after every routine that `first_rk_step_part1/2` call (tags `p1:radiation_driver`,
  `p2:cal_deform_and_div`, …), with their tendencies and `*_PHY` arrays;
- a checkpoint after every routine that `rk_tendency` calls (tags `rkt:advect_u`, `rkt:horizontal_pressure_gradient`,
  …), with the tendencies.

The first differing record names the routine after which the runs first differ, and the field. Then, **inside that
routine**, add checkpoints after each kernel (or group of kernels) and run again:

```fortran
#ifdef WRF_TRACE_FINE
      CALL bt_fine3('advect_u:Y2', 'TENDENCY', tendency, 'X', ids, ide, jds, jde, kds, kde, &
                    ims, ime, jms, jme, kms, kme, its, ite, jts, jte, kts, kte)
#endif
```

- `bt_fine3` for `(ims:ime,kms:kme,jms:jme)` arrays; stag `'X'`, `'Y'`, `'Z'`, `'XZ'`, … or `'-'`. `bt_fine2` for
  `(ims:ime,jms:jme)`. `bt_finef` for fire-grid arrays `(ifms:ifme,jfms:jfme)` with the fire dims.
- `USE module_bittrace, ONLY : bt_fine2, bt_fine3, bt_finef` inside the same `#ifdef WRF_TRACE_FINE`.
- Put the call where the same state exists in both views: **after** the kernel(s) that replace one source loop nest,
  never between Y1 and Y2 of a split. If that point is inside an `#ifdef WRF_GPU … #else … #endif`, put the call in
  both branches with the same tag and name.
- The routine may run on the device when the checkpoint is reached. `bt_fine*` then copies the array from the device
  first (`gpu_world_host` is `.FALSE.` inside a device-run routine). Trace dummies, pool and work arrays, and
  whole-array or last-index slices (`moist(:,:,:,n)`). Do not trace a kernel's private column arrays.
- These lines are allowed in the CPU view (`CALL bt_*`, under a GPU-port macro). You may keep them in the commit;
  they cost nothing in normal builds.

The same set of checkpoints in both runs is required. If one run has records the other lacks, the comparison
reports "records only in A/B": rebuild both with the same tree.

Filters (environment, both runs identical): `WRF_BITTRACE_FROM`, `WRF_BITTRACE_TO`, `WRF_BITTRACE_DOMAIN`,
`WRF_BITTRACE_FIELDS=U_2,RU_TEND` (names as in the trace).

## 2. Narrow it to one route, then one kernel

```sh
bash port/gates/t_ab.sh <suspect route> W-20      # device vs host of the same code
bash port/h100/window.sh <gpu build> W-20 WRF_GPU_OFF=<route>        # then compare with the CPU-REF run
bash port/h100/window.sh <gpu build> W-20 WRF_GPU_ONLY=<route>       # only this route on the device
```

- T-AB fails → device execution differs from host execution of the **same** code: race (missing `private`, two
  iterations writing one element), uninitialized device data, missing island entry, FMA or a math function
  outside `rp_*`, a module variable not uploaded.
- T-AB passes but T-TRACE fails → the GPU-view code differs from the CPU code (a restructuring mistake): wrong
  range, missing range guard, wrong order, a statement changed, something only in the CPU path (e.g. an
  `IF` branch you did not port).
- Bisect routes: `WRF_GPU_OFF=all` must equal CPU-REF (if not, the problem is in the islands/sync points/Phase 1);
  then switch routes back on in halves with `WRF_GPU_OFF=a,b,c`.
- **One kernel on the host** (to confirm the suspect found with fine tracing):
  ```sh
  python3 port/tools/kernel_off.py --list WRF/dyn_em/module_advect_em.F advect_u   # numbers, IDs, lines
  python3 port/tools/kernel_off.py WRF/dyn_em/module_advect_em.F K-ADVU-X           # or advect_u:3
  bash port/h100/build.sh gpu-repro --worktree --tag koff
  bash port/h100/window.sh $WORK/builds/gpu-repro/worktree-koff W-20                  # compare with the CPU-REF run
  python3 port/tools/kernel_off.py --revert WRF/dyn_em/module_advect_em.F
  ```
  The kernel then runs on the host over host data, with its `shared(...)` arrays copied from the device before and
  back after. If the mismatch disappears (or moves later), that kernel is wrong. The edit is marked `KOFF-TEMP`;
  `static.sh` fails until you revert it, so it cannot be committed.

## 3. Inspect the kernel

Compare the kernel with its CPU lines (`KERNEL_REFS.md`) side by side, statement by statement:

- same statements, same order, same operand order;
- every loop range identical to the source (staggered ends, `itf/jtf/ktf`, halo rings);
- every scalar written in the body is `private`; nothing written is `shared` unless each iteration writes its own
  element;
- statement groups with different ranges have range guards;
- "once before the loop" initializations inside the column;
- for templates B/L/R: the reference test in `port/tests` passes, and your kernel matches its structure;
- the island lists every array the routine touches (dummies, plus non-dummies by hand).

## 4. Tools

| Tool | Use |
|---|---|
| `-Minfo=mp` lines in `compile.log` | was the loop offloaded? parallelized over teams and threads? any "loop carried dependence" message? |
| `NVCOMPILER_ACC_NOTIFY=3` (env; NVHPC's offload runtime; if it prints nothing for OpenMP in your version, use nsys) | prints every kernel launch and data transfer; look for unexpected uploads/downloads |
| `RUN_WRAPPER="compute-sanitizer --tool memcheck"` | out-of-bounds and misaligned device accesses (GPU-DEBUG build) |
| `RUN_WRAPPER="compute-sanitizer --tool racecheck"` / `initcheck` | shared-memory races, reads of uninitialized device memory |
| `port/gates/t_nsys.sh W-20` | every host↔device copy with size: finds implicit copies of unmapped arrays |
| GPU-DEBUG build (`build.sh gpu-debug --worktree`) | `-g -traceback -gpu=lineinfo`, `WRF_TRACE_FINE`; line numbers in sanitizer reports |
| `build.sh <mode> --worktree --fine`, `port/gates/t_fine.sh` | level-3 checkpoints after every routine, and your `bt_fine*` calls inside routines (§1b) |
| `port/tools/kernel_off.py` | one kernel on the host, temporarily (§2) |
| `port/h100/harness.sh`, `port/h100/compile_one.sh` | one routine / one file in seconds to a minute (§0, BUILD_SYSTEM.md) |
| `python3 port/compare_fields.py A/wrfout... B/wrfout... --all` | which history fields differ and by how much (the size of the difference hints at the cause: 1 ulp → rounding/FMA/order; large → wrong index/stale data) |

Pass `RUN_WRAPPER` and other variables through `window.sh`: `RUN_WRAPPER="compute-sanitizer --tool memcheck"
bash port/h100/window.sh <build> W-20 --tag memcheck` (the wrapper goes between `mpirun -np 1` and `wrf.exe`).

## 5. Typical causes, by symptom

| Symptom | Likely cause |
|---|---|
| differs in the first step at the first tag after a newly ported routine, many fields | island missing or incomplete; kernel not offloaded but data on the device |
| differs by 1 ulp in a few points | operation order changed, FMA, a non-`rp_*` function, `MAX(0.,NaN)` or `SIGN(-0.)` (T-IEEE) |
| differs only on boundary rows/columns | range of an edge loop, missing strip kernel, x/y strip order, halo ring not written |
| differs only at the first k level or the top | `k=kts`/`kte` special cases, "once before the loop" statement not in the column |
| T-AB differs randomly between runs | race: a shared scalar, two iterations writing the same element, missing kernel ordering |
| crash `illegal address` / `partially present` | array not mapped, pointer not associated with the pool, wrong bounds on a work array |
| runs, but much slower than expected | implicit copies of unmapped arrays at each launch (T-NSYS), island around a hot routine in the host world (expected until Phase 5) |

## 6. When to stop

Three honest attempts per failure mode (each a real hypothesis tested with a tool above). Then: BLOCKERS.md entry
(command, output, what you tried), kernel `blocked` in kernels.csv, workbook log, and continue with an independent
task. Never leave a route switched off to make a gate pass.
