# Phase 3 — physics kernels

Plan: [plan.md §8](../../plan.md) (8.0 column-physics transformation CP-1..CP-5, 8.1–8.5 tables, G3). Rules:
[CODING_STANDARD.md](CODING_STANDARD.md) (template CP, §5.7). Exact lines: [KERNEL_REFS.md](KERNEL_REFS.md), routes
and call sites: [ROUTES.md](ROUTES.md). Same way of working as Phase 2 (PHASE2.md §0): host world, one routine per
commit, T-AB + T-TRACE per routine, W-100 (radiation: W-RAD) per sub-phase.

**Context (WORKFLOW.md §11).** The physics files are the largest of the port: `module_ra_rrtmg_lw.F` (14,640
lines, more than your whole context), `module_surface_driver.F` (7,288), `module_sf_noahlsm.F` (4,760). Map them with
`python3 port/tools/index.py <file>` and read one subroutine at a time (`ref.py <routine>`). The CP-3 work (fixed-size
locals in the core routine and every callee) is spread over many subroutines: keep a per-subroutine list in the
kernel row's note (`workbook.py set <kernel> in-progress --note "CP-3 done: SFLX, REDPRM; next: SNOPAC"`) and commit
WIP after each group. Noah (`lsm`, 6,421 lines with callees), `surface_driver`, `pbl_driver`, `ysu`, `wsm6` and RRTMG
each take several sessions; the split is in WORKFLOW.md §11.

## P3.0 Column-physics infrastructure (before any scheme)

1. `WRF/inc/gpu_col.h` (new): `#define WRF_KMAX 64`, `#define WRF_NLAYMAX 128`, `#define WRF_NSOILMAX 4`, and the
   macros for fixed-size column declarations of plan.md CP-3 (e.g. `GPUCOL1(a)` expanding to `a(1:WRF_KMAX)` under
   `WRF_GPU`, to the original bounds otherwise — decide the exact macro form once, document it in the file, use it
   everywhere).
2. Stack size (CP-5): after building the first scheme, read the per-kernel frame sizes from the `-Minfo`/`ptxinfo`
   output (`-gpu=ptxinfo` in a GPU-DEBUG build), set the device stack limit at startup through the shim
   (`wrf_gpu_shim.c`, P1.10; probe F-STACK told you whether `NV_ACC_CUDA_STACKSIZE` works), abort if it is smaller
   than needed, and record the value in `port/ENVIRONMENT.md`.
3. Error codes from device code: an integer array or scalar reduced with `reduction(max:)`; the host prints the
   source's message and calls `wrf_error_fatal` with the source's text.

## How a column scheme is ported (CP-1..CP-4)

For `wsm6` (the model for all the others; plan.md §8.2 and the wrapper `phys/module_mp_wsm6.F:17-236`):

1. Under `#ifdef WRF_GPU` in the wrapper: one kernel `!$omp target teams distribute parallel do collapse(2)` over
   (j,i) replacing the wrapper's j-slab loop. Per thread: gather the column with **the wrapper's own expressions**
   (e.g. `t(k) = th(i,k,j)*pi(i,k,j)`) into private fixed-size arrays; call the core routine with
   `its=ite=1, kts=1, kte=nz`; scatter back with the wrapper's expressions (`th = t/pi`). Accumulators the core
   updates in place (`rain`, `rainncv`, ...) are passed as 1-element private arrays and written back.
2. The core routine (`mp_wsm6_run`, `physics_mmm/mp_wsm6.F90:214-1469`) and every callee get `!$omp declare target`;
   their automatic arrays sized by the tile become fixed size (`gpu_col.h`); whole-array statements
   (`dz(:)=...`, `precip(:)=0.`) become explicit `(1:nz)` sections — grep each routine for `(:)`, `(:,:)`, `SIZE(`,
   `LBOUND(`, `UBOUND(` and list every hit in the commit message.
3. `errmsg`/`errflg` character handling → integer codes; `OPTIONAL`/`PRESENT` tests → host logicals passed in.
4. The CPU wrapper stays unchanged for CPU-REF (`#ifndef WRF_GPU` around it, or the GPU block ends with `RETURN`).
5. Module SAVE scalars and tables the core reads → `declare target` + P1.4 upload.
6. Test: `t_ab.sh wsm6 W-20`, `t_trace.sh W-20`. The column harnesses of plan.md (T-WSM6-COL etc.) are optional
   debugging aids: if you write one, put it under `port/tests/columns/` with a `run_<name>.sh` that prints PASS/FAIL
   (g3.sh runs every `run_*.sh` there).

Shared refactors of this phase (WORKFLOW.md §6, one commit each, then move the base): RRTMG — hoist
`rrtmg_lw_ini` to init and flatten the EQUIVALENCEd `rrlw_kg*` tables into 1D arrays (P0.9a item 6); Noah —
`iloc`/`jloc` as arguments and `LUTYPE`/`SLTYPE` as integer codes (item 7); skipping provable no-ops (item 8: WSM6
effective radius with `has_req*=0`, radiation q save/restore, unused `mptenmax/min`); KISS rewrite only if T-KISS
failed in H0.4 (item 9).

## P3.A (plan.md §8.1) physics glue

- `phy_prep`: 4950–4961 (v4.6.0) is a column recurrence (downward `p_hyd_w` with the species sum in order).
- `add_a2c_v` runs k=kts..**kte** (quirk, keep).
- `moist_physics_finish_em`: drop the unused `mptenmax/min` argmax (a shared "no-op" refactor, protocol) or simply do
  not port them in the GPU view (they only feed nothing).

| Route | Routine(s), base commit | Kernel rows (KERNEL_REFS.md) | Called from (base commit) |
|---|---|---|---|
| `init_zero_tendency` | init_zero_tendency dyn_em/module_em.F:1920-2038 | 8.1:init_zero_tendency (n/a) | dyn_em/module_first_rk_step_part1.F:182 |
| `phy_prep` | phy_prep dyn_em/module_big_step_utilities_em.F:4731-4974 | K-PPR-1..7 | dyn_em/module_first_rk_step_part1.F:208 |
| `calculate_phy_tend` | calculate_phy_tend dyn_em/module_em.F:2079-2452 | K-CPT-1 | dyn_em/module_first_rk_step_part2.F:393 |
| `update_phy_ten` | add_a2a phys/module_physics_addtendc.F:2285-2331<br>add_a2c_u phys/module_physics_addtendc.F:2381-2432<br>add_a2c_v phys/module_physics_addtendc.F:2435-2486<br>update_phy_ten phys/module_physics_addtendc.F:28-176 | K-A2A, 8.1:update_phy_ten (n/a) | add_a2a: phys/module_physics_addtendc.F:202; add_a2a: phys/module_physics_addtendc.F:259; add_a2a: phys/module_physics_addtendc.F:275; add_a2a: phys/module_physics_addtendc.F:282 … |
| `(none)` | advance_ppt phys/module_physics_addtendc.F:2059-2283 | 8.1:advance_ppt (n/a) | - |
| `phy_prep_part2` | phy_prep_part2 dyn_em/module_big_step_utilities_em.F:4981-5392 | K-PP2-1 | dyn_em/solve_em.F:3618 |
| `moist_physics_prep_em` | moist_physics_prep_em dyn_em/module_big_step_utilities_em.F:5395-5590 | K-MPP-1..5 | dyn_em/solve_em.F:3699 |
| `moist_physics_finish_em` | moist_physics_finish_em dyn_em/module_big_step_utilities_em.F:5594-5785 | K-MPF | dyn_em/solve_em.F:4121 |
| `set_physical_bc3d` | set_physical_bc3d share/module_bc.F:651-1113 | 8.1:set_physical_bc3d (n/a) | dyn_em/couple_or_uncouple_em.F:352; dyn_em/couple_or_uncouple_em.F:358; dyn_em/couple_or_uncouple_em.F:364; dyn_em/couple_or_uncouple_em.F:370 … |

**Gate G3.A:** T-AB (W-100; radiation W-RAD) for every route above, T-TRACE W-100.

## P3.B (plan.md §8.2) WSM6

- See "How a column scheme is ported" above. `loops = max(nint(dt/120),1) = 1` for both domains; keep the general
  code. Effective radius returns immediately (`has_req*=0`): the GPU wrapper skips the call (bit-neutral).

| Route | Routine(s), base commit | Kernel rows (KERNEL_REFS.md) | Called from (base commit) |
|---|---|---|---|
| `wsm6` | wsm6 phys/module_mp_wsm6.F:17-236<br>mp_wsm6_run phys/physics_mmm/mp_wsm6.F90:214-1469<br>vrec phys/physics_mmm/module_libmassv.F90:7-10<br>vsqrt phys/physics_mmm/module_libmassv.F90:12-15<br>mp_wsm6_effectRad_run phys/physics_mmm/mp_wsm6_effectRad.F90:60-194 | K-WSM6, 8.2:CP-3, 8.2:CP-4, 8.2:rp_ (done), 8.2:effective-radius, 8.2:minor-loop | wsm6: phys/module_microphysics_driver.F:2311; mp_wsm6_run: phys/module_mp_wsm6.F:149; vrec: phys/mic-wsm5-3-5-code.h:282; vrec: phys/module_mp_wdm5.F:560 … |

**Gate G3.B:** T-AB (W-100; radiation W-RAD) for every route above, T-TRACE W-100.

## P3.C (plan.md §8.3) surface

- `surface_driver`: ten small A kernels in source order (plan.md table).
- `sfclayrev`: per point, level `kts` only; `zolri` already has its defined result (Phase 0); psi tables `declare
  target`.
- Noah `lsm`/`SFLX`: per point, one thread runs the whole point (`module_sf_noahdrv.F` 791–1596 in v4.6.0; see
  KERNEL_REFS.md for the base lines); the `itimestep==1` block is a host-scalar test; `FATAL_ERROR`/`PRINT` → codes.

| Route | Routine(s), base commit | Kernel rows (KERNEL_REFS.md) | Called from (base commit) |
|---|---|---|---|
| `surface_driver` | surface_driver phys/module_surface_driver.F:8-4503 | K-SD-1..8 | dyn_em/module_first_rk_step_part1.F:594 |
| `sfclayrev` | SFCLAYREV phys/module_sf_sfclayrev.F:17-290<br>sf_sfclayrev_pre_run phys/module_sf_sfclayrev.F:293-327<br>sf_sfclayrev_run phys/physics_mmm/sf_sfclayrev.F90:84-925 | K-SFCLAY, 8.3:UB-fix (done) | SFCLAYREV: phys/module_surface_driver.F:2117; SFCLAYREV: phys/module_surface_driver.F:6089; SFCLAYREV: phys/module_surface_driver.F:6176; sf_sfclayrev_pre_run: phys/module_sf_sfclayrev.F:204 … |
| `lsm` | lsm phys/module_sf_noahdrv.F:39-1780<br>SFLX phys/module_sf_noahlsm.F:70-889<br>REDPRM phys/module_sf_noahlsm.F:2316-2536<br>CSNOW phys/module_sf_noahlsm.F:1149-1188<br>SNOW_NEW phys/module_sf_noahlsm.F:3602-3651<br>SNFRAC phys/module_sf_noahlsm.F:2818-2920<br>ALCALC phys/module_sf_noahlsm.F:892-1007<br>TDFCND phys/module_sf_noahlsm.F:4125-4248<br>SNOWZ0 phys/module_sf_noahlsm.F:3553-3598<br>PENMAN phys/module_sf_noahlsm.F:2196-2313<br>CANRES phys/module_sf_noahlsm.F:1010-1146<br>NOPAC phys/module_sf_noahlsm.F:1905-2193<br>EVAPO phys/module_sf_noahlsm.F:1324-1422<br>DEVAP phys/module_sf_noahlsm.F:1190-1229<br>TRANSP phys/module_sf_noahlsm.F:4356-4459<br>SMFLX phys/module_sf_noahlsm.F:2670-2814<br>FAC2MIT phys/module_sf_noahlsm.F:1425-1445<br>SRT phys/module_sf_noahlsm.F:3654-3948<br>WDFCND phys/module_sf_noahlsm.F:4462-4520<br>SSTEP phys/module_sf_noahlsm.F:3951-4078<br>ROSR12 phys/module_sf_noahlsm.F:2538-2597<br>SHFLX phys/module_sf_noahlsm.F:2601-2667<br>HRT phys/module_sf_noahlsm.F:1589-1851<br>TBND phys/module_sf_noahlsm.F:4081-4121<br>TMPAVG phys/module_sf_noahlsm.F:4251-4353<br>SNKSRC phys/module_sf_noahlsm.F:2923-3008<br>FRH2O phys/module_sf_noahlsm.F:1448-1586<br>HSTEP phys/module_sf_noahlsm.F:1854-1902<br>SNOPAC phys/module_sf_noahlsm.F:3011-3414<br>SNOWPACK phys/module_sf_noahlsm.F:3418-3550<br>SFLX_GLACIAL phys/module_sf_noahlsm_glacial_only.F:32-410 | K-LSM | lsm: phys/module_surface_driver.F:2820; SFLX: phys/module_sf_noahdrv.F:1106; SFLX: phys/module_sf_noahdrv.F:3565; SFLX: phys/module_sf_noahdrv.F:4488 … |
| `seaice_noah` | seaice_noah phys/module_sf_noah_seaice_drv.F:15-501 | K-SEAICE | phys/module_surface_driver.F:2918; phys/module_surface_driver.F:3262; phys/module_surface_driver.F:4075 |
| `sfcdiags` | SFCDIAGS phys/module_sf_sfcdiags.F:8-78 | K-SFCDIAG | phys/module_surface_driver.F:2577; phys/module_surface_driver.F:2995; phys/module_surface_driver.F:3923 |

**Gate G3.C:** T-AB (W-100; radiation W-RAD) for every route above, T-TRACE W-100.

## P3.D (plan.md §8.4) YSU (d01 only)

- `ysu` → `bl_ysu_run`: CP-1..CP-4; the BEP guard already exists (Phase 0). `get_pblh`'s `DO WHILE` stays.

| Route | Routine(s), base commit | Kernel rows (KERNEL_REFS.md) | Called from (base commit) |
|---|---|---|---|
| `pbl_driver` | pbl_driver phys/module_pbl_driver.F:12-2289 | K-PBLD-1 | dyn_em/module_first_rk_step_part1.F:1113 |
| `ysu` | ysu phys/module_bl_ysu.F:17-478<br>bl_ysu_run phys/physics_mmm/bl_ysu.F90:57-1420 | K-YSU, 8.4:get_pblh | ysu: phys/module_pbl_driver.F:1218; bl_ysu_run: phys/module_bl_ysu.F:402 |
| `(none)` | diff4d phys/module_pbl_driver.F:2599-2727 | 8.4:OOB-fix (done), 8.4:diff4d (n/a) | - |

**Gate G3.D:** T-AB (W-100; radiation W-RAD) for every route above, T-TRACE W-100.

## P3.E (plan.md §8.5) radiation

- RRTMG LW design: plan.md §8.5 (batches of `WRF_RRTMG_BATCH` columns, per-column work arrays with a trailing batch
  index, one thread per column running setup → McICA → `rrtmg_lw(ncol=1)` → outputs). T-KISS (H0.4) covers the
  random numbers.
- `ozn_p_int` (K-OZP): **one thread per j-row**, exactly as `port/tests/ozn/t_ozn.F90`'s `ozn_p_int_gpu` (the
  per-column rewrite first proposed in plan.md is not exact for all profiles; do not use it).
- Dudhia SW: CP per column; DATA tables → PARAMETER (shared refactor, protocol).
- Test windows: `t_ab.sh radiation_driver W-RAD` (and the other radiation routes), `t_trace.sh W-RAD`.

| Route | Routine(s), base commit | Kernel rows (KERNEL_REFS.md) | Called from (base commit) |
|---|---|---|---|
| `radiation_driver` | solar_eclipse phys/module_ra_eclipse.F:30-? | K-RAD-ACC, K-RAD-CLDT, K-RAD-ECL, K-RAD-Z, K-RAD-LWPOST, K-RAD-SWPOST | phys/module_radiation_driver.F:1195 |
| `(none)` | pre_radiation_driver phys/module_radiation_driver.F:3286-3464<br>radconst phys/module_radiation_driver.F:3470-3512<br>read_CAMgases phys/module_ra_clWRF_support.F:101-290 | 8.5:pre_radiation_driver (n/a), 8.5:host (n/a), 8.5:caller (n/a), 8.5:host#2 (n/a), 8.5:o3rad-d02 | - |
| `calc_coszen` | calc_coszen phys/module_radiation_driver.F:3515-3542 | K-RAD-COSZ | phys/module_radiation_driver.F:1167; phys/module_radiation_driver.F:1207 |
| `cal_cldfra1` | cal_cldfra1 phys/module_radiation_driver.F:3762-3987 | K-RAD-CF0 | phys/module_radiation_driver.F:1327 |
| `ozn_time_int` | ozn_time_int phys/module_radiation_driver.F:4865-4970 | K-OZT | phys/module_radiation_driver.F:1814 |
| `ozn_p_int` | ozn_p_int phys/module_radiation_driver.F:4972-5106 | K-OZP | phys/module_radiation_driver.F:1820 |
| `rrtmg_lwrad` | RRTMG_LWINIT phys/module_ra_rrtmg_lw.F:12990-13019<br>rrtmg_lw_ini phys/module_ra_rrtmg_lw.F:7982-8129<br>RRTMG_LWRAD phys/module_ra_rrtmg_lw.F:11577-12845 | 8.5:hoist, K-RRTMG- | RRTMG_LWINIT: phys/module_physics_init.F:2272; RRTMG_LWINIT: phys/module_radiation_driver.F:2042; rrtmg_lw_ini: phys/module_ra_rrtmg_lw.F:13017; rrtmg_lw_ini: phys/module_ra_rrtmg_lwf.F:16613 … |
| `swrad` | SWRAD phys/module_ra_sw.F:11-248<br>SWPARA phys/module_ra_sw.F:251-516 | K-SW | SWRAD: phys/module_ra_goddard.F:2066; SWRAD: phys/module_ra_goddard.F:2073; SWRAD: phys/module_radiation_driver.F:2344; SWPARA: phys/module_ra_sw.F:232 |

**Gate G3.E:** T-AB (W-100; radiation W-RAD) for every route above, T-TRACE W-100 and W-RAD.

## G3

`bash port/gates/g3.sh` → `== G3: PASS` (T-AB for every Phase 3 route, T-TRACE W-100 and W-RAD, G-MEM ≤ 70 GB on the
full case with physics on the device, T-DRIFT, T-NSYS, reference tests, column harnesses if any).
