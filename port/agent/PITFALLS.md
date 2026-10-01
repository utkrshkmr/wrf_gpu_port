# Pitfalls

Everything below has either broken bit-for-bit equality in this project or is known to do so with NVHPC and OpenMP
offload. Read it once completely; come back when a test fails.

## Arithmetic

1. **FMA contraction.** `a*b+c` fused into one rounding differs from two roundings. The build flags disable it on
   host and device (`-Mnofma`, `-gpu=nofma`); T-FMA (H0.2) proves it for the pinned compiler. Never add flags, never
   use `-fast`/`-O3` variants in the GPU-port stanzas.
2. **Reassociation.** `(a+b)+c` ≠ `a+(b+c)`. Do not reorder terms, factor (`a*c+b*c` → `(a+b)*c`), distribute,
   hoist a common subexpression that changes grouping, or replace a division by a multiplication with a reciprocal.
   Copy statements verbatim. arith_guard reports new "skeletons".
   Exact rewrites exist (`a-b` ↔ `-b+a`, scaling by powers of two) but are still forbidden: the rule is "verbatim".
3. **Sums over loops.** A sum over k (`dmdt = dmdt + divv(k)`) must stay sequential in source order. A
   `reduction(+:x)` on floating point is never allowed for model values (only integers, or values used for messages).
4. **Transcendentals.** Only `rp_*` (module_repro_math) in model code: `EXP`, `LOG`, `**` with a real exponent,
   `SIN`, ... are forbidden in kernels (kernel_lint E6) and in new GPU code (arith_guard). Integer powers `x**2`,
   `x**3` stay as written. `SQRT` is correctly rounded on both sides and stays.
5. **`x**2.0`**: the rewrite made it `x**2` (integer power). Do not turn `x**2` into `x*x` or back into `rp_pow`.
6. **`MAX`/`MIN` with NaN, `SIGN` with −0.0**: host and device may differ (T-IEEE, H0.2). If T-IEEE flagged a case,
   follow its instruction in `port/ENVIRONMENT.md` (`rp_max`/`rp_min`/`rp_sign`). `flux3`/`flux5` use
   `sign(1.,ua)` where `ua` is often −0.0.
7. **Integer overflow** is undefined in Fortran; the KISS generator relies on wraparound (T-KISS, H0.4).
8. **Default REAL constants.** `4.*ATAN(1.)` is REAL(4); a kernel must not "improve" it to double.
9. **Mixed precision.** `REAL(8)` variables in a few places (`read_CAMgases`); keep kinds exactly.

## Loops and indices

10. **Ranges.** Every statement group keeps its own i/j/k range (range guards in column kernels). Staggered fields
    (`u` to `ide`, `v` to `jde`, `w`/`ph` to `kde`) have one more point; `itf=MIN(ite,ide-1)` etc.
11. **Halo writes.** Some loops write one halo ring (`calculate_full`, `WW_SPLIT`); boundary routines write
    `ids-3..ids-1`. Keep the source ranges exactly; do not clip to the interior.
12. **Order between kernels.** Consecutive loop nests often depend on each other (K-PGB-1 before K-PGB-2, x strips
    before y strips, MU-4a/4b after MU-3). One kernel per source nest, in source order.
13. **Hidden dependencies inside one nest.** A loop that reads `a(i-1)` and writes `a(i)` is a recurrence, not
    pointwise. Check every array that is both read and written in a nest, with different indices.
14. **Rolling buffers and saved scalars.** `jp1/jp0` swaps, a scalar carried from one iteration to the next
    (`dpn(k)` reused as `dpn(k+1)`), `ww(k-1)` recurrences: template B or C, never A.
15. **Early-exit searches** (`GOTO 35`, `EXIT` when found) inside a kernel: keep the same search order; if the
    search state is shared across i (`ozn_p_int`), use template R.
16. **Non-rectangular nests** cannot be collapsed; collapse only the rectangular outer loops.
17. **Loop-invariant "once before the loop" statements** (`rhs(:,1)=0.`) must be executed inside each column.

## Data and memory

18. **`default(none)`** catches missing data-sharing attributes; a scalar written in the loop but listed as
    `firstprivate` or forgotten in `private` is a race. Every scalar assigned in the loop body is `private`.
19. **Private arrays** must have fixed size (`WRF_KMAX`); a runtime-sized private array goes to the slow device heap
    and can fail when the heap is full (F-PRIVARR).
20. **Automatic arrays of a ported routine** are allocated on the host stack; if a kernel uses them, the runtime maps
    them implicitly at every launch (slow, and with `defaultmap(present)` an error). Make them work arrays (P1.7) or
    private column arrays.
21. **`grid%x` and `config_flags%x` in a kernel** are not allowed: derived types with pointer components are not
    mapped as such. Pass arrays as arguments; copy config values into scalars.
22. **Module variables** used in a kernel need `declare target` and an upload (P1.4); a module variable changed on
    the host after the upload is stale on the device (update it, or pass it as an argument).
23. **Islands move dummy arguments only.** A callee inside a ported routine that touches `grid%` or module arrays
    needs those added to the island by hand.
24. **Partly written OUT arrays.** The island copies every array to the device at entry (including INTENT(OUT)) so
    that the unwritten parts come back unchanged. Do not "optimize" the entry copy of OUT arrays away.
25. **`target update` of an unmapped array does nothing** (OpenMP semantics) — no error. If an island seems to have
    no effect, the array is not mapped (see 20).
26. **Uninitialized device memory.** `map(alloc:)` memory is not zero. The pool and work arrays are zero-filled at
    allocation on both sides (P1.6/P1.7); a new device-only array must be initialized exactly like its host
    counterpart.
27. **Assumed-size dummies (`a(*)`)** cannot be moved by name and have no bounds in device code; avoid them in kernels.
28. **Sequence association** (passing `a(ims,kms,jms,n)` to a 3D dummy) works on the host but hides the extent; pass
    sections (`a(:,:,:,n)`) in new code.

## Directives and build

29. **An apostrophe in a `!$omp` line** makes WRF's build delete the line (it strips comment lines containing `'`).
    The kernel then silently runs on the host. `-Minfo=mp` shows which loops were offloaded — check it.
30. **Directive continuation**: `&` at the end, `!$omp&` at the start of the next line. A directive broken by a
    preprocessor line (`#ifdef` between the directive and its loop) fails to compile or attaches to the wrong loop.
31. **`collapse(n)` with statements between the loops** is invalid (kernel_lint E4).
32. **`if(target: ...)` must be evaluated on the host** — use `gpu_on(R_X)` only.
33. **Statement functions and internal procedures in device code** may be rejected (F-STMTFN, F-INTPROC probes);
    the fallback is a `PURE` module function with the identical expression (template B, `TMPL_NO_STMTFN`).
34. **`STOP`, `PRINT`, `WRITE`, `wrf_error_fatal` in device code**: not allowed; error flags + host reporting.
35. **`OPTIONAL` / `PRESENT()` in device code**: hoist the test to the host (plan.md CP-4).
36. **CHARACTER arguments** in device code (Noah's `LUTYPE`): replace by integer codes (a shared refactor, both
    builds).
37. **Incremental builds** follow WRF's make dependencies; after editing a widely used module or the Registry, build
    `--clean`.
38. **Mixing builds**: CPU-REF and GPU-REPRO must come from the same source tree state; the gates build both from
    the working tree. Never compare against a stale build (check `BUILD_INFO`).

## Runs and tests

39. **Restart-vs-restart.** Windows start from the dev reference restarts; never compare a window with a
    continuous run.
40. **`OMP_TARGET_OFFLOAD=MANDATORY`** (set by window.sh for GPU runs): a failed offload is an error. Without it the
    runtime may silently run kernels on the host.
41. **NaN payloads**: the GPU produces canonical NaNs, the host propagates payloads. A NaN in a model field is a bug
    anyway; the tracer will show different hashes.
42. **Test the right thing**: T-AB compares the GPU view on the device with the GPU view on the host; it cannot find
    a restructuring mistake. T-TRACE (GPU vs CPU-REF) finds those. Both must pass.
43. **A TIMEOUT is a finding, not noise.** `window.sh` stops a run after `RUN_TIMEOUT` and writes `TIMEOUT` in
    `window.info` (`harness.sh`: `HARNESS_TIMEOUT`). First compare with the wall time of the same window with the
    previous build (`window.info`). If that build took far less, the new code hangs: a device loop that never ends,
    e.g. a `DO WHILE` on unphysical data. Find it with the call check or `t_fine.sh`. Only a run that is merely slow
    (a bigger window, a busy machine) is rerun with a larger `RUN_TIMEOUT`.

## Preprocessor and language

44. **`/*` in a Fortran comment** (`! see physics_mmm/*.F90`) opens a C comment for cpp, and the file fails with
    "unterminated comment". Never write `/*` or `*/` in a `.F`/`.F90` file. Apostrophes in comment lines are
    removed by WRF's sed step (BUILD_SYSTEM.md §3).
45. **Never name a `grid` field in an OpenMP clause** (`map(to: grid%u_2)`, `target update to(grid%u_2)`): it is
    a structure-member map, which gfortran rejects for types with allocatable components and compilers treat
    differently. Whole-state moves call `module_gpu_map` (P1.2/P1.3). Inside a routine the field is an
    explicit-shape dummy, and the islands and kernels name that.
46. **Operator precedence in host checks**: `.OR.` binds tighter than `.EQV.`/`.NEQV.`, so
    `a .NEQV. b .OR. c .NEQV. d` is not two comparisons joined by `.OR.`. Parenthesize every logical expression
    that mixes them.
