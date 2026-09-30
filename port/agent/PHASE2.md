# Phase 2 — dynamics kernels

Plan: [plan.md §7](../../plan.md) (7.0 coding standard, 7.1–7.7 kernel tables, G2). Coding rules:
[CODING_STANDARD.md](CODING_STANDARD.md). Exact CPU lines of every kernel: [KERNEL_REFS.md](KERNEL_REFS.md) (base
commit). Every route with its routines and call sites: [ROUTES.md](ROUTES.md). The tables below (generated from
those) list, per sub-phase, the routes, the routines to edit (file:lines in the base commit), the kernel rows and
where the routines are called from.

## 0. How Phase 2 works

- The model stays on the host (the P1.9 bracket, `gpu_world_host = .TRUE.`). Each ported routine gets kernels and
  an island; with its route on, it copies its arguments to the device, runs there, and copies results back. So each
  routine can be ported and tested on its own, in any order, and `WRF_GPU_OFF=<route>` gives the host execution of
  the same code (T-AB).
- Work routine by routine (one commit each), in the order of the tables. Start with **`calc_alt`** (K-PREP-7): its
  complete port is the tested example `port/tests/tools/example_calc_alt.F`. Getting it through `static.sh`, the
  build, `t_ab.sh calc_alt W-20` and `t_trace.sh W-20` proves the whole pipeline before any hard kernel.
- Per routine: read the routine completely in the base commit; list its loop nests; map each nest to a kernel row of
  KERNEL_REFS.md and a template; write the kernels and the island; `static.sh`; build; `t_ab.sh <route> W-20`;
  `t_trace.sh W-20`; commit; `workbook.py set ... done`.
- Per sub-phase gate (G2.A … G2.G): every route of the sub-phase passes `t_ab.sh <route> W-100`, and
  `t_trace.sh W-100` passes. Tick the sub-phase in the workbook with those results.
- **Branches the case never takes** (other advection orders, periodic/symmetric boundaries, polar, IEVA, hydrostatic,
  other `km_opt`/`diff_opt`): do not port them. In the GPU view, a routine must not silently run an unported branch on
  the host while its data were moved to the device: make such a branch stop with
  `CALL wrf_error_fatal('<routine>: <option> not ported to the GPU')` under `#ifdef WRF_GPU`, placed before the
  entry island (gpu_check_config already rejects those options; this is the second safety net).
- New GPU-only temporaries (the `fqy3` flux array of template B, the limiter's `scl`/`lim`) are work arrays that
  exist only in the GPU build: add them to `module_gpu_work.F` under `#ifdef WRF_GPU`; no shared-refactor protocol
  is needed. Replacing an **existing** automatic array by a work array changes the CPU view: that is the P1.7 shared
  refactor (WORKFLOW.md §6).
- `-mp=gpu` also enables the host `!$OMP PARALLEL DO` tile loops of `solve_em`; with one tile and
  `OMP_NUM_THREADS=1` they run one iteration on one thread. Target regions inside them are fine.
- Level-2 trace checkpoints (`CALL bt_checkpoint(grid, '<tag>', 2, rk_step)` in `solve_em.F`) exist after the
  larger steps only (`grep -n bt_checkpoint WRF/dyn_em/solve_em.F`). Add more (after each step of plan.md §7.1) when
  you need finer localization: they are allowed in the CPU view, change no result, and appear in both CPU-REF and
  GPU-REPRO traces of the same working tree.


## P2.A (plan.md §7.1) RK preparation and physical BCs

- `set_physical_bc3d`/`2d` are called ~100 times per step from many places (ROUTES.md). Their island moves one
  array per call; that is expected until Phase 5. Port only the `open_*`/`specified` branches (template G, tested in
  `port/tests/templates/t_tmpl_g.F90`: the GPU version there is exactly "directive in front of each loop nest of the
  open blocks"). Periodic/symmetric branches: fatal error in the GPU view (see §0).
- `calc_ww_cp`: template C, tested in `t_tmpl_c.F90` (K-PREP-5a = the two `muu`/`muv` loops with work arrays
  `muu`/`muv`, K-PREP-5b = the column kernel with the range guard `i <= itf`).
- `calc_mu_uv`, `calc_mu_uv_1`: interior and edge loops are separate kernels, in order (K-PREP-3a..f).
- `rk_phys_bc_dry_1` has no kernels: it only calls the BC routines.

| Route | Routine(s), base commit | Kernel rows (KERNEL_REFS.md) | Called from (base commit) |
|---|---|---|---|
| `initialize_moist_old` | initialize_moist_old dyn_em/module_big_step_utilities_em.F:6641-6671 | K-PREP-1 | dyn_em/solve_em.F:526 |
| `calculate_full` | calculate_full dyn_em/module_big_step_utilities_em.F:3588-3637 | K-PREP-2 | dyn_em/module_em.F:143; dyn_em/module_em.F:457; dyn_em/module_em.F:1238 |
| `calc_mu_uv` | calc_mu_uv dyn_em/module_big_step_utilities_em.F:27-181 | K-PREP-3a..d | dyn_em/module_em.F:148 |
| `couple_momentum` | couple_momentum dyn_em/module_big_step_utilities_em.F:330-400 | K-PREP-4a..c | dyn_em/module_em.F:154 |
| `calc_ww_cp` | calc_ww_cp dyn_em/module_big_step_utilities_em.F:641-783 | K-PREP-5a, K-PREP-5b | dyn_em/module_em.F:163 |
| `calc_cq` | calc_cq dyn_em/module_big_step_utilities_em.F:788-907 | K-PREP-6 | dyn_em/module_em.F:171 |
| `calc_alt` | calc_alt dyn_em/module_big_step_utilities_em.F:911-950 | K-PREP-7 | dyn_em/module_em.F:176 |
| `calc_php` | calc_php dyn_em/module_big_step_utilities_em.F:1228-1267 | K-PREP-8 | dyn_em/module_em.F:181 |
| `set_physical_bc3d` | set_physical_bc3d share/module_bc.F:651-1113 | K-BC-3D-x | dyn_em/couple_or_uncouple_em.F:352; dyn_em/couple_or_uncouple_em.F:358; dyn_em/couple_or_uncouple_em.F:364; dyn_em/couple_or_uncouple_em.F:370 … |
| `set_physical_bc2d` | set_physical_bc2d share/module_bc.F:202-647 | K-BC-2D-x | dyn_em/couple_or_uncouple_em.F:87; dyn_em/couple_or_uncouple_em.F:93; dyn_em/couple_or_uncouple_em.F:99; dyn_em/module_bc_em.F:897 … |
| `(none)` | rk_phys_bc_dry_1 dyn_em/module_bc_em.F:961-1042 | 7.1:rk_phys_bc_dry_1 (n/a) | - |

**Gate G2.A:** `t_ab.sh <route> W-100` for every route above, `t_trace.sh W-100`; tick the sub-phase.

## P2.B (plan.md §7.2) large-step tendencies (`rk_tendency`)

- `advect_u/v/w/scalar` (h5/v3 only): y-flux = template B (`t_tmpl_b.F90` is advect_u's y-flux, exactly), x-flux
  = per-thread faces or X1/X2, z-flux = column with `vflux(kts)=vflux(kte)=0` inside. `advect_w` has extra `k=ktf+1`
  lid loops. Use one work array `fqy3` (GPU only) for all four routines.
- `rhs_ph`: keep the quirk (no 4th-order x-advection at ids+2/ide-3 under specified BCs).
- `pg_buoy_w`: K-PGB-1 (the `k=kde` statement, reads the original `cqw(kde-1)`) **before** K-PGB-2 (converts `cqw`
  in place).
- `w_damp`: `reduction(max:)` for the CFL values and `reduction(+:)` for the count; the in-loop `WRITE` becomes a
  host pass when the count is > 0 and the debug level asks for it.
- `curvature`: six kernels in order (vxgm, x-edge copies, y-edge copies, u/v/w tendencies).

| Route | Routine(s), base commit | Kernel rows (KERNEL_REFS.md) | Called from (base commit) |
|---|---|---|---|
| `zero_tend` | zero_tend dyn_em/module_big_step_utilities_em.F:4574-4608<br>zero_tend2d dyn_em/module_big_step_utilities_em.F:4612-4644 | K-ZT-1 | zero_tend: dyn_em/module_em.F:370; zero_tend: dyn_em/module_em.F:375; zero_tend: dyn_em/module_em.F:380; zero_tend: dyn_em/module_em.F:385 … |
| `ww_split` | WW_SPLIT dyn_em/module_ieva_em.F:49-323 | K-WWS-1 | dyn_em/module_em.F:438; dyn_em/module_em.F:1222 |
| `advect_u` | advect_u dyn_em/module_advect_em.F:127-1527 | K-ADVU-Y1, K-ADVU-X, K-ADVU-Z | dyn_em/module_em.F:505 |
| `advect_v` | advect_v dyn_em/module_advect_em.F:1531-3025 | K-ADVV-Y1 | dyn_em/module_em.F:546 |
| `advect_scalar` | advect_scalar dyn_em/module_advect_em.F:3030-4360 | K-ADVS-Y1 | dyn_em/module_advect_em.F:10712; dyn_em/module_advect_em.F:10729; dyn_em/module_advect_em.F:10747; dyn_em/module_em.F:625 … |
| `advect_w` | advect_w dyn_em/module_advect_em.F:4365-6065 | K-ADVW-Y1 | dyn_em/module_em.F:589 |
| `rhs_ph` | rhs_ph dyn_em/module_big_step_utilities_em.F:1366-2179 | K-RHSPH-1, K-RHSPH-2, K-RHSPH-3..8 | dyn_em/module_em.F:668 |
| `horizontal_pressure_gradient` | horizontal_pressure_gradient dyn_em/module_big_step_utilities_em.F:2184-2416 | K-HPG-Y | dyn_em/module_em.F:717 |
| `pg_buoy_w` | pg_buoy_w dyn_em/module_big_step_utilities_em.F:2420-2500 | K-PGB-1 | dyn_em/module_em.F:730 |
| `w_damp` | w_damp dyn_em/module_big_step_utilities_em.F:2504-2712 | K-WDAMP | dyn_em/module_em.F:738 |
| `coriolis` | coriolis dyn_em/module_big_step_utilities_em.F:3641-3851 | K-COR-U | dyn_em/module_em.F:761 |
| `curvature` | curvature dyn_em/module_big_step_utilities_em.F:4176-4470 | K-CURV-1..6 | dyn_em/module_em.F:773 |

**Gate G2.B:** `t_ab.sh <route> W-100` for every route above, `t_trace.sh W-100`; tick the sub-phase.

## P2.C (plan.md §7.3) tendency combination and lateral boundaries

- `relax_bdytend_core`, `spec_bdytend`: four strip kernels each (template G), private `fls0..fls4`.
- `rk_addtend_dry`: six pointwise kernels; the `rk_step==1` in-place update stays inside (scalar test).

| Route | Routine(s), base commit | Kernel rows (KERNEL_REFS.md) | Called from (base commit) |
|---|---|---|---|
| `mass_weight` | mass_weight dyn_em/module_bc_em.F:1717-1746 | K-MW | dyn_em/module_bc_em.F:275; dyn_em/module_bc_em.F:293; dyn_em/module_bc_em.F:328; dyn_em/module_bc_em.F:394 |
| `relax_bdytend_core` | relax_bdytend_core share/module_bc.F:1221-1427 | K-RLX-YS | relax_bdytend_core: share/module_bc.F:1155; relax_bdytend_core: share/module_bc.F:1206; relax_bdy_scalar: dyn_em/solve_em.F:2295; relax_bdy_scalar: dyn_em/solve_em.F:2543 … |
| `(none)` | relax_bdy_dry dyn_em/module_bc_em.F:162-347<br>spec_bdy_dry dyn_em/module_bc_em.F:414-531 | 7.3:relax_bdy_dry (n/a), 7.3:spec_bdy_dry (n/a) | - |
| `rk_addtend_dry` | rk_addtend_dry dyn_em/module_em.F:959-1092 | K-ADT-U | dyn_em/solve_em.F:997 |
| `spec_bdytend` | spec_bdytend share/module_bc.F:1430-1549 | K-SPT-YS | spec_bdytend: dyn_em/module_bc_em.F:480; spec_bdytend: dyn_em/module_bc_em.F:488; spec_bdytend: dyn_em/module_bc_em.F:496; spec_bdytend: dyn_em/module_bc_em.F:504 … |

**Gate G2.C:** `t_ab.sh <route> W-100` for every route above, `t_trace.sh W-100`; tick the sub-phase.

## P2.D (plan.md §7.4) acoustic loop (most launched kernels)

- `calc_coef_w`: the tested example `port/tests/tools/calc_coef_w_gpu.inc` (with island) is a complete port.
- `advance_uv`: column kernels with range guards (`i_start_u_tend` vs `i_start_up`).
- `advance_mu_t`: K-AMT-1 (column with `dmdt` sum in k order and the `ww` recurrence), K-AMT-2, K-AMT-3.
- `advance_w`: one column kernel; `rhs_col(1)=0` set inside; the damping block with `dampwt` private; `pi` computed
  on the host and passed firstprivate.
- `spec_bdyupdate`, `spec_bdyupdate_ph`, `zero_grad_bdy`: strips (template G).

| Route | Routine(s), base commit | Kernel rows (KERNEL_REFS.md) | Called from (base commit) |
|---|---|---|---|
| `small_step_prep` | small_step_prep dyn_em/module_small_step_em.F:17-291 | K-SSP-1..4 | dyn_em/solve_em.F:1119 |
| `calc_p_rho` | calc_p_rho dyn_em/module_small_step_em.F:439-569 | K-CPR-1, K-CPR-2 | dyn_em/solve_em.F:1139; dyn_em/solve_em.F:1653 |
| `calc_coef_w` | calc_coef_w dyn_em/module_small_step_em.F:571-653 | K-CCW | dyn_em/solve_em.F:1154 |
| `advance_uv` | advance_uv dyn_em/module_small_step_em.F:655-968 | K-AUV-U | dyn_em/solve_em.F:1309 |
| `spec_bdyupdate` | spec_bdyupdate share/module_bc.F:1955-2064 | K-SBU-YS | dyn_em/solve_em.F:1375; dyn_em/solve_em.F:1385; dyn_em/solve_em.F:1491; dyn_em/solve_em.F:1501 … |
| `advance_mu_t` | advance_mu_t dyn_em/module_small_step_em.F:970-1176 | K-AMT-1, K-AMT-2, K-AMT-3 | dyn_em/solve_em.F:1422 |
| `advance_w` | advance_w dyn_em/module_small_step_em.F:1179-1470 | K-AW | dyn_em/solve_em.F:1529 |
| `sumflux` | sumflux dyn_em/module_small_step_em.F:1474-1634 | K-SFX-1..3 | dyn_em/solve_em.F:1596 |
| `spec_bdyupdate_ph` | spec_bdyupdate_ph dyn_em/module_bc_em.F:18-158 | K-SBUPH-YS | dyn_em/solve_em.F:1616 |
| `zero_grad_bdy` | zero_grad_bdy share/module_bc.F:2219-2332 | K-ZGB-YS | dyn_em/solve_em.F:1628 |
| `small_step_finish` | small_step_finish dyn_em/module_small_step_em.F:296-435 | K-SSF-1..5 | dyn_em/solve_em.F:1771 |

**Gate G2.D:** `t_ab.sh <route> W-100` for every route above, `t_trace.sh W-100`; tick the sub-phase.

## P2.E (plan.md §7.5) scalar transport

- `advect_scalar_pd` limiter: K-PD-L3a/b exactly as `port/tests/pdlim/t_pdlim.F90` (logical flag `lim`, not a
  sentinel; the donor-cell rule per face). plan.md's first description with a `-1.0` sentinel is superseded.
- `rk_update_scalar(_pd)`: private `muold`/`munew`; the `tendency` automatic array → work array (P1.7 protocol).
- RK stages 1–2 call `advect_scalar`, stage 3 `advect_scalar_pd` (for moist and TKE).

| Route | Routine(s), base commit | Kernel rows (KERNEL_REFS.md) | Called from (base commit) |
|---|---|---|---|
| `rk_update_scalar_pd` | rk_update_scalar_pd dyn_em/module_em.F:1803-1916 | K-UPD-PD | dyn_em/solve_em.F:1889; dyn_em/solve_em.F:1952; dyn_em/solve_em.F:2019; dyn_em/solve_em.F:2081 … |
| `(none)` | rk_scalar_tend dyn_em/module_em.F:1096-1442 | 7.5:rk_scalar_tend (n/a) | - |
| `advect_scalar_pd` | advect_scalar_pd dyn_em/module_advect_em.F:6070-7886 | K-PD-Y, K-PD-X, K-PD-Z, K-PD-L1, K-PD-L2, K-PD-L3a, K-PD-L3b, K-PD-D | dyn_em/module_advect_em.F:10760; dyn_em/module_em.F:1267 |
| `relax_bdytend_core` | relax_bdy_scalar dyn_em/module_bc_em.F:349-411 | K-RLXS | relax_bdytend_core: share/module_bc.F:1155; relax_bdytend_core: share/module_bc.F:1206; relax_bdy_scalar: dyn_em/solve_em.F:2295; relax_bdy_scalar: dyn_em/solve_em.F:2543 … |
| `spec_bdytend` | spec_bdy_scalar dyn_em/module_bc_em.F:659-702 | K-SPS | spec_bdytend: dyn_em/module_bc_em.F:480; spec_bdytend: dyn_em/module_bc_em.F:488; spec_bdytend: dyn_em/module_bc_em.F:496; spec_bdytend: dyn_em/module_bc_em.F:504 … |
| `rk_update_scalar` | rk_update_scalar dyn_em/module_em.F:1587-1799 | K-UPD-1..3 | dyn_em/solve_em.F:2340; dyn_em/solve_em.F:2451; dyn_em/solve_em.F:2591; dyn_em/solve_em.F:2746 … |
| `flow_dep_bdy` | flow_dep_bdy share/module_bc.F:2335-2456 | K-FDB-YS | dyn_em/solve_em.F:2375; dyn_em/solve_em.F:2478; dyn_em/solve_em.F:2785; dyn_em/solve_em.F:2969 |
| `bound_tke` | bound_tke dyn_em/module_em.F:2490-2520 | K-BTKE | dyn_em/solve_em.F:2470 |

**Gate G2.E:** `t_ab.sh <route> W-100` for every route above, `t_trace.sh W-100`; tick the sub-phase.

## P2.F (plan.md §7.6) end of step

- `calc_p_rho_phi`: the moist pressure uses `rp_pow(temp, cpovcv)` inline (what `vspow` computes; both builds use
  `rp_pow`).
- `update_phys_fields`: pass `grid%th_phy_m_t0` etc. as arguments instead of `grid%` references in the loop (a
  change of the CPU view only if done in the CPU code: do it in the GPU block).

| Route | Routine(s), base commit | Kernel rows (KERNEL_REFS.md) | Called from (base commit) |
|---|---|---|---|
| `calc_p_rho_phi` | calc_p_rho_phi dyn_em/module_big_step_utilities_em.F:954-1224 | K-CPRP-1, K-CPRP-2 | dyn_em/solve_em.F:2997; dyn_em/solve_em.F:4225 |
| `(none)` | rk_phys_bc_dry_2 dyn_em/module_bc_em.F:1046-1105<br>set_phys_bc_dry_2 dyn_em/module_bc_em.F:809-909<br>diagnostic_output_calc phys/module_diag_misc.F:14-638 | 7.6:rk_phys_bc_dry_2 (n/a), 7.6:diagnostic_output_calc (n/a) | - |
| `spec_bdy_final` | spec_bdy_final share/module_bc.F:2066-2216 | K-SBF-YS | dyn_em/solve_em.F:4580; dyn_em/solve_em.F:4593; dyn_em/solve_em.F:4607; dyn_em/solve_em.F:4621 … |
| `set_w_surface` | set_w_surface dyn_em/module_bc_em.F:1197-1296 | K-SWS | dyn_em/solve_em.F:4771; dyn_em/start_em.F:1521; dyn_em/start_em.F:1527 |
| `update_phys_fields` | update_phys_fields phys/module_diagnostics_driver.F:1221-1271 | K-UPF | phys/module_diagnostics_driver.F:189 |

**Gate G2.F:** `t_ab.sh <route> W-100` for every route above, `t_trace.sh W-100`; tick the sub-phase.

## P2.G (plan.md §7.7) turbulence and LES

- `cal_deform_and_div` has about 40 loop nests: one kernel each, in source order.
- `horizontal_diffusion_*`/`vertical_diffusion_*` share the routes `horizontal_diffusion_2`/`vertical_diffusion_2`;
  `cal_titau_*` share `cal_titau` (nested routes: their islands see the world flag set by the caller's island).
- T-TRACE-TKE: `bash port/gates/t_trace.sh W-TKE` (1008 d02 steps) at the end of the sub-phase.

| Route | Routine(s), base commit | Kernel rows (KERNEL_REFS.md) | Called from (base commit) |
|---|---|---|---|
| `compute_diff_metrics` | compute_diff_metrics dyn_em/module_diffusion_em.F:6883-7131 | K-CDM-1..6 | dyn_em/module_first_rk_step_part2.F:427 |
| `(none)` | phy_bc dyn_em/module_diffusion_em.F:5902-6095 | 7.7:caller (n/a), 7.7:phy_bc (n/a) | - |
| `cal_deform_and_div` | cal_deform_and_div dyn_em/module_diffusion_em.F:18-1191 | K-DEF-01..40 | dyn_em/module_first_rk_step_part2.F:510 |
| `calculate_n2` | calculate_N2 dyn_em/module_diffusion_em.F:1486-1714 | K-N2-1..6 | dyn_em/module_diffusion_em.F:1290 |
| `smag2d_km` | smag2d_km dyn_em/module_diffusion_em.F:1935-2045 | K-SMAG | dyn_em/module_diffusion_em.F:1329 |
| `tke_km` | tke_km dyn_em/module_diffusion_em.F:2050-2337 | K-TKEKM-1..4 | dyn_em/module_diffusion_em.F:1309 |
| `tke_shear` | tke_shear dyn_em/module_diffusion_em.F:6530-6878 | K-TKES-1..9 | dyn_em/module_diffusion_em.F:6173 |
| `tke_buoyancy` | tke_buoyancy dyn_em/module_diffusion_em.F:6235-6380 | K-TKEB-1 | dyn_em/module_diffusion_em.F:6185 |
| `calc_l_scale` | calc_l_scale dyn_em/module_diffusion_em.F:2342-2407 | K-LSC | dyn_em/module_diffusion_em.F:2230; dyn_em/module_diffusion_em.F:6491 |
| `tke_dissip` | tke_dissip dyn_em/module_diffusion_em.F:6385-6525 | K-TKED | dyn_em/module_diffusion_em.F:6194 |
| `tke_rhs` | tke_rhs dyn_em/module_diffusion_em.F:6100-6230 | K-TKER | dyn_em/module_first_rk_step_part2.F:901 |
| `conv_t_tendf_to_moist` | conv_t_tendf_to_moist dyn_em/module_big_step_utilities_em.F:6675-6708 | K-CTM | dyn_em/module_first_rk_step_part2.F:998 |
| `vertical_diffusion_2` | vertical_diffusion_2 dyn_em/module_diffusion_em.F:4005-4459<br>vertical_diffusion_u_2 dyn_em/module_diffusion_em.F:4464-4572<br>vertical_diffusion_s dyn_em/module_diffusion_em.F:4790-4908 | K-VD2-, K-VDU, K-VDS-1..3 | vertical_diffusion_2: dyn_em/module_first_rk_step_part2.F:1053; vertical_diffusion_u_2: dyn_em/module_diffusion_em.F:4132; vertical_diffusion_s: dyn_em/module_diffusion_em.F:4274; vertical_diffusion_s: dyn_em/module_diffusion_em.F:4334 … |
| `horizontal_diffusion_2` | horizontal_diffusion_2 dyn_em/module_diffusion_em.F:2865-3114<br>horizontal_diffusion_u_2 dyn_em/module_diffusion_em.F:3119-3319<br>horizontal_diffusion_s dyn_em/module_diffusion_em.F:3712-4000 | K-HD2-, K-HDU-1..3, K-HDS-1..11 | horizontal_diffusion_2: dyn_em/module_first_rk_step_part2.F:1087; horizontal_diffusion_u_2: dyn_em/module_diffusion_em.F:2980; horizontal_diffusion_s: dyn_em/module_diffusion_em.F:3010; horizontal_diffusion_s: dyn_em/module_diffusion_em.F:3023 … |
| `cal_titau` | cal_titau_11_22_33 dyn_em/module_diffusion_em.F:5332-5452 | K-TT-11 | dyn_em/module_diffusion_em.F:3239; dyn_em/module_diffusion_em.F:3453; dyn_em/module_diffusion_em.F:4761 |

**Gate G2.G:** `t_ab.sh <route> W-100` for every route above, `t_trace.sh W-100`; tick the sub-phase.

## G2

`bash port/gates/g2.sh` → `== G2: PASS`: static, reference tests, T-AB (W-100) for every Phase 2 route (the script
lists routes that still have no kernel as a FAIL), T-TRACE W-100 and W-TKE, T-CPU-VIEW, T-DRIFT, T-NSYS (W-20;
explain every copy in the workbook: in Phase 2 they are the islands of the ported routines and the P1.9 bracket).
Record the table in the workbook and in `port/RESULTS.md` ("Phase 2"). A100 runs of the gate are done later by the
project owner.
