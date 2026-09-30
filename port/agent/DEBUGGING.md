# Debugging a mismatch

From "FAIL" to the statement that is wrong. Work top-down; write what you find into the workbook log as you go.

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

Level-2 traces cover every checkpoint of every step; if you need more (inside a routine), use the GPU-DEBUG build:
`WRF_GPU_TRACE_FINE` adds checkpoints you place with `CALL bt_checkpoint(grid, '<tag>', 2, rk_step)` in
`#ifdef WRF_GPU_TRACE_FINE` blocks (they compile only in GPU-DEBUG and do not change results).

## 2. Narrow it to one route

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
| GPU-DEBUG build (`build.sh gpu-debug --worktree`) | `-g -traceback -gpu=lineinfo`; line numbers in sanitizer reports |
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
