# Phase 4 — WRF-Fire kernels

Plan: [plan.md §9](../../plan.md) (9.0 preparation, 9.1 kernel table, G4). Exact lines: [KERNEL_REFS.md](KERNEL_REFS.md);
routes and call sites: [ROUTES.md](ROUTES.md). Fire runs on d02 once per step (RK stage 1) on the fire mesh
(724×724 on the dev case). Same way of working as Phase 2.

## P4.0 Fire shared refactors (plan.md §9.0; WORKFLOW.md §6, one commit each, then move the base)

Not done in Phase 0 (RESULTS.md deviation 6). Each one: `t_cpu_view.sh W-T0 W-20 W-100` and `t_cpu_view.sh W-IGN`
(the ignition window) and `t_drift.sh` PASS, then move the base and add a REFACTORS.md row.

1. Hoist `set_flags` (`module_fr_fire_driver.F`, called every fire step) to once per domain at init.
2. Replace `fp%...` pointer-component uses inside loops by explicit array arguments down to `tend_ls` → `fire_ros`
   and `heat_fluxes`.
3. Integer any-NaN counts (`x /= x`) instead of the float-sum NaN checks in `print_2d_stats`/`print_3d_stats`.
4. Delete the unused `tend_1..3` automatics of `reinit_ls_rk3` and the dead post-loop ignition check.
5. Remove in-loop `WRITE`s/`CRITICAL` blocks (messages only, `fire_print_msg=0`).
6. Fire automatic arrays → work arrays (P1.7).

## Kernels

- `tend_ls`: WENO5/ENO1 per point with `fire_ros` as a `declare target` function (K-TLS, K-ROS); `reduction(max:tb)`
  and `tbound` on the host.
- `continue_at_boundary`: three kernels in order (j-strips, i-strips, corners).
- `interpolate_2d`: one thread per coarse cell writing its 4×4 fine nodes (no overlaps for even `sr`).
- `ignite_fire`: host early-exit window test, then per point; the counter replaces the in-loop warning.
- `fuel_left`: per cell, 4 subcells sequential in source order; reads the ghost cells of `lfn`/`tign`.
- `sum_2d_cells`: per atmospheric cell, inner fire-cell loops sequential in source order.
- Self test T-FIRE-GHOST (`gpu_selftest: T-FIRE-GHOST PASS/FAIL ...`, WRF_GPU_SELFTEST=1): the device copy of
  `lfn`/`tign_g` has 0.0 in ghost rows/columns 0 and 725 (dev case) after init.

## P4.1–P4.3 (plan.md §9.1)

| Route | Routine(s), base commit | Kernel rows (KERNEL_REFS.md) | Called from (base commit) |
|---|---|---|---|
| `interpolate_atm2fire` | interpolate_atm2fire phys/module_fr_fire_driver.F:1173-1605 | K-A2F-1, K-A2F-2, K-A2F-3, K-A2F-5, K-A2F-6, K-A2F-9, K-A2F-12, K-A2F-15 | phys/module_fr_fire_driver.F:823 |
| `(none)` | - | 9.1:host (n/a) | - |
| `continue_at_boundary` | continue_at_boundary phys/module_fr_fire_util.F:294-392 | K-CAB-J | dyn_em/module_initialize_fire.F:748; phys/module_fr_fire_core.F:1585; phys/module_fr_fire_core.F:1609; phys/module_fr_fire_core.F:1630 … |
| `interpolate_2d` | interpolate_2d phys/module_fr_fire_util.F:520-592 | K-I2D | dyn_em/module_initialize_fire.F:720; phys/module_fr_fire_driver.F:1558; phys/module_fr_fire_driver.F:1568; phys/module_fr_fire_util.F:121 |
| `fire_model` | fire_model phys/module_fr_fire_model.F:12-546 | K-NAN, K-FM5, K-FM6, K-FSC | phys/module_fr_fire_driver.F:877 |
| `prop_ls_rk3` | prop_ls_rk3 phys/module_fr_fire_core.F:1272-1505 | K-PLS-0, K-PLS-1..3 | phys/module_fr_fire_model.F:313 |
| `tend_ls` | tend_ls phys/module_fr_fire_core.F:1887-2125 | K-TLS | phys/module_fr_fire_core.F:1411; phys/module_fr_fire_core.F:1438; phys/module_fr_fire_core.F:1465 |
| `fire_ros` | fire_ros phys/module_fr_fire_phys.F:1541-1671 | K-ROS | phys/module_fr_fire_core.F:2048; phys/module_fr_fire_core.F:2394; phys/module_fr_fire_phys.F:1164 |
| `tign_update` | tign_update phys/module_fr_fire_core.F:1776-1848 | K-TIGN-1, K-TIGN-G | phys/module_fr_fire_model.F:328 |
| `calc_flame_length` | calc_flame_length phys/module_fr_fire_core.F:1854-1881 | K-FLAME | phys/module_fr_fire_model.F:335 |
| `reinit_ls_rk3` | reinit_ls_rk3 phys/module_fr_fire_core.F:1511-1668 | K-RI-0, K-RI-F | phys/module_fr_fire_model.F:341 |
| `advance_ls_reinit` | advance_ls_reinit phys/module_fr_fire_core.F:1674-1770 | K-ALR | phys/module_fr_fire_core.F:1598; phys/module_fr_fire_core.F:1619; phys/module_fr_fire_core.F:1640 |
| `ignite_fire` | ignite_fire phys/module_fr_fire_core.F:86-257<br>nearest phys/module_fr_fire_core.F:261-337 | K-IGN | ignite_fire: phys/module_fr_fire_model.F:400; nearest: phys/module_fr_fire_core.F:202 |
| `fuel_left` | fuel_left phys/module_fr_fire_core.F:344-584 | K-FL-1, K-FL-2 | phys/module_fr_fire_model.F:436 |
| `heat_fluxes` | heat_fluxes phys/module_fr_fire_phys.F:1412-1449 | K-HF | phys/module_fr_fire_model.F:458 |
| `sum_2d_cells` | sum_2d_cells phys/module_fr_fire_util.F:428-515 | K-S2D | phys/module_fr_fire_driver.F:915; phys/module_fr_fire_driver.F:922; phys/module_fr_fire_driver.F:930 |
| `fire_tendency` | fire_tendency phys/module_fr_fire_atm.F:113-305 | K-FT-1, K-FT-2, K-FT-3 | phys/module_fr_fire_driver_wrf.F:127 |

Split the table into three commits groups as the workbook lists them: P4.1 atmosphere-to-fire (`interpolate_atm2fire`,
`continue_at_boundary`, `interpolate_2d`), P4.2 level set (`prop_ls_rk3`, `tend_ls`, `fire_ros`, `tign_update`,
`calc_flame_length`, `reinit_ls_rk3`, `advance_ls_reinit`), P4.3 the rest (`ignite_fire`, `fuel_left`,
`heat_fluxes`, `sum_2d_cells`, `fire_tendency`, `fire_model`).

## G4

`bash port/gates/g4.sh` → `== G4: PASS`: T-AB (W-100) for every Phase 4 route, T-TRACE W-100, T-FIRE-IGN and
T-FIRE-WIN (`t_fire.sh`: level-1 traces with the fire arrays, history bitwise, `compare_fire.py` 0 differing burned
cells), T-FIRE-GHOST, T-NSYS, T-DRIFT. Afterwards the P1.9 bracket still exists; Phase 5 removes it.
