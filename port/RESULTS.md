# Results log of the GPU port

One section per gate. Every entry names the binary (git sha, `BUILD_INFO`), the image (`ENVIRONMENT.md`) and the
case manifest it was obtained with.

## Phase 0 (gate G0)

### G0 checklist

"Local" means checked in the development container of this repository (gfortran 13, no NVHPC, no GPU; see
`ENVIRONMENT.md`). The rows marked **CCR** or **GPU node** are still to be run with the scripts of `port/ccr/` and
`port/tests/` (runbook in `port/README.md`).

| Item | Plan step | Status |
|---|---|---|
| Container image built, digest recorded | P0.0 | to do (CCR): `port/container/wrf-gpu.def` written |
| Original CCR build identified | P0.2 | to do (CCR): `port/ccr/identify_build.sh` |
| Input manifest | P0.3 | `cases/eaton_20250108/manifest.md5` written (3 inputs + 9 tables); check on CCR with `manifest.py check` |
| Configure stanzas | P0.4 | done; `./configure` lists them as options 84–89; build on CCR |
| `T-FMA`, `T-SIGNZERO`, `T-MINMAX`, `T-SUBNORM`, `T-RM-EXH`, `T-RM-POW`, `T-RM-D` | P0.5 | GPU node: `port/tests/repro_math/run_tests.sh` (compiled and run host-only locally) |
| `T-RM-ACC` | P0.5 | local, host: pass (below); repeat in the image on the GPU nodes |
| `T-OMP-FEAT` | P0.5b | GPU node: `port/tests/omp_features/run_probes.sh` |
| `T-IPOW` | P0.6 | exponents found (below); host vs device test `t_ipow` on the GPU node |
| `T-SYM` | P0.6 | CCR / GPU node: `port/sym_audit.sh` |
| `T-SHARED-*` | P0.9a | local (gfortran): T-SHARED-1 and T-SHARED-POOL pass bitwise on both smoke cases (below); on CCR: `port/ccr/t_shared.sh` |
| `T-UNINIT` | P0.9a | local physics smoke case passes; dev case on CCR: `port/ccr/t_uninit.sh` |
| `T-DET`, `T-DEC-A`, `T-DEC-B`, `T-RST`, `T-XM` | P0.10 | to do (CCR, GPU-node host) |
| Reference runs archived (full case, dev case) | P0.11, P0.16 | to do (CCR) |
| E0, E1 | P0.13, P0.14 | to do (CCR) |
| Prof-CPU | P0.15 | to do (CCR): `port/ccr/prof_run.sh` |
| Memory estimator validated | P0.15 | local: within 3.5 % of WRF's own count on two smoke cases; repeat on the full case (CCR) |

### Local results

#### Reproducible math (`WRF/frame/module_repro_math.F`), host, gfortran 13

`python3 port/tests/repro_math/test_accuracy.py --exhaustive` and `--quick`:

| Test | Result |
|---|---|
| REAL(4) exp, log, log10, sin, cos, tan, asin, acos, atan, sinh, cosh, tanh: **all 2³² inputs each** | 0 results not correctly rounded; 0 non-canonical NaNs |
| REAL(4) atan2, 2·10⁶ samples | 0 not correctly rounded |
| REAL(4) pow, 4.8·10⁶ samples on the WRF exponents + 2.5·10⁶ random pairs | 0 not correctly rounded |
| REAL(8) exp, log, sin, cos, tan, asin, acos, atan, atan2, pow (6·10⁵ samples each) | ≤ 1 ulp |
| REAL(8) log10, sinh, cosh, tanh | ≤ 2.05 ulp (worst: cosh 2.046, tanh 2.049, log10 1.78, sinh 1.73); fdlibm's accuracy for these, see "Deviations" |
| `rp_mod` REAL(4), REAL(8) | bit-exact against C `fmod` (4·10⁶ and 4·10⁵ samples) |
| Special values (±0, ±Inf, NaN, subnormals, domain edges) | C99 results, canonical NaN |

The host-vs-device programs (`t_fma`, `t_ieee`, `t_ipow`, `t_rm_exh`, `t_rm_pow`, `t_rm_d`) compile with gfortran and
run in host mode (`ALLOW_HOST=1`); their device half needs the GPU node.

#### Substitutions (P0.6)

`port/rp_subst.py` over the 49 files of `port/rp_subst_files.txt`: 38 files changed, 646 intrinsic calls and 265
powers rewritten to `rp_*`; 35 powers with the literal exponent `2.` / `2.0` written as `**2`; 62 powers with a
constant exponent (named constants) kept as written; 6 statements rewritten by hand (continued lines); 6 "refused"
reports, all of them the array `gamma` in `module_small_step_em.F`, not the intrinsic (unchanged). `--check` on the
result: nothing left to rewrite.

`port/ipow_scan.py`: integer-literal exponents left in the rewritten files are 2, 3, 4, 8 and 32; `t_ipow` tests
exactly these, and integer-variable exponents from −8 to 32 through `rp_pow`.

#### Compiler feature probes, gfortran 13 host fallback (compile check only)

All probes compile except `f_present` and `f_defmap` (gfortran 13 has no `present` map-type modifier), which is
expected. The results that matter come from nvfortran on the GPU nodes.

#### WRF regression (T-SHARED), gfortran 13, serial, em_fire

Two smoke cases built from `test/em_fire`, both with the Eaton fire options (`fire_upwinding = 9`, level-set
re-initialization, z-coupling, atmosphere feedback) and WSM6:

- **fire:** the em_fire case, 6 simulated minutes (720 steps);
- **physics:** the Eaton physics suite on top (RRTMG LW with `o3input = 2`, `ghg_input = 1`, Dudhia SW, sfclayrev,
  Noah, YSU, `km_opt = 4`), 3 simulated minutes (360 steps, radiation every 30 s).

Each run compares all fields of all history frames with `port/compare_fields.py --bitwise`.

Builds (all from this repository's commits, gfortran `-O2 -ftree-vectorize -funroll-loops`, REPRO_MATH off unless
stated; all except nan/zero with `-nostdinc -fintrinsic-modules-path <gfortran finclude>` so that no loop calls
glibc's vector math, see "Deviations" 9):

| Build | Source |
|---|---|
| up | unmodified WRF v4.6.0 |
| mod | this commit, no pool |
| up+infra | v4.6.0 physics and dynamics, plus all Phase 0 infrastructure (tracer, routing, pool module, `solve_em.F`, `module_wrf_top.F`, generated i1 files) |
| pool | mod with `-DWRF_POOL` |
| repro | pool with `-DREPRO_MATH` (the CPU-REF configuration, gfortran instead of nvfortran) |
| nan / zero | this commit, default flags plus `-finit-real=snan …` / `-finit-real=zero …` |

Physics case (3 simulated minutes, 360 steps, radiation every 30 s, ignition at 120 s), and fire case (6 simulated
minutes, 720 steps, no PBL/surface/radiation schemes):

| Test | Comparison | Result |
|---|---|---|
| **T-SHARED-1**, physics case | up vs mod | **identical**: 241 history fields in 7 frames, 189,000 level-2 trace records over 360 steps (vs up+infra), identical fire spread |
| **T-SHARED-1**, fire case | up vs mod | **identical**: 224 history fields in 7 frames; fire: the same 3,444 burned cells at 6 min, 0 differing cells in every frame |
| Infrastructure is neutral | up vs up+infra | **identical** (241 history fields, 7 frames) |
| Tracer only reads | mod with vs without `WRF_BITTRACE=2` | **identical** |
| **T-SHARED-POOL** | mod vs pool | **identical**: 189,000 level-2 trace records, 241 history fields |
| **T-UNINIT** | nan vs zero | **identical** (189,000 trace records, 241 history fields): no uninitialized local or automatic array is read (run at commit 9c4c126; the fix below only changes how 62 powers are written, not which memory is read) |
| Determinism of REPRO_MATH | repro vs repro (two runs) | **identical** (run at commit 9c4c126) |

**How T-SHARED-1 was brought to bitwise.** The first comparison differed everywhere. Three causes were found and fixed:

1. Vector math in the comparison builds (see "Deviations" 9): fixed by building both without glibc's vector
   variants. After that the runs agreed for 183 steps.
2. The remaining difference started at step 184 in `RVBLTEN`. The tracer localized it (up+infra vs mod), and a
   bisection over files, then over the 25 rewrite hunks of `physics_mmm/bl_ysu.F90`, found one statement:
   `xkzm = … zfac(i,k)**pfac …` with `real, parameter :: pfac = 2.0`. The compiler folds `x**pfac` into `x*x`;
   `rp_pow(zfac, pfac)` computed `powf(zfac, 2.0)` at run time, which rounds some exact ties differently.
   `rp_subst.py` now leaves powers with constant exponents (named constants with the value −1, 0, 1, 2 and INTEGER
   constants) as written; 62 such sites were restored, among them Noah's `SNCOVR**SNOEXP` (`SNOEXP = 2.0`), which the
   Eaton case runs.
3. Not a result difference, but found on the way: WRF's `.f90.o` suffix rule (`arch/postamble`) lacked
   `$(MODULE_DIRS)`, so an incremental rebuild after editing a `physics_mmm/*.F90` file could not find
   `module_repro_math.mod`. Fixed; clean builds were never affected.

Ruled out on the way (for the record): the tracer, the pool, uninitialized memory, the fire files, the surface layer
(including the `zolri` fix), `module_bl_ysu.F` (BEP guard), `module_pbl_driver.F`, `sincos` merging (glibc's
`sincosf`/`sincos` equal `sinf`/`cosf` and `sin`/`cos` on 6·10⁸ inputs), and folding of non-integral constant
exponents (gfortran calls `powf` for them, as `rp_pow` does).

#### Memory estimator (P0.15)

`port/gpu_mem_estimate.py --check-rsl` on the two smoke cases: −3.5 % and −3.2 % against the sum of WRF's
`alloc_space_field` lines. For the Eaton namelist:

| Item | GB |
|---|---:|
| d01 state (460×60×460 memory) | 6.76 |
| d02 state (821×60×821 memory, including 1.68 GB fire grid) | 24.67 |
| i1 scratch pool | 7.47 |
| work arrays (approx.) | 3.43 |
| RRTMG batch (4096 columns) | 4.51 |
| local memory (column physics) | 8.29 |
| context etc. | 1.50 |
| **total** | **56.6** (limit 70) |

The state is larger than plan.md §3 (6.1 + 20.5 + 1.7 GB) because the estimator now counts the 4D arrays' members and
the boundary arrays exactly; the pool and work arrays are smaller. The total stays within the plan's range.

### Deviations from plan.md in Phase 0

1. **Location of `module_repro_math`:** `WRF/frame/` instead of `WRF/share/`. `frame/libmassv.F` (`vspow`) uses it,
   and `frame` is compiled before `share`.
2. **REAL(8) accuracy:** plan.md's target was ≤ 1 ulp. fdlibm's `log10`, `sinh`, `cosh`, `tanh` are ≤ 2.05 ulp in
   the tests above. The port needs host and device to agree, which they do by construction (same code, no FMA), so
   the bound was set to 2.5 ulp for these four. WRF calls the REAL(8) versions in a few places only (e.g.
   `read_CAMgases`).
3. **Integer powers and `MOD`:** `rp_pow` also has integer specifics (`x**n` unchanged, so code that `rp_subst.py`
   could not classify as real or integer stays bit-identical), and `rp_mod` has integer specifics (the intrinsic).
4. **Tracer hash:** instead of sum + XOR, each line carries the exact integer sum of the value bits and a
   position-weighted sum modulo 2³¹−1. The second word also catches values that moved to another grid point, which an
   XOR would not. Both are exact integer arithmetic and independent of the decomposition. API:
   `bt_on`, `bt_checkpoint(grid, tag, level, rk)`, `bt_field2/3`, `bt_fieldf` (fire grid), `bt_flush`.
5. **Shared refactors (P0.9a) done now:** item 1 (`rp_*`); item 2 for the i1 pool (`-DWRF_POOL`, generated by
   `gen_defs.c`); item 3 (`zolri`, with an occurrence counter that prints a message: `T-ZOLRI`); item 4 (YSU BEP
   guard); from item 7, `SNUPGRD` → `PARAMETER`.
6. **Shared refactors moved to their phases:** P1.7 work arrays (Phase 1), items 5 (fire), 6 (RRTMG tables),
   7 (Noah `iloc`/`LUTYPE`), 8 (skipping no-ops), 9 (KISS, only if `T-KISS` fails). They are restructurings that do
   not change any arithmetic, and each will be done in the commit that ports the routine. Doing them there keeps
   Phase 0 small and keeps each change next to the GPU code that needs it. The safeguard is `T-DRIFT` at G2, G3 and
   G4: the CPU-REF build at those commits must equal the archived reference bit for bit. For the work arrays,
   `T-UNINIT` (passed locally on the smoke case; to be repeated on the dev case on CCR) shows the model does not read
   uninitialized scratch, so replacing automatic arrays by zero-filled work arrays cannot change results.
7. **`T-UNINIT` (new test):** two gfortran builds, one initializing every local to signaling NaN and the other to
   zero, must give identical traces. This shows directly whether WRF reads memory it did not write, and it is the
   evidence for item 6.
8. **`x**2.0` stays an integer power:** plan.md's standing rule "`x**2.0` becomes `x*x`" is implemented as `x**2`
   (the exponent literals −1., 0., 1., 2. become integers; 35 powers). Compilers fold `x**2.0` into `x*x` and
   compute `x**2` the same way, while `rp_pow(x, 2.0)` with REPRO_MATH off calls `powf`, which may round an exact
   tie differently; so only the integer form keeps the rewrite a pure refactor. The same holds for exponents that
   are named constants: `x**pfac` with `parameter :: pfac = 2.0` (YSU), `SNCOVR**SNOEXP` with `SNOEXP = 2.0`
   (Noah), and INTEGER constants such as the WENO `pw = 2` stay powers (62 sites; `rp_subst.py` resolves the
   file's PARAMETERs). T-IPOW tests these forms host vs device, and T-SYM would show any `pow` call a compiler
   leaves in host code.
9. **Vector math and T-SHARED-1:** gfortran vectorizes loops that call `exp`, `log`, `pow`, … into glibc's SIMD
   variants (`_ZGVbN4v_expf`, …), whose results differ from the scalar functions. The rewritten loops call `rp_*`
   and are never vectorized, so unmodified and rewritten code differ although no arithmetic changed. The local
   T-SHARED-1 therefore builds both with `-nostdinc -fintrinsic-modules-path <gfortran finclude>` (which drops
   glibc's vector-math declarations but keeps the intrinsic modules), and
   `port/ccr/t_shared.sh` builds both with `-Mnovect`. CPU-REF itself is not affected: with REPRO_MATH every such
   call is an `rp_*` call.
10. **Pool and element designators:** with `-DWRF_POOL` the i1 arrays are pointers, which Fortran does not allow to
    be passed as element designators (`moist_tend(ims,kms,jms,im)`) to explicit-shape dummies. The 41 call sites in
    `solve_em.F` now pass sections (`moist_tend(:,:,:,im)`); same storage, no copy, in both builds.
11. **`share/module_interp_fcn.F` is not rewritten:** it is only used by WRFDA (`var/`), not by `wrf.exe`, so it
    was dropped from `port/rp_subst_files.txt` (49 files).
12. **T-UNINIT and `module_mp_morr_two_moment_aero.F`:** its routines have a bare `SAVE` statement and gfortran
    rejects `-finit-*` for their automatic arrays, so this one file (not used by the case) is compiled without the
    `-finit-*` flags (`port/ccr/t_uninit.sh`). T-UNINIT builds are serial (`GNU (gfortran/gcc)` serial option),
    because the image's MPI is built for nvfortran.
