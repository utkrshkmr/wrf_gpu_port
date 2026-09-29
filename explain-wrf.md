# WRF v4.6.0 + WRF-Fire: Guide for Porting the Simulation to NVIDIA GPUs

This guide covers what you need to understand the WRF v4.6.0 code in `WRF/` well enough to move the whole
simulation onto **one NVIDIA A100 or H100 GPU**, with fire spread that is **identical cell by cell** to a CPU
reference run. It covers the architecture, core files, the time-step algorithm, kernels, data structures, WRF-Fire,
data movement, a bit-reproducibility design, an acceleration plan, and a phased porting plan with verification gates.

The scope is set by the run configuration you provided (`namelist.input`, `namelist.output`, `namelist.fire`); only
facts that shape the port were taken from it. All file and line references are relative to this repository and
point at the unmodified v4.6.0 sources.

The task-by-task execution plan (kernels, wiring, tests, gates and performance analysis for A100 80 GB and H100
80 GB) is in [plan.md](plan.md).

---

## Contents

0. [Summary](#0-summary)
1. [Decisions and target case](#1-decisions-and-target-case)
2. [Scope of the port for this case](#2-scope-of-the-port-for-this-case)
3. [Programming model and toolchain](#3-programming-model-and-toolchain)
4. [Arithmetic accuracy: bit-reproducible CPU and GPU runs](#4-arithmetic-accuracy-bit-reproducible-cpu-and-gpu-runs)
5. [Acceleration on one GPU](#5-acceleration-on-one-gpu)
6. [Codebase map](#6-codebase-map)
7. [Build system](#7-build-system)
8. [Program flow](#8-program-flow)
9. [Core data structures and index conventions](#9-core-data-structures-and-index-conventions)
10. [The Registry](#10-the-registry)
11. [The dynamical core time step](#11-the-dynamical-core-time-step)
12. [Kernel patterns and how to port each one](#12-kernel-patterns-and-how-to-port-each-one)
13. [Physics in this case](#13-physics-in-this-case)
14. [WRF-Fire in this case](#14-wrf-fire-in-this-case)
15. [Boundary conditions](#15-boundary-conditions)
16. [MPI and tiles on a single GPU](#16-mpi-and-tiles-on-a-single-gpu)
17. [Host/device sync points: I/O, inputs, nesting](#17-hostdevice-sync-points-io-inputs-nesting)
18. [GPU data-management design](#18-gpu-data-management-design)
19. [Porting plan with verification gates](#19-porting-plan-with-verification-gates)
20. [Profiling and debugging tools](#20-profiling-and-debugging-tools)
21. [Runtime configuration](#21-runtime-configuration)
22. [Pitfall checklist](#22-pitfall-checklist)
23. [Appendix: file index and glossary](#23-appendix)

---

## 0. Summary

- **Target:** one A100 or H100 (80 GB parts), one MPI rank, both domains of your nested run resident on the GPU.
  WPS, `real.exe`, initialization and file I/O stay on the CPU.
- **Priority 1, accuracy:** "cell-by-cell identical fire spread" in a two-way coupled 100 m LES
  (`fire_atm_feedback = 1`) effectively requires the GPU to reproduce a CPU reference **bit for bit**. Any last-bit
  difference in the winds grows through the turbulence and eventually moves the fire front by whole cells. The
  guide makes bitwise CPU/GPU identity the engineering target, and it is achievable ([§4](#4-arithmetic-accuracy-bit-reproducible-cpu-and-gpu-runs)):
  - the same Fortran source, compiled by the same compiler for CPU and GPU;
  - IEEE-exact arithmetic with no fused multiply-add (FMA);
  - one shared implementation of `exp`/`log`/`pow`/trig used on both sides;
  - no reordering of floating-point sums.
- **What "the CPU reference" is:** a CPU build of this repository with those same rules. It won't be bitwise equal to
  your original CPU run, because no GPU build can reproduce a different compiler's math library. How much the new
  reference differs from the original is measured once, up front ([§4.2](#42-which-cpu-results-to-match)).
- **Priority 2, acceleration:** everything stays resident on the GPU, with no host↔device traffic per step and no
  device memory allocation per step. d02 (811×811×60 at `dt = 1/3 s`, 183,600 steps) accounts for about 97% of
  the atmospheric work, plus a 3240×3240 fire grid every step. Speedups are allowed only if they don't change a
  single bit ([§5](#5-acceleration-on-one-gpu)).
- **Programming model:** OpenMP target offload in the existing Fortran with `nvfortran`. Compiling one source for
  both CPU and GPU with one compiler front end is also what makes bitwise equality realistic.

---

## 1. Decisions and target case

### 1.1 Decisions

| Topic | Decision |
|---|---|
| GPUs | **A100 and H100 only** (`cc80`, `cc90`). Use **80 GB** variants: see the memory estimate in [§1.3](#13-work-and-memory-budget). |
| Parallelism | **Single GPU, single MPI rank.** Multi-GPU is deferred (design notes in [§16](#16-mpi-and-tiles-on-a-single-gpu)). |
| Priorities | **(a) arithmetic accuracy, (b) acceleration**, in that order. |
| Accuracy acceptance | **Fire spread identical cell by cell.** Operationally: `tign_g` (fire arrival time) and `fire_area` on the fire grid are **bitwise identical** to the CPU reference at every d02 history time (every 15 min). The engineering target is bitwise identity of all state ([§4](#4-arithmetic-accuracy-bit-reproducible-cpu-and-gpu-runs)). |
| Port style | Minimal: directives plus data movement. No algorithm or layout changes. Restructure only where a loop can't run in parallel as written, and always preserve the arithmetic exactly. |
| Framework | OpenMP target offload with `nvfortran` (NVIDIA HPC SDK). CUDA is not needed for the single-GPU port. |

### 1.2 Facts taken from your run configuration

Only settings that change what must be ported, how it must be verified, or what it costs are listed here.

**Domains and time stepping**

| | d01 | d02 |
|---|---|---|
| Grid (`e_we × e_sn × e_vert`) | 450 × 450 × 60 | 811 × 811 × 60 |
| Mass points | 449 × 449 × 59 ≈ 11.9 M | 810 × 810 × 59 ≈ 38.7 M |
| `dx` | 900 m | 100 m (`parent_grid_ratio = 9`) |
| `dt` | 3 s | 1/3 s (`parent_time_step_ratio = 9`) |
| Steps in 17 h | 20,400 | 183,600 |
| Acoustic steps (`time_step_sound = 0` → computed) | 4 per `dt` → 7 acoustic sub-steps per step (1+2+4) | 4 per `dt` → 7 |
| Lateral BCs | `specified` from `wrfbdy_d01`, every 3 h (`spec_bdy_width 5`, `spec_zone 1`, `relax_zone 4`) | `nested`, **one-way** (`feedback = 0`, `smooth_option = 0`) |
| Fire | off (`ifire = 0`) | `ifire = 2`, `sr_x = sr_y = 4` → 25 m fire grid, 3240 × 3240 ≈ 10.5 M cells |

**Dynamics (both domains unless noted)**

`rk_ord = 3`; non-hydrostatic; `hybrid_opt = 2` (`etac = 0.2`); `use_theta_m = 1` (moist θ);
`hypsometric_opt = 2`; `p_top = 200 hPa`; advection orders h5/v3 for momentum and scalars; `momentum_adv_opt = 1`;
`moist_adv_opt = scalar_adv_opt = tke_adv_opt = 1` (**positive-definite**); `diff_opt = 2`;
**`km_opt = 4` (d01, 2D Smagorinsky with YSU vertical mixing) and `km_opt = 2` (d02, 3D TKE LES)**; `m_opt = 1` on
d02 (SGS stress output); `damp_opt = 3` (w damping inside `advance_w`, `zdamp = 5000 m`, `dampcoef = 0.2`);
`w_damping = 1`; `epssm = 0.5 / 0.8`; `diff_6th_opt = 0`; `use_adaptive_time_step = F`; `zadvect_implicit = 0`.

**Physics (both domains unless noted)**

| Option | Value | Scheme |
|---|---|---|
| `mp_physics` | 6 | WSM6 |
| `ra_lw_physics` | 4 | RRTMG LW (single precision in WRF: `kind_rb = kind(1.0)`, `module_ra_rrtmg_lw.F:42`) |
| `ra_sw_physics` | 1 | Dudhia SW |
| `radt` | 1 min | → every 20 d01 steps, every 180 d02 steps |
| `sf_sfclay_physics` | 1 | Revised MM5 surface layer (`sfclayrev`) |
| `sf_surface_physics` | 2 | Noah LSM (4 soil layers, 21 land categories) |
| `bl_pbl_physics` | 1 / **0** | YSU on d01; **none on d02 (LES)** |
| `cu_physics`, `shcu_physics`, `sf_urban_physics`, lake | 0 | off |
| `icloud`, `isfflx`, `ifsnow` | 1, 1, 1 | cloud fraction for radiation; surface fluxes on; snow |

**WRF-Fire (d02)**

| Option | Value | Meaning for the port |
|---|---|---|
| `fire_fuel_read` | -1 | `nfuel_cat` comes from `wrfinput_d02` (WPS fire grid). Init only, on the CPU. |
| `nfuelcats` / fuels | 53 (`namelist.fire`: Anderson 13 plus Scott & Burgan 40), `no_fuel_cat = 14` | Fuel property tables are module data → copy to the device once |
| `fire_fmc_read`, `fmoist_run` | 1, F | uniform ground fuel moisture 0.08 set at init; **fuel-moisture model not run** |
| `fire_sprd_mdl` | 1 | BEHAVE (Rothermel) spread-rate formula |
| `fire_upwinding` | 9 | hybrid WENO5/ENO1 level-set spatial scheme |
| `fire_lsm_reinit` (iter, scheme, band) | T (1, 4, 4 cells) | level-set reinitialization every step |
| `fire_advection` | 1 | spread from fireline particle speed projected on the normal |
| `fire_lsm_zcoupling`, `fire_wind_height` | T (ref 60 m), 1 m | log-profile wind from 60 m to 1 m (uses `log`) |
| `fire_atm_feedback` | 1 | heat and moisture fluxes feed back into the atmosphere (two-way coupling) |
| `fire_fuel_left_method` | 1 (2×2 subcells) | burned-fraction quadrature |
| `fire_grows_only`, `fire_boundary_guard`, `fire_viscosity` | 1, 8, 0.4 | defaults |
| Ignition | 1 circle, radius 100 m, 8280–9080 s (02:18–02:31 UTC), ROS 0.1 m/s | `ignite_fire` is active during that window |
| Off | smoke tracer (`tracer_opt = 0`), firebrand spotting, fuel-moisture model | not ported |

**I/O**

| Output | Setting | Consequence |
|---|---|---|
| d02 history | every 15 min (69 frames over 17 h) | device → host copy per frame |
| d01 history | `history_interval = -1` | effectively off |
| Restart files | `restart_interval = 60` | **written every hour for both domains, even though `restart = .false.`** |
| Aux inputs, diagnostics | none; `nwp_diagnostics = output_diagnostics = do_radar_ref = 0` | nothing extra to port |

### 1.3 Work and memory budget

| Quantity | Value | Notes |
|---|---|---|
| d02 share of atmospheric cell-steps | **≈ 97%** (7.1×10¹² vs 2.4×10¹¹) | d02 dominates. d01 still has to be ported because it forces d02. |
| Fire cells updated per d02 step | 10.5 M × (3 level-set RK stages + reinitialization) | runs every step, including the 24,840 steps before ignition |
| Radiation calls | about 1,020 per domain | every simulated minute |
| Nest forcing (d01 → d02) | 20,400 times | once per d01 step |
| One 3D `REAL` array | d02 ≈ 164 MB, d01 ≈ 52 MB | memory dimensions include halo |
| One fire-grid array | ≈ 42 MB | 39 fire-grid arrays in `registry.fire` ≈ 1.6 GB |
| Per-step scratch (`i1`) | ~50 3D arrays ≈ 8 GB at d02 size | made persistent, see [§5.3](#53-persistent-device-scratch) |

**Measure the total before buying or allocating GPUs.** WRF prints
`alloc_space_field: domain N, <bytes> bytes allocated` (`WRF/frame/module_domain.F:1433`) in `rsl.error.*` for each
rank. Sum it over the ranks of your CPU run for each domain, then add the ~8 GB scratch pool and ~2 GB for
lookup tables and work arrays. A rough estimate is that d02 alone needs tens of GB. **An A100 40 GB is very likely
too small; plan on A100 80 GB or H100 80/94 GB.**

---

## 2. Scope of the port for this case

### 2.1 Ground rules (minimal port)

1. Same algorithms, same data layout (`(i,k,j)` arrays with unchanged bounds), and **the same floating-point
   operations in the same order**.
2. Changes are limited to:
   - OpenMP directives and data mapping;
   - the reproducible-math substitution ([§4.4](#44-reproducible-math-module));
   - the smallest restructuring needed where a loop can't run in parallel as written. The restructured loop must
     give the same bits as the original.
3. Code paths your case never executes are left alone. A startup check in the GPU build rejects unported options
   ([§2.4](#24-switched-off-in-this-case-not-ported)).

### 2.2 What runs on the GPU

| Area | Routines (files) |
|---|---|
| RK step preparation | `rk_step_prep` → `calculate_full`, `calc_mu_uv`, `couple_momentum`, `calc_ww_cp`, `calc_cq`, `calc_alt`, `calc_php` (`dyn_em/module_em.F`, `module_big_step_utilities_em.F`) |
| Large-step tendencies | `rk_tendency` → `zero_tend`, `WW_SPLIT`, `calc_mut_new`, `calc_mu_uv_1`, `advect_u/v/w`, `advect_scalar` (θ), `rhs_ph`, `horizontal_pressure_gradient`, `pg_buoy_w`, `w_damp`, `coriolis`, `curvature` (`module_em.F`, `module_advect_em.F`, `module_big_step_utilities_em.F`) |
| Tendency combination and lateral BCs | `rk_addtend_dry`, `relax_bdy_dry`, `spec_bdy_dry` (d01 specified, d02 nested) (`module_em.F`, `module_bc_em.F`) |
| Acoustic loop | `small_step_prep`, `calc_p_rho`, `calc_coef_w`, `advance_uv`, `advance_mu_t`, `advance_w` (incl. `damp_opt = 3`), `sumflux`, `small_step_finish`, `spec_bdyupdate`, `spec_bdyupdate_ph`, `zero_grad_bdy` (`module_small_step_em.F`, `share/module_bc.F`) |
| Scalar transport (6 moist species on both domains, plus TKE on d02) | `rk_update_scalar_pd`, `rk_scalar_tend` → `advect_scalar_pd`, `rk_update_scalar`, `relax_bdy_scalar`, `spec_bdy_scalar`, `flow_dep_bdy`, `bound_tke` |
| Diagnosis and BCs | `calc_p_rho_phi`, `set_physical_bc2d/3d`, `rk_phys_bc_dry_1/2`, `set_phys_bc_dry_2`, `spec_bdy_final`, `set_w_surface`, `zero_bdytend` |
| Turbulence (`diff_opt = 2`) | `compute_diff_metrics`, `cal_deform_and_div`, `calculate_km_kh` → **`smag2d_km` (d01)**, **`tke_km` (d02)**, `tke_rhs` (d02), `horizontal_diffusion_2` (both), **`vertical_diffusion_2` (d02 only, since it has no PBL)**, `phy_bc`, m_opt stress terms (d02) (`module_diffusion_em.F`, `module_first_rk_step_part2.F`) |
| Physics glue | `init_zero_tendency`, `phy_prep`, `calculate_phy_tend`, `update_phy_ten`, `moist_physics_prep_em`, `moist_physics_finish_em`, `phy_prep_part2` |
| Physics schemes | WSM6, RRTMG LW, Dudhia SW (plus radiation-driver prep: cloud fraction, solar geometry), sfclayrev, Noah LSM, YSU (d01) ([§13](#13-physics-in-this-case)) |
| WRF-Fire (d02) | stages 3–6 of `fire_driver_em`, plus `fire_tendency` ([§14](#14-wrf-fire-in-this-case)) |
| Per-step diagnostics | Whatever `after_all_rk_steps` → `diagnostics_driver` still computes with your options. Check it and port it, or confirm it's inactive. |

### 2.3 What stays on the CPU

| Component | When | Transfer cost |
|---|---|---|
| WPS, `real.exe` | before the run | — |
| `wrf_init`, `start_domain` (d01), physics init (tables), `med_nest_initial` plus `start_domain` (d02, incl. fire init and `nfuel_cat`) | once | one full host → device copy per domain |
| History (d02, every 15 min) and restart (hourly) output | 69 + 17 times | device → host copy of the output fields |
| Lateral BC read from `wrfbdy_d01` | every 3 h | host → device copy of the d01 boundary arrays |
| Nest forcing interpolation `med_nest_force` → `force_domain_em_part2` (`share/mediation_force_domain.F`, generated code in `external/RSL_LITE/module_dm.F`) | every d01 step | slab of d01 fields to host, d02 boundary arrays to device ([§17](#17-hostdevice-sync-points-io-inputs-nesting)). Can be ported later if it shows in profiles. |
| Clocks, alarms, namelist, messages | always | none |

### 2.4 Switched off in this case (not ported)

Cumulus, shallow convection, urban, lake, FDDA/nudging, stochastic perturbations, WRF-Chem, tracers (including fire
smoke), WENO and monotonic advection, 6th-order diffusion, Rayleigh damping (`damp_opt = 2`), polar filters,
adaptive time stepping, periodic BCs, nest feedback and moving nests, fuel-moisture model, firebrand spotting,
trajectories, and all MPI halo exchanges (with one rank they're no-ops, [§16](#16-mpi-and-tiles-on-a-single-gpu)).

Add a small check at startup in the GPU build (next to `share/module_check_a_mundo.F`) that stops with a clear
message if any of these, or any physics option other than those in [§1.2](#12-facts-taken-from-your-run-configuration),
is enabled. That prevents an unported path from silently running on stale host data.

---

## 3. Programming model and toolchain

### 3.1 Why OpenMP target offload

| Criterion | OpenMP target offload (chosen) | CUDA Fortran | CUDA C/C++ rewrite |
|---|---|---|---|
| Change per loop | Directive lines | `device` data attributes plus kernels or `!$cuf` | Rewrite every loop |
| Same source for CPU reference and GPU | **Yes**: directives are inert without `-mp=gpu` | No | No |
| Bitwise CPU/GPU equality | **Most realistic**: one compiler front end lowers the same expressions for both targets | Possible, but two code paths | Hard: must replicate Fortran evaluation order by hand |
| Data movement | `target enter/exit data`, `target update` | `device` arrays | `cudaMemcpy` |
| Fit for column physics | `declare target` on existing routines | Poor | Poor |

OpenACC (also in `nvfortran`) would work the same way. This guide uses OpenMP as agreed.

### 3.2 Toolchain and build modes

Use one NVIDIA HPC SDK version and **one container or OS image** for every build and run, both CPU reference and
GPU ([§4.3](#43-the-reproducibility-contract), rule R10). Any recent NVHPC release with CUDA 12.x or 13.x supports
`cc80` and `cc90`.

| Build | Purpose | Fortran flags (host) | Device flags | cpp |
|---|---|---|---|---|
| **CPU-REF** | the reference run; also used for shadow tests | `-O2 -Kieee -Mnofma -Mnoflushz` | — (no `-mp=gpu`) | `-DREPRO_MATH` |
| **GPU-REPRO** (default, production) | bitwise equal to CPU-REF | `-O2 -Kieee -Mnofma -Mnoflushz` | `-mp=gpu -gpu=cc80,cc90,nofma` (no `fastmath`; keep denormals, i.e. no flush-to-zero) | `-DREPRO_MATH` |
| GPU-FAST (optional, later) | measures the cost of reproducibility; **not** bitwise | `-O3` | `-mp=gpu -gpu=cc80,cc90` (FMA on) | — |

Flag spellings differ slightly between NVHPC releases, so confirm with `nvfortran -help` and
`nvfortran -help -gpu` (look for the `fma`/`nofma` and `flushz`/`noflushz` sub-options and the host `-M[no]fma`,
`-M[no]flushz`, `-Kieee`). `-Minfo=mp` is always on in GPU builds: it reports every offloaded loop and every
implicit data mapping.

### 3.3 A100 vs H100 (NVIDIA datasheet values)

| | A100 40 GB | A100 80 GB | H100 PCIe 80 GB | H100 SXM 80 GB | H100 NVL 94 GB |
|---|---|---|---|---|---|
| Compute capability | 8.0 | 8.0 | 9.0 | 9.0 | 9.0 |
| HBM bandwidth | ~1.6 TB/s | ~1.9–2.0 TB/s | ~2.0 TB/s | ~3.35 TB/s | ~3.9 TB/s |
| FP64 : FP32 throughput | 1 : 2 | 1 : 2 | 1 : 2 | 1 : 2 | 1 : 2 |
| Fits this case? | very likely not | expected | expected | expected | expected |

WRF's stencil kernels are limited by memory bandwidth, so expect H100 SXM/NVL to be clearly faster than A100 for
the same code. Fast FP64 on both parts matters here because the reproducible math functions evaluate single-precision
results in double precision ([§4.4](#44-reproducible-math-module)); RRTMG LW itself runs in single precision in
WRF. Unified/HMM memory (`-gpu=mem:unified`) is
available on both GPUs with open kernel modules. It's useful for bring-up experiments, but **don't use it in
production**: page migration makes performance unpredictable.

---

## 4. Arithmetic accuracy: bit-reproducible CPU and GPU runs

### 4.1 Why "identical fire spread" means bitwise identity

- d02 is a 100 m LES with resolved turbulence (`bl_pbl_physics = 0`, `km_opt = 2`). Differences of one unit in the
  last place (ulp) in any field grow through the turbulence to O(1) differences in eddies within model minutes to
  hours.
- The fire spreads at 25 m resolution, driven by 1 m winds (`fire_wind_height = 1`, log-coupled from 60 m), and
  **feeds its heat back** into the LES (`fire_atm_feedback = 1`). A changed gust changes the local rate of spread,
  which changes where the front is, which changes the heating and hence the winds.
- Over the ~14.7 h the fire burns, a last-bit difference is therefore expected to show up as different burned cells.
  Tolerance-based matching ("agrees to 5 digits") can't guarantee the criterion; bitwise identity can.

**Experiment E1 (sensitivity, run it early on CPU-REF):** perturb one value by 1 ulp (for example θ at one d02 point
at 02:00, before ignition) and compare `tign_g`/`fire_area` against the unperturbed run at every 15-min frame.

- If burned cells diverge (expected), bitwise identity is required. This guide assumes that outcome.
- If they don't diverge over 17 h, the criterion is looser than bitwise, but bitwise remains the safest engineering
  target.

### 4.2 Which CPU results to match

- **CPU-REF** is this repository (with the reproducible-math module and any restructured kernels) built for the CPU
  with `nvfortran` and the flags in [§3.2](#32-toolchain-and-build-modes). The GPU build must reproduce CPU-REF bit
  for bit. Because restructuring preserves arithmetic exactly, **CPU-REF output must never change during the port**.
  Any commit that changes CPU-REF bits has a bug.
- **Your original CPU results** came from some compiler and its host math library (`exp`, `log`, `pow`, ...). A GPU
  build can't run that library, so it can't reproduce those results bitwise, and neither can CPU-REF.
- **Experiment E0:** run CPU-REF for the full case once and compare with your original run: fields (`diffwrf`) and
  fire spread (number of differing burned cells per frame, arrival-time differences). That difference comes from
  the CPU build change and the reproducible-math substitution, not from the GPU. Keep it as a documented baseline.

  To get closer to the original, compile CPU-REF with the original compiler instead. That only helps if that
  compiler can also target your GPU, which in practice means NVHPC/PGI. If the original run already used
  `nvfortran`/`pgf90`, E0 will show the smallest possible gap.

### 4.3 The reproducibility contract

Every ported routine must satisfy all of these rules. Rules R1–R6 are about arithmetic; R7–R11 are about inputs and
execution.

| # | Rule | How |
|---|---|---|
| R1 | Same source and front end | CPU-REF and GPU-REPRO are built from the same commit with the same `nvfortran`. The GPU build differs only by `-mp=gpu`. |
| R2 | IEEE basic arithmetic | No fast-math anywhere. `-Kieee` on the host. Device `/` and `sqrt` stay IEEE-rounded (the default; never `-gpu=fastmath`). `+ - * / sqrt` are then correctly rounded on both sides, so they agree bitwise. |
| R3 | **No FMA contraction** | Host `-Mnofma`, device `-gpu=nofma`. A fused multiply-add (`a*b+c` with one rounding) on one side but not the other is the most common source of CPU/GPU bit differences. |
| R4 | Same denormal handling | No flush-to-zero on either side (`-Mnoflushz`; no device `flushz`). |
| R5 | **Same transcendental implementations** | Every `exp`, `log`, `log10`, real-exponent `**`, `sin`, `cos`, `tan`, `atan`, `atan2`, `tanh`, and real `MOD` in code that runs on the GPU goes through `module_repro_math` ([§4.4](#44-reproducible-math-module)) in **both** builds. Exact intrinsics (`sqrt`, `abs`, `min`, `max`, `sign`, `int`, `nint`, `real`, `floor`) stay as they are. |
| R6 | Same operation order | No reassociation. Floating-point sums run sequentially within one GPU thread, in the CPU order (vertical integrals, fire subcell sums). No float atomics. No parallel float-sum reductions in the time step. `max`/`min` reductions are exact and allowed. |
| R7 | Restructuring preserves expressions | Pattern B (§12) uses full 3D flux arrays with the identical expression. Never simplify algebra ("`a*b/c` → `a*(b/c)`"). Keep parentheses. |
| R8 | Constants | Runtime constants computed from intrinsics (for example `pi = 4.*atan(1.)` in `advance_w`, `module_small_step_em.F:1283`) use `rp_*` functions or become `PARAMETER`s. |
| R9 | Integer powers | `x**2` compiles to `x*x` on both sides. For `x**n` with n ≥ 3, confirm with shadow tests, and write explicit products if they differ. |
| R10 | Identical inputs and environment | The device state is a bit copy of the host state after CPU initialization. Physics tables are built once on the host and bit-copied. Build and run CPU-REF and GPU-REPRO in the **same container image on the same CPU model**, because host-side init uses the host math library, whose results can depend on the library version and CPU features. |
| R11 | Deterministic decomposition | GPU runs are 1 patch, 1 tile. CPU-REF may use many MPI ranks for speed only after test R0 shows bitwise-equal results for 1 rank vs N ranks over a short window. |

The RRTMG LW McICA sub-column generator uses integer arithmetic (deterministic), so ported faithfully it produces
identical streams. Output (netCDF) and clocks are identical by construction.

### 4.4 Reproducible math module

**Design:**

- New file `WRF/frame/module_repro_math.F` provides `elemental` functions with generic interfaces for `REAL(4)` and
  `REAL(8)`: `rp_exp`, `rp_log`, `rp_log10`, `rp_pow(x,y)`, `rp_sin`, `rp_cos`, `rp_tan`, `rp_atan`,
  `rp_atan2`, `rp_tanh`, `rp_mod`. Each is marked `!$omp declare target`.
- `#ifdef REPRO_MATH` selects the portable implementations; otherwise each `rp_*` calls the intrinsic, so a build
  without the flag behaves exactly like upstream.
- **Single precision** (nearly all of WRF, RRTMG LW included): use correctly rounded algorithms that evaluate in
  double precision (the approach of the CORE-MATH project's binary32 functions). They're as accurate as possible
  (≤ 0.5 ulp) and **identical on any IEEE machine by definition**.
- **Double precision** (the few `REAL(8)` callers on executed paths, e.g. the greenhouse-gas scalars from
  `read_CAMgases`): a fixed portable algorithm (fdlibm/musl style) written only with IEEE basic
  operations and exact bit manipulation (`TRANSFER`, `IAND`, `ISHFT`, `SCALE`, `EXPONENT`). With R2–R4 it gives
  identical bits on CPU and GPU, even though it isn't necessarily correctly rounded.
- **Testing:** exhaustive for binary32 (all 2³² inputs, CPU vs GPU bit-compare, and error against a high-precision
  reference; minutes on a GPU). For binary64: large random samples plus edge cases (±0, subnormals, ±Inf, NaN,
  overflow and underflow thresholds, integer and half-integer exponents for `pow`).

**Call-site inventory in the files your case executes.** The counts are approximate (from `grep`, code only). `sqrt`
is omitted because it's exact. "`**` real" counts powers with a real or variable exponent, which become `rp_pow`.

| File | exp | log | log10 | sin/cos/tan | atan* | tanh | `**` real |
|---|---:|---:|---:|---:|---:|---:|---:|
| `dyn_em/module_small_step_em.F` | 0 | 0 | 0 | 2 | 1 | 0 | 0 |
| `dyn_em/module_big_step_utilities_em.F` | 2 | 6 | 0 | 7 | 1 | 0 | 9 |
| `dyn_em/module_diffusion_em.F` | 2 | 0 | 0 | 8 | 0 | 1 | 32 |
| `dyn_em/module_bc_em.F` | 1 | 0 | 0 | 0 | 0 | 0 | 0 |
| `share/module_bc.F` | 0 | 0 | 0 | 0 | 0 | 0 | 3 |
| `dyn_em/module_advect_em.F` | 0 | 0 | 0 | 0 | 0 | 0 | 0 in active paths (51 are in WENO, which is off) |
| `phys/physics_mmm/mp_wsm6.F90` (WSM6) | 32 | 9 | 1 | 0 | 1 | 0 | 31 |
| `phys/physics_mmm/mp_wsm6_effectRad.F90` | 1 | 0 | 0 | 0 | 0 | 0 | 1 |
| `phys/module_ra_rrtmg_lw.F` | 7 | 1 | 0 | 0 | 2 | 0 | 17 |
| `phys/module_ra_sw.F` (Dudhia) | 0 | 2 | 1 | 17 | 0 | 0 | 1 |
| `phys/module_radiation_driver.F` (per-point prep) | 8 | 8 | 1 | 67 | 27 | 0 | 8 |
| `phys/physics_mmm/sf_sfclayrev.F90` | 7 | 36 | 0 | 0 | 6 | 0 | 15 |
| `phys/module_sf_noahdrv.F`, `module_sf_noahlsm.F` | 21 | 17 | 2 | 0 | 1 | 0 | 32 |
| `phys/module_surface_driver.F` | 4 | 1 | 0 | 17 | 1 | 0 | 12 |
| `phys/physics_mmm/bl_ysu.F90` (d01) | 6 | 0 | 0 | 0 | 0 | 1 | 16 |
| `phys/module_fr_fire_core.F`, `_phys.F`, `_atm.F`, `_driver.F` | 26 | 12 | 0 | 1 | 0 | 4 | 19 |

Many of the radiation-driver and surface-driver hits are in branches your options don't take, or in once-per-run
setup. Replace only the calls on executed GPU paths, but always in both builds (same source). The WSM6 wrapper
(`module_mp_wsm6.F`), `module_sf_sfclayrev.F` and `module_bl_ysu.F` have no hits.

### 4.5 Bit-level verification tooling

1. **Bit-hash tracer (debug option).** At fixed checkpoints (after each call group in `solve_em`, per RK stage, and
   after the fire driver), compute for every state field an order-independent integer hash: the sum over elements
   of `INT(TRANSFER(x, 0_4), 8)` (64-bit integer arithmetic wraps and is associative). Log
   `(domain, step, checkpoint, field, hash)`. Integer sums are exact in any order, so the GPU computes them with an
   ordinary parallel reduction. Run CPU-REF and GPU-REPRO with the tracer and `diff` the logs: the first differing
   line names the step, the checkpoint and the field.
2. **Kernel shadow tests (debug build).** For a routine under test: bit-copy its inputs, run the CPU path
   (`if(target: .false.)`), run the GPU path, then compare outputs with **zero tolerance** and report the first
   mismatching index. Use this to bisect inside a checkpoint the tracer flagged.
3. **Restart windows.** CPU-REF writes hourly restarts (your `restart_interval = 60`). Start both builds from the
   same restart at interesting times and compare short windows:
   - 02:00, before ignition at 02:18;
   - 03:00, when the lateral boundary is updated;
   - the time radiation first sees fire-modified clouds.

   First confirm that CPU-REF restarted at T is bitwise equal to the continuous CPU-REF run (test R1 in
   [§19](#19-porting-plan-with-verification-gates)).
4. **Final acceptance.** A full 17 h GPU-REPRO run: `diffwrf` shows no differences in any of the 69 d02 frames, and
   `tign_g`, `fire_area`, `fuel_frac`, `fgrnhfx` and `ros` compare equal (`diffwrf` or an array `cmp`).

### 4.6 What reproducibility costs

- **No FMA:** most WRF kernels are limited by memory bandwidth, so the impact there is small. Column physics and the
  WENO fire stencils are more compute-bound and lose more.
- **Reproducible math:** slower than hardware intrinsics (double-precision evaluation). The cost concentrates in
  WSM6, RRTMG, sfclayrev, Noah and fire ROS.
- **How to quantify:** time GPU-REPRO against GPU-FAST per simulated hour. GPU-FAST can't meet the fire criterion
  (see §4.1 and E1), so GPU-REPRO is the production build unless E1 proves otherwise.

---

## 5. Acceleration on one GPU

### 5.1 Where the time goes

Per d02 step (repeated 183,600 times), for 38.7 M points:

| Part | Work |
|---|---|
| RK and acoustic dynamics | 3 RK stages. Each stage: step prep, advection of u, v, w, θ (h5/v3), pressure gradient, buoyancy, BCs. Plus 7 acoustic sub-steps (`advance_uv`, `advance_mu_t`, `advance_w` tridiagonal, `calc_p_rho`, BCs). |
| Scalar transport | 7 advected scalars (6 moist plus TKE) × 3 stages with the positive-definite scheme (`advect_scalar_pd`, 8 tile-sized 3D temporaries per call) |
| Turbulence | deformation, `tke_km`, `tke_rhs`, `horizontal_diffusion_2`, `vertical_diffusion_2` |
| Physics every step | WSM6, sfclayrev, Noah |
| Physics every 180 steps | RRTMG LW and Dudhia SW |
| Fire every step | 10.5 M cells: wind interpolation, 3-stage level-set RK with WENO5/ENO1, reinitialization, fuel burn-down, flux aggregation, `fire_tendency` |

Profile CPU-REF first (Phase 0) to rank these for your case. Porting order follows the call graph for correctness,
but tuning effort follows the profile.

### 5.2 Speed rules that don't change a bit

1. **Resident data:** all state of both domains stays on the GPU for the whole run. The only per-step transfers are
   the nest-forcing slabs; everything else is at output or input times ([§17](#17-hostdevice-sync-points-io-inputs-nesting)).
2. **No device allocation inside the time step:** use persistent scratch ([§5.3](#53-persistent-device-scratch)).
   On d02 every 3D temporary is ~164 MB, so allocating and freeing per call would dominate.
3. **Coalesced access:** map `i` (fastest index) to adjacent threads with `collapse(3)` over `j,k,i`. Physics runs
   one thread per column (656 k columns on d02, 202 k on d01).
4. **Safe optimizations:**
   - fuse independent loops;
   - run independent kernels concurrently (`nowait` plus `taskwait` before dependents);
   - tune registers (`-gpu=maxregcount`, per file);
   - change loop mapping.

   All of these leave each operation's inputs and order untouched.
5. **Forbidden optimizations:** algebraic rewrites, FMA, fast math, float atomics, reordered sums, or approximate
   intrinsics. They break R2–R7.
6. **No host round-trips for scalars:** keep maxima such as the CFL max on the device unless they're printed.

### 5.3 Persistent device scratch

- **`i1` scratch in `solve_em`:** 43 named arrays plus the 4D `moist_tend`/`moist_old` etc., about 8 GB at d02
  size. Upstream declares them as automatic stack arrays, recreated every call (`solve_em.F:168`). Change the
  generator (`gen_i1_decls` in `WRF/tools/gen_defs.c`) to emit **pointers remapped onto one pre-mapped device pool**,
  sized for the largest domain and shared by both domains (only one `solve_em` is active at a time):

  ```fortran
  ! generated i1_decl.inc (sketch)
  REAL, POINTER, CONTIGUOUS :: ru_tendf(:,:,:)
  ...
  ! generated i1_assoc.inc, after bounds are known
  ru_tendf(ims:ime,kms:kme,jms:jme) => scratch_pool(off_ru_tendf+1 : off_ru_tendf+n3d)
  ```

  `scratch_pool` is allocated and `target enter data map(alloc:)`-ed once at startup. Explicit-shape dummy
  arguments receive contiguous storage inside mapped memory, so OpenMP finds them present without copying. This
  also removes ~8 GB from the host stack.
- **Large local automatic arrays** (for example `fqx, fqy, fqz, fqxl, fqyl, fqzl, flux_out, ph_low` in
  `advect_scalar_pd`, `module_advect_em.F:6146-6157`; the per-`j` slabs in `advance_w`; driver locals): replace
  them with module-level work arrays allocated and mapped once at the maximum size, remapped the same way.

### 5.4 I/O and nest forcing

| Item | Cost | Action |
|---|---|---|
| d02 history every 15 min | device → host of the history fields, several GB per frame, once per 2,700 steps | negligible transfer. The **serial netCDF write** becomes visible once compute is fast: use I/O quilting (`nio_tasks_per_group ≥ 1`, extra MPI ranks on idle CPU cores; compute stays 1 GPU rank). Quilting doesn't change results. |
| Hourly restarts (both domains) | large writes | keep them in CPU-REF for restart-window testing. In production, raise `restart_interval` if you don't need them (no effect on results). |
| Nest forcing every d01 step | d01 slab covering the nest (~100 of 460 `j` rows, ~12 forced fields ≈ 0.1–0.2 GB) to host; d02 boundary arrays (width 5, ≈ 0.1 GB) to device | a few ms per d01 step, i.e. under 1 ms per d02 step. Port the interpolation only if the profile says so. |
| `wrfbdy_d01` every 3 h | small | — |

### 5.5 Measuring acceleration

- WRF prints `Timing for main: ... on domain N: X elapsed seconds` per step in `rsl.error.0000`. Compare CPU-REF and
  GPU-REPRO per domain and per simulated hour.
- Use Nsight Systems with NVTX ranges from the `BENCH_START/END` macros ([§20](#20-profiling-and-debugging-tools)) to
  get a labeled timeline. Any `memcpy` or `cudaMalloc` inside a step (other than nest forcing) is a defect.
- Use Nsight Compute on the top ~10 kernels: check achieved memory bandwidth against the GPU's peak.

---

## 6. Codebase map

### 6.1 Repository layout

```
wrf_gpu_port/
├── README.md            provenance: exact upstream commits
├── explain-wrf.md       this guide
├── WPS/                 WPS v4.6.0 (stays CPU)
└── WRF/                 WRF v4.6.0 (built-in WRF-Fire; Noah-MP vendored in phys/noahmp)
```

### 6.2 `WRF/` directories

| Directory | Code lines | Role | Touched by this port |
|---|---:|---|---|
| `dyn_em/` | 73k | ARW dynamical core: `solve_em.F`, advection, acoustic steps, diffusion, BCs | **Yes**: all time-step routines |
| `phys/` | 671k | Physics schemes and drivers, WRF-Fire, `physics_mmm/`, `noahmp/` | **Only the schemes in §13, drivers, fire** |
| `share/` | 51k | Mediation (I/O, nesting), `module_bc.F`, `solve_interface.F` | `module_bc.F`, sync points |
| `frame/` | 24k | Domain type, allocation, tiles, `integrate` loop | Mapping hooks; new `module_repro_math.F`, tracer, routing, pool |
| `external/` | 155k | RSL_LITE (MPI), I/O libraries, ESMF time | No (single rank) |
| `main/` | 16k | `wrf.F`, `real_em.F`, `module_wrf_top.F` | `module_wrf_top.F` (routing init, sync points) |
| `Registry/`, `tools/` | — / 11k | Registry tables and code generator | `gen_allocs.c`, `gen_defs.c` |
| `arch/` | 13k | `configure.defaults` compiler stanzas | New stanzas |
| `run/`, `test/em_fire/` | — | Runtime tables; ideal fire case | Test data |
| `chem/`, `hydro/`, `var/`, `wrftladj/` | 1.2M | Chem, Hydro, WRFDA, WRFPLUS | No |

### 6.3 Executables

| Executable | Built by | Role |
|---|---|---|
| `geogrid.exe`, `ungrib.exe`, `metgrid.exe` | `WPS/compile` | Real-data preprocessing (`GEOGRID.TBL.FIRE` gives the fire-grid fuels and topography) |
| `real.exe` | `./compile em_real` (CPU build) | `wrfinput_d01/d02`, `wrfbdy_d01` |
| **`wrf.exe`** | CPU-REF and GPU-REPRO builds | The model |
| `diffwrf` | built with WRF (`external/io_netcdf/diffwrf`) | Field-by-field comparison of two `wrfout` files |

---

## 7. Build system

### 7.1 How a build works

```
./configure          → reads arch/configure.defaults, you pick a stanza → writes configure.wrf
./compile em_real    → 1. builds tools/registry and runs it on Registry/Registry.EM → generates inc/*.inc
                          (declarations, allocations, halo code, I/O calls, argument lists)
                       2. phys/Makefile "submodules" target symlinks phys/noahmp/... into phys/ and run/
                       3. cpp-preprocesses each .F → .f90, compiles external/, frame/, share/, phys/, dyn_em/
                          into main/libwrflib.a
                       4. links main/wrf.exe, real.exe, diffwrf
```

- The compiler sees cpp output (`.f90`). When a directive seems to "do nothing", read the `.f90`.
- Build macros: `DM_PARALLEL` (MPI), `_OPENMP` (set by the compiler under `-mp`), `RWORDSIZE` (4, single
  precision), `EM_CORE`, and the new `REPRO_MATH`.

### 7.2 Stanzas to add

Start from the PGI stanza at `WRF/arch/configure.defaults:137` and add two stanzas with `nvfortran`/`nvc`, `dmpar`.
They differ only in the lines below:

```make
#ARCH    Linux x86_64, NVHPC nvfortran CPU-REF (bit-reproducible reference) # dmpar
SFC             =       nvfortran
SCC             =       nvc
CCOMP           =       nvc
DM_FC           =       mpif90
DM_CC           =       mpicc
FCOPTIM         =       -O2 -Kieee -Mnofma -Mnoflushz
ARCH_LOCAL      =       -DNONSTANDARD_SYSTEM_SUBR -DREPRO_MATH
OMP             =
...
#ARCH    Linux x86_64, NVHPC nvfortran GPU-REPRO (A100/H100) # dmpar
FCOPTIM         =       -O2 -Kieee -Mnofma -Mnoflushz
ARCH_LOCAL      =       -DNONSTANDARD_SYSTEM_SUBR -DREPRO_MATH
OMP             =       -mp=gpu -gpu=cc80,cc90,nofma -Minfo=mp
OMPCC           =       -mp
...
```

- Build **CPU-REF and GPU-REPRO in separate source trees** (or clean between builds). `real.exe` comes from any CPU
  build; it's the same program.
- `-mp` also turns on host OpenMP. The host tile loops then run with one thread (`OMP_NUM_THREADS=1`,
  `numtiles = 1`, [§21](#21-runtime-configuration)).
- The old `PGI accelerator` stanza (`configure.defaults:225`, `-ta=nvidia,cuda5.0,cc35`) is obsolete.
- A CMake build (`configure_new`, `compile_new`) also exists. The classic build is the reference here.

---

## 8. Program flow

```
main/wrf.F
 ├─ wrf_init                    namelist, alloc d01, read wrfinput_d01, start_domain (physics init)  [CPU]
 │                              → GPU: map + update-to-device all d01 state (§18)
 ├─ wrf_run → integrate(d01)    frame/module_integrate.F:8 (RECURSIVE)
 │    DO WHILE not stop time                                      ← 20,400 d01 steps
 │       med_setup_step
 │       open nests if due: alloc d02, med_nest_initial (reads wrfinput_d02, start_domain, fire init)  [CPU, t=0]
 │                              → GPU: map + update-to-device all d02 state
 │       med_before_solve_io    hourly restart, history (d02 only), wrfbdy_d01 read every 3 h     [CPU I/O]
 │       solve_interface → solve_em(d01)                           ← one d01 step            [GPU]
 │       med_after_solve_io
 │       med_nest_force(d01 → d02)   interpolate d01 onto d02 boundary arrays                [CPU + slab transfers]
 │       integrate(d02)  (recursive)
 │           DO 9 times: med_before_solve_io (d02 history), solve_em(d02)  ← 183,600 d02 steps [GPU]
 │       med_nest_feedback      returns immediately (feedback = 0)
 │    END DO
 └─ wrf_finalize
```

`solve_interface` passes every state array to `solve_em` as an **explicit argument** (generated
`actual_new_args.inc`). The dynamics kernels therefore see plain arrays, which is what makes the data-mapping design
in §18 work.

---

## 9. Core data structures and index conventions

### 9.1 The domain type

- `TYPE(domain)` (`WRF/frame/module_domain_type.F`) holds one domain: hundreds of Registry-generated
  `REAL, POINTER` arrays (`grid%u_2`, ...), tiling (`num_tiles`, `i_start(:)`, ...), nest pointers and the clock.
- Allocation is in `alloc_space_field` (`frame/module_alloc_space_*.F`, generated `allocs.inc`), deallocation in
  `dealloc_space_field` (`frame/module_domain.F:1729`, `deallocs.inc`). **These generated files are the single
  choke point for device residency** (§18.2).
- Inactive packages get minimal allocations, so device memory follows your options automatically.
- `config_flags` (`TYPE(grid_config_rec_type)`) holds the namelist values for the current domain. **Never reference
  it inside a kernel**: copy the scalars you need first.

### 9.2 Time levels, tracers, scratch

| Kind | Examples | Notes |
|---|---|---|
| Two time levels | `u_1/u_2`, `v_*`, `w_*`, `t_*` (moist θ here), `ph_*`, `mu_*`, `tke_*` | `_2` current/predicted, `_1` saved |
| 4D tracers | `moist(ims:ime,kms:kme,jms:jme,num_moist)` with QV, QC, QR, QI, QS, QG for WSM6 | species index `P_QV`...; `PARAM_FIRST_SCALAR = 2` |
| Base state, metrics | `mub`, `phb`, `pb`, `alb`, `c1h/c2h/c1f/c2f`, `msf*`, `rdx`, `rdy`, `rdnw`, `fnm`, `fnp` | constant |
| Boundary arrays | `u_bxs/bxe/bys/bye` and tendencies `u_btxs...` (same for v, w, t, ph, mu, moist...) | d01 from `wrfbdy`; d02 from nest forcing |
| `i1` scratch | 43 named (`ru_tendf`, `t_tend`, `ph_tend`, `a`, `alpha`, `gamma`, `cqu`, `th_phy`, `p_phy`, `dz8w`, ...) plus the 4D `moist_tend`, `moist_old`, ... | automatic in `solve_em`, to be made persistent (§5.3) |
| Fire grid (d02) | 39 arrays `*i*j`: `lfn`, `lfn_0/1/2`, `tign_g`, `fuel_frac`, `fire_area`, `uf`, `vf`, `zsf`, `dzdxf/dzdyf`, `nfuel_cat`, `ros`, `fgrnhfx`, `fgrnqfx`, `fcanhfx`, `fcanqfx`, `fmc_g`, `bbb`, `betafl`, `phiwc`, `r_0`, `fgip`, `ischap`, `iboros`, `fuel_time`, ... | bounds `ifms:ifme, jfms:jfme` |

### 9.3 Index conventions

```
ids,ide, jds,jde, kds,kde   domain  (staggered sizes: e_we, e_sn, e_vert)
ims,ime, jms,jme, kms,kme   memory  (allocated bounds: patch + halo)
ips,ipe, jps,jpe, kps,kpe   patch   (this rank; = domain for 1 rank)
its,ite, jts,jte, kts,kte   tile    (loop bounds; = patch with numtiles = 1)
```

- **Memory order `(i,k,j)`**: `i` fastest, then `k`, then `j`. Loops are `DO j / DO k / DO i`. Map `i` to adjacent
  GPU threads.
- **Arakawa C staggering:** `u` to `ide`, `v` to `jde`, `w`/`ph` to `kde`. Mass points end at `ide-1`, `jde-1`,
  `kde-1` (`itf = MIN(ite,ide-1)`). Keep all bounds exactly.
- **Fire subgrid bounds** come from `get_ijk_from_subgrid`: `ifds..ifde`, `ifms..ifme`, `ifts..ifte`.

---

## 10. The Registry

`WRF/Registry/Registry.EM` (includes `Registry.EM_COMMON` and `registry.*`) drives the code generator in
`WRF/tools/`. Search it first whenever you need to know what a field is, which scheme allocates it, or which streams
and halos include it.

| Entry | Example | Meaning |
|---|---|---|
| `state` | `state real u ikjb dyn_em 2 X i0rhusdf=(bdy_interp:dt) "U" ...` | field, dims (`b` = boundary arrays), 2 time levels, stagger, **I/O streams and nest flags** (`i0` input, `r` restart, `h` history, `d`/`u`/`f`/`s` nest down/up/force/smooth) |
| `i1` | `i1 real ru_tendf ikj dyn_em 1 X` | per-step scratch in `solve_em` |
| `package` | `package wsm6scheme mp_physics==6 - moist:qv,qc,qr,qi,qs,qg;state:re_cloud,re_ice,re_snow` | fields allocated only for that option |
| `halo`, `period` | `halo HALO_EM_A dyn_em 8:ru,rv,...` | generated MPI exchanges (no-ops with 1 rank) |
| `rconfig` | `rconfig integer fire_upwinding namelist,fire max_domains 9 ...` | namelist variable → `config_flags%...` |

Generated files the port touches: `allocs.inc`/`deallocs.inc` (`tools/gen_allocs.c`), `i1_decl.inc`
(`tools/gen_defs.c`), plus new generated includes for update-to/from-device lists (all state; per stream `h`, `r`,
`b`; nest-forced `f`).

---

## 11. The dynamical core time step

RK3 large step with split-explicit acoustic sub-steps (vertically implicit for `w`/`ph`). For your case,
`num_sound_steps = 4` on both domains (`solve_em.F:441-458`), so each step does:

| RK stage | Stage length | Acoustic sub-steps |
|---|---|---|
| 1 | `dt/3` | 1 |
| 2 | `dt/2` | 2 |
| 3 | `dt` | 4 |

Physics tendencies are computed once per step (RK stage 1); microphysics runs after the RK loop.

### 11.1 `solve_em` in order

Line numbers refer to `WRF/dyn_em/solve_em.F` unless another file is named. The "Your case" column uses: ✓ runs;
"no-op" for a halo with 1 rank; "off" when not executed with your options.

| # | Step | Routines | Your case | Pattern (§12) |
|---|---|---|---|---|
| 0 | Setup | `get_ijk_from_grid`, `set_tiles` (`:286-349`) | ✓ (host scalars) | — |
| 1 | Pre-step halos (`:387-421`) | `HALO_EM_SCALAR_E_*`, ... | no-op | — |
| 2 | First-step setup (`:483-544`) | `zero_bdytend`, `initialize_moist_old`, `set_physical_bc3d(moist_old)` | ✓ | A, G |
| RK | `Runge_Kutta_loop` (`:573`) | | | |
| 3 | Prep | `rk_step_prep` (`module_em.F:37`) → `calculate_full`, `calc_mu_uv`, `couple_momentum`, `calc_ww_cp`, `calc_cq`, `calc_alt`, `calc_php` | ✓ | A; `calc_ww_cp` C |
| 4 | BCs (`:703-776`) | `rk_phys_bc_dry_1`, `set_physical_bc3d(rho, al, ph_2)` | ✓ (halo no-op) | G |
| 5 | **Physics, stage 1 only** | `first_rk_step_part1`, `first_rk_step_part2` (§11.2) | ✓ | §13, §14 |
| 6 | Large-step tendencies | `rk_tendency` (`module_em.F:190`): `advect_u/v/w`, `advect_scalar`(θ), `rhs_ph`, `horizontal_pressure_gradient`, `pg_buoy_w`, `w_damp`, `coriolis`, `curvature` | ✓ (no 6th-order diffusion, no Rayleigh) | A, **B**, F |
| 7 | Combine and lateral BCs | `relax_bdy_dry` (stage 1), `rk_addtend_dry`, `spec_bdy_dry` | ✓ | A, G |
| 8 | Acoustic prep | `small_step_prep`, `calc_p_rho`, `calc_coef_w` (`module_small_step_em.F:16,438,570`) | ✓ | A, C |
| 9 | BCs (`:1171-1258`) | `set_physical_bc3d/2d(...)` | ✓ | G |
| SS | `small_steps` loop (`:1261`) | runs 1, 2, 4 times per stage | | |
| 10 | Horizontal momentum | `advance_uv` (`:654`) | ✓ | A |
| 11 | BC | `spec_bdyupdate(u,v)` | ✓ | G |
| 13 | Mass and θ | `advance_mu_t` (`:969`) | ✓ | C |
| 14 | BC | `spec_bdyupdate(t_2, mu_2, muts)` | ✓ | G |
| 15 | Vertical implicit | `advance_w` (`:1178`), **incl. the `damp_opt = 3` block (`:1445`)** | ✓ | **C** |
| 16 | Flux accumulation | `sumflux` | ✓ | A |
| 17 | BC | `spec_bdyupdate_ph`, `zero_grad_bdy` (d01), `spec_bdyupdate(w)` | ✓ | G |
| 18 | Diagnose | `calc_p_rho` | ✓ | A (uses `rp_pow`) |
| 19 | BCs | `set_physical_bc*` (`:1654-1710`) | ✓ | G |
| 20 | Finish acoustic | `calc_mu_uv_1`, `small_step_finish`, BCs on `ru_m`, `rv_m`, `ww_m`, `mut`, `muts` | ✓ | A |
| 21 | Positive-definite pre-update | `rk_update_scalar_pd` for moist, TKE (`:1850-2150`) | ✓ | A |
| 23 | Scalar transport | `rk_scalar_tend` → `advect_scalar_pd`; `relax_bdy_scalar`, `spec_bdy_scalar`, `rk_update_scalar`, `flow_dep_bdy`, `bound_tke` (`:2195-2948`) | ✓ (6 moist, plus TKE on d02) | A, B, I |
| 24 | Diagnose p, ρ, φ | `calc_p_rho_phi` (`:2956`) | ✓ (`hypsometric_opt = 2`: `rp_log`/`rp_exp`) | A/C |
| 25 | Between stages | `rk_phys_bc_dry_2`, `set_physical_bc3d` (tracers) | ✓ (halos no-op, polar off) | G |
| 26 | Post-RK | `advance_ppt`, `phy_prep_part2` (`:3556-3601`) | ✓ (`advance_ppt` is cumulus bookkeeping; confirm it's trivial with `cu_physics = 0`) | A |
| 27 | **Microphysics** | `moist_physics_prep_em` → `microphysics_driver` (WSM6) → `microphysics_zero_outb/outa` → `moist_physics_finish_em` (`:3661-4096`) | ✓ | E |
| 28 | Re-diagnose | `calc_p_rho_phi` (`:4186`) | ✓ | A/C |
| 29 | End-of-step BCs | `set_phys_bc_dry_2`, **`spec_bdy_final`** for all prognostic fields (`:4452-4700`) | ✓ | G |
| 30 | Surface w | `set_w_surface` (`:4731`) | ✓ | A |
| 31 | Diagnostics | `after_all_rk_steps` → `diagnostics_driver` | check what runs with your options | A |
| 33 | Firebrand spotting (`:4847`) | | off | — |

### 11.2 Physics steps within RK stage 1

`first_rk_step_part1` (`dyn_em/module_first_rk_step_part1.F`):

1. `init_zero_tendency`.
2. `phy_prep`.
3. Radiation, when the 1-min alarm rings: `pre_radiation_driver` and `radiation_driver` → RRTMG LW and Dudhia SW
   (`:236`, `:263`).
4. `surface_driver` → sfclayrev and Noah (`:593`).
5. `pbl_driver` → YSU (d01 only) (`:1112`).
6. **`fire_driver_em_step` (d02, `:1354`)**.
7. `cumulus_driver` is called but `cu_physics = 0`.

`first_rk_step_part2` (`dyn_em/module_first_rk_step_part2.F`):

1. `calculate_phy_tend`.
2. `compute_diff_metrics`, `cal_deform_and_div`, `calculate_km_kh` (`smag2d_km` d01, `tke_km` d02), `phy_bc`.
3. **`update_phy_ten` (`:793`)**, which adds all physics and fire tendencies (`rthfrten`, `rqvfrten`).
4. `tke_rhs` (d02).
5. `vertical_diffusion_2` (d02 only: it's called only when `bl_pbl_physics = 0`).
6. `horizontal_diffusion_2` (both).

---

## 12. Kernel patterns and how to port each one

Every porting pattern below must also satisfy the reproducibility contract in §4.3.

### Pattern A: pointwise 3D/2D stencil

Example: `calc_php` (`module_big_step_utilities_em.F:1227`).

```fortran
      !$omp target teams loop collapse(3)
      DO j=jts,jtf
      DO k=kts,ktf
      DO i=its,itf
        php(i,k,j) = 0.5*(phb(i,k,j)+phb(i,k+1,j)+ph(i,k,j)+ph(i,k+1,j))
      ENDDO
      ENDDO
      ENDDO
```

- Keep the loop order `j, k, i`. Every scalar temporary in the loop body is `private`: use `default(none)` while
  porting.
- Copy `config_flags%...` into local scalars before the region. Pass arrays as arguments; never use `grid%...`
  inside a kernel.
- `target teams loop` is the preferred `nvfortran` form. `target teams distribute parallel do` is the fallback.

### Pattern B: rolling buffer across `j` (advection) — restructure preserving bits

`advect_scalar` (`module_advect_em.F:3195-3290`) and the other advection routines compute y-fluxes into a two-slab
buffer `fqy(i,k,jp1/jp0)`. Each `j` iteration updates `tendency(i,k,j-1)`, then swaps the slabs, creating a
dependency from one `j` to the next (60 swaps in the file). Promote the buffer to a 3D work array (persistent scratch,
§5.3) and split the loop in two kernels. The expressions are unchanged, so **the result is bitwise identical**.

```fortran
!$omp target teams loop collapse(3) private(vel)
DO j = j_start, j_end+1            ! kernel 1: every y-face flux; same per-j branch selection
 DO k = kts, ktf
  DO i = i_start, i_end
    IF ((j >= j_start_f) .AND. (j <= j_end_f)) THEN
       vel = rv(i,k,j)
       fqy3(i,k,j) = vel*flux6(field(i,k,j-3),...,field(i,k,j+2),vel)
    ELSE IF (j == jds+1) THEN
       fqy3(i,k,j) = 0.5*rv(i,k,j)*(field(i,k,j)+field(i,k,j-1))
    ELSE IF ...                      ! other boundary-degraded branches unchanged
    END IF
  END DO
 END DO
END DO

!$omp target teams loop collapse(3) private(mrdy)
DO j = j_start+1, j_end+1          ! kernel 2: divergence, same expression as the original
 DO k = kts, ktf
  DO i = i_start, i_end
    mrdy = msftx(i,j-1)*rdy
    tendency(i,k,j-1) = tendency(i,k,j-1) - mrdy*(fqy3(i,k,j)-fqy3(i,k,j-1))
  END DO
 END DO
END DO
```

`advect_scalar_pd` (positive-definite, used for your moist species and TKE) already uses full 3D temporaries
(pattern A with persistent scratch). Its limiter is pointwise.

### Pattern C: vertical recurrence or tridiagonal solve

Examples: `advance_w`, `advance_mu_t`, `calc_ww_cp`, `calc_coef_w`, hydrostatic parts of `calc_p_rho_phi`,
`vertical_diffusion_2`, and the YSU/Noah column solvers. Parallelize over `(j,i)`; each thread runs `k`
sequentially, in the original order. Promote per-`j` slab scratch such as `rhs(its:ite,kts:kte)` in `advance_w` to
`(i,k,j)` scratch.

**Watch for hidden shared scratch.** In `advance_w`'s `damp_opt = 3` block (`module_small_step_em.F:1445-1456`),
`dampwt(k)` is a local 1D array overwritten for every `i`. It's really a per-point temporary, so it must become a
private scalar. It also calls `sin` (→ `rp_sin`), and `pi` comes from `4.*atan(1.)` at `:1283` (→ `rp_atan`, R8).

### Pattern D: column physics with 1D locals (thread per column)

Examples: RRTMG LW, Dudhia SW, Noah (`lsm` → `SFLX`). Use `collapse(2)` over `j,i`, private column arrays, and
`!$omp declare target` on the column routine and everything it calls. Module tables must be `declare target` and
copied once (§18.5). Raise the device per-thread stack limit if large column routines need it (see the NVHPC runtime
docs), or convert big locals to persistent work arrays. Avoid automatic arrays inside device routines: they use the
slow device heap.

### Pattern E: slab physics (MMM wrappers)

WSM6 (`module_mp_wsm6.F` → `physics_mmm/mp_wsm6.F90`), sfclayrev (`module_sf_sfclayrev.F` →
`physics_mmm/sf_sfclayrev.F90`) and YSU (`module_bl_ysu.F` → `physics_mmm/bl_ysu.F90`) loop `DO j`, copy an
`(its:ite,kts:kte)` slab and call `*_run`, which loops `i` inside. Minimal port: collapse over `(j,i)` and call
`*_run` with a one-column slab (`its = ite = i`), with the wrapper's slab arrays private per column. The `_run`
internals are unchanged apart from `declare target` and `rp_*` substitutions. Per-column arithmetic is identical to
the slab version, because columns are independent.

### Pattern F: reductions

- `w_damp` (`module_big_step_utilities_em.F:2503`): CFL maxima via `reduction(max:)` (exact). Move its in-loop
  warning `WRITE` out of the kernel: detect on the device, then locate and print on the host in the rare case it
  fires.
- Fire `tend_ls` `tbound`: `reduction(min:)` (exact).
- **No float `+` reductions across threads.** All float sums stay sequential inside a thread (R6).

### Pattern G: boundary-zone and strip loops

`set_physical_bc2d/3d`, `spec_bdyupdate(_ph)`, `spec_bdy_final`, `relax_bdytend`, `spec_bdytend`, `flow_dep_bdy`
(`share/module_bc.F`) and `relax_bdy_dry`/`spec_bdy_dry` (`dyn_em/module_bc_em.F`) run inside the acoustic loop, so
port them together with the kernels they bracket.

### Pattern H: 2D fire-grid stencils

`collapse(2)` over `j,i` on the fire grid (§14).

### Pattern I: loops over species

`rk_scalar_tend`/`rk_update_scalar` are called once per species, so each species launches its own kernels. That's
fine; batching species is an optional optimization.

---

## 13. Physics in this case

### 13.1 Schemes, files and patterns

| Scheme (option) | Domains | Entry → core | Pattern | Notes |
|---|---|---|---|---|
| WSM6 (`mp 6`) | both | `microphysics_driver` → `wsm6` (`phys/module_mp_wsm6.F`, 240 lines) → `mp_wsm6_run` (`physics_mmm/mp_wsm6.F90`, 2449), `mp_wsm6_effectRad_run` | E | many `exp`/`log`/`pow` (§4.4); sedimentation sub-stepping is sequential per column (keep it so) |
| RRTMG LW (`ra_lw 4`) | both, every 1 min | `radiation_driver` → `RRTMG_LWRAD` (`phys/module_ra_rrtmg_lw.F`, 14.6k) | D | `kind_rb = kind(1.0)` (single precision; the `RWORDSIZE` selection above it is disabled by `#if 0`); k-distribution tables from `RRTMG_LW_DATA` (module data → device once); McICA generator (integer, deterministic) |
| Dudhia SW (`ra_sw 1`) | both, every 1 min | `radiation_driver` → `SWRAD` (`phys/module_ra_sw.F`, 538) | D | trig for solar geometry (`rp_sin/cos`) |
| Radiation prep | both | `radiation_driver` per-point loops (cloud fraction `icloud = 1`, solar zenith, tendency conversion) | A/D | only the branches your options take |
| sfclayrev (`sfclay 1`) | both | `surface_driver` → `SFCLAYREV` (`phys/module_sf_sfclayrev.F`) → `sf_sfclayrev_pre_run`/`_run` (`physics_mmm/sf_sfclayrev.F90`) | E (2D) | many `log` (stability functions) |
| Noah LSM (`sf_surface 2`) | both | `surface_driver` → `lsm` (`phys/module_sf_noahdrv.F`) → `SFLX` (`phys/module_sf_noahlsm.F`) | D (point) | soil tables from `run/*.TBL` (module data); `pow` in soil hydraulics |
| YSU (`bl_pbl 1`) | d01 | `pbl_driver` → `ysu` (`phys/module_bl_ysu.F`) → `bl_ysu_run` (`physics_mmm/bl_ysu.F90`) | E | tridiagonal per column (C inside) |
| LES turbulence | d02 | `module_diffusion_em.F` (`tke_km`, `tke_rhs`, `horizontal_diffusion_2`, `vertical_diffusion_2`) | A, C | `m_opt = 1` stress outputs |
| Glue | both | `phy_prep`, `calculate_phy_tend`, `update_phy_ten` (`phys/module_physics_addtendc.F`), `moist_physics_prep_em`/`finish_em` | A | every step |

### 13.2 Physics porting notes

- **Driver tile loops:** keep them (1 tile). Put target regions inside the scheme loops, or around the call when the
  scheme is fully `declare target`.
- **Module tables:** WSM6 constants, RRTMG coefficients, Noah parameters (`VEGPARM`, `SOILPARM`, `GENPARM`) and fire
  fuel tables are built on the host at init. Mark them `declare target` and bit-copy them after init.
- **In-kernel errors:** replace `wrf_error_fatal`/`WRITE` inside kernels with error flags (reduced with `max`) that
  are checked on the host.
- **Existing GPU code in the tree** (`module_ra_rrtmg_lwf.F`/`swf.F` CUDA Fortran, `*_accel.F` OpenACC) belongs to
  **different schemes** (options 24 etc.). It's useful only as a reference for how column physics was mapped to
  GPUs; don't switch schemes.

---

## 14. WRF-Fire in this case

### 14.1 Concepts

- **Fire grid:** 25 m, `sr_x = sr_y = 4` (3240 × 3240).
- **Level-set:** `lfn ≤ 0` is burning, advanced by `∂lfn/∂t + ROS·|∇lfn| = 0` with RK3 in time,
  `fire_upwinding = 9` (hybrid WENO5/ENO1; WENO within `fire_lsm_band_ngp = 4` cells of the front), artificial
  viscosity 0.4, and reinitialization every step (1 iteration, scheme 4).
- **ROS:** BEHAVE/Rothermel (`fire_sprd_mdl = 1`) from the 53-category fuel tables (`namelist.fire`), fuel moisture
  0.08, terrain slope (`dzdxf`, `dzdyf` from WPS), and 1 m wind from the atmosphere by log profile from 60 m
  (`fire_lsm_zcoupling`). `fire_advection = 1` projects the fireline particle speed on the normal.
- **Burn-down:** `tign_g` and exponential fuel decay give `fuel_frac`, which gives heat and moisture fluxes. These
  are averaged to the atmospheric grid (`grnhfx`, `grnqfx`, `canhfx`, `canqfx`), spread vertically (extinction depth
  50 m) into `rthfrten`/`rqvfrten`, and added by `update_phy_ten`.
- **Ignition:** one circle of radius 100 m, active 8280–9080 s.

### 14.2 Files

| File | Lines | Content |
|---|---:|---|
| `phys/module_fr_fire_driver_wrf.F` | 149 | `fire_driver_em_init` (ifun 1–2), `fire_driver_em_step` (ifun 3–6, then `fire_tendency`) |
| `phys/module_fr_fire_driver.F` | 1672 | `fire_driver_em` (stages, fire halos), `fire_driver_phys` (interpolation, calls `fire_model`, flux aggregation) |
| `phys/module_fr_fire_model.F` | 552 | `fire_model`: per-stage logic, time step |
| `phys/module_fr_fire_core.F` | 2402 | `prop_ls_rk3`, `tend_ls`, `reinit_ls_rk3`, `advance_ls_reinit`, `select_*` (ENO/WENO), `speed_func`, `ignite_fire`, `fuel_left`, `tign_update`, `calc_flame_length` |
| `phys/module_fr_fire_phys.F` | 1672 | `type fire_params` (pointer components), `init_fuel_cats`, `read_namelist_fire`, `set_fire_params`, `fire_ros`, `heat_fluxes` |
| `phys/module_fr_fire_atm.F` | 373 | `fire_tendency` |
| `phys/module_fr_fire_util.F` | 1646 | interpolation atm↔fire, `sum_2d_cells`, `continue_at_boundary`, module-level flags |

### 14.3 Per-step sequence (d02, `module_first_rk_step_part1.F:1343-1360`)

```
fire_driver_em_step                                             module_fr_fire_driver_wrf.F:66
 └─ fire_driver_em(ifun = 3..6)                                 module_fr_fire_driver.F:46
     ifun=3: interpolate_atm2fire → uf, vf (log profile, zcoupling); ignition bookkeeping
     ifun=4: fire_model time step:
               prop_ls_rk3: 3 stages of tend_ls (WENO5/ENO1, tbound min)       core.F:1271
               tign_update, calc_flame_length
               reinit_ls_rk3 (1 iteration)                                     core.F:1510
               ignite_fire (active 8280-9080 s)                                core.F:85
     ifun=5: copy lfn_out → lfn
     ifun=6: fuel_left (2×2 subcells), heat_fluxes, sum_2d_cells → grnhfx, grnqfx, canhfx, canqfx
 └─ fire_tendency → rthfrten, rqvfrten                          module_fr_fire_atm.F:112
```

The fire halo includes (`HALO_FIRE_*`) are no-ops with one rank. The fuel-moisture stages (`advance_moisture`,
`fuel_moisture`) aren't executed (`fmoist_run = F`).

### 14.4 Fire porting notes (all bit-preserving)

| Issue | Where | Fix |
|---|---|---|
| 2D stencils | `tend_ls`, stage updates in `prop_ls_rk3`, `advance_ls_reinit`, `tign_update`, `calc_flame_length`, `fire_ros`, `heat_fluxes`, `set_fire_params`, interpolation | Pattern H |
| `tbound` stable-dt | `tend_ls`, combined at `core.F:1489` | `reduction(min:)` (exact) |
| Per-cell functions | `select_*`, `speed_func`, `fire_ros`, `fuel_left_cell_*`, `nrm2` | `!$omp declare target`; `rp_*` for `exp`/`log`/`pow`/`tanh` |
| `fp%vx`, `fp%zsf`, ... pointer components | `type fire_params`, `module_fr_fire_phys.F:20-30` | local pointer aliases or explicit array arguments; don't map `fp` |
| Module flags and fuel tables (`fire_upwinding`, `fire_viscosity`, `windrf`, `fgi`, `savr`, ...) | `module_fr_fire_util`, `module_fr_fire_phys` | `declare target`; `target update to` after init |
| `sum_2d_cells` (fire → atmosphere averaging) | `module_fr_fire_util.F` | one thread per atmospheric cell, **sequential subcell sum in the original order** (R6) |
| `fire_tendency` vertical distribution | `module_fr_fire_atm.F:112` | parallel over `(i,j)`, `k` inside |
| `ignite_fire` distance tests, ignited counts | `core.F:85,260`; `wrf_dm_maxval` in `fire_driver_phys` | per-cell kernel; integer `+` reduction for counts |
| `!$OMP SINGLE`/`CRITICAL`, messages, `write_array_m` | `fire_driver_phys` | stay on the host outside kernels (`fire_print_msg = 0`) |
| `continue_at_boundary` | `module_fr_fire_util.F` | strip kernel (G) |

---

## 15. Boundary conditions

| Domain | Type | Code | Data |
|---|---|---|---|
| d01 | specified (`spec_zone 1`, `relax_zone 4`) | `relax_bdy_dry`, `spec_bdy_dry` (`dyn_em/module_bc_em.F`); `relax_bdytend`, `spec_bdytend`, `spec_bdyupdate`, `spec_bdy_final`, `flow_dep_bdy`, `zero_grad_bdy` (`share/module_bc.F`) | `*_bxs...`/`*_btxs...` from `wrfbdy_d01`, every 3 h → update to device |
| d02 | nested | same routines | boundary arrays from `med_nest_force` every d01 step → update to device |
| both | lower w, upper damping | `set_w_surface`; `damp_opt = 3` in `advance_w`; `w_damp` | — |

---

## 16. MPI and tiles on a single GPU

- **One MPI rank:** RSL_LITE skips all halo packing when there's a single task (`external/RSL_LITE/c_code.c` checks
  `np_y > 1` / `np_x > 1`), so every `HALO_*` include is a no-op. No periodic BCs are used either. The single-GPU
  port needs **no communication work**.
- **One tile:** `numtiles = 1` and `OMP_NUM_THREADS = 1` make the 178 host tile loops run once, so each target region
  covers the whole patch.
- **Multi-GPU later (not now):** one rank per GPU, device-side pack/unpack in `RSL_LITE` (`f_pack.F90`, generated
  by `gen_comms.c`), optionally CUDA-aware MPI. The bitwise requirement then also needs decomposition independence
  (test R0).

---

## 17. Host/device sync points: I/O, inputs, nesting

| Event | Where | Frequency (your case) | Data movement |
|---|---|---|---|
| d01 initialized | after `wrf_init` | once | update to device, all d01 state |
| d02 opened | after `med_nest_initial` (`frame/module_integrate.F:351`) | once (t = 0) | update to device, all d02 state (incl. fire grid) |
| d02 history | before `med_hist_out` (`share/mediation_integrate.F`) | every 15 min | update from device, history-stream fields (Registry `h`) |
| Restarts | before `med_restart_out` | hourly | update from device, restart-stream fields (Registry `r`), both domains |
| d01 lateral BCs | after `med_latbound_in` | every 3 h | update to device, d01 boundary arrays |
| **Nest forcing** | around `med_nest_force` | every d01 step (20,400 times) | **before:** update from device the d01 nest-forced fields (Registry `f`) over the `j` rows covering d02. **After:** update to device the d02 boundary arrays and any other field the forcing writes. |
| Nest feedback | `med_nest_feedback` | — | none (`feedback = 0`) |
| Time series | `calc_ts` | only if a `tslist` file is present | port it, or update just those points |

**Input safety rule:** after an input, update to the device **only the fields that input wrote** (lists generated from
the Registry streams). Never push all host state to the device without first pulling it, or you'll overwrite newer
device values with stale host copies.

---

## 18. GPU data-management design

### 18.1 Residency model

```
host (CPU)                                         device (GPU)
ALLOCATE grid%x        ── enter data map(alloc) ─▶ device copy
init on CPU (d01; later d02 incl. fire)
                       ── target update to (all) ▶ state valid on device
                                                   ┌─────────── time loop ────────────┐
                                                   │ solve_em(d01), solve_em(d02) ×9  │
                                                   │ scratch pool: mapped once         │
                                                   │ nest forcing: slab ↔ per d01 step │
                                                   └───────────────────────────────────┘
output due             ◀─ target update from (stream) ─
wrfbdy read            ── target update to (bdy) ─▶
DEALLOCATE grid%x      ── exit data map(delete) ──▶
```

The device copy is authoritative during the run.

### 18.2 State arrays: map at allocation

Extend `WRF/tools/gen_allocs.c` so that each generated `ALLOCATE(grid%x(...))` in `allocs.inc` is followed by
`!$omp target enter data map(alloc: grid%x)`, and each `DEALLOCATE(grid%x)` in `deallocs.inc` is preceded by
`!$omp target exit data map(delete: grid%x)`. Also generate:

- `update_device_all.inc` and `update_host_all.inc` (every allocated field);
- per-stream lists: history `h`, restart `r`, boundary `b`, nest-forced `f`.

Kernels receive plain array arguments, so OpenMP finds the device copies by host address. The rule is **never
reference `grid%...` inside a target region**.

### 18.3 Scratch

The persistent pool for `i1` arrays and large local automatic arrays is described in §5.3. During bring-up, before
the pool exists, `!$omp target data map(alloc: ...)` around a routine is acceptable. **Any array that isn't mapped is
implicitly mapped `tofrom` at every target construct**, meaning silent copies on every launch.

### 18.4 Local arrays inside routines

Wrap every routine that uses local arrays in kernels with `!$omp target data map(alloc: ...)`, or switch them to pool
arrays. If `nvfortran` supports OpenMP 5.1 `defaultmap(present)`, use it during development so a missing mapping
becomes an error instead of a copy.

### 18.5 Module-level data

Mark module tables used in kernels `!$omp declare target(...)`. Allocatable module tables get
`!$omp target enter data map(to: ...)` after init; fixed-size ones get `!$omp target update to(...)`.

### 18.6 Incremental porting with islands

While a routine `R` is not yet ported, bracket its call with `target update from(<inputs of R>)` before and
`target update to(<outputs of R>)` after. Start with everything on the CPU and all state mapped; that build must be
**bitwise equal to CPU-REF** (Phase 1). Port routines in call-graph order and delete islands as you go. The
`if(target: flag)` clause runs a kernel on the host for A/B tests.

---

## 19. Porting plan with verification gates

This section is the overview. [plan.md](plan.md) breaks each phase into tasks, kernels, tests and gates.

Every gate uses the tools in §4.5. **"Bitwise" means the bit-hash logs are identical and `diffwrf` shows no
differences.**

| Phase | Work | Gate |
|---|---|---|
| **0. Reference and harness** | (a) `module_repro_math` plus call-site substitution (§4.4), exhaustive function tests. (b) CPU-REF stanza and build. (c) Bit-hash tracer and shadow-test switch. (d) **R0:** CPU-REF 1 rank vs N ranks, 30 min window: bitwise? (decides how CPU-REF may be run). (e) **R1:** CPU-REF restart at T vs continuous: bitwise? (f) Full 17 h CPU-REF run: this is the reference. **E0** vs your original run; **E1** 1-ulp sensitivity. (g) Profile CPU-REF; measure memory (`alloc_space_field`). | R0 and R1 pass; reference archived; E0/E1 documented |
| **1. GPU infrastructure** | GPU-REPRO stanza; mapping in `gen_allocs.c`; generated update lists; scratch pool; startup option check (§2.4); islands around the whole `solve_em`; `numtiles = 1` | GPU-REPRO (all compute still on the CPU) is **bitwise** equal to CPU-REF |
| **2. Dynamics** | Call order: `rk_step_prep` → BCs → `rk_tendency` (advection A+B, PGF, buoyancy, `w_damp`) → `rk_addtend_dry` → acoustic (`small_step_prep`, `calc_p_rho`, `calc_coef_w`, `advance_uv`, `advance_mu_t`, `advance_w`, `sumflux`, `small_step_finish`) → scalar transport (`rk_update_scalar_pd`, `advect_scalar_pd`, `rk_update_scalar`, `flow_dep_bdy`, `bound_tke`) → `calc_p_rho_phi` → `spec_bdy_final` → turbulence (`smag2d_km`, `tke_km`, `tke_rhs`, `horizontal_diffusion_2`, `vertical_diffusion_2`) | each kernel: shadow test 0 ulp; tracer bitwise over 100 steps of both domains |
| **3. Physics** | glue (`phy_prep`, `calculate_phy_tend`, `update_phy_ten`, moist prep/finish) → WSM6 → sfclayrev → Noah → YSU (d01) → radiation prep → Dudhia SW → RRTMG LW | same, and a window including radiation calls (tracer bitwise over ≥ 2 radiation calls) |
| **4. WRF-Fire** | `interpolate_atm2fire`, `set_fire_params`, `prop_ls_rk3`/`tend_ls`, `reinit_ls_rk3`, `tign_update`, `calc_flame_length`, `ignite_fire`, `fuel_left`, `heat_fluxes`, `sum_2d_cells`, `fire_tendency`, fuel tables and flags | restart window 02:00–03:00 (covers ignition): bitwise, `tign_g`/`fire_area` identical |
| **5. Remove islands; sync points** | `diagnostics_driver` items, nest-forcing slab transfers, output and bdy updates (§17); verify no per-step memcpy or malloc | full 17 h GPU-REPRO: **bitwise equal to CPU-REF at all 69 d02 frames**; fire arrays identical (the acceptance criterion) |
| **6. Acceleration** | §5.2 optimizations only, one at a time, each re-gated | bitwise preserved; time per simulated hour tracked |
| 7. Later | multi-GPU (§16); optional GPU-FAST comparison | — |

Keep a **short regression test** for every commit: start from a CPU-REF restart taken while the fire is active,
run 20 d02 steps, and compare with the tracer. Hourly restarts don't land in the ignition window, so make one at
02:20: restart CPU-REF from 02:00 with `restart_interval = 20` (bitwise-equal to the continuous run if test R1
passes).

---

## 20. Profiling and debugging tools

| Tool | Use |
|---|---|
| `rsl.error.0000` `Timing for main` | time per step per domain (CPU-REF vs GPU) |
| `BENCH_START/END` (`inc/bench_solve_em_def.h`) | redefine as NVTX push/pop (small `ISO_C_BINDING` interface to `nvtxRangePushA`/`nvtxRangePop`) → labeled `solve_em` sections in Nsight Systems |
| `nsys profile -t cuda,nvtx` | timeline; catches per-step `memcpy`/`cudaMalloc` (defects) |
| `ncu` | top kernels: achieved bandwidth, registers, occupancy |
| `compute-sanitizer` | races and out-of-bounds on small test domains |
| `-Minfo=mp` | what was offloaded, private and implicitly mapped |
| Bit-hash tracer, shadow tests | first divergent step/field, then kernel (§4.5) |
| `diffwrf` | field-by-field comparison of history files |

---

## 21. Runtime configuration

```bash
export OMP_NUM_THREADS=1
ulimit -s unlimited                 # still needed for remaining automatic arrays
export CUDA_VISIBLE_DEVICES=0
mpirun -np 1 ./wrf.exe              # 1 compute rank; add ranks only for I/O quilting (nio_tasks_per_group)
```

In `namelist.input`, add `numtiles = 1` under `&domains` (already the default in your `namelist.output`) and keep
every other setting identical to CPU-REF. For production (not verification) you may raise `restart_interval`.

---

## 22. Pitfall checklist

- [ ] Every scalar assigned in a loop body is `private` (`default(none)` while porting).
- [ ] Hidden shared per-point scratch made private (e.g. `dampwt(k)` in `advance_w`).
- [ ] No `grid%...` or `config_flags%...` inside target regions; no derived types with pointer components (fire `fp%`).
- [ ] No non-contiguous array sections passed to explicit-shape dummies (host temporaries aren't mapped). Passing a
      start element such as `moist(ims,kms,jms,im)` is fine.
- [ ] Every local array used in a kernel is in the pool or a `target data map(alloc:)`.
- [ ] Rolling `j` buffers removed without changing expressions (pattern B).
- [ ] Vertical recurrences and all float sums sequential in the original order (R6).
- [ ] **Every transcendental on a GPU path goes through `rp_*`** in both builds (R5); runtime constants too (R8).
- [ ] No FMA and no fast math in either build; flags checked in the actual compile lines (R2–R4).
- [ ] No `WRITE`/`PRINT`/`wrf_error_fatal`/MPI inside kernels.
- [ ] Called routines are `!$omp declare target`; statement functions compile inside kernels (or are converted to
      `pure` internal functions).
- [ ] Module tables and flags are `declare target` and copied after init.
- [ ] Only `max`/`min`/integer reductions; no float atomics.
- [ ] After every host write to state (init, input, nest forcing), update to device exactly those fields; before every
      host read (output, forcing), update from device.
- [ ] `-Minfo=mp` reviewed: no implicit per-step copies.
- [ ] Shadow test 0 ulp, tracer bitwise, CPU-REF output unchanged by the commit.

---

## 23. Appendix

### 23.1 Key file index

| File | Key routines |
|---|---|
| `WRF/main/wrf.F`, `frame/module_integrate.F` | program entry; time loop and nest recursion |
| `WRF/dyn_em/solve_em.F` | one step: RK loop `:573`, acoustic loop `:1261`, microphysics `:3720`, `spec_bdy_final` `:4540` |
| `WRF/dyn_em/module_em.F` | `rk_step_prep`, `rk_tendency`, `rk_addtend_dry`, `rk_scalar_tend`, `rk_update_scalar(_pd)`, `calculate_phy_tend` |
| `WRF/dyn_em/module_advect_em.F` | `advect_u/v/w`, `advect_scalar`, `advect_scalar_pd` |
| `WRF/dyn_em/module_small_step_em.F` | `small_step_prep/finish`, `calc_p_rho`, `calc_coef_w`, `advance_uv`, `advance_mu_t`, `advance_w` |
| `WRF/dyn_em/module_big_step_utilities_em.F` | `calc_mu_uv`, `couple_momentum`, `calc_ww_cp`, `horizontal_pressure_gradient`, `pg_buoy_w`, `w_damp`, `coriolis`, `curvature`, `calc_p_rho_phi`, `phy_prep`, `moist_physics_prep_em/finish_em` |
| `WRF/dyn_em/module_diffusion_em.F` | `compute_diff_metrics`, `cal_deform_and_div`, `smag2d_km` `:1934`, `tke_km` `:2049`, `horizontal_diffusion_2` `:2864`, `vertical_diffusion_2` `:4004`, `tke_rhs` `:6099` |
| `WRF/dyn_em/module_first_rk_step_part1.F`, `..._part2.F` | physics drivers, fire call `:1354`, `update_phy_ten` `:793` |
| `WRF/dyn_em/module_bc_em.F`, `share/module_bc.F` | lateral and physical BCs |
| `WRF/phys/module_mp_wsm6.F`, `physics_mmm/mp_wsm6*.F90` | WSM6 |
| `WRF/phys/module_ra_rrtmg_lw.F`, `module_ra_sw.F`, `module_radiation_driver.F` | radiation |
| `WRF/phys/module_sf_sfclayrev.F`, `physics_mmm/sf_sfclayrev.F90`, `module_sf_noahdrv.F`, `module_sf_noahlsm.F`, `module_surface_driver.F` | surface |
| `WRF/phys/module_bl_ysu.F`, `physics_mmm/bl_ysu.F90`, `module_pbl_driver.F` | YSU (d01) |
| `WRF/phys/module_physics_addtendc.F` | `update_phy_ten` |
| `WRF/phys/module_fr_fire_*.F` | WRF-Fire (§14.2) |
| `WRF/frame/module_domain.F`, `module_alloc_space_*.F`, `tools/gen_allocs.c`, `tools/gen_defs.c` | allocation and codegen hooks |
| `WRF/share/mediation_integrate.F`, `mediation_force_domain.F` | I/O and nest-forcing sync points |
| `WRF/arch/configure.defaults` | compiler stanzas (PGI at `:137`) |

### 23.2 Glossary

| Term | Meaning |
|---|---|
| CPU-REF / GPU-REPRO | bit-reproducible CPU reference build / GPU build that must match it bit for bit |
| ulp | unit in the last place (smallest float step at a value) |
| FMA | fused multiply-add (`a*b+c` with one rounding) |
| RK3, acoustic step | 3-stage Runge-Kutta large step; split-explicit sound-wave sub-steps |
| `mu`, `mut`, `muts` | dry column mass (perturbation, total, total at small step) |
| `ph`/`phb`, `al`/`alb`/`alt` | perturbation/base geopotential; inverse density perturbation/base/total |
| `ru`, `rv`, `rw`, `ww` | mass-coupled velocities; `ww` is the coupled η-velocity |
| `*_tend` / `*_tendf` | large-step dynamics tendency / physics and forcing tendency |
| `lfn`, `tign_g`, ROS | fire level-set function, fire arrival time, rate of spread |
| `sr_x`, `sr_y` | fire subgrid refinement |
| `rthfrten`, `rqvfrten` | fire θ and water-vapor tendencies on the atmospheric grid |
| Island | a not-yet-ported call bracketed by host/device updates |
