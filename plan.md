# WRF v4.6.0 + WRF-Fire → NVIDIA A100 80 GB / H100 80 GB: Execution Plan

This is the step-by-step plan for porting `wrf.exe` to a single NVIDIA A100 80 GB or H100 80 GB GPU. It lists
every task, the code to write and where to wire it in, every test, every verification gate, and the performance
analysis. The design rationale is in [explain-wrf.md](explain-wrf.md); this file is the executable to-do list.
Line numbers refer to the unmodified WRF v4.6.0 sources in `WRF/`.

**Implementation of Phases 1–7 on the H100 machine:** start with [AGENTS.md](AGENTS.md) and
[port/agent/README.md](port/agent/README.md) (workflow, coding standard with tested templates, phase task cards, the
generated per-kernel source references `port/agent/KERNEL_REFS.md` in current line numbers, the workbook). Where the
agent documents refine this plan (islands, window lengths, K-PD-L3, K-OZP), they say so and they take precedence;
the list is in "Refinements during Phase 0 and the agent handoff" at the end of this file.

---

## 0. How to use this plan

### Conventions

| Item | Format | Example |
|---|---|---|
| Task | `P<phase>.<n>` | `P2.14` |
| Kernel (a GPU loop nest to write) | `K-<area>-<n>` | `K-ADV-3` |
| Test | `T-<name>` | `T-TRACE-100` |
| Gate (all listed tests must pass before the next phase) | `G<phase>` | `G2` |

### Definitions

- **Bitwise:** identical bits in every compared value. Checked by identical bit-trace logs (P0.7) and by
  `diffwrf` reporting no differing fields.
- **CPU-REF:** the reproducible CPU build and its runs. This is the reference.
- **GPU-REPRO:** the GPU build that must equal CPU-REF bit for bit.
- **Island:** a not-yet-ported call wrapped by host↔device updates (P1.9).
- **Fire grid:** d02's fire domain mesh is 3244×3244 (this is what `wrfinput` stores); the memory mesh is
  3284×3284 on one rank; the active region is 3240×3240.
- **Dev case:** `eaton_small`, a reduced-size copy of the case used for all development gates (P0.16). The full
  case is used for the reference, memory gates and acceptance.

### Rules that apply to every task

1. **Never change arithmetic.** Every GPU kernel performs the same IEEE operations in the same order as the
   original loop. Loop nests may be split, promoted or re-parallelized; expressions may not be rewritten.
2. **Two kinds of source change, kept apart:**
   - **Shared refactors** apply to both builds: reproducible math, undefined-behaviour fixes, dead-code removal,
     hoisting, pool and work arrays, NaN-check changes. They are **all done in Phase 0, before the reference run**
     (P0.9a), so the archived reference already contains them.
   - **GPU restructurings** are split loops, per-column wrappers, fixed-size locals, the limiter split, and so on.
     They live under `#ifdef WRF_GPU`, so CPU-REF keeps the original loop structure.
3. **Every commit keeps two invariants,** checked by `T-REG-20` on the dev case:
   - the CPU-REF build at that commit equals the archived reference;
   - GPU-REPRO equals CPU-REF.
4. **One routine per commit** during Phases 2–4. Each commit message names the kernel IDs it adds and the tests
   that passed.

---

## 1. Target, acceptance and scope

| Item | Decision |
|---|---|
| Hardware | A100 80 GB (SXM or PCIe) and H100 80 GB (SXM or PCIe). One GPU, one MPI compute rank. A100 40 GB is deferred (§16). |
| Priority | (1) arithmetic accuracy, (2) acceleration. |
| Acceptance | For the full 17 h case, GPU-REPRO equals CPU-REF **bitwise**: every d02 history frame (every 15 min), every restart, and all fire arrays (`tign_g`, `fire_area`, `fuel_frac`, `fgrnhfx`, `fgrnqfx`, `ros`, `lfn`). This implies cell-by-cell identical fire spread. |
| Reference | CPU-REF: this repository built with `nvfortran` in reproducible mode (§4), run on CCR CPU nodes inside the same container image as the GPU runs. |
| Relation to the original CCR run | Measured once (experiment E0, P0.13) and documented. It is not an acceptance criterion: bitwise equality with a different compiler's math library is impossible on a GPU. |
| Framework | OpenMP 5 target offload in the existing Fortran, `nvfortran` (NVIDIA HPC SDK). No CUDA source is needed. A small C shim is used only for NVTX and `cudaMemGetInfo`. |

**In scope:** everything `wrf.exe` executes per time step for this case family, on both domains (§2.2), including
nest forcing.

**Not ported (stays on the CPU):**

- WPS, `real.exe`, `ideal.exe`;
- initialization (`start_domain`, `phy_init`, fire init);
- I/O, clocks, namelist;
- the host-side interpolation inside nest forcing (only its data movement is engineered).

---

## 2. The case contract

### 2.1 Case `eaton_20250108` (reference case)

The run folder is `runs/20260928_124741` on CCR (the Sep 9 run before it used the same inputs). The ignition point
and time (34.18604 N, −118.09325 W, 02:18 UTC on 8 Jan 2025) are the Eaton Fire's.

**Inputs** (made by `real.exe` v4.6.0, `MODIFIED_IGBP_MODIS_NOAH`, 21 land categories):

| File | Size | md5 | Content |
|---|---|---|---|
| `wrfinput_d01` | 289 MB | `4a50bf559d1486b00b486287fdd3c567` | d01 initial state, 450×450×60, dx 900 m |
| `wrfinput_d02` | 876 MB | `f53040929f3d0ec486cfe6ffb8a054a2` | d02 initial state, 811×811×60, dx 100 m; fire mesh `NFUEL_CAT` (LANDFIRE), `ZSF`, slopes on 3244² |
| `wrfbdy_d01` | 122 MB | `51cffbc8a8c6f53203a35b301e519582` | d01 lateral BCs, every 3 h, Jan 8 00:00–21:00 |

**Runtime tables** (symlinked from `test/em_real`): `LANDUSE.TBL`, `VEGPARM.TBL`, `SOILPARM.TBL`, `GENPARM.TBL`
(Noah); `RRTMG_LW_DATA`; `ozone.formatted`, `ozone_lat.formatted`, `ozone_plev.formatted` (`o3input = 2`);
`CAMtr_volume_mixing_ratio` (`ghg_input = 1`). No other file is read.

**Namelists:**

- `namelist.input`: the provided file with `fire_fuel_read = -1, -1`.
- **No `namelist.fire` is present.** WRF uses its built-in 53-category table (`module_fr_fire_phys.F:170` DATA
  defaults) and writes `namelist.fire.output`. Uniform fuel moisture `fuelmc_g = 0.08` (`fire_fmc_read = 1`).
  `FMC_GC` in `wrfinput_d02` is all zeros and is not used.

**Not used:** `met_em` files, a d02 boundary file, SST update, aerosol input. Copies of the inputs with different
md5s (e.g. Nisha's, about 6% larger) are **different inputs** and must never be mixed into a comparison.

### 2.2 Configuration facts that drive the port

Two domains with one-way nesting (`feedback = 0`, `smooth_option = 0`), ratio 9 in both space and time.

**d01:** 450×450×60, `dt = 3 s`, 20,400 steps in 17 h.

**d02:** 811×811×60, `dt = 1/3 s`, 183,600 steps.

**Dynamics (both domains unless noted):**

- `rk_ord = 3`; `time_step_sound = 0`, which gives 4 acoustic steps per `dt` and 1+2+4 = 7 acoustic sub-steps per
  step.
- non-hydrostatic; `hybrid_opt = 2`; `use_theta_m = 1`; `hypsometric_opt = 2`.
- advection h5/v3; momentum `adv_opt = 1`; moist/scalar/TKE `adv_opt = 1` (positive-definite).
- `diff_opt = 2`; `km_opt = 4` on d01 (2D Smagorinsky with YSU vertical mixing) and `km_opt = 2` on d02 (3D TKE LES).
- `m_opt = 1` on d02 (SGS stress output).
- `damp_opt = 3`; `w_damping = 1`; `epssm = 0.5 / 0.8`.

**Physics:**

- WSM6; RRTMG LW (single precision, `kind_rb = kind(1.0)`); Dudhia SW; `radt = 1 min` (radiation runs every 20 d01
  steps and every 180 d02 steps); `o3input = 2`; `ghg_input = 1`; `icloud = 1`.
- sfclayrev (revised MM5 surface layer); Noah LSM.
- YSU on d01 only; no PBL scheme on d02.
- No cumulus, shallow convection, urban or lake.
- Effective radii are never computed (Dudhia SW sets `has_req* = 0`).

**Fire (d02):**

| Option | Value |
|---|---|
| `ifire` | 2 |
| `sr_x`, `sr_y` | 4, 4 |
| `fire_upwinding` | 9 (hybrid WENO5/ENO1) |
| `fire_lsm_reinit` | `.true.`, 1 iteration, scheme 4, band 4 |
| `fire_advection` | 1 |
| `fire_viscosity` | 0.4 (`fire_viscosity_ngp = 2` from the registry default) |
| `fire_lsm_zcoupling` | `.true.`, ref 60 m; `fire_wind_height = 1 m` |
| `fire_atm_feedback` | 1 |
| `fire_fuel_left_method` | 1 (2×2 subcells) |
| `fire_grows_only` | 1 |
| `fire_boundary_guard` | 8 |
| Ignition | one circular ignition, radius 100 m, 8280–9080 s, ROS 0.1 m/s |
| Off | `fmoist_run`, tracers, spotting |

**I/O:** d02 history every 15 min (69 frames); d01 history off (`history_interval = -1`); restarts every 60 min
for both domains even with `restart = .false.`; `wrfbdy_d01` read every 3 h.

### 2.3 Supported-option envelope (for other fires)

Other fires may change these freely:

- dates and run length;
- `e_we`, `e_sn`, `e_vert`, `dx`, `time_step`, nest position and ratios;
- ignition parameters;
- history and restart intervals;
- `interval_seconds`;
- input files.

Everything else in §2.2 is fixed. `gpu_check_config` (P1.8) enforces this at startup, and onboarding (§12) checks
it before any run.

### 2.4 Case files in the repo

Create `cases/eaton_20250108/` containing:

- `namelist.input` (as run);
- `manifest.md5` (md5 of the 3 inputs and 8 tables);
- `README.md` (CCR run folder, dates, CCR build path, known facts, e.g. no `namelist.fire`).

Large files are never committed; they stay on CCR and the GPU nodes and are verified against `manifest.md5` before
every run (P0.3).

---

## 3. GPU memory budget (A100 80 GB / H100 80 GB)

The estimate uses the Registry, evaluated with `port/gpu_mem_estimate.py` (P0.15), plus the survey of automatic
and work arrays. One 3D `REAL` array is 162 MB on d02 (memory dims 821×60×821) and 51 MB on d01 (460×60×460). One
fire-grid array is 43 MB (3284²).

| Item | Size | Note |
|---|---:|---|
| d01 state | 6.1 GB | 99 3D arrays plus 2D |
| d02 state | 20.5 GB | 107 3D arrays (incl. 2-time-level fields) plus 2D |
| d02 fire grid | 1.7 GB | 39 `*i*j` arrays |
| `i1` scratch pool (sized to d02) | 9.1 GB | 32 3D + 11 2D named + 24 4D slots (`moist_tend/old` ×7, …) |
| Work arrays (from automatic arrays) | ≈ 7 GB | fire 1.6, radiation driver 1.6, `advect_scalar_pd` 1.3, advection `fqy3` + limiter `scl` 0.5, `couple_or_uncouple` 0.8, drivers 0.8 |
| RRTMG LW batch work | ≈ 4.5 GB | batch of 4096 columns × ≈ 1.1 MB (NL = 109 layers incl. 50 buffer layers; tunable, §8.5) |
| Local-memory reservation (column physics, fixed-size locals CP-3) | ≈ 7–9 GB | ≈ 30 KB/thread (WSM6 is the largest) × max resident threads (A100 ≈ 221k, H100 ≈ 270k) |
| CUDA context, runtime pool, fragmentation | ≈ 1–2 GB | |
| **Total** | **≈ 58–62 GB** | fits 80 GB with ≈ 18–22 GB headroom |

Gate **G-MEM:** the logged peak device memory (P1.12) is ≤ 70 GB on both GPUs. It is checked three times:

- at G1, with state, pool and work arrays;
- at G3, after the RRTMG batch and column-physics local memory exist;
- at G5, on the full run.

**Rule of thumb for other fires:**
device bytes ≈ 540 B × Σ(domain memory points) + 350 B × (largest domain memory points) + 300 B × (fire memory
cells) + 13 GB (RRTMG batch, local memory, context). `port/gpu_mem_estimate.py` gives the exact per-case number.

---

## 4. Environment, toolchain and build modes

### P0.0 Container and machines

1. Build one container image with:
   - NVIDIA HPC SDK, pinned version, CUDA 12.x (supports `cc80`/`cc90`);
   - OpenMPI 4.x built with `nvc`/`nvfortran`;
   - HDF5, netCDF-C and netCDF-Fortran built with `nvfortran`;
   - `perl`, `csh`, `m4`, `make`, `git`, Python 3 with `netCDF4`, `numpy`, `mpmath`.

   Record the image digest in `port/ENVIRONMENT.md`.
2. Run the image with Apptainer on CCR CPU nodes (CPU-REF) and on the A100/H100 nodes (GPU runs). Never mix
   images.
3. Build every binary with an explicit, portable host target, `-tp=haswell` (AVX2 without FMA use because of
   `-Mnofma`), so the same CPU-REF binary runs on any CCR node and on the GPU nodes' hosts.

### Build modes (exact flags)

`WRF/arch/configure.defaults` gets three new stanzas (P0.4):

| Mode | Where it runs | Fortran flags | Device flags | cpp |
|---|---|---|---|---|
| CPU-REF | CCR nodes; GPU-node hosts for `T-XM` | `-O2 -Kieee -Mnofma -Mnoflushz -Mnodaz -Mvect=noassoc -tp=haswell` | none | `-DREPRO_MATH -DWRF_POOL` |
| GPU-REPRO | A100/H100 nodes | same | `-mp=gpu -gpu=cc80,cc90,nofma,noflushz -Minfo=mp,vect` | `-DREPRO_MATH -DWRF_POOL -DWRF_GPU` |
| GPU-DEBUG | A100/H100 nodes | GPU-REPRO + `-g -traceback` | + `-gpu=lineinfo` | + `-DWRF_GPU_TRACE_FINE` |

`-Mvect=noassoc` stops the host vectorizer from reassociating floating-point reductions. The device evaluates
sums in source order, so the host must too (e.g. `sum_2d_cells`, the Noah `DO K=1,NSOIL` sums, the WSM6 sums). If
`-Minfo=vect` still reports a vectorized floating-point reduction in an in-scope file, compile that file with
`-Mnovect` in all builds.

Confirm every flag spelling against the pinned NVHPC version (`nvfortran -help`, `nvfortran -help -gpu`).
`T-FMA` (P0.5) is the binding check for FMA; `T-SUBNORM` is the binding check for denormals.

---

## 5. Phase 0 — Reference, harness, baselines

### P0.1 Repository scaffolding

Create:

- `port/`: Python tools and the test harness;
- `port/tests/`: standalone Fortran tests;
- `cases/eaton_20250108/` (§2.4);
- `port/ENVIRONMENT.md`: container digest, flags, node types;
- `port/RESULTS.md`: a running log of gate results.

### P0.2 Identify the original CCR build

On CCR:

- `module show wrf/4.6.0-dmpar`; read `configure.wrf` in the WRF tree under `/cvmfs/.../WRFV4.6.0/`;
- read the run's `rsl.error.0000` header and the job script.

Record in `cases/eaton_20250108/README.md`: compiler and version, `FCOPTIM`, MPI library, rank count,
`nproc_x × nproc_y`, wall time per simulated hour (from the `Timing for main` lines).

### P0.3 Input manifest check

Write `port/manifest.py` with `write` and `check` subcommands. `check` verifies the md5 of every input and table in
a run folder against `manifest.md5` and verifies there is **no** `namelist.fire`. Every run script (CPU-REF and GPU)
calls it first and aborts on mismatch.

### P0.4 Configure stanzas

- Add the three stanzas (CPU-REF, GPU-REPRO, GPU-DEBUG) at the end of `WRF/arch/configure.defaults`. Copy the
  `PGI compiler with gcc` stanza (`:137`) and change: `SFC`/`DM_FC` = `nvfortran`/`mpif90`, `SCC`/`CCOMP` = `nvc`,
  `FCOPTIM`, `ARCH_LOCAL` (+ the cpp macros).
- **Wiring caveats:**
  - `Config.pl` (`arch/Config.pl:954`) only uncomments `OMP` for the `smpar`/`dm+sm` options. With `dmpar`, a
    commented `OMP` stays empty. The GPU stanzas therefore put `-mp=gpu -gpu=…` in a line that isn't commented
    out (e.g. `OMP = -mp=gpu …`, with no `#`), and CPU-REF sets `OMP =` (empty).
  - `$(OMP)` must appear in `FCBASEOPTS_NO_G` and reaches the linker through `LDFLAGS` (`arch/postamble:63`).
    This matters because the allocation files that receive the `enter data` lines are compiled with
    `$(FCNOOPT) $(FCBASEOPTS_NO_G)`, not `FCOPTIM` (`frame/Makefile:90ff`).
  - The inherited `FCBASEOPTS_NO_G` contains `-w`, so compiler warnings are hidden. The new `port/` and `frame`
    files are checked separately (`T-BUILD-*` compiles them once without `-w`).
- Build CPU-REF with `./configure` (choose the stanza, option `dmpar`, nesting `basic`) then `./compile em_real`.

### P0.5 Reproducible math module `WRF/frame/module_repro_math.F`

**Interface:**

- generic, `ELEMENTAL`, all procedures `!$omp declare target`;
- `REAL(4)` and `REAL(8)` specifics: `rp_exp`, `rp_log`, `rp_log10`, `rp_pow(x,y)`, `rp_sin`, `rp_cos`,
  `rp_tan`, `rp_asin`, `rp_acos`, `rp_atan`, `rp_atan2`, `rp_sinh`, `rp_cosh`, `rp_tanh`, `rp_mod`;
- conditional `rp_max`/`rp_min`/`rp_sign` exist only if `T-SIGNZERO`/`T-MINMAX` find a host/device difference.

**Two implementations, selected by `#ifdef REPRO_MATH`:**

- *off:* each function returns the Fortran intrinsic (upstream behaviour, zero cost);
- *on:* the portable implementation below.

**Portable REAL(4) implementation:**

- Convert to REAL(8), evaluate with a fixed double-precision algorithm, round once with `REAL(y,4)`.
- Algorithms are fdlibm-style ports to Fortran:
  - exp: Cody-Waite reduction by `ln2` hi/lo, degree-5 Remez rational;
  - log: `2^k·(1+f)` decomposition and polynomial in `s = f/(2+f)`;
  - pow: `exp(y·log(x))` in double-double for the product;
  - sin/cos/tan: reduction by π/2 in 3 parts (arguments in WRF are below 1e5 rad);
  - atan/asin/tanh: fdlibm.
- Special cases (±0, ±Inf, NaN, `x < 0` in log, integer `y` with negative `x` in pow) follow IEEE/C99.
- Bit access uses `TRANSFER` to `INTEGER(8)`, never `EQUIVALENCE`.

**Portable REAL(8):** the same fdlibm algorithms with double-double where fdlibm uses it.

**`rp_mod(a,p)`** = `a - AINT(a/p)*p`, spelled exactly like that on both sides.

**Standing rules:**

- `x**2.0` becomes `x*x`; this is identical to a correctly rounded `pow`.
- `x**0.5` becomes `SQRT(x)`; identical for the same reason.
- `x**n` with integer `n ≥ 3` stays as is if `T-IPOW` passes (P0.6).

**Build:** add the file to `WRF/frame/Makefile` (`MODULES`, first entry) and to `WRF/main/depend.common`
(`module_repro_math.o` before every user). It lives in `frame/`, not `share/`, because `frame/libmassv.F` (`vspow`)
uses it and `frame` is compiled before `share`.

**Tests**, in `port/tests/repro_math/`:

- `T-FMA` (run first, gates everything else): a device kernel and a host loop compute `d = a*b + c` with `a`, `b`
  and `c` **read from an input file at run time**, so they can't be constant-folded.
  - Use `a = b = 1+2⁻¹²` and `c = -1`. The exact product `1+2⁻¹¹+2⁻²⁴` is a rounding tie in binary32, so the
    unfused result is `2⁻¹¹` and the fused result is `2⁻¹¹+2⁻²⁴`.
  - Add 10⁶ random triples in which fused and unfused differ (chosen offline with `mpmath`).
  - Pass: device bits equal host bits, and both equal the unfused result.
- `T-SIGNZERO`, `T-MINMAX`: host and device results of `SIGN(1.,x)`, `MAX(a,b)`, `MIN(a,b)`, `ABS(x)` for all
  combinations of ±0, ±subnormal, ±Inf, NaN and ordinary values, in both operand orders. `flux3`/`flux5` use
  `sign(1.,ua)` with `ua` often `−0.0`, and the limiter uses `max(0.,…)`. Pass: identical bits. Otherwise add
  `rp_sign`/`rp_max`/`rp_min` (explicit IEEE-defined branches) and substitute them in the in-scope files.
- `T-SUBNORM`: `+ - * /` and `sqrt` on subnormal operands, plus 10⁹ random normal operand pairs (so a
  non-correctly-rounded device `/` or `sqrt` is caught too), host vs device. Pass: identical and not flushed.
- `T-RM-EXH`: exhaustive REAL(4). For all 2³² bit patterns and every 1-argument function, compute on the host
  (OpenMP threads) and the device (`target teams loop`) and compare bit patterns. Pass: 0 mismatches.
- `T-RM-POW`: `rp_pow` on 2³⁰ random (x,y) pairs plus the grid `x ∈ all floats in [1e-3,1e3]` × 257 exponents
  used in WRF (0.25, 0.33, 0.46, 0.49, 0.635, 1.31, 1.33, 1.5, 7/3, `rovcp`, `cpovcv`, `cvpm`, `r_d/cp`, `bvt*`,
  …). Pass: 0 host/device mismatches.
- `T-RM-D`: REAL(8), 10⁹ random plus edge cases, host vs device. Pass: 0 mismatches.
- `T-RM-ACC`: accuracy against `mpmath` (60 digits) on 10⁷ samples per function. Report the max ulp error. Target:
  REAL(4) ≤ 0.5 ulp except listed hard cases; REAL(8) ≤ 1 ulp.

### P0.5b Compiler feature probes (`port/tests/omp_features/`)

These are small programs that decide the coding standard before any kernel is written. Record each result in
`port/ENVIRONMENT.md`.

| Probe | Checks | If unsupported |
|---|---|---|
| `F-IFTARGET` | `if(target: flag)` runs the region on the host with host data when `flag` is false | the `T-AB` method uses a cpp macro that emits a host copy of the loop instead |
| `F-CALLS` | `target teams loop` vs `target teams distribute parallel do` around a loop that calls a `declare target` routine; `-Minfo=mp` shows full parallelization | use `teams distribute parallel do` for every kernel that calls a procedure (CP-1, RRTMG, `fire_ros`, `select_*`) |
| `F-DECLMOD` | `declare target` on module scalars, fixed arrays and **allocatable** arrays, plus `target enter data` / `update` of them | fixed-size module arrays, or pass them as arguments |
| `F-PRESENT` | a pointer bounds-remapped onto a sub-range of a mapped pool, passed to an explicit-shape dummy, is found present (no copy) | per-array mapping instead of a pool |
| `F-DEFMAP` | `defaultmap(present)` / `map(present,alloc:…)` accepted and enforced | rely on `T-NSYS` (all-size copy counting) |
| `F-PRIVARR` | private arrays with **runtime** size in a kernel | use fixed `KMAX` sizes (the default in this plan) |
| `F-AUTO` | automatic arrays in `declare target` routines (heap use and speed) | CP-3 (fixed-size locals, the default) |
| `F-STMTFN`, `F-INTPROC`, `F-OPT`, `F-CHAR` | statement functions, internal procedures, `OPTIONAL`/`PRESENT`, `CHARACTER` args in device code | the CP-4 conversions |
| `F-RED` | `reduction(ieor:)` on `INTEGER(8)`; `reduction(max:)` on REAL | second additive hash with a different multiplier |
| `F-NAN` | `x /= x` as a NaN test under `-Kieee` on the device (`IEEE_IS_NAN` may not be available in device code) | — |
| `F-STACK` | the stack limit set via NVHPC env `NV_ACC_CUDA_STACKSIZE` applies to OpenMP kernels (read back with `cudaDeviceGetLimit` through the shim) | `cudaDeviceSetLimit` through the shim before the first kernel |

- `T-OMP-FEAT` = all probes run and results recorded. It is part of G0.

### P0.6 Substitute transcendentals (both builds)

**Tool:** `port/rp_subst.py <file>...` rewrites calls in place:

- `EXP(`/`ALOG(`/`LOG(`/`ALOG10(`/`LOG10(`/`SIN(`/`COS(`/`TAN(`/`ASIN(`/`ATAN(`/`ATAN2(`/`TANH(` → `rp_*`;
- real-exponent `a**b` → `rp_pow(a,b)`, parenthesizing operands exactly as parsed. Precedence: `**` binds
  tighter than unary minus, and `-a**b` stays `-(rp_pow(a,b))`;
- `MOD(` on REAL arguments → `rp_mod(`.

It prints every rewrite for review, adds `USE module_repro_math` to each program unit, skips comments, string
literals and `PARAMETER`/`DATA` initializers (compile-time constants are folded identically), and **refuses** any
transcendental intrinsic that isn't in its list (e.g. `DEXP`, `ACOS`, `COSH`), rather than skipping it.

A regex can't reliably tell a real exponent from an integer one, so the binding check is a **symbol audit
(`T-SYM`)**:

- host objects: `nm` on every in-scope object, checking for math-library references (`expf`, `logf`, `powf`,
  `sinf`, `__mth_*`, `__pgmath_*`, `__fmth_*`, etc.);
- device code: `cuobjdump -sass` / `-ptx`, checking for `__nv_expf`, `__nv_powf`, … and inline `ex2`/`lg2`
  approximations.

Pass: none remain, apart from a documented allow-list of calls on host-only paths (I/O, clocks).

**Files** — every file executed per step or at init in this case family:

- **Dynamics:**
  - `dyn_em/module_small_step_em.F`, `module_big_step_utilities_em.F`, `module_diffusion_em.F`,
    `module_bc_em.F`, `start_em.F`, `module_em.F`, `module_first_rk_step_part1.F`,
    `module_first_rk_step_part2.F`, `couple_or_uncouple_em.F`;
  - `share/module_bc.F`, `share/interp_fcn.F` (nest interpolation);
  - `frame/libmassv.F` (`vspow` used by `calc_p_rho_phi`).
- **Physics:**
  - radiation: `phys/module_radiation_driver.F`, `module_ra_rrtmg_lw.F`, `module_ra_sw.F`,
    `module_ra_clWRF_support.F`;
  - surface: `module_surface_driver.F`, `module_sf_sfclayrev.F`, `physics_mmm/sf_sfclayrev.F90`,
    `module_sf_noahdrv.F`, `module_sf_noahlsm.F`, `module_sf_noahlsm_glacial_only.F`,
    `module_sf_noah_seaice.F`, `module_sf_noah_seaice_drv.F`, `module_sf_sfcdiags.F`;
  - PBL: `module_pbl_driver.F`, `module_bl_ysu.F`, `physics_mmm/bl_ysu.F90`;
  - microphysics: `module_microphysics_driver.F`, `module_mp_wsm6.F`, `physics_mmm/mp_wsm6.F90`,
    `physics_mmm/mp_wsm6_effectRad.F90`;
  - glue and init: `module_physics_addtendc.F`, `module_physics_init.F`.
- **Fire:** `phys/module_fr_fire_*.F` (all 7).

Excluded: files in WENO or other inactive branches and I/O code. Within a file, substitute all calls, not only those
on active paths; the result is the same and it is simpler to audit.

**Tests:**

- `T-IPOW`: grep every integer power with exponent ≥ 3 in the substituted files and run a unit test of each
  expression host vs device. Pass: identical; otherwise rewrite as products.
- `T-SYM`: the symbol audit above, for both CPU-REF and GPU-REPRO objects.
- `T-BUILD-REF`: CPU-REF builds; the new files compile cleanly without `-w`.

### P0.7 Bit-hash tracer `WRF/frame/module_bittrace.F`

**API:**

```fortran
CALL bt_open(grid)                    ! reads env WRF_BITTRACE (0/1/2), WRF_BITTRACE_FROM, _TO (step range)
CALL bt_field3(tag, name, a, ips,ipe,kps,kpe,jps,jpe)   ! and bt_field2, bt_field4(…, n4), bt_fieldf (fire grid)
CALL bt_checkpoint(grid, tag)         ! hashes the registered field set, writes one line per field
```

**Hash:** `h = Σ INT(TRANSFER(a(i,k,j),0_4),8)` over the **patch interior only**, using each field's own patch
extents including staggered ends (the same extents the I/O layer writes), never halos. 64-bit wraparound. Also XOR-fold the same values into a second 64-bit word. For MPI CPU-REF runs, the rank sums
are combined with `MPI_Allreduce(MPI_INTEGER8, MPI_SUM)` and XOR with `MPI_BXOR`. The result is independent of
decomposition and evaluation order.

**Device version:** the same loop with `!$omp target teams loop collapse(3) reduction(+:h) reduction(ieor:x)`.
Integer reductions are exact.

**Output:** `bittrace.d0N.txt`, one line `step rkstage tag field hsum hxor`.

**Checkpoint sets:**

- level 1 (production and long runs): end of each step, all prognostic fields
  (`u_2, v_2, w_2, t_2, ph_2, mu_2, p, al, moist(:,:,:,2:7), tke_2`, plus fire `lfn, tign_g, fire_area, fuel_frac`),
  about 20 fields;
- level 2 (debug): after every numbered step of §7.1 and every call in §8/§9, with the fields written by that call.

**Wiring:** `CALL bt_checkpoint(grid,'<tag>')` lines, guarded by `IF (bt_level>=N)`, at every step in §7.1.

**Comparison tool:** `port/bittrace_diff.py a.txt b.txt` prints the first differing `(domain, step, stage, tag,
field)` and a summary.

### P0.8 Per-routine GPU routing switch `WRF/frame/module_gpu_route.F`

- `INTEGER, PARAMETER :: R_<ROUTINE> = n` for every ported routine (the list grows in Phases 2–4).
- `LOGICAL :: gpu_on(nroutes)`, read from env `WRF_GPU_OFF=name1,name2,...` (default all on) and
  `WRF_GPU_ONLY=...`.
- Every ported target construct carries `if(target: gpu_on(R_<ROUTINE>))`. When off, the region runs on the host
  over host data.
- Every ported call site is wrapped:

  ```fortran
  IF (.NOT. gpu_on(R_X)) THEN
  #include "island_in_X.inc"     ! !$omp target update from(<INTENT(IN) and INOUT actuals>)
  END IF
  CALL x(...)
  IF (.NOT. gpu_on(R_X)) THEN
  #include "island_out_X.inc"    ! !$omp target update to(<INTENT(OUT) and INOUT actuals>)
  END IF
  ```

  The island lists are written by hand from each routine's `INTENT`s and kept next to the call site.
- **`T-AB-<routine>` (the per-kernel test):** on the dev case, from the 02:20 restart (fire active), run 100 d02
  steps with the tracer at level 2 twice: once with `WRF_GPU_OFF=<routine>` and once with everything on. The traces
  must be identical. This proves the device version of the routine equals its host execution on real data.
- **`T-AB` only compares the GPU-restructured code with itself.** A mistake in the restructuring shows up in the
  GPU-REPRO vs CPU-REF comparisons (`T-TRACE-*`), where CPU-REF runs the original loop structure. Both kinds of
  test are required at every sub-gate.

### P0.9a Shared refactors (both builds; must be finished before the reference run)

Each item is a separate commit. After each, the CPU-REF build is compared with the unrefactored `nvfortran` CPU
build over the dev-case window (`T-SHARED-<n>`). Expected: bitwise, except where the item deliberately defines
previously undefined behaviour; any difference is explained in `port/RESULTS.md`.

1. The `rp_*` substitutions (P0.6).
2. Pool (P1.6) and work arrays (P1.7) in **both** builds (`-DWRF_POOL`), zero-filled once at allocation.
   - This gives CPU-REF and GPU the same scratch semantics.
   - `T-SHARED-POOL` also documents whether upstream WRF ever reads uninitialized scratch (a difference against the
     stack-based build means it does; record the field).
3. The `zolri` defined-result fix (§8.3) with an occurrence counter.
4. The YSU BEP out-of-bounds guard (§8.4).
5. Fire:
   - hoist `set_flags`;
   - explicit arrays instead of `fp%` pointer components;
   - integer any-NaN checks (`x /= x`) replacing the float-sum checks;
   - delete the unused `tend_1..3` and the dead ignition check;
   - remove in-loop message `WRITE`s (§9.0).
6. RRTMG:
   - hoist `rrtmg_lw_ini` to init;
   - flatten the EQUIVALENCEd `rrlw_kg*` tables into 1D arrays with explicit index arithmetic (§8.5);
   - delete the unused Mersenne-Twister local.
7. Noah:
   - `iloc`/`jloc` → arguments;
   - `LUTYPE`/`SLTYPE` → integer codes;
   - implicitly-SAVEd initialized locals (e.g. `SNUPGRD` in `SNFRAC`, `module_sf_noahlsm.F:2845`) → `PARAMETER`.
8. Skip provable no-ops: WSM6 effective radius with `has_req*=0`; radiation q save/restore; the unused
   `mptenmax/min` reductions.
9. The KISS RNG with explicit 32-bit wraparound arithmetic (`IAND`/`ISHFT` on `INTEGER(8)`), if `T-KISS` shows any
   host/device difference.

### P0.9 Build CPU-REF on CCR

Build once in the container on CCR with the CPU-REF stanza **after P0.9a**, and keep `wrf.exe` (with md5) in
`/…/builds/cpu-ref/<git-sha>/`. Every CPU-REF run uses this exact binary.

### P0.10 Reproducibility tests of CPU-REF

| Test | What | Pass |
|---|---|---|
| `T-DET` | Same binary, same ranks, run twice for 1 h | bitwise |
| `T-DEC-A` | 1 rank vs 64 ranks, the first 3 d01 steps (27 d02 steps), level-2 trace | bitwise |
| `T-DEC-B` | 64 vs 128 vs 144 ranks, 30 simulated min | bitwise |
| `T-RST` | continuous run vs restart at 02:00, compare to 03:00 | bitwise (if it fails, see below) |
| `T-XM` | same CPU-REF binary on a CCR node vs a GPU-node host, 3 d01 steps from t = 0 and from the 02:00 restart | bitwise |

**Restart-window rule:** every windowed test (`T-AB`, `T-TRACE-*`, `T-REG-20`, `T-FIRE-WIN`) compares a **restart
run against a restart run from the same file**. That is, CPU-REF restarted from file F versus GPU-REPRO restarted
from F; never against the continuous archive. Such windows are valid whether or not `T-RST` passes.

**If `T-RST` fails:** find the first differing field with the trace (typical causes: a field missing from the
restart stream, or a SAVE variable not restored). Fix it in P0.9a if feasible. Otherwise record it; only the
continuous 17 h comparisons (G5) then depend on continuous runs.

**If `T-DEC` fails:** bisect with the trace to the first routine whose result depends on the decomposition. Fix it
so the result equals the 1-rank result (the GPU is 1 rank). Typical culprits are loops bounded by patch rather than
domain edges, and non-associative sums across tiles. Record the fix in `port/RESULTS.md`. CPU-REF must be
decomposition-independent before P0.11.

**If `T-XM` fails:** a host library result reaches the state. Find the field with the trace, substitute the missing
`rp_*`, and repeat.

### P0.11 CPU-REF full reference run

- 17 h on CCR, same rank layout as `T-DEC-B`.
- History as the original: d02 every 15 min. Restarts every 60 min.
- Level-1 trace for every step on both domains (about 1 GB of logs).
- Extra restart run from 02:00 with `restart_interval = 20`, to create a 02:20 restart (fire active) for the
  full-case windows.
- Archive under `/…/reference/eaton_20250108/<cpu-ref-sha>/`: `wrfout_d02_*`, `wrfrst_d0*`,
  `bittrace.d0*.txt`, `rsl.*`, `namelist.*`, `manifest.md5`, and an md5 list of every output.

### P0.12 Comparison tools

**`port/compare_fields.py A B`:** runs `diffwrf` semantics in Python. Per field: number of differing points, max
abs/rel difference, digits of agreement. Exits non-zero on any difference in `--bitwise` mode.

**`port/compare_fire.py A B`:** per history frame:

- burned-cell masks (`tign_g < t_frame`) and number of differing cells;
- symmetric-difference area (m²);
- max/mean `|Δtign_g|` over cells burned in both;
- burned area in each run;
- differences in `fire_area` and `fuel_frac`.

Writes a CSV and a PNG of the differing cells per frame.

### P0.13 Experiment E0 (CPU-REF vs the original CCR run)

Run both tools on all 69 frames. Record in `port/RESULTS.md` how far a CPU rebuild alone moves the fire (differing
cells over time). This documents the baseline; it is not a gate.

### P0.14 Experiment E1 (1-ulp sensitivity)

- `port/perturb_input.py` copies `wrfinput_d02` and changes `T` at one d02 point (center of the fire area,
  k = 10) to `nextafter(T, +inf)`.
- Run CPU-REF for 17 h and compare with P0.11 using `compare_fire.py`.
- **Expected:** burned masks diverge. That confirms bitwise identity is required for the acceptance criterion.
- **If they don't diverge:** record it. Bitwise remains the engineering target anyway.

### P0.15 Memory estimator and CPU profile

**`port/gpu_mem_estimate.py namelist.input`:**

- parses `Registry/Registry.EM` (includes, `ifdef EM_CORE=1`, packages evaluated against the namelist);
- prints per-domain state bytes, the fire grid, the `i1` pool and the work-array total;
- validates against the `alloc_space_field: domain N, ... bytes allocated` lines (`frame/module_domain.F:1429`)
  summed over the ranks of the CPU-REF run (tolerance 5%).

**CPU profile:** build CPU-REF once more with `-DBENCH` (the `BENCH_START/END` timers in `solve_em`) and run 1 h.
Produce `port/RESULTS.md` table **Prof-CPU**: seconds per simulated hour per section (dynamics RK, acoustic, scalar
transport, turbulence, each physics scheme, fire, nest forcing, I/O) for d01 and d02.

### P0.16 Development case `eaton_small`

**Why:** during Phases 1–4 whatever isn't yet ported runs on **one host core** (one rank, one tile). A full-size
d02 step then costs minutes, so windows on the full case would take days. All development gates therefore run on a
reduced case.

**Make it with the user's WPS + `real.exe` pipeline:**

- the same namelist options as §2.2, the same dates and the same ignition;
- d01 unchanged (450×450×60);
- **d02 reduced to 181×181×60** (`dx = 100 m`, ratio 9), placed so that the ignition point sits in the middle of
  the nest; fire grid 724²;
- all physics, fire and nest-forcing code paths identical to the full case.

**Store** it as `cases/eaton_small/` with its own manifest.

**Run its own CPU-REF reference** (1 h continuous from 02:00 plus a 17 h run on CCR). Also produce restarts at 02:00
and 02:20 (the latter via a restart run with `restart_interval = 20`).

**Standard dev windows (all restart-vs-restart, P0.10):**

| Window | Definition |
|---|---|
| `W-20` | 9 s from 02:20 = 3 d01 steps = 27 d02 steps (a window must end on a d01 step) |
| `W-100` | 36 s from 02:20 = 12 d01 steps = 108 d02 steps |
| `W-RAD` | 240 s from 02:20 = 80 d01 steps = 720 d02 steps, containing 4 radiation calls on each domain |

### G0 — Phase 0 gate

All of the following hold:

- `T-FMA`, `T-SIGNZERO`, `T-MINMAX`, `T-SUBNORM`, `T-RM-*`, `T-IPOW`, `T-SYM` pass; `T-OMP-FEAT` is recorded.
- Every `T-SHARED-*` passes or its difference is explained.
- `T-DET`, `T-DEC-A`, `T-DEC-B`, `T-XM` are bitwise. `T-RST` is bitwise or its failure is documented.
- The reference runs (P0.11 full case, P0.16 dev case) are archived with md5s.
- E0 and E1 are recorded.
- Prof-CPU is filled in.
- The memory estimator is validated.

---

## 6. Phase 1 — GPU infrastructure (all compute still on the host)

### P1.1 First GPU-REPRO build

Build `em_real` with the GPU-REPRO stanza on an A100 node and an H100 node (same image). Fix compile-only issues
without changing any executable statement. Keep the `-Minfo=mp` log per file in `builds/gpu-repro/minfo/`.

### P1.2 Device residency of all state (`WRF/tools/gen_allocs.c`)

**`gen_alloc2`**, inside the in-use `THEN` branch, immediately after the initial-value `fprintf` statement (which
ends at line 297; insert before 298, never inside the `ALLOCATE` `fprintf` at 282–286), for non-boundary arrays:

```c
fprintf(fp,"#ifdef WRF_GPU\n  IF (.NOT. grid%%is_intermediate) THEN\n"
           "!$omp target enter data map(to:%s%s)\n  ENDIF\n#endif\n", structname, fname);
```

- **Boundary arrays:** the same text after line 265, inside the `bdy` loop, with the `bdy_indicator(bdy)` suffix
  (`_bxs`, `_bxe`, `_bys`, `_bye`, and `_btxs...`).
- **Not-in-use dummies** (`ALLOCATE(grid%x(1,1,1))`, the `fprintf`s at lines 471/476): the same line after each,
  so present-lookups of unused driver arguments succeed.

**`gen_dealloc2`:** before each `DEALLOCATE` `fprintf` (lines 638, 660), emit
`!$omp target exit data map(delete:...)` under the same guard.

**Intermediate grids** are allocated and freed every parent step (`mediation_force_domain.F:99/:211`). They stay
host-only because of the `is_intermediate` guard.

**Test `T-MAP`:** after `wrf_init`, call `omp_target_is_present(c_loc(grid%u_2), omp_get_default_device())` for 20
sampled fields per domain. Pass: all present.

### P1.3 Generated update lists: new generator `WRF/tools/gen_gpu.c`

Call it from `registry.c` after `gen_alloc`. It walks `Domain.fields` and the 4D members (like `gen_alloc2`) and
writes the following files into `inc/`. Every line is guarded by `IF (in_use_for_config(grid%id,'<name>'))` and
`#ifdef WRF_GPU`.

| File | Content (one `!$omp target update` per field) | Used by |
|---|---|---|
| `gpu_upd_dev_all.inc` / `gpu_upd_host_all.inc` | every allocated field, including boundary arrays | init, debug, the Phase-1 nest-forcing bridge |
| `gpu_upd_dev_bdy.inc` | `*_b*` and `*_bt*` boundary arrays (`BOUNDARY_STREAM`) | after `med_latbound_in` and after nest forcing |
| `gpu_upd_host_force_slab.inc` | every field with `nest_mask & INTERP_DOWN`: the same predicate that generates `nest_interpdown_pack.inc` (`external/RSL_LITE/gen_comms.c:2686–2687, 3066`), which is exactly what `interp_domain_em_part1` sends from the parent. This includes every `f` field and its helper fields, e.g. `pc` (`registry.hyb_coord:56`) and `ht_shad` (`Registry.EM_COMMON:1412`), both flagged `df`. Each field is copied as a **j-slab** `(:,:,js:je)` or `(:,js:je)`. | nest forcing, parent side |
| `gpu_pack_force_strips.inc` | the device pack kernel body for the nest's FORCE_DOWN fields' spec-zone strips | nest forcing, child side |
| `gpu_upd_dev_force_full.inc` | FORCE_DOWN fields whose force function writes the whole nest field (non-`bdy_interp`, e.g. `o3rad` via `p2c`) | nest forcing, child side |

**History and restart transfers are not generated**, because the history contents can change at run time
(`iofields_filename`). Instead, `gpu_upd_host_stream(grid, stream)` walks `grid%head_statevars` (the linked list
built by `gen_allocs`, with `rfield_Nd` pointers and `streams(:)` masks). It does a `target update from` for every
field on that stream, and for a 4D array does one update of the whole array if any member is on the stream.

Each generated line looks like:

```fortran
IF (in_use_for_config(grid%id,'u')) THEN
!$omp target update from(grid%u_2)
ENDIF
```

Slab variants take `js, je` from the caller.

**Test `T-UPD`:** a debug switch runs `upd_host_all` then `upd_dev_all` every step. Results remain bitwise equal to
CPU-REF on `W-20` (G1).

### P1.4 Module tables to the device

Add `!$omp declare target(<list>)` in each module, and a routine `gpu_update_tables()` in
`WRF/share/module_gpu_tables.F` that issues `target update to` (or `enter data map(to:)` for allocatables).

| Module (file) | Data |
|---|---|
| `rrlw_kg01..16`, `rrlw_tbl`, `rrlw_wvn`, `rrlw_ref`, `rrlw_cld`, `rrlw_con`, `rrtmg_lw_rtrnmc` DATA, `rrtmg_lw_rad` (`retab`, `nlayers`) (`module_ra_rrtmg_lw.F`) | ≈ 0.75 MB. The EQUIVALENCE pairs are already flattened to 1D arrays in P0.9a (item 6). |
| `module_ra_sw` | `CSSCA`; DATA `ALBTAB`, `ABSTAB`, `XMUVAL` → module PARAMETERs |
| `sf_sfclayrev` (`physics_mmm/sf_sfclayrev.F90:14`) | `psim_stab`, `psim_unstab`, `psih_stab`, `psih_unstab(0:1000)` |
| generated `module_state_description` | the runtime `P_*` species indices (`P_QV`…`P_QG`, `P_m11`…; `INTEGER` variables, not PARAMETERs; `tools/gen_mod_state_descr.c:56`). `declare target` + update, or pass as firstprivate scalars. |
| `module_sf_noahlsm` (NL:24-63) | VEGPARM, SOILPARM, GENPARM arrays and scalars; `LUTYPE`/`SLTYPE` passed as integer codes instead of `CHARACTER(256)` (bit-neutral) |
| `mp_wsm6` (MC:45-63) | ~70 SAVE scalars |
| `module_fr_fire_util` | flags set by `set_flags` (`fire_upwinding`, `fire_viscosity*`, `fire_lsm_band_ngp`, `fire_lfn_ext_up`, `fire_advection`, `fire_grows_only`, `fire_upwind_split`, `fire_slope_factor`, `boundary_guard`, `fire_lsm_zcoupling*`, `fire_atm_feedback`, `fuel_left_*`, …) |
| `module_fr_fire_phys` | `cmbcnst` and any other scalar read in `heat_fluxes` |

**When:** after d01 init (P1.5) and after nest init. `set_flags` runs every fire call (`module_fr_fire_driver.F:124`)
with constant values, so hoist it to a once-per-domain init and update once. This is bit-neutral.

**Test `T-TAB`:** for each table, compute on the device a checksum identical to the host checksum (integer
bit-sum).

### P1.5 Sync-point wiring (exact places)

| # | File:line | Insert |
|---|---|---|
| S1 | `main/module_wrf_top.F:414`, after `CALL med_initialdata_input(head_grid, config_flags)` | `CALL gpu_update_tables(); CALL gpu_upd_dev_all(head_grid)` |
| S2 | `frame/module_integrate.F:351`, after `CALL med_nest_initial(grid, new_nest, config_flags)` | `CALL gpu_update_tables(); CALL gpu_upd_dev_all(new_nest); CALL gpu_upd_dev_all(grid)`. The parent's `start_domain` is re-run at `mediation_integrate.F:838`. |
| S2' | `frame/module_integrate.F:351`, **before** `med_nest_initial` | `CALL gpu_upd_host_all(grid)` (the parent). Needed when a nest opens after t=0: the parent's host copy is stale and is read by the nest interpolation. |
| S3 | **first executable statement of `SUBROUTINE med_hist_out`** (`share/mediation_integrate.F`) | `CALL gpu_upd_host_stream(grid, <history stream of this alarm>)`. Placing it inside the routine covers every call site: `:97`, `:104`, `:111`, the auxhist loop `:155`, and the **final frame** from `med_last_solve_io` (`:1092`). |
| S4 | **first executable statement of `SUBROUTINE med_restart_out`** | `CALL gpu_upd_host_stream(grid, RESTART_STREAM)`. Covers `:354`, the recursion over nests (`:1181`), and the **final restart** from `med_last_solve_io` (`:1110`). |
| S5 | `share/mediation_integrate.F:362`, after `CALL med_latbound_in(grid, config_flags)` | `IF (grid%id==1 .AND. config_flags%specified .AND. <bdy read this step>) CALL gpu_upd_dev_bdy(grid)` |
| S6 (Phase 1–4 form) | `frame/module_integrate.F:416`, around `CALL med_nest_force(grid_ptr, nest)` | before: `gpu_upd_host_all(grid_ptr)`, `gpu_upd_host_all(nest)`; after: `gpu_upd_dev_all(grid_ptr)`, `gpu_upd_dev_all(nest)`. The forcing couples and uncouples both domains' full state on the host (`x*m*(1/m) ≠ x` in general), writes the nest boundary arrays and `o3rad`, and sets `imask`, so everything must round-trip. P5.2 replaces this. |
| S7 | end of `wrf_finalize` | nothing (exit data happens in `dealloc_space_field`) |

"Bdy read this step" is detected by comparing `grid%dtbc` and the boundary-time alarm before and after the call, or
by adding a `LOGICAL, SAVE` set inside `med_latbound_in`'s read branch (`:1471`).

### P1.6 Persistent scratch pool (`i1` arrays)

**New module `WRF/frame/module_gpu_scratch.F`:**

```fortran
REAL, ALLOCATABLE, TARGET :: gpu_pool(:)          ! sized once: max over domains of Σ i1 array sizes
INTEGER(8) :: pool_off(n_i1)                        ! offsets (generated)
SUBROUTINE gpu_scratch_init()                       ! ALLOCATE + !$omp target enter data map(alloc:gpu_pool)
```

**Generator** (`WRF/tools/gen_defs.c`, `gen_i1_decls`, lines 90–135): under `#ifdef WRF_GPU` emit

```fortran
REAL, POINTER, CONTIGUOUS :: ru_tendf(:,:,:)
REAL, POINTER, CONTIGUOUS :: moist_tend(:,:,:,:)
```

instead of automatic arrays. Also emit a new `i1_assoc.inc`:

```fortran
ru_tendf(grid%sm31:grid%em31, grid%sm32:grid%em32, grid%sm33:grid%em33) => gpu_pool(o+1 : o+n)
```

with running offsets `o` and 64-byte alignment. Include `i1_assoc.inc` in `solve_em.F` before the first executable
statement (the `bench_solve_em_init.h` include at line 265).

**Build and semantics:**

- The pool is compiled into **both** builds (`-DWRF_POOL`, introduced in P0.9a before the reference run), so
  CPU-REF and GPU share the same scratch semantics.
- It is zero-filled once at allocation. The `target enter data map(alloc:)` exists only under `WRF_GPU`, preceded by
  a device zero-fill kernel.
- `T-SHARED-POOL` (P0.9a) records whether upstream ever reads uninitialized scratch.

**Test `T-POOL`:** `F-PRESENT` holds in the real build. For 10 sampled `i1` arrays per domain,
`omp_target_is_present` is true inside `solve_em`, and `T-NSYS` shows no copies of them.

### P1.7 Work arrays (large automatic arrays inside routines)

**New module `WRF/frame/module_gpu_work.F`:** named `REAL, ALLOCATABLE, TARGET` work arrays, allocated at init for
the largest domain (or the fire grid) and mapped once. Each routine replaces its automatic array by a pointer
remapped onto the work array, with identical bounds.

| Routine (file:line) | Automatic arrays |
|---|---|
| `advect_scalar_pd` (`module_advect_em.F:6146-6157`) | `fqx, fqy, fqz, fqxl, fqyl, fqzl, flux_out, ph_low` |
| `advance_w` (`module_small_step_em.F:1178`) | none needed: K-AW uses private fixed-size column arrays (`rhs_col`, `wdwn_col` of size `WRF_KMAX+1`) and private scalars (`msft_inv`, `dampwt`) |
| `solve_em` (ST:150–151) | `h_tendency`, `z_tendency` |
| `relax_bdy_scalar` (BCE:348) | `rscalar` |
| `vertical_diffusion_2` (DIF:4004) | `var_mix` |
| `rk_update_scalar(_pd)` (EM:1587/1803) | `tendency` |
| `advect_u/v/w/scalar` (pattern B, §7.2) | new `fqy3` (one reused 3D flux array) |
| `radiation_driver` (RD:953-991) | `cldfra1_flag, CEMISS, qc_temp, qi_save, qc_save, qs_save, q*_cu_weight, cldfra_cu, ozmixt(ims:ime,59,jms:jme), aerodt, ERBE_out(…,8), sflxd(…,4), GLAT, GLON, coszen_loc, hrang_loc, mask_loc, obscur_loc` |
| `couple_or_uncouple_em` (`dyn_em/couple_or_uncouple_em.F`) | the five mu work arrays |
| `interpolate_atm2fire` (`module_fr_fire_driver.F:1224-1225`) | `ua, va, altw, altub, altvb, hgtu, hgtv` |
| `fire_driver_em` (`module_fr_fire_driver.F:46–363`) | `lfn_out` |
| `fire_model` | `fuel_frac_burnt`, `fuel_frac_end` |
| `prop_ls_rk3` | `tend` |
| `reinit_ls_rk3` | `tend_1..3` are **unused**: delete them (bit-neutral) |
| `fire_tendency` (`module_fr_fire_atm.F`) | `prop_heat`, `hfx`, `qfx` |
| `surface_driver`, `pbl_driver`, `microphysics_driver` | 3D automatics (e.g. `u_phytmp`, `v_phytmp`) |

The work arrays are also in both builds (`-DWRF_POOL`, P0.9a) and are zero-filled once.

**Test `T-WORK`:** as `T-POOL`, for the work arrays.

### P1.8 Startup gate `WRF/share/module_gpu_check.F`

`SUBROUTINE gpu_check_config(id)` is called from `wrf_init` after the namelist is read and from
`alloc_and_configure_domain` for each nest.

- It compares `model_config_rec%<opt>(id)` against the allowed values in §2.2 (a table in the source) and stops with
  `wrf_error_fatal` listing every violation.
- It also pins the options that change executed code without being physics choices:
  - `mp_zero_out = 0`;
  - `bucket_mm < 0`, `bucket_J < 0`;
  - `prec_acc_dt = 0`, `acc_phy_tend = 0`;
  - `nwp_diagnostics = 0`, `output_diagnostics = 0`, `do_radar_ref = 0`;
  - `sfs_opt = 0`, `topo_shading = 0`, `slope_rad = 0`, `use_adaptive_time_step = .false.`;
  - `vert_refine_method = 0`;
  - `sr_x = sr_y` and **even** (odd ratios make `interpolate_2d` write overlapping fire nodes);
  - `e_vert - 1 ≤ WRF_KMAX`; RRTMG `NLAYERS ≤ WRF_NLAYMAX`.
- It also checks `numtiles = 1` and a single compute rank (quilting I/O ranks are allowed).
- For fire domains, it scans `nfuel_cat` after init and aborts on any value outside 1..204, or any value that
  `ksb()` maps to an index above `nfuelcats`. For example `204` (SB4) maps to 54 > 53 and would crash at
  `module_fr_fire_phys.F:1326`. The same check also runs in onboarding (§12).

### P1.9 Whole-`solve_em` island (Phase-1 mode)

- At the top of `solve_em` (after `i1_assoc.inc`): `CALL gpu_upd_host_all(grid)`.
- At the bottom: `CALL gpu_upd_dev_all(grid)`.
- All compute runs on the host, on one core.

This mode exercises mapping, updates, the pool and the sync points end to end. Phases 2–4 shrink the island from the
inside. Because the host part runs on one core, all Phase 1–4 windows use the dev case (P0.16).

### P1.10 NVTX ranges

- `port/nvtx/nvtx_shim.c`: `void wrf_nvtx_push(const char*)` / `wrf_nvtx_pop(void)` calling `nvtxRangePushA` /
  `nvtxRangePop` (NVTX3 headers from CUDA 12).
- Fortran `BIND(C)` interfaces are in `module_gpu_route.F`.
- Under `WRF_GPU`, redefine `BENCH_START(x)` / `BENCH_END(x)` in `inc/bench_solve_em_def.h` to call them with the
  timer name.
- Link with `-lnvToolsExt` or the NVTX3 header-only form (compile the shim with `nvc`).

### P1.11 Timing log

A new env switch `WRF_GPU_TIMING=1` prints, per simulated hour and per domain:

- wall seconds (from the existing `Timing for main` values);
- seconds in each NVTX range (host timers around the ranges, with `omp_get_wtime`, after
  `!$omp taskwait` / a device synchronize in timing mode only).

### P1.12 Memory log

`cudaMemGetInfo` via the C shim. Log free and total at startup, after each domain's init, after the first step of
each domain, and hourly. Record the peak.

### G1 — Phase 1 gate

- `T-MAP`, `T-TAB`, `T-POOL`, `T-WORK` pass.
- `T-UPD` passes.
- GPU-REPRO (whole-`solve_em` island, S6 Phase-1 form) is **bitwise** equal to CPU-REF on the dev case, on **both**
  A100 and H100 nodes:
  - `W-20` (level-2 trace);
  - the first 3 d01 steps from t=0 (27 d02 steps, including nest open and forcing);
  - one history write and one restart write inside those windows (compare the files).
- **G-MEM (1st check):** on the **full case**, `wrf_init` plus the first d01 step plus the first d02 step (with
  host compute) shows the logged peak (state + pool + work) ≤ 55 GB.
- The startup gate rejects a namelist with `cu_physics = 1` (negative test `T-GATE`).

---

## 7. Phase 2 — Dynamics kernels

### 7.0 Kernel coding standard (applies to Phases 2–5)

**Where directives go:** inside the existing routine, around each existing loop nest. The routine's signature and
call sites don't change, except that the call site gets the P0.8 island wrapper.

**Every routine gets:** `USE module_gpu_route, ONLY: gpu_on, R_<NAME>` and `USE module_repro_math`.

**Template A — pointwise 3D:**

```fortran
!$omp target teams loop collapse(3) if(target: gpu_on(R_X)) default(none) &
!$omp&  shared(<arrays>) firstprivate(<bounds and scalars>) private(<temporaries>)
DO j = j0, j1
DO k = k0, k1
DO i = i0, i1
   <original statements, unchanged>
END DO
END DO
END DO
```

`default(none)` is required while porting. Arrays are already present (P1.2/P1.6/P1.7), so the implicit map does
nothing.

**Template C — column recurrence:** `collapse(2)` over `j, i`, with the `k` loops sequential inside and in the
original order.

- A per-`j` slab `s(its:ite, kts:kte)` becomes a **private fixed-size** column array `s_col(WRF_KMAX+1)`, never a
  runtime-sized private (those would use the device heap; see `F-PRIVARR`).
- A per-`j` vector `v(its:ite)` becomes a private scalar.
- **Index-range guards:** statement groups in one source `j` iteration often use different `i` ranges. For
  example, `calc_ww_cp` zeroes `ww` over `its..ite` (BSU:713–715) but runs the recurrence over `its..itf`, and
  `advance_uv` uses `i_start_u_tend` (SS:804) vs `i_start_up` (SS:808). The column kernel runs over the union of the
  ranges, and every statement group keeps its own range as `IF (i >= lo_g .AND. i <= hi_g)`.

**Template D — kernels that call procedures:** use `!$omp target teams distribute parallel do collapse(n)` rather
than `teams loop` whenever the body calls a `declare target` routine (`F-CALLS`).

**Template G — boundary strip:** one kernel per strip, `collapse` over the strip's own loop nest. Strips whose
results depend on ordering (x-strips before y-strips, corner fixes) stay separate kernels in the original order.

**Rules:**

- **Once-before-the-loop initializations** of slab elements (`vflux(:,kts)=0`, `rhs(:,1)=0`) move inside the
  column code (the same value is written for each `j`). This is identical.
- **`config_flags%x` used inside a loop:** copy it to a local scalar before the kernel.
- **`grid%x` inside a loop:** pass the array as an argument, or associate a local `POINTER` before the kernel.
- **In-loop `WRITE`, `wrf_debug`, `wrf_message`:** replace with an integer counter (`reduction(+:)`). After the
  kernel, if the counter is > 0 and the debug level allows, do a host pass that prints what the original printed.
- **Unreachable error branches:** leave them in; they compile as device traps. Error branches that are reachable
  set an error flag (`reduction(max:)`) and `wrf_error_fatal` is called on the host after the kernel.
- **Statement functions:** keep them if `nvfortran` accepts them in target regions (check with `-Minfo=mp`).
  Otherwise convert each to a `PURE` internal function with the identical expression and `!$omp declare target`.
- **External calls inside loops:** inline them with identical arithmetic (e.g. `VPOW`→`rp_pow`), or mark them
  `declare target`.
- **Presence enforcement:** from Phase 2 on, if `F-DEFMAP` passed, every target construct carries
  `defaultmap(present)` (or `map(present, alloc: …)`), so an unmapped array is a runtime error instead of a silent
  per-launch copy.
- **NaN tests in device code:** `x /= x` (`F-NAN`).

**Test per routine:** `T-AB-<routine>` (P0.8).

**Test per sub-phase:**

- `T-TRACE-100`: dev case, window `W-100` (100 d02 steps from the 02:20 restart: ≥ 11 d01 steps, all 3 RK stages,
  both domains, fire active), level-2 trace, GPU-REPRO vs CPU-REF, restart-vs-restart, bitwise.
- `T-NSYS`: one `nsys` capture of `W-20`, counting **every** host↔device copy of any size. Every copy must be
  explained by an island, sync point or bridge that still exists.

### 7.1 P2.A — RK preparation and physical BCs

| Kernel | Routine (file:line) | Parallelization and restructuring |
|---|---|---|
| K-PREP-1 | `initialize_moist_old` (BSU:6640) | A |
| K-PREP-2 | `calculate_full` (BSU:3587) | A, 2D (writes one halo ring) |
| K-PREP-3a..d | `calc_mu_uv` (BSU:26), single-tile branches (95–116, 156–177) | A, 2D. Interior and edge loops are separate kernels, in order. |
| K-PREP-4a..c | `couple_momentum` (BSU:329) | A ×3 (`ru`, `rv`, `rw`) |
| K-PREP-5a | `calc_ww_cp` (BSU:640): `muu`, `muv` (698–708) | A ×2 |
| K-PREP-5b | `calc_ww_cp` main (710–779) | **C.** Per column: `dmdt=0`; for k=kts..ktf compute `divv(k)` into private `divv_col(WRF_KMAX)` and `dmdt += divv(k)` in k order; then `ww(k)` for k=2..ktf recurrence. `ww(1)=ww(kte)=0` inside. **Range guard:** the zeroing covers i=`its..ite` (BSU:713–715) while the recurrence covers `its..itf`. |
| K-PREP-6 | `calc_cq` (BSU:787, 822–870) | A over (i,k,j). The species sum `qtot` becomes a private scalar summed ispe=2..7 in order. `cqu`, `cqv`, `cqw` as in the source (`cqw` only for k=kts+1..ktf). |
| K-PREP-7 | `calc_alt` (BSU:910) | A |
| K-PREP-8 | `calc_php` (BSU:1227) | A |
| K-BC-3D-x, K-BC-3D-y | `set_physical_bc3d` (BC:651), open branches (867–923, 1061–1107) | G: the x-phase kernel runs over (j,k) and copies the i-edges; the y-phase kernel runs over (k,i) and copies the j-edges. **Two kernels, x before y** (the y copies read the x-halo corners). |
| K-BC-2D-x, K-BC-2D-y | `set_physical_bc2d` (BC:202), 388–424 and 558–601 | same as 3D |
| — | `rk_phys_bc_dry_1` (BCE:960) | caller only: 7 3D + 3 2D BC kernel calls |

`calc_mu_uv_1` (BSU:184) uses the same kernels as K-PREP-3 (K-PREP-3e..f).

**Gate G2.A:** `T-AB` for each routine; `T-TRACE-100`.

### 7.2 P2.B — Large-step tendencies (`rk_tendency`, EM:190)

| Kernel | Routine | Parallelization and restructuring |
|---|---|---|
| K-ZT-1 | `zero_tend` (BSU:4573), `zero_tend2d` (BSU:4611) | A; called 12 times |
| K-WWS-1 | `WW_SPLIT` (IEVA:49), non-IEVA branch 296–303 | A (writes one halo ring) |
| K-ADVU-Y1, K-ADVU-Y2 | `advect_u` y-flux `j_loop_y_flux_5` (ADV:553–647) | **B.** Y1 computes every face flux into `fqy3(i,k,j)` (pool) for j=max(jts,jds+1)..min(jte,jde-2)+1 with the same per-`j` branch (full `flux5` for jds+3..jde-3; 2nd order at jds+1/jde-1; `flux3` at jds+2/jde-2). Y2 computes `tendency(i,k,j-1) -= msfux(i,j-1)*rdy*(fqy3(i,k,j)-fqy3(i,k,j-1))` for j = start+1..end+1. |
| K-ADVU-X | `advect_u` x-flux (651–745) | Per (i,k,j) thread: compute `fqx` at faces i and i+1 inline, reusing the same branch per `i` (`flux5` / 2nd order upstream / `flux3`), then the tendency at 738–743. Identical expressions. Alternative: X1 fills `fqx3` then X2 takes the divergence (choose X1/X2 if register pressure is too high). |
| K-ADVU-Z | `advect_u` z-flux (v3, 1470–1498) | Per (i,j) column (C-style but no recurrence). Private `vflux_col(kts:kte)`; `vflux(kts)=vflux(kte)=0` **inside the kernel**; then the tendency loop. |
| K-ADVV-Y1/Y2/X/Z | `advect_v` (ADV:1530; y 1964–2066, x 2070–2171, z 2961–2994) | as `advect_u`. **Note** the xs edge loop has `i` outside `k` (2116–2134); inside the kernel, order doesn't matter. |
| K-ADVS-Y1/Y2/X/Z | `advect_scalar` (ADV:3029; y 3452–3547, x 3551–3649, z 4306–4333) | as `advect_u`. Used for θ every RK stage and for moist/TKE in RK stages 1–2 (via `rk_scalar_tend`). |
| K-ADVW-Y1/Y2/X/Z | `advect_w` (ADV:4364; y 4841–4969 including the extra `k=ktf+1` lid loops, x 4973–5096, z 5996–6031 including the lid term at 6026–6029) | as `advect_u` |
| K-RHSPH-1 | `rhs_ph` (BSU:1365) vertical (1459–1494) | C per column. Private `wdwn_col`. `phi_adv_z` copied to a scalar. |
| K-RHSPH-2 | `rhs_ph` gw term (1496–1510) | A |
| K-RHSPH-3..8 | `rhs_ph` y- and x-advection (1783–2070) | A. One kernel per original nest (6th-order interior, 4th/2nd-order edge rows, the separate `k=kte` passes). **Keep the quirk:** there's no 4th-order x-advection at i=ids+2 and ide-3 under specified/nested BCs (the branch at 1973–2019 is guarded by `open_xs/xe` only). |
| K-HPG-Y, K-HPG-X | `horizontal_pressure_gradient` (BSU:2183; y 2285–2319, x 2358–2394) | C per column (the `dpn` slab becomes a private `dpn_col(WRF_KMAX+1)`): `dpn(1)`, `dpn(kde)=0`, `dpn(2..ktf)`, then `dpy` and `rv_tend`. |
| K-PGB-1, K-PGB-2 | `pg_buoy_w` (BSU:2419) | K-PGB-1: the `k=kde` statement (reads the original `cqw(kde-1)`), A over (i,j). K-PGB-2: k=2..kde-1, A over (i,k,j); converts `cqw` in place. **Order: 1 then 2.** |
| K-WDAMP | `w_damp` (BSU:2503, 2635–2695) | A with `reduction(max: max_vert_cfl, max_horiz_cfl)` and `reduction(+: some1)`. The `rw_tend` update is unchanged. The argmax and in-loop `WRITE` are removed; if `some1 > 0` and the debug level is ≥ 100, a host pass prints them. `w_crit_cfl` and `w_damping` are copied to scalars. **Keep the quirk:** activation uses `w_beta`, the offset uses `w_crit_cfl`. |
| K-COR-U/V/W | `coriolis` (BSU:3640) | A ×3 |
| K-CURV-1..6 | `curvature` (BSU:4175) | K-1: `vxgm` (4273–4286). K-2: x-edge copies (4292–4312). K-3: y-edge copies (4317–4340). K-4/5/6: u, v, w tendencies. In order. |

`rk_tendency` itself: the six unused IEVA 2D automatic arrays are deleted (bit-neutral), and `nl_get_time_step`
stays on the host.

**Gate G2.B:** `T-AB` for each; `T-TRACE-100`.

### 7.3 P2.C — Tendency combination and lateral BCs

| Kernel | Routine | Parallelization and restructuring |
|---|---|---|
| K-MW | `mass_weight` (BCE:1716) | A (`rfield` → work array) |
| K-RLX-YS/YE/XS/XE | `relax_bdytend_core` (BC:1221; strips 1293–1422) | G ×4. X strips iterate `j` innermost in the source; collapse `(i,k,j)` over the strip. Private `fls0..fls4`. |
| — | `relax_bdy_dry` (BCE:161) | caller: 7 K-MW / K-RLX calls; `rfield` → work array (reused sequentially, as in the source) |
| K-ADT-U/V/W/PH/T/MU | `rk_addtend_dry` (EM:959, 1037–1090) | A ×6. The `rk_step==1` in-place `*_tendf += *_save*msf` stays inside (scalar test). |
| K-SPT-YS/YE/XS/XE | `spec_bdytend` (BC:1430) | G ×4 |
| — | `spec_bdy_dry` (BCE:413) | caller; the `w` call only on d02 |

**Gate G2.C:** `T-AB` for each; `T-TRACE-100`.

### 7.4 P2.D — Acoustic loop (7 sub-steps per step; most-launched kernels)

| Kernel | Routine | Parallelization and restructuring |
|---|---|---|
| K-SSP-1..4 | `small_step_prep` (SS:16; RK1 branch 128–192, RK>1 branch 194–217, common 223–288) | A; one kernel per original nest |
| K-CPR-1 | `calc_p_rho` (SS:438), non-hydrostatic 515–532 | A |
| K-CPR-2 | `calc_p_rho` smdiv (550–566) | A. `step==0` branch vs the `ptmp` branch chosen by a host scalar. |
| K-CCW | `calc_coef_w` (SS:570, 621–651) | C per column: `a(2)=0`, `a(kde)`, `gamma(1)=0`; `a(kk)`; forward `alpha`/`gamma` recurrence k=2..kde-1, then k=kde. `cof` is a scalar. |
| K-AUV-U, K-AUV-V | `advance_uv` (SS:654; `u_outer_j_loop` 802–871, `v_outer_j_loop` 873–946) | C per column. Private `dpn_col(WRF_KMAX+1)`, `dpxy_col(WRF_KMAX)`, scalar `mudf_xy`. Statement order inside the column exactly as in the source (u += dts·ru_tend, mudf, dpxy, dpn, dpxy +=, u -=, u +=). **Range guards:** `i_start_u_tend` (SS:804) vs `i_start_up` (SS:808). |
| K-SBU-YS/YE/XS/XE | `spec_bdyupdate` (BC:1955, 2011–2062) | G ×4. Called for u, v, t, mu_2, muts, and w (d02). |
| K-AMT-1 | `advance_mu_t` (SS:969, 1067–1122) | C per column: `dmdt=0`; for k: `dvdxi(k)` into private `dvdxi_col`, `dmdt += dnw(k)*dvdxi(k)` in k order; then the `mu`, `mudf`, `muts`, `muave` updates; the `ww` upward recurrence kk=2..k_end; then `ww -= ww_1`. |
| K-AMT-2 | `advance_mu_t` (1138–1145) | A |
| K-AMT-3 | `advance_mu_t` (1146–1174) | C per column: private `wdtn_col`; `wdtn(1)=wdtn(kde)=0`; the θ flux divergence. |
| K-AW | `advance_w` (SS:1178, 1308–1467) | **C per column, one kernel.** Private `rhs_col(WRF_KMAX+1)` with `rhs_col(1)=0` **set inside** (was once before the j loop, SS:1304–1306); private `wdwn_col(WRF_KMAX+1)`; `msft_inv` scalar. Statement groups in order: `t_2ave` and `rhs(k+1)`; `wdwn`; `rhs -=`; `rhs = ph + …`; surface `w(1)`; explicit `w`; top `w`; forward sweep; back sweep; **damp_opt=3 block with `dampwt` as a private scalar** and `rp_sin` (`sin(x)*sin(x)` evaluated as two calls, as in the source); `ph` update (descending k). `pi = 4.*rp_atan(1.)` (default REAL, as in the source) is computed on the host and passed firstprivate. |
| K-SFX-1..3 | `sumflux` (SS:1473) | A: zero at iteration 1 (1528–1538); accumulate (1545–1581, including staggered edges); last-iteration average (1583–1630) |
| K-SBUPH-YS/YE/XS/XE | `spec_bdyupdate_ph` (BCE:17, 80–155) | G ×4. `mu_old` becomes a private scalar (was a 2D array rewritten at every `k`). |
| K-ZGB-YS/YE/XS/XE | `zero_grad_bdy` (BC:2219, 2269–2330), d01 `w` | G ×4 |
| K-SSF-1..5 | `small_step_finish` (SS:295; 379–432) | A. The RK-stage branch (409–415 vs 418–425) is chosen by a host scalar. |

**Launch-count note (performance):** per d02 step there are 7 × (≈ 4 + 6 + 3 + 1 + 3 + 4 + 2 + BC strips) ≈ 150
acoustic launches. Fusion is optional and comes after G5 (§11.3, O2 and O7).

**Gate G2.D:** `T-AB` for each; `T-TRACE-100`.

### 7.5 P2.E — Scalar transport (6 moist species on both domains, TKE on d02)

| Kernel | Routine | Parallelization and restructuring |
|---|---|---|
| K-UPD-PD | `rk_update_scalar_pd` (EM:1803, 1881–1912) | A ×3: zero `tendency`; `tendency += sc_tend` and `sc_tend=0` in place; update with `muold`/`munew` as private scalars. `tendency` → work array. |
| — | `rk_scalar_tend` (EM:1096) | caller. `WW_SPLIT(ww_m)` (K-WWS-1) overwrites `wwE`, as in the source. The three `zero_tend` calls per species stay (K-ZT-1). **RK stages 1–2** call `advect_scalar` (K-ADVS-*); **stage 3** calls `advect_scalar_pd`. |
| K-PD-Y | `advect_scalar_pd` (ADV:6069) y-fluxes (6524–6649) | A over faces (i, k, j=face index): `fqy`, `fqyl` (already 3D, no rolling buffer). All 8 temporaries → work arrays. |
| K-PD-X | x-fluxes (6655–6777) | A |
| K-PD-Z | z-fluxes (7595–7645) | A per (i,k,j), with the k=1/kde zero writes as a separate small kernel first (K-PD-Z0). Keep the `c1(k)*mut+c2(k)` half-level quirk. |
| K-PD-L1 | limiter (a) `ph_low` (7724–7741) | A |
| K-PD-L2 | limiter (b) `flux_out` (7743–7758) | A |
| K-PD-L3a | limiter (c1), over **exactly the source's cell range** `[i_start,i_end]×[kts,ktf]×[j_start,j_end]` (ADV:7762ff): `scl(i,k,j) = max(0.,ph_low/(flux_out+eps))` if `flux_out > ph_low`, plus a logical work array `lim(i,k,j) = flux_out > ph_low` ("limited"; refined from a `-1.0` sentinel, see the end of this file) | A (new work arrays `scl`, `lim`) |
| K-PD-L3b | limiter (c2), per **face**, applying the source's rules exactly (ADV:7762–7779). **x-face f:** if `fqx(f) > 0` and the donor cell `f-1` is inside the cell range with `lim(f-1)`, then `fqx(f) = scl(f-1)*fqx(f)`; else if `fqx(f) < 0` and cell `f` is inside the range with `lim(f)`, then `fqx(f) = scl(f)*fqx(f)`; otherwise unchanged. This includes `fqx(f) == 0` (both tests strict, as in the source) and faces whose donor is outside the range (e.g. inflow at `i_start`, outflow at `i_end+1`). **y** is the same with j. **z** uses the reversed sign: `fqz(k) < 0` → donor `k-1`, `fqz(k) > 0` → donor `k`. Faces are only visited over the index ranges the source can reach. | A over faces (3 kernels: x, y, z). One multiply per face, by the same factor as the source, for exactly the faces the source scales. Identical results and no read/write race. **Unit test `T-PDLIM`:** host original vs split version on random and real states, including zero fluxes and range edges, bitwise. |
| K-PD-D | divergence z, x, y (7785–7883) | A ×3, in source order |
| K-RLXS | `relax_bdy_scalar` (BCE:348) | K-MW + K-RLX-*; `rscalar` → work array |
| K-SPS | `spec_bdy_scalar` (BCE:658) | K-SPT-* |
| K-UPD-1..3 | `rk_update_scalar` (EM:1587; RK1 1680–1730, RK>1 1736–1795) | A; private `muold`, `munew`; `tendency` → work array |
| K-FDB-YS/YE/XS/XE | `flow_dep_bdy` (BC:2335, 2377–2454) | G ×4 |
| K-BTKE | `bound_tke` (EM:2490) | A |

**Gate G2.E:** `T-AB` for each; `T-TRACE-100`, with a window that includes RK stage 3 of both domains (always
true).

### 7.6 P2.F — End of step

| Kernel | Routine | Parallelization and restructuring |
|---|---|---|
| K-CPRP-1 | `calc_p_rho_phi` (BSU:953), hypsometric al (1042–1051) | A; `LOG` → `rp_log` |
| K-CPRP-2 | `calc_p_rho_phi` moist p (1058–1078) | A: `temp = (r_d*(t0+t))/(p0*(al+alb))`; `p = rp_pow(temp, cpovcv)*p0 - pb`. This inlines `VPOW`/`vspow` (MASSV:375, `y**x`) with the identical rounded operation, because `rp_pow` is also used in the CPU-REF `vspow` (substitute there too). |
| — | `rk_phys_bc_dry_2` (BCE:1045), `set_phys_bc_dry_2` (BCE:808) | callers of K-BC-* |
| K-SBF-YS/YE/XS/XE | `spec_bdy_final` (BC:2066, 2146–2214) | G ×4. `msfcouple`/`mucouple` become scalars. |
| K-SWS | `set_w_surface` (BCE:1196, 1261–1282) | A, 2D |
| K-UPF | `update_phys_fields` (DD:1220, 1253–1260) | A; pass `grid%th_phy_m_t0`, `t_2` and `moist` as arguments (replacing the `grid%` references inside the loop) |
| — | `diagnostic_output_calc` (DMISC:13) | returns at 460 for this config; stays on the host (no state touched) |

**Gate G2.F:** `T-AB` for each; `T-TRACE-100`.

### 7.7 P2.G — Turbulence and LES (`first_rk_step_part2`)

| Kernel | Routine | Parallelization and restructuring |
|---|---|---|
| K-CDM-1..6 | `compute_diff_metrics` (DIF:6882; 6933–7128) | A. `z_at_w` → work; `rdzw`/`rdz` computed per column in private k order (the j-loop body 6933–6973 becomes C per column); `zx` in 2 passes; `zy`; edge zeroing; `z` at mass points. In order. |
| — | metric BCs (P2:443–498) | K-BC-* |
| K-DEF-01..40 | `cal_deform_and_div` (DIF:17) | One kernel per original nest (≈ 40), in source order. `tmp1`, `hat`, `hatavg`, `mm`, `zzavg`, `zeta_zd12` → work. The `config_flags%polar` test becomes a scalar. |
| K-N2-1..6 | `calculate_N2` (DIF:1485) | A ×6 in order: `qctmp`; zero; species accumulation (`tmp1 += moist`; species loop outside, sequential, as in the source); `qvs` (`EXP` → `rp_exp`); BN2 interior; surface (`**(R_d/Cp)` → `rp_pow`); top copy |
| K-SMAG | `smag2d_km` (DIF:1934; 2001–2042), d01 | A ×2; `diff_opt==2` test becomes a scalar; `def2` → work |
| K-TKEKM-1..4 | `tke_km` (DIF:2049; 2163–2226), d02 | A: `tke_seed`; `dthrdn` interior, surface, top (`rp_pow`); `mlen_s` with `rp_pow(…,0.5)` (spelled `**0.5` → `SQRT` is also allowed, since it's identical); `xkmh`/`xkmv`/`xkhh`/`xkhv` |
| — | `phy_bc` (DIF:5901) | caller of K-BC-* |
| K-TKES-1..9 | `tke_shear` (DIF:6529; 6678–6870) | A, one kernel per nest in order. Unused `zxavg`/`zyavg`/`titau`/`titau12`/`tmp1` are deleted (bit-neutral). |
| K-TKEB-1, K-TKEB-2 | `tke_buoyancy` (DIF:6234; 6325–6331, 6357–6367) | A ×2 |
| K-LSC | `calc_l_scale` (DIF:2341) | A (`**0.33333333` → `rp_pow`) |
| K-TKED | `tke_dissip` (DIF:6384; 6496–6523) | A (`rp_pow` for `**0.33333333` and `**1.5`); `km_opt` scalar |
| K-TKER | `tke_rhs` floor (DIF:6221–6227) | A |
| K-CTM | `conv_t_tendf_to_moist` (BSU:6674) | A |
| K-VD2-* | `vertical_diffusion_2` (DIF:4004), d02 | `var_mix` → work. Surface momentum flux u (4204–4221) and v (4223–4240): A 2D; `m_opt`/`sfs_opt` scalars; writes `nba_mij(…,P_m13/P_m23)` at kts. `var_mix` fill: A. Heat-flux surface term: A 2D. `vertical_diffusion_s` calls: see K-VDS. Moisture loop: species sequential on the host (as in the source); per species a K-VDS call plus the QV surface flux kernel. |
| K-VDU, K-VDV, K-VDW | `vertical_diffusion_u_2`/`_v_2`/`_w_2` (DIF:4463/4576/4688) | `cal_titau_*` (K-TT-*) then the tendency, A |
| K-VDS-1..3 | `vertical_diffusion_s` (DIF:4789) | A: `H3`; zero `H3(kts)`/`H3(ktf+1)`; tendency (with the TKE doubling). `xkxavg`, `rravg`, `tmptendf` → work. |
| K-HD2-* | `horizontal_diffusion_2` (DIF:2864) | callers: `_u_2`, `_v_2`, `_w_2`, `_s` (θ, TKE on d02, each moist species) |
| K-HDU-1..3, K-HDV-1..3, K-HDW-1..3 | `horizontal_diffusion_u_2`/`_v_2`/`_w_2` (DIF:3118/3323/3519) | `cal_titau_*`, then A nests in order |
| K-HDS-1..11 | `horizontal_diffusion_s` (DIF:3711; 3828–3997) | 11 A kernels in order. Arrays reused across phases stay reused; kernel boundaries give the needed ordering. |
| K-TT-11, K-TT-12, K-TT-13, K-TT-23 | `cal_titau_11_22_33` / `12_21` / `13_31` / `23_32` (DIF:5331/5456/5598/5749) | A. On d02 (`m_opt=1`) they write `nba_mij` (duplicate writers write identical values in separate kernels, so ordering is harmless). The k=kts/ktf+1 zeroing is a separate small kernel after the main one. |

**Gate G2.G:** `T-AB` for each; `T-TRACE-100`. Also `T-TRACE-TKE`: 1,000 d02 steps on the dev case covering TKE
and the `nba_mij` output fields (bitwise via the level-1 trace plus the `nba_mij` fields).

### G2 — Phase 2 gate

- All G2.A–G2.G pass on **A100 and H100**.
- The `solve_em` island now brackets only physics and fire calls.
- `T-NSYS` on `W-20`: only physics/fire islands and sync-point copies remain.
- **`T-DRIFT`** (reference drift): the CPU-REF build at this commit, run on CCR (multi-rank) over the dev case's
  1 h continuous window, equals the archived dev reference bitwise. This proves no shared-source change slipped in
  after P0.9a.

---

## 8. Phase 3 — Physics kernels (this case's schemes)

### 8.0 Column-physics transformation (CP-1..CP-5)

This applies to WSM6, YSU, sfclayrev, Dudhia, Noah, and RRTMG setup. It is bit-identical because it only remaps
indices; each column performs the same operations in the same order.

- **CP-1 gather/scatter wrapper.** Replace the wrapper's `DO j` slab loop with one kernel
  `!$omp target teams distribute parallel do collapse(2)` over `(j,i)` (Template D). Each thread copies its
  column's inputs from the 3D arrays into private fixed-size arrays `x_col(1,KMAX)`, calls the core routine, then
  copies the outputs back. The copies use the same expressions as the original slab copies (e.g. WSM6
  `t = th*pi`, and back `th = t/pi`). The original wrapper stays for CPU-REF (`#ifndef WRF_GPU`).
- **CP-2 1-column call.** Call the core routine with `its=ite=1`, `kts=1`, `kte=nz` (`nz` = the original
  `kte-kts+1`). Loops `DO i=its,ite` then run once per thread.
- **CP-3 fixed-size locals.** Under `#ifdef WRF_GPU`, every automatic array in the core routine and its callees
  that is dimensioned by `(its:ite, kts:kte)`, `(its:ite)` or `(kts:kte)` is redeclared with fixed bounds
  `(1:1, 1:KMAX)`, `(1:1)` or `(1:KMAX)`. Use the macro `GPUCOL2(a)`/`GPUCOL1(a)` in `inc/gpu_col.h`.
  - `KMAX` = cpp `WRF_KMAX` (default 64); for RRTMG, `WRF_NLAYMAX` (default 128).
  - `gpu_check_config` (P1.8) stops if `e_vert-1 > WRF_KMAX` or `NLAYERS > WRF_NLAYMAX`.
  - Automatic arrays in device code would otherwise use the slow, size-limited device heap.
  - **Whole-array syntax must be rewritten**, because the fixed arrays are longer than the active column:
    - `dz(:)=dzl(i,:)`, `wd(:)=ww(:)`, `precip(:)=0.0` (e.g. `mp_wsm6.F90:1798–1887`, `2045–2150`) become
      explicit sections `(1:km)`;
    - assumed-shape dummies (`dimension(its:,:)` in `mp_wsm6_run`) receive explicit sections `x_col(1:1,1:nz)` from
      the wrapper, so their shape is the active size, not `KMAX`.
  - Grep every CP-3 routine for `(:)`, `(:,:)`, `SIZE(`, `SHAPE(`, `LBOUND(` and `UBOUND(`; each hit is reviewed and
    listed in the commit message.
  - **Implicitly SAVEd initialized locals** (e.g. `REAL :: SNUPGRD = 0.02` in `SNFRAC`, `module_sf_noahlsm.F:2845`)
    become `PARAMETER` (done in P0.9a).
- **CP-4 device routines.** Mark the core routine and every callee `!$omp declare target`.
  - SAVE/module scalars → `declare target` (P1.4).
  - `errmsg`/`errflg` character assignments become an integer error code in device code. Messages are printed on
    the host from the code.
  - Internal procedures (e.g. `taugb1..16` inside `taumol`) become module procedures if the compiler rejects them.
  - `OPTIONAL`/`PRESENT()` tests are hoisted into host logicals passed as arguments.
- **CP-5 stack size.** Read each kernel's per-thread frame size from `-gpu=ptxinfo` output.
  - Set the device stack to `max_frame + 1 KB` with NVHPC's `NV_ACC_CUDA_STACKSIZE`. Read it back with
    `cudaDeviceGetLimit` through the shim at startup and abort if it's smaller. If `F-STACK` showed the env var
    doesn't apply, use `cudaDeviceSetLimit` from the shim.
  - Record the value in `port/ENVIRONMENT.md`.
  - The local-memory reservation is that value × max resident threads (A100 about 221k, H100 about 270k); add it
    to G-MEM.

### 8.1 P3.A — Physics glue (both domains, every step)

| Kernel | Routine | Parallelization and restructuring |
|---|---|---|
| — | `init_zero_tendency` (EM:1920) | K-ZT-1 ×N (moist slots 1..7, dummy chem/tracer/scalar slots) |
| K-PPR-1..7 | `phy_prep` (BSU:4730) | A: 4831–4837 (`th_phy`); 4848–4862 (`pi_phy=rp_pow(p_phy/p1000mb, rcp)`); 4866–4896; 4900–4907; 4912–4939 as 2D (`p8w(kde)=rp_exp(w1*rp_log(…)+w2*rp_log(…))`); **4950–4961 as C per column** (downward `p_hyd_w` recurrence with the species sum n=2..7 in order); 4965–4971. |
| K-CPT-1, K-CPT-2 | `calculate_phy_tend` (EM:2079) | A: radiation coupling `RTHRATEN *= (c1*mut+c2)` (2196–2202; on radiation steps only, host-scalar test as in the source); d01 YSU coupling (2334–2371) |
| K-A2A, K-A2CU, K-A2CV | `add_a2a` (ADDT:2285), `add_a2c_u` (2381), `add_a2c_v` (2435) | A. **Keep the quirk:** `add_a2c_v` runs k=kts..**kte**. |
| — | `update_phy_ten` (ADDT:28) | caller: `phy_ra_ten`; `phy_bl_ten` (d01); `phy_fr_ten` (d02: `t_tendf += rthfrten`, `moist_tend(P_QV) += rqvfrten`) |
| — | `advance_ppt` (ADDT:2059) | returns immediately (`cu_physics=0`); host |
| K-PP2-1, K-PP2-2 | `phy_prep_part2` (BSU:4980) | A: `RTHRATEN /= (c1*muts+c2)` (5095–5101); d01 BL decouple (5245–5282) |
| K-MPP-1..5 | `moist_physics_prep_em` (BSU:5394) | A: 5477–5497; 5506–5512; 5523–5549 (`rp_pow`); 5553–5559; 5564–5587 (`rp_exp`/`rp_log`, 2D) |
| K-MPF | `moist_physics_finish_em` (BSU:5593; 5682–5768) | A. The `mptenmax/min` argmax/argmin are never used, so they are removed (bit-neutral). `use_theta_m` and `mp_tend_lim*dt` become scalars. Keep the backslash-continued statements exactly. |
| — | `set_physical_bc3d(h_diabatic)` (ST:4105) | K-BC-* |

**Gate G3.A:** `T-AB` for each; `T-TRACE-100`.

### 8.2 P3.B — WSM6 (both domains, every step, after the RK loop)

| Kernel / change | Where | What |
|---|---|---|
| K-WSM6 | `wsm6` (MW:17–236) | CP-1: `collapse(2)` over (j,i). The column gather replicates MW:115–146 per column, including `t=th*pi`, and copies the column's surface accumulators (`rain`, `rainncv`, `snow`, `snowncv`, `graupel`, `graupelncv`, `sr`) into 1-element private arrays. Call `mp_wsm6_run(its=1, ite=1, kts=1, kte=nz, …)` (MC:213); the accumulations happen **inside** `mp_wsm6_run` (MC:740–771), as in the source. Scatter replicates MW:161–189 (`th=t/pi`, the hydrometeors) and writes the accumulators back. |
| CP-3 | `mp_wsm6_run` (MC:213–1468) | ≈ 78 `(its:ite,kts:kte)` automatics (including 10 of shape `(…,3)` at MC:318–328) → fixed. Callees: `slope_wsm6` (1525–1602), `slope_rain`, `slope_snow`, `slope_graup`, `nislfv_rain_plm` (1751–1994), `nislfv_rain_plm6` (1997–2272): ≈ 27 k-vectors → fixed. |
| CP-4 | as above, plus `vrec`, `vsqrt` (`physics_mmm/module_libmassv.F90`) | `declare target`. Statement functions `cpmcal`, `xlcal`, `diffus`, `viscos`, `xka`, `diffac`, `venfac`, `conden` (MC:418–431) and `lamdar/s/g` (1549–1551): keep, or convert to pure internal functions. ≈ 70 SAVE scalars → `declare target`. |
| rp_* | MC | exp 32, log 9, log10 1, real pow 31 (§P0.6) |
| effective radius | `mp_wsm6_effectRad_run` (ME:59) | returns at ME:115 (`has_req*=0`). The GPU wrapper skips the call and the `re_*` copies (unchanged values). Bit-neutral. |
| minor loop | MC:483–487 | `loops = max(nint(dt/120),1) = 1` for both domains (`dt ≤ 3 s`); keep the general code |

**Tests:**

- `T-AB-wsm6`.
- `T-WSM6-COL`: for 10⁵ columns sampled from the CPU-REF state at 02:30, CPU-REF column results vs GPU
  bit-compare, run as a standalone harness in `port/tests/wsm6/` linking the same objects.

**Gate G3.B:** the above plus `T-TRACE-100`.

### 8.3 P3.C — Surface: `surface_driver`, sfclayrev, Noah, sea ice, diagnostics (both domains, every step)

| Kernel / change | Where | What |
|---|---|---|
| K-SD-1..8 | `surface_driver` (SD:7–4502) | A/2D kernels, in source order: zero `u_phytmp`, `v_phytmp`, QGH, CHS, CPM, CHS2 (1537–1554); `RAINBL` accumulation (1560–1595); `PSFC` and the u/v copies (1980–1998); `ch=chs` (2131–2136); `uratx`, `vratx`, `tratx` (2472–2490, `rp_pow`); `vdfg=0` (2494–2500); `RA = WSPD/UST**2.0` → `UST*UST` rule (2654); accumulations `SFCEVP`, `SFCEXC`, `ACHFX`, `ACLHF`, `ACGRDFLX` (2983–2992); `RAINBL=0` (4430–4441); Q2 cap (4447–4458). 3D automatics → work (P1.7). |
| K-SFCLAY | `SFCLAYREV` (SLW:16–278) → `sf_sfclayrev_pre_run` (SLW:281–315) → `sf_sfclayrev_run` (SLC:78–919) | CP-1..CP-4, per point (only level `kts` is used; gather the k=1 values only, which matches the wrapper's copy of all k for level 1). `zolri` (SLC:922–957), `zolri2` (960–981), `psim/psih` table lookups (1034–1095) and `*_full` fallbacks (987–1030) → `declare target`. ψ tables → `declare target` (P1.4). |
| UB fix | `zolri` (SLC:943) | It can return an unassigned result when `fx1==fx2` on the first pass. Initialize the result to the current iterate before the loop, **in both builds**, and add a counter. `T-ZOLRI`: the CPU-REF reference run (instrumented once) records 0 occurrences, which proves the fix is bit-neutral for this case. |
| K-LSM | `lsm` (ND:38–1779) → `SFLX` (NL:69–888) and the whole tree (`REDPRM`, `CSNOW`, `SNOW_NEW`, `SNFRAC`, `ALCALC`, `TDFCND`, `SNOWZ0`, `PENMAN`, `CANRES`, `NOPAC`, `EVAPO`, `DEVAP`, `TRANSP`, `SMFLX`, `FAC2MIT`, `SRT`, `WDFCND`, `SSTEP`, `ROSR12`, `SHFLX`, `HRT`, `TBND`, `TMPAVG`, `SNKSRC`, `FRH2O`, `HSTEP`, `SNOPAC`, `SNOWPACK`) and `SFLX_GLACIAL` (NGL:31) | Per point: `collapse(2)` over (j,i), one thread runs ND:791–1596 for its point, including the one-time `itimestep==1` block (749–788; host-scalar test). **Changes:** `iloc`/`jloc` threadprivate module variables (NL:63–64) → private locals passed as arguments; `LUTYPE`/`SLTYPE` `CHARACTER(256)` → integer codes; `FATAL_ERROR` (NL:511, 2434–2440, 2505–2507), `PRINT` (NL:1573) → error codes reduced and reported on the host; NSOIL-sized locals → fixed (`WRF_NSOILMAX=4`); ND:681–691 2D automatics → work. Keep `DO K=1,4` at NL:823. |
| K-SEAICE | `seaice_noah` (NSI:14–500) | per point; cycles unless `XICE ≥ 0.5`; error branch → code |
| K-SFCDIAG | `SFCDIAGS` (DG:7–77) | A 2D (`rp_pow`) |

**Tests:**

- `T-AB-surface_driver` (whole driver);
- `T-AB-sfclayrev`, `T-AB-lsm`;
- `T-NOAH-PT`: standalone Noah per point, 10⁵ points from the CPU-REF state, host vs device bitwise;
- `T-ZOLRI`.

**Gate G3.C:** the above plus `T-TRACE-100`.

### 8.4 P3.D — YSU PBL (d01 only; d02 returns at PD:885)

| Kernel / change | Where | What |
|---|---|---|
| K-PBLD-1 | `pbl_driver` (PD:1016–1148) | A: saves `TSKOLD`, `USTOLD`, `ZNTOLD`, `HPBL_HOLD`, the u/v copies and `PSFC`; zeroes the BL tendencies |
| K-YSU | `ysu` (YW:17–474) → `bl_ysu_run` (YC:56–1419) | CP-1..CP-4: gather replicates the YW:318–377 slab copies per column; call `bl_ysu_run(its=1, ite=1, kts=1, kte=nz, …)`; scatter replicates YW:441–471 (`rthblten/pi3d`, etc.). ≈ 50 `(its:ite,kts:kte)` arrays + `zq(its:ite,kme)` + ≈ 40 vectors → fixed. Callees `tridin_ysu` (YC:1514–1582), `tridi2n` (1422–1510), `get_pblh` (1585–1692) → `declare target`. |
| **OOB fix** | YW:351–377 | Copies `a_u_bep(i,k,j)` … (13 BEP arrays) that are allocated as `(1,1,1)` when urban is off. Guard with `IF (flag_bep)` **in both builds**; the values are never used when the flag is false, so this is bit-neutral. |
| `get_pblh` | YC:1624 `DO WHILE` without a bounds guard | keep as is (it terminates for physical profiles); the column harness asserts termination |
| — | `diff4d` (PD:2598–2726) | no-op (`num_tracer < PARAM_FIRST_SCALAR`) |

**Tests:** `T-AB-ysu`; `T-YSU-COL` (as `T-WSM6-COL`); `T-TRACE-100` (d01 steps).

**Gate G3.D:** the above.

### 8.5 P3.E — Radiation (both domains; every step plus radiation steps: d01 every 20 steps, d02 every 180)

**Every step (radiation step or not):**

| Kernel | Where | What |
|---|---|---|
| K-RAD-ACC | RD:3170–3209 | A 2D: LW flux accumulations `+= flux*DT` |
| K-RAD-CLDT | RD:3255–3281 | C per column: product `1 − Π(1 − cldfra)` in k order |
| — | `pre_radiation_driver` (RD:3285–3463) | host (the MPI `minval` runs only at `itimestep=1`) |

**Radiation steps** (`run_param` decided on the host, RD:1111–1138):

| Kernel / change | Where | What |
|---|---|---|
| host | `radconst` (RD:3469–3511) | host scalars (`rp_*` trig) |
| K-RAD-ECL | `solar_eclipse` (ECL:29; 140–146) | A 2D zero of `obscur`/`mask` |
| K-RAD-COSZ | `calc_coszen` (RD:3514–3541) | A 2D (`rp_*` trig) |
| — | q save/restore (RD:1212–1260, 3107–3168) | no-ops for this config; skipped under a host test that proves they're no-ops (cu off, no BL clouds). Bit-neutral. |
| K-RAD-CF0, K-RAD-CF1 | zero `CLDFRA` (RD:1310–1316); `cal_cldfra1` (RD:3761–3986) | A 3D (`rp_exp` ×2, `rp_pow` ×2) |
| K-RAD-Z | RD:1719–1743 | A: zero GSW, GLW, SWDOWN, `swddir`, `swddni`, `swddif`; GLAT/GLON; zero `RTHRATEN*` and `CEMISS` for k=kts..kte+1 |
| K-OZT | `ozn_time_int` (RD:4864–4969), **d01 only** | A over (i, 59 levels, j) |
| K-OZP | `ozn_p_int` (RD:4971–5105), **d01 only** | **One thread per j-row** (refined; see the end of this file): the original shares a `kkstart`/`kount` search shortcut across `i` in a j-slab (`goto 35`), so a column's result can depend on the other columns of its row. The row-parallel version keeps the row's i loops unchanged inside one thread; `pmid` and `kupper` become work arrays with a j index; `goto 35` becomes a flag and `EXIT`; `wrf_error_fatal` (RD:5097) → error code. Reference: `port/tests/ozn/t_ozn.F90`. |
| host | `read_CAMgases` (LW:11969) | called once per radiation call on the host (outside kernels); returns the scalars `co2`, `n2o`, `ch4`, `cfc11`, `cfc12` (REAL(8)); passed as kernel firstprivates |
| hoist | `RRTMG_LWINIT` (RD:2041) → `rrtmg_lw_ini` (LW:7976–8123) | Called every radiation call in the source; it rebuilds identical host tables. Call it **once** at init (after `phy_init`) and upload the tables (P1.4). `NLAYERS = kme + nint(p_top*0.01/4) − 1 = 109` for this case (module variable, constant). Bit-neutral; `T-TAB` verifies the table checksums. |
| K-RRTMG-* | `RRTMG_LWRAD` (LW:11570–12838) | See the RRTMG design below. |
| K-RAD-LWPOST | RD:2252–2262 | A: `RTHRATENLW = RTHRATEN`, `OLR = RLWTOA` |
| K-SW | `SWRAD` (SW:10–247) → `SWPARA` (SW:250–515) | CP-1..CP-4 per column: reverse the column (NK) as in the source; night columns exit early (GOTO 7); the `SDOWN(K+1)` recurrence is sequential; `rp_pow(…,0.635)`, `rp_log10`; DATA tables `ALBTAB`, `ABSTAB`, `XMUVAL` → PARAMETER. `GSW` and `RTHRATEN +=` as in SW:238–242. |
| K-RAD-SWPOST | RD:2866–2928 | A 2D/3D: `RTHRATENSW = RTHRATEN − RTHRATENLW`; `SWDOWN = GSW/(1−ALBEDO)`; the direct/diffuse split at `coszen > 1e-3` (`rp_exp` ×3, nested `rp_exp(-rp_exp(…))`, `rp_asin`, `rp_pow`); `diffuse_frac` |
| o3rad (d02) | nest forcing (P5.2 step 6) | **eager** `target update to(nest%o3rad)` after every forcing (≈ 162 MB per d01 step, ≈ 3.3 TB over the run, ≈ 2–3 min at host-link bandwidth). A lazy variant (upload only before the next d02 radiation call) is performance item O10; it must then exclude `o3rad` from the restart D2H while dirty. |

**RRTMG LW design (K-RRTMG-*):**

- **Tables:** the P1.4 upload, with the EQUIVALENCE in `rrlw_kg01..16` removed as follows. Each `ka`/`absa` pair
  becomes one 1D storage array `ka_s(nka*ng)`. Each `absa(ind,ig)` reference in `taugbN` becomes
  `ka_s(ind + (ig-1)*nka)`; each `ka(a,b,c,ig)` reference becomes the column-major linear index. Same storage
  order, same values, so identical results.
- **Batching:** columns are processed in batches of `B` (env `WRF_RRTMG_BATCH`, default 4096; per-column scratch
  ≈ 2.5k·NL words ≈ 1.1 MB at NL=109, so ≈ 4.5 GB per batch).
  - Every per-column automatic array in `RRTMG_LWRAD` (≈ 760·NL words), `rrtmg_lw` (≈ 1270·NL),
    `generate_stochastic_clouds` (`CDF`, `CDF2`, `iscloudy` 140·NL, plus the unused 625-int Mersenne state →
    delete), `rtrnmc` (`abscld`, `efclfrac`, `odcld`) and `cldprmc`/`setcoef`/`inatm` locals is **hoisted** into a
    batch work array with a trailing index `b` (e.g. `taug_w(NL, 140, B)`).
  - The routine receives `taug_w(:,:,b)` as an explicit-shape dummy of its original shape, so the code body is
    unchanged apart from its declarations.
- **Kernel K-RRTMG-COL** (correctness version): `collapse(1)` over `b` (one thread per column). Each thread runs,
  in the original order:
  - the column setup (LW:11993–12430), including the buffer layers against `PPROF`/`TPROF` (DATA → PARAMETER),
    `INIRAD`/`O3DATA`, `relcalc`, `reicalc`, and `reice*1.0315` / min 140;
  - `mcica_subcol_lw` → `generate_stochastic_clouds` → `kissvec` (KISS, integer, seeded from `pmid` fractional
    parts; 150 warm-up draws);
  - `rrtmg_lw(ncol=1)`: `inatm`, `cldprmc`, `setcoef`, `taumol` (`taugb1..16`), `taut=taug+taua`, `rtrnmc`;
  - the outputs (LW:12782–12830).

  Host loops over batches: `DO b0 = 1, ncol, B`.
- **Error branches:** `STOP` (LW:2188, 2426, 2911, 2925, 2930, 2940, 3004) and `wrf_error_fatal` (2959, 2981) →
  error codes checked on the host.
- **`mod(x,1.0)`** in `taumol` (44 calls) → `rp_mod`.
- **Performance version** (P6, only if the profile warrants it; still bit-identical):
  - K-RRTMG-TAU: over `(b, layer)` with the `ig` loop inside `taugbN`.
  - K-RRTMG-RT1: over `(b, ig)` running the per-g-point vertical recurrences of `rtrnmc` into `urad_g`/`drad_g`
    work arrays.
  - K-RRTMG-RT2: over `(b, level)`, summing the g-point contributions **sequentially in the original band/g order**.

**Tests:**

- `T-KISS`: `kissvec` streams for 10⁶ seeds, host vs device, bitwise (checks 32-bit wraparound).
- `T-OZN`: the row-parallel `ozn_p_int` vs the original (`port/tests/ozn/`), host and device, bitwise, including
  non-monotone columns and levels exactly at ozone levels.
- `T-RRTMG-COL`: 10⁵ columns from the CPU-REF state at 02:00 and 12:00, host vs device, bitwise
  (`rthratenlw`, `glw`, fluxes).
- `T-AB-radiation_driver` on window `W-RAD`.
- `T-TRACE-RAD`: dev case, window `W-RAD` (720 d02 steps = 80 d01 steps from 02:20, containing 4 radiation calls
  on each domain), level 2, bitwise.

**Gate G3.E:** the above.

### G3 — Phase 3 gate

- G3.A–E pass on A100 and H100.
- The `solve_em` island now brackets only `fire_driver_em_step`.
- `T-TRACE-RAD` bitwise.
- `T-NSYS` on `W-20`.
- **G-MEM (2nd check):** on the full case, 1 d01 step including a radiation call on both domains (first step)
  with physics on the device; logged peak ≤ 70 GB.
- `T-DRIFT` (as in G2).

---

## 9. Phase 4 — WRF-Fire kernels (d02, every step at RK stage 1)

### 9.0 Preparation (already done in P0.9a, item 5; listed here with exact locations)

These are shared refactors, so they were applied in both builds **before** the reference run (P0.9a). Phase 4
only adds the GPU kernels below.

| Change | Where |
|---|---|
| Hoist `set_flags` (module flags from `config_flags`) out of every call to once per domain at init; upload with P1.4 | `module_fr_fire_driver.F:124` → call from `fire_driver_em_init` |
| Replace `fp%…` pointer-component use inside loops with explicit array arguments (`vx=grid%uf`, `vy=grid%vf`, `zsf`, `dzdxf`, `dzdyf`, `bbb`, `betafl`, `phiwc`, `r_0`, `fgip`, `ischap`, `iboros`, `fmc_g`) passed down to `tend_ls` → `fire_ros` and `heat_fluxes` | `module_fr_fire_driver.F:105–117`, `module_fr_fire_core.F`, `module_fr_fire_phys.F` |
| Replace the float-sum NaN checks in `print_2d_stats` and `print_3d_stats` with an integer any-NaN count (`x /= x`, see `F-NAN`); crash on the host as before. `print_2d_stats_vec` is not called in this configuration; leave it unchanged on the host. | `module_fr_fire_util.F:1122–1191, 1068–1075` |
| Remove the unused `tend_1..3` automatics | `reinit_ls_rk3` (`module_fr_fire_core.F:1510`) |
| Remove the dead post-loop ignition check | `module_fr_fire_driver.F:975–994` |
| Remove internal `WRITE`s and `CRITICAL` blocks inside loops (messages only; `fire_print_msg=0`); keep those outside kernels on the host | `continue_at_boundary` (util:337–374); `ignite_fire` (core:206–243) |
| Fire automatics → work arrays (P1.7) | `lfn_out`, `ua`, `va`, `altw`, `altub`, `altvb`, `hgtu`, `hgtv`, `fuel_frac_burnt`, `fuel_frac_end`, `tend`, `hfx`, `qfx`; `prop_heat` is unused with `fire_sfc_flx=0` (keep allocated, don't zero, or delete if unused) |

**Test `T-FIRE-REF`** is `T-SHARED-5` (P0.9a): the CPU-REF build with these refactors equals the unrefactored
`nvfortran` CPU build over the dev-case window, bitwise. That proves the refactors are bit-neutral, and the archived
reference already contains them.

### 9.1 Fire kernels

| Kernel | Routine | Parallelization and restructuring |
|---|---|---|
| K-A2F-1 | `interpolate_atm2fire` (driver:1172) NaN init (1241–1247) | A (kept; cheap) |
| K-A2F-2 | `altw` (1317–1323) | A 3D |
| K-A2F-3, K-A2F-4 | `altub`/`hgtu` (1338–1349); `altvb`/`hgtv` (1363–1374) | A 3D (stencils i−1, j−1) |
| host | zcoupling constants (1383–1389) | `logfwh=rp_log(60.)` etc. |
| K-A2F-5, K-A2F-7 | u log interpolation (1393–1420); v (1429–1455) | per point `collapse(2)`; sequential k-search with early exit (same `GOTO 10` semantics as a `EXIT`); `rp_log` |
| K-A2F-6, K-A2F-8 | `ua(1,j)=ua(2,j)`; `va(i,1)=va(i,2)` | 1D |
| K-A2F-9 | `uah`/`vah` store (1461–1472) | A 2D (`DEBUG_OUT` is defined) |
| K-CAB-J, K-CAB-I, K-CAB-C | `continue_at_boundary` (util:293–391) | three kernels in order: j-strips, i-strips, corners (internal `EX` function → `declare target`) |
| K-A2F-12 | `uah`/`vah` store (1495–1500) | A 2D |
| K-I2D | `interpolate_2d` (util:519–591) | `collapse(2)` over coarse `(j2,i2)`; each thread writes its 4×4 fine nodes (no overlaps; ceiling/floor exact) |
| K-A2F-15 | zcoupling on the fire tile (1578–1591) | A 2D: `wsf=max(sqrt(uf*uf+vf*vf),0.1)` (the `**2.` → `x*x` rule); `rp_log` ×2 |
| K-NAN | stats checks | any-NaN reductions |
| K-PLS-0 | `prop_ls_rk3` (core:1271): `lfn_0 = lfn` | A 2D |
| K-TLS | `tend_ls` (core:1886–2124), called 3× | K-CAB on the input first. Then `collapse(2)` over (j,i) of the fire tile 1..3240: one-sided differences; ENO1 within 10 points of the edge; else `abs(lfn) < fire_lsm_band_ngp*dx` → WENO5 (`select_4th` ×4, `select_weno5` ×2) else ENO (`select_eno` ×2); `grad=sqrt(…)`; `scale=sqrt(grad*grad+eps)` (the `**2.0` rule); normals; `fire_ros(...)` inline or `declare target` (reads explicit arrays); `rr`, `max(rr,0)`; `te=-rr*grad`; artificial viscosity (`fire_viscosity_ngp=2` from the registry default; all branches give 0.4); `reduction(max:tb)`; then `tbound=1/(tb+tol)` on the host. |
| K-PLS-1..3 | stage updates (`lfn_1`, `lfn_2`, `lfn_out`, `lfn_2=lfn_out`) | A 2D; `dt/3`, `dt/2`, `dt` as in the source |
| K-ROS | `fire_ros` (phys:1540–1670) | `declare target`; Rothermel `ibeh=1`; `rp_pow` for `umid**bbb` and `betafl**(-0.3)`; **keep the `ros_max` capping quirk (1651–1657)** |
| K-TIGN-1 | `tign_update` (core:1806–1815) | A 2D |
| K-TIGN-G | boundary guard (core:1817–1842) | integer any-reduction over the guard strips; the host crashes with the original message |
| K-FLAME | `calc_flame_length` (core:1853–1880) | A 2D (`rp_pow(…,0.46)`) |
| K-RI-0 | `reinit_ls_rk3` (core:1574–1579) | A 2D: `lfn_s0 = lfn_2/sqrt(lfn_2*lfn_2+dx*dx)`; `lfn_s3=lfn_2` |
| K-ALR ×3 | `advance_ls_reinit` (core:1673–1769) | A 2D, stencil ±3 on `lfn_curr`; edge ENO1; case-4 signed threshold; K-CAB between stages exactly as in the source (s3, s1, s2, s3); the last call has `lfn_ini` and `lfn_fin` as the same array (pointwise, so safe) |
| K-RI-F | final `lfn_out = min(lfn_s3, lfn)` (1660–1665) | A 2D |
| K-FM5 | `fire_model` ifun=5 copy (model:368–374) | A 2D |
| K-IGN | `ignite_fire` (core:85–256) with `nearest` (260–336) | Host early-exit window test (returns unless 8280 ≤ end_ts and start_ts ≤ 10080). Then `collapse(2)` per point: distance, `lfn_new`, the `tign` clamp (counter replaces the in-loop WARNING), `lfn=min(lfn,lfn_new)`; integer `reduction(+:ignited)`, `reduction(max/min)` for `dmax`/`dmin` (messages only) |
| K-FL-1 | `fuel_left` (core:343–583) | `collapse(2)` over cells (`jcl` outer, `icl` inner in the kernel; the source order `icl` outer is irrelevant because cells are independent); 4 subcells sequential in source order; `fuel_left_cell_1` (core:589–731) `declare target` (`rp_exp`); crash checks → flags. Reads the ghost cells 0/3241 of `lfn` and `tign` (the zeros from allocation are on the device because of `map(to:)` in P1.2). |
| K-FL-2, K-FL-3 | normalization (551–556); check loop (559–575) | A 2D; flag plus `fmax` (message only) |
| K-FM6 | ifun=6 update (model:446–452) | A 2D |
| K-HF | `heat_fluxes` (phys:1411–1448) | A 2D (`cmbcnst` `declare target`) |
| K-S2D ×3 | `sum_2d_cells` (util:427–514) | `collapse(2)` over atmospheric cells; inner `joff`/`ioff` loops sequential in source order |
| K-FSC | scaling (driver:942–955) | A 2D |
| K-FT-1 | `fire_tendency` (atm:112): zero `hfx`, `qfx` (177–184) | A 3D |
| K-FT-2 | fluxes per (i,k,j), `fire_sfc_flx=0` branch | A 3D (`rp_exp` ×2–4); `wrf_error_fatal` branch → code |
| K-FT-3 | divergence (286–297) | A 3D (reads `hfx(k+1)` from K-FT-2) |

Fire halo includes are no-ops (one rank; `rsl_comm_iter` never iterates).

`time_start = itimestep*dt` stays on the host. `fire_ignition_convert` stays on the host (scalars).

**Tests:**

- `T-AB-<each fire routine>` on `W-100`.
- `T-FIRE-IGN`: dev case, restart-vs-restart from the **02:00** restart through 02:35 (6,300 d02 steps): covers the
  whole 8280–9080 s ignition phase (02:18–02:31:20) and the first minutes of free spread. Level-1 trace with all
  fire arrays at every step; level 2 for the first 100 steps after 8280 s. Bitwise.
- `T-FIRE-WIN`: dev case, restart-vs-restart, 02:20 → 03:00 (7,200 d02 steps). Level-1 trace with all fire arrays,
  bitwise. Compare the 02:30, 02:45 and 03:00 history frames with `compare_fire.py`.
- `T-FIRE-GHOST`: the device copy of `lfn`/`tign_g` has 0.0 in ghost rows/columns 0 and 3241 after init (and 0 and
  725 on the dev case).

**Gate G4:**

- The above on A100 and H100.
- `compare_fire.py` reports 0 differing cells at 02:30, 02:45 and 03:00.
- `solve_em` has no islands left (P5.3 removes the bracket code).
- `T-NSYS` on `W-20`.
- `T-DRIFT` (as in G2).

---

## 10. Phase 5 — Nest forcing, sync points, full-run acceptance

### P5.1 `couple_or_uncouple_em` on the device

`dyn_em/couple_or_uncouple_em.F`. All loops run over the **patch clipped to the domain**, not the halo:
`j = max(jds,jps)..min(jde-1,jpe)` (`v`: `..min(jde,jpe)`), `i = max(ids,ips)..min(ide-1,ipe)` (`u`:
`..min(ide,ipe)`), exactly as in the source. The periodic branches (86–105, 351ff) are inactive
(`gpu_check_config` rejects periodic BCs), and the halo includes are no-ops on one rank.

| Kernel | Lines | What |
|---|---|---|
| K-CPL-MU-1 | couple 119–126 / uncouple 193–200 | A over (i,k,j), k=kps..kpe: `mutf_2`, `muwt_2` (uncouple: `1./(…)` and `msfty/(…)`, as written) |
| K-CPL-MU-2 | 128–134 / 202–208 | A: `muth_2` |
| K-CPL-MU-3 | 140–147 / 212–226 | A: `muut_2`, `muvt_2` (uncouple: two separate nests, same result) |
| K-CPL-MU-4a, 4b | 149–187 / 228–266 | `nested .or. specified` branch (true on both domains): 4a the `j=jde` row of `muvt_2` if `jpe==jde`; 4b the `i=ide` column of `muut_2` if `ipe==ide`. Run **after** MU-3, since they overwrite its edge values. |
| K-CPL-F | 274–337 | A over (i,k,j) for `ph_2`, `w_2` (k to kpe), `t_2`, `moist(:,:,:,2:num_moist)` (species loop inside the thread, in order), `u_2` (i to `min(ide,ipe)`). `chem`/`scalar`/`tracer` loops are skipped when `num_* < PARAM_FIRST_SCALAR` (host test, as in the source). |
| K-CPL-V | 342–348 | A: `v_2` (j to `min(jde,jpe)`) |

The five mu work arrays (`mutf_2`, `muwt_2`, `muth_2`, `muut_2`, `muvt_2`) → work arrays (P1.7). Uncoupling
multiplies by a stored reciprocal, so couple followed by uncouple does not return the original bits. That's why the
device must perform both (P5.2 steps 2 and 7) rather than skip them.

### P5.2 `med_force_domain` rewiring (`share/mediation_force_domain.F:4–220`)

| Step | Source line | GPU-REPRO action |
|---|---|---|
| 1 | 99–107 `alloc_space_field(intermediate)` | unchanged (host; not mapped, P1.2 guard) |
| 2 | 112–123 couple parent; 125–135 couple nest | **device** K-CPL-* on parent and nest |
| 3 | before 160 `interp_domain_em_part1` | `CALL gpu_upd_host_force_slab(parent, js, je)` (generated, P1.3): every INTERP_DOWN field of the parent, j-rows `js..je`. **The rows are the ones the pack loop visits** (`rsl_bcast.c:258–260`): with `jcoord = j_parent_start(intermediate) − shw` and `jdim_cd = ijde − ijds + 1` taken from the **intermediate** grid exactly as `module_dm.F:4296–4303` does, `js = max(cjps, jcoord)` and `je = min(cjpe, jcoord + jdim_cd − 1)`. Compute them with the same `nl_get_*` and `get_ijk_from_grid` calls, after step 1 (the intermediate grid must exist). |
| 4 | before 173 `force_domain_em_part2` | K-NEST-STRIP-PACK on the device (generated body `gpu_pack_force_strips.inc`): `bdy_interp1` reads the nest's own field (`nfld`) in the spec zone to form `_b = nfld` and `_bt = rdt·(new − nfld)` (`share/interp_fcn.F:2579–2615`). So pack the four edge strips of every FORCE_DOWN field that uses `bdy_interp` into a contiguous device buffer. Strip width is `sz + 1 = 6` rows/columns for every field (`sz = min(max(spec_zone, relax_zone+1), spec_bdy_width) = 5`, +1 covers the staggered `nide−ni+1` indexing), over all k. Then `target update from(buffer)` and a host unpack into the host arrays. |
| 5 | 160, 173 | host: `interp_domain_em_part1`, `force_domain_em_part2`. `bdy_interp` writes the nest `_b`/`_bt` arrays (including `pc` and `ht_shad` boundary arrays); `p2c` writes the whole nest `o3rad`; the `imask_*` arrays are written and read only by the host forcing code, so they are never uploaded. |
| 6 | after 173 | `CALL gpu_upd_dev_bdy(nest)`; **eager** `CALL gpu_upd_dev_force_full(nest)` (`o3rad`, the only non-`bdy_interp` FORCE_DOWN field in this configuration). |
| 7 | 180–190 uncouple nest; 192–202 uncouple parent | **device** K-CPL-* |
| 8 | 208–213 `dealloc_space_field(intermediate)` | unchanged |

This replaces the Phase 1–4 S6 bridge (the full-state round trip of both domains) at the same call site.

**Tests:**

- `T-FORCE`: level-2 trace with checkpoints right after steps 2, 6 and 7, over 20 d01 steps (dev case,
  restart-vs-restart), bitwise to CPU-REF.
- `T-SLAB` (GPU-DEBUG): before step 3, fill the **host** copy of every INTERP_DOWN parent field outside rows
  `js..je` with a signaling-NaN pattern, and fill the host nest arrays outside the packed strips the same way.
  After forcing, the nest `_b`/`_bt` arrays and `o3rad` must be bitwise equal to CPU-REF. This proves the slab and
  strips cover everything the host code reads.
- `T-O3`: d02 `o3rad` on the device equals CPU-REF after every forcing (checksum).
- `T-NSYS` bytes per d01 step for steps 3, 4 and 6 are recorded in `port/PERF.md`. If step 3 is significant,
  apply O11 (§11.3).

### P5.3 Remove the whole-`solve_em` island

After Phases 2–4, `solve_em` has no islands left. Delete the P1.9 bracket.

**`T-NSYS-CLEAN`:** an `nsys` capture of 200 d02 steps (dev case and full case) lists **every** host↔device copy,
of any size. Each must belong to one of:

- nest forcing (P5.2 steps 3, 4, 6);
- a `wrfbdy` read (S5), history (S3) or restart (S4) write;
- the scalar results of reductions and error flags (a few bytes per kernel that has them; counted and listed).

Anything else fails the test. There is no `cudaMalloc`/`cudaFree` inside the time loop.

### P5.4 Output and input sync verification

- **`T-OUT`:** GPU-REPRO history frames 00:15 … 03:00 and the restarts at 01:00, 02:00, 03:00 are bitwise equal to
  CPU-REF.
- **`T-BDY`:** a window across 03:00 (a `wrfbdy` read) is bitwise.

### G5 — Acceptance gate (per GPU type: A100 80 GB and H100 80 GB)

1. The full 17 h GPU-REPRO run completes.
2. `port/compare_fields.py --bitwise`: all 69 d02 history frames and all 34 restart files (17 per domain) are
   identical to CPU-REF.
3. `port/compare_fire.py`: 0 differing burned cells at every frame; `tign_g`, `fire_area`, `fuel_frac`, `fgrnhfx`,
   `fgrnqfx`, `ros`, `lfn` identical.
4. The level-1 traces of both domains are identical for all 183,600 d02 steps.
5. The A100 run and the H100 run are identical to each other (they're both identical to CPU-REF).
6. **`T-DRIFT-FULL`:** CPU-REF rebuilt at the final commit is rerun for the full 17 h on CCR and is bitwise equal to
   the P0.11 archive (history, restarts and level-1 traces). This proves no shared change after P0.9a moved the
   reference. If it differs, the new CPU-REF run becomes the reference only after the difference is explained in
   `port/RESULTS.md`, and items 2–5 are re-checked against it.
7. **`T-XM` on the final binaries:** the final CPU-REF binary gives identical results on a CCR node and on a GPU
   node's host (3 d01 steps from t = 0 and from the 02:00 restart).
8. **G-MEM (3rd check):** the logged peak device memory over the full run is ≤ 70 GB on both GPUs.
9. Results are recorded in `port/RESULTS.md` with the binary md5s, image digest and input manifest.

---

## 11. Phase 6 — Performance analysis and tuning (bit-neutral only)

### 11.1 Metrics (reported in `port/PERF.md` for each GPU)

| Metric | Source |
|---|---|
| Wall seconds per simulated hour, total and per domain | `rsl.error.0000` `Timing for main` (P1.11) |
| Speedup vs the CPU-REF run (same case, N CCR cores) and vs the original CCR run (P0.2) | the above |
| Time share per NVTX range (dynamics RK, acoustic, scalar transport, turbulence, WSM6, surface, radiation, fire, nest forcing, I/O) | `nsys` |
| Top-20 kernels: duration, DRAM bytes, achieved bandwidth vs peak, registers, occupancy, local-memory traffic | `ncu` |
| Launch gaps (GPU idle between kernels) per step | `nsys` |
| Peak device memory | P1.12 |

### 11.2 Analysis method

1. **Bandwidth floor per step:** Σ over kernels of (DRAM bytes / peak bandwidth). Peak: A100 80 GB SXM ≈ 2.0 TB/s,
   PCIe ≈ 1.9 TB/s; H100 SXM ≈ 3.35 TB/s, PCIe ≈ 2.0 TB/s. Achieved step time ÷ floor gives the efficiency.
2. **Classify each top kernel:** memory-bound (stencils, updates) versus latency- or divergence-bound (WENO fire,
   column physics, RRTMG). Target: memory-bound kernels ≥ 60% of peak bandwidth.
3. **Launch overhead:** Σ of launch gaps per d02 step. With ≈ 400–500 launches per d02 step this should be under 5%
   of the step at 811×811×60; otherwise apply O2/O3.
4. **Compare with Prof-CPU** (P0.15): note which sections gained least.

### 11.3 Optimization backlog (each item needs T-REG-20, T-TRACE-100 and T-TRACE-RAD bitwise before merge)

| ID | Optimization | Expected effect |
|---|---|---|
| O1 | Remove fire NaN-check kernels from GPU-REPRO production (keep them in GPU-DEBUG); they don't touch state | ≈ 14 fire-grid + 6 atmospheric passes per step saved |
| O2 | Merge the 4 strip kernels of each BC routine into one kernel with an index map; merge zero/copy kernels | fewer launches in the acoustic loop |
| O3 | `nowait` plus `depend` for independent kernels (species loops, independent BC calls); `taskwait` before dependents | overlaps short kernels |
| O4 | `thread_limit`/`num_teams` and loop-mapping tuning per kernel, separately for A100 and H100 | occupancy |
| O5 | `-gpu=maxregcount:N` per file (advection, WENO fire, WSM6, Noah) | register-bound kernels |
| O6 | RRTMG performance version (§8.5): (b,layer) and (b,g) parallelism with ordered sums | radiation-step spikes |
| O7 | Fuse pointwise sequences in the same routine (e.g. `small_step_prep` nests) without reordering any expression | bandwidth |
| O8 | Output: `target update from` into pinned buffers; I/O quilting (`nio_tasks_per_group ≥ 1`, extra CPU ranks) | hides netCDF writes |
| O9 | Production only: raise `restart_interval` if hourly restarts aren't needed (no effect on results) | I/O time |
| O10 | Lazy `o3rad` upload: set `o3rad_dirty(2)` in P5.2 step 6 instead of uploading; upload only before the next d02 radiation call. While dirty, the host copy is the current one, so S4 must skip the `o3rad` D2H (otherwise it overwrites the host value with the stale device value). Test: `T-O3` and a restart written while dirty is bitwise. | ≈ 3.3 TB less H2D per run |
| O11 | Parent-side forcing transfer: replace the j-slab update (P5.2 step 3) with a device pack kernel over the rectangle `[is:ie]×[js:je]` (the `icoord`/`idim_cd` bounds, same formula as j), one D2H of the packed buffer, host unpack | cuts step-3 bytes by about the ratio of the nest footprint's i extent to the parent's width (≈ 100/460 here) |

**H100 vs A100:** tune O4 and O5 separately per GPU and keep per-GPU settings in `port/ENVIRONMENT.md`. Results
remain bitwise identical across GPUs (G5.5).

### G6 — Performance gate

- `port/PERF.md` complete for both GPUs.
- Every merged optimization passed its tests.
- The final G5 run is repeated with the tuned binary: still bitwise.

---

## 12. Phase 7 — Other fires (onboarding and regression)

For each new case `cases/<case_id>/`:

1. `port/manifest.py write` (inputs and tables). There's no `namelist.fire`, or the file is recorded if used.
2. `port/check_case.py namelist.input wrfinput_d0N`:
   - every option in the §2.3 envelope;
   - `e_vert-1 ≤ WRF_KMAX`;
   - RRTMG `NLAYERS ≤ WRF_NLAYMAX`;
   - fuel categories present in `NFUEL_CAT` ⊂ the mappable set (no `204`/SB4 unless `nfuelcats ≥ 54`);
   - `sr_x = sr_y`.
3. `port/gpu_mem_estimate.py` → must be ≤ 70 GB for 80 GB GPUs.
4. **Short acceptance:** CPU-REF vs GPU-REPRO, 1 h window around ignition from a CPU-REF restart, bitwise
   (`T-CASE-1H`).
5. **Full run** if required: G5 criteria.

**Regression suite** (run on every change to `WRF/`), `port/regress.sh`:

| Test | What |
|---|---|
| `T-REG-20` | dev case, `W-20` (27 d02 steps from the 02:20 restart), level-2 trace, GPU-REPRO vs CPU-REF restart-vs-restart, plus CPU-REF vs the archived dev reference; bitwise |
| `T-TRACE-100`, `T-TRACE-RAD` | as defined above |
| `T-FMA`, `T-SUBNORM` | rerun after any compiler or flag change |
| `T-BUILD-REF`, `T-BUILD-GPU` | both builds compile with no new warnings |

---

## 13. Test catalog

All windowed tests are restart-vs-restart (P0.10) and run on the dev case `eaton_small` unless marked "full case".

**Standard windows** (P0.16): `W-20` = 27 d02 steps from 02:20; `W-100` = 108 d02 steps from 02:20; `W-RAD` = 720
d02 steps from 02:20 (4 radiation calls per domain).

| ID | Defined in | What | Pass |
|---|---|---|---|
| T-FMA | P0.5 | device and host `a*b+c` on run-time operands, including the binary32 tie case | unfused and identical |
| T-SIGNZERO, T-MINMAX | P0.5 | `SIGN`, `MAX`, `MIN`, `ABS` on ±0, subnormals, ±Inf, NaN | identical bits |
| T-SUBNORM | P0.5 | `+ - * /`, `sqrt` on subnormal operands | identical, not flushed |
| T-RM-EXH, T-RM-POW, T-RM-D, T-RM-ACC | P0.5 | reproducible math | 0 host/device mismatches; accuracy reported |
| T-OMP-FEAT | P0.5b | compiler feature probes `F-*` | results recorded; fallbacks chosen |
| T-IPOW | P0.6 | integer powers | identical |
| T-SYM | P0.6 | no math-library symbols in host objects or device code | none outside the allow-list |
| T-BUILD-REF, T-BUILD-GPU | P0.6, P1.1 | builds; new files compile without `-w` | clean |
| T-SHARED-1..9 (incl. T-SHARED-POOL; T-SHARED-5 = T-FIRE-REF) | P0.9a | each shared refactor vs the unrefactored CPU build | bitwise, or difference explained |
| T-KISS | P0.9a, §8.5 | KISS RNG streams, host vs device | bitwise |
| T-DET, T-DEC-A, T-DEC-B, T-RST, T-XM | P0.10 | CPU-REF reproducibility (full case) | bitwise (`T-RST`: or documented) |
| T-MAP, T-TAB, T-UPD, T-POOL, T-WORK | P1 | mapping, tables, update lists, pool, work arrays | as specified |
| T-GATE | P1.8 | startup gate rejects a disallowed namelist | fatal error with the violation listed |
| T-AB-<routine> | P0.8 | device vs host execution of one routine, `W-100` (radiation: `W-RAD`) | identical traces |
| T-PDLIM | §7.5 | split positive-definite limiter vs original, standalone | bitwise |
| T-TRACE-100 | §7.0 | GPU-REPRO vs CPU-REF, `W-100`, level 2 | bitwise |
| T-TRACE-TKE | §7.7 | 1,000 d02 steps incl. `nba_mij` | bitwise |
| T-TRACE-RAD | §8.5 | `W-RAD`, level 2 | bitwise |
| T-WSM6-COL, T-YSU-COL, T-NOAH-PT, T-RRTMG-COL, T-OZN | §8 | column harnesses, 10⁵ columns/points | bitwise |
| T-ZOLRI | §8.3 | occurrences of the undefined `zolri` path in the reference | 0 |
| T-FIRE-IGN, T-FIRE-WIN, T-FIRE-GHOST | §9.1 | ignition window 02:00–02:35; spread window 02:20–03:00; ghost cells | bitwise; 0 differing cells |
| T-NSYS | §7.0 | every host↔device copy in `W-20` is explained | no unexplained copies |
| T-DRIFT | G2 | CPU-REF at the current commit vs the archived dev reference, 1 h | bitwise |
| T-FORCE, T-SLAB, T-O3 | P5.2 | nest forcing | bitwise |
| T-NSYS-CLEAN | P5.3 | only forcing, I/O and reduction-result copies remain | as specified |
| T-OUT, T-BDY | P5.4 | history/restart files; `wrfbdy` read window | bitwise |
| G5 items 1–9 (incl. T-DRIFT-FULL) | G5 | full-case acceptance | bitwise |
| G-MEM | §3 | peak device memory (G1, G3, G5) | ≤ 55 GB at G1; ≤ 70 GB at G3 and G5 |
| T-REG-20 | §12 | per-commit regression, `W-20`, level 2 | bitwise |
| T-CASE-1H | §12 | new case, 1 h around ignition | bitwise |

---

## 14. Gate summary

| Gate | Entry condition for | Key criteria |
|---|---|---|
| G0 | GPU work | `T-FMA`, `T-SIGNZERO`, `T-MINMAX`, `T-SUBNORM`, `T-RM-*`, `T-IPOW`, `T-SYM` pass; `T-OMP-FEAT` recorded; shared refactors done and `T-SHARED-*` pass; CPU-REF reproducible (`T-DET`, `T-DEC-A/B`, `T-XM`; `T-RST` or documented); full and dev references archived; E0, E1, Prof-CPU recorded; memory estimator validated |
| G1 | kernels | `T-MAP`, `T-TAB`, `T-UPD`, `T-POOL`, `T-WORK`, `T-GATE`; GPU build with all compute on the host bitwise on `W-20` and the first 3 d01 steps, on A100 and H100; G-MEM ≤ 55 GB |
| G2 | physics | all dynamics on the device; sub-gates G2.A–G; `T-TRACE-100`, `T-TRACE-TKE`, `T-PDLIM`, `T-NSYS`, `T-DRIFT` |
| G3 | fire | all physics on the device; sub-gates G3.A–E; `T-TRACE-RAD`, `T-NSYS`, `T-DRIFT`; G-MEM ≤ 70 GB (full case) |
| G4 | acceptance | fire on the device; `T-FIRE-IGN`, `T-FIRE-WIN` bitwise; 0 differing cells; `T-NSYS`, `T-DRIFT` |
| G5 | performance work | nest forcing on the device (`T-FORCE`, `T-SLAB`, `T-O3`, `T-NSYS-CLEAN`, `T-OUT`, `T-BDY`); full 17 h bitwise on A100 and H100; `T-DRIFT-FULL`; `T-XM` on the final binary; G-MEM ≤ 70 GB |
| G6 | production | `port/PERF.md`; each optimization passed `T-REG-20`, `T-TRACE-100`, `T-TRACE-RAD`; tuned binary repeats G5 bitwise |

---

## 15. Risk register

| Risk | Detection | Mitigation |
|---|---|---|
| `nvfortran` rejects a construct in device code (statement functions, internal procedures, `OPTIONAL`, `CHARACTER` args, module allocatables in `declare target`) | P1.1 / per-routine compile | the CP-4 conversions; hoist to host logicals; module procedures |
| A core OpenMP offload feature is missing or unusable in the pinned `nvfortran`: `if(target:)` (`F-IFTARGET`), presence of pointers remapped onto the pool (`F-PRESENT`), `declare target` on module allocatables (`F-DECLMOD`), calls inside `teams loop` (`F-CALLS`) | `T-OMP-FEAT` at G0, before any kernel is written | the per-probe fallbacks in P0.5b. If `F-PRESENT` or `F-DECLMOD` fail and no fallback works, try a newer NVHPC; if that also fails, stop at G0 and put the choice of directive dialect back to the user (OpenACC in the same `nvfortran` is the closest alternative; the kernel list, tests and gates stay the same). |
| Device `/` or `sqrt` not correctly rounded (a fast-math default or flag) | `T-SUBNORM`, `T-AB` | remove the flag; check `-gpu` suboptions of the pinned version; keep `T-SUBNORM` in the regression suite |
| Compiler mis-optimization breaks bitwise identity | T-AB | lower `-O` for that file on both builds, or split the kernel; report to NVIDIA with a reproducer |
| Device FMA contraction can't be disabled with the pinned NVHPC | `T-FMA` (P0.5) | try the alternative spellings (`-gpu=nofma`, `-Mnofma` applying to device code); pin an NVHPC version where `T-FMA` passes. If none does, stop and re-plan before any kernel work: bitwise CPU/GPU identity isn't reachable while the device contracts `a*b+c`. |
| CPU-REF depends on decomposition | T-DEC | bisect and fix (P0.10) before the reference run |
| Host library leaks into state across machines | T-XM | add missing `rp_*` substitutions |
| Undefined behavior in physics (`zolri`, YSU BEP) | T-ZOLRI, OOB guard | defined fix in both builds; prove 0 occurrences in the reference |
| Local-memory / stack limits for column physics | P3 first launch fails, CP-5 numbers | fixed-size locals (CP-3); set the stack limit; reduce `WRF_RRTMG_BATCH` |
| Device memory > 70 GB | G-MEM | reduce the RRTMG batch; release unused work arrays; map only in-use fields |
| KISS RNG integer overflow differs host/device | T-KISS | explicit `IAND`-masked 32-bit arithmetic in both builds (bit-identical to the wraparound) |
| I/O dominates after speedup | P6 metrics | O8, O9 |
| Other fires use SB4 (204) or `e_vert > 64` | P7 `check_case.py` | extend the fuel table / rebuild with a larger `WRF_KMAX` |

---

## 16. Deferred (not in this plan's scope)

- **A100 40 GB:** this case needs ≈ 58–62 GB of device memory (§3). Options for later are 2× A100 40 GB with MPI and a device-side halo port
  (`external/RSL_LITE` `f_pack.F90` pack/unpack on device, plus `T-DEC` for bitwise), or a memory diet.
- **Multi-GPU** (larger fires): the same RSL_LITE port.
- **GPU-FAST** (FMA and hardware intrinsics): not bitwise, so it can't meet the fire criterion; measure only if
  requested.

---

## 17. Deliverables and file index

**New files:**

| File | Purpose |
|---|---|
| `WRF/frame/module_repro_math.F` | reproducible math (P0.5) |
| `WRF/frame/module_bittrace.F` | bit-hash tracer (P0.7) |
| `WRF/frame/module_gpu_route.F` | per-routine switch, NVTX interfaces (P0.8, P1.10) |
| `WRF/frame/module_gpu_scratch.F`, `WRF/frame/module_gpu_work.F` | pool and work arrays (P1.6, P1.7) |
| `WRF/share/module_gpu_tables.F`, `WRF/share/module_gpu_check.F` | tables upload; startup gate |
| `WRF/tools/gen_gpu.c` | update-list generator (P1.3) |
| `WRF/inc/gpu_col.h` | CP-3 macros |
| `port/nvtx/nvtx_shim.c` | NVTX, `cudaMemGetInfo`, `cudaDeviceSetLimit` |
| `port/*.py` | `manifest`, `rp_subst`, `bittrace_diff`, `compare_fields`, `compare_fire`, `perturb_input`, `gpu_mem_estimate`, `check_case` |
| `port/tests/repro_math/` | `T-FMA`, `T-SIGNZERO`, `T-MINMAX`, `T-SUBNORM`, `T-RM-*` |
| `port/tests/omp_features/` | compiler feature probes `F-*` (P0.5b) |
| `port/tests/pdlim/` | `T-PDLIM` (§7.5) |
| `port/tests/{wsm6,ysu,noah,rrtmg,kiss,ozn}/` | column and unit harnesses (§8) |
| `port/regress.sh` | regression suite |
| `port/ENVIRONMENT.md`, `port/RESULTS.md`, `port/PERF.md` | environment, gate results, performance |
| `cases/eaton_20250108/…` | case contract (full case) |
| `cases/eaton_small/…` | development case: namelists, manifest, README (P0.16) |

**Modified files (representative; every file listed in P0.6 also gets `rp_*` substitutions):**

- `WRF/arch/configure.defaults`
- `WRF/tools/gen_allocs.c`, `WRF/tools/gen_defs.c`, `WRF/tools/registry.c`
- `WRF/main/module_wrf_top.F`, `WRF/frame/module_integrate.F`, `WRF/share/mediation_integrate.F`,
  `WRF/share/mediation_force_domain.F`
- `WRF/dyn_em/solve_em.F`, `module_em.F`, `module_advect_em.F`, `module_small_step_em.F`,
  `module_big_step_utilities_em.F`, `module_diffusion_em.F`, `module_bc_em.F`, `couple_or_uncouple_em.F`,
  `module_first_rk_step_part1.F`, `module_first_rk_step_part2.F`
- `WRF/share/module_bc.F`
- the `phys/` files of §8 and §9
- `WRF/inc/bench_solve_em_def.h`

### Rough effort (one engineer experienced in Fortran and OpenMP offload; indicative only)

| Phase | Weeks |
|---|---|
| P0 | 3–5 |
| P1 | 2–3 |
| P2 | 5–8 |
| P3 | 5–8 (RRTMG is the largest single item) |
| P4 | 2–4 |
| P5 | 1–2 |
| P6 | 2–4 |
| **Total** | **≈ 20–34 weeks** |

Each gate is a natural review point.

---

## Refinements during Phase 0 and the agent handoff

These refine the plan above; `port/RESULTS.md` ("Deviations from plan.md in Phase 0") lists the Phase 0 ones.

1. **Islands live inside the routine, not at the call site (P0.8, P1.9).** One flag in `module_gpu_route`,
   `gpu_world_host`, says where the current data are. Through Phase 4 the model stays on the host (the P1.9 bracket)
   and each ported routine copies its own array arguments to the device, runs there and copies them back when its
   route is on; from P5.3 the model lives on the device and a routine copies its arguments to the host only when its
   route is off. The island code is the same in both worlds and is generated from the routine's dummy arguments by
   `port/tools/gen_island.py`; `kernel_lint` rule E9 requires it (`port/agent/CODING_STANDARD.md` §3). This replaces
   the call-site `island_in_X.inc`/`island_out_X.inc` of P0.8: routines like `set_physical_bc3d` have ~100 call sites.
2. **Window lengths** end on d01 steps: W-20 = 27, W-100 = 108 d02 steps (above).
3. **K-PD-L3a/b** use a logical "limited" flag next to the scale instead of a `-1.0` sentinel (`MAX(0.,x)` with a NaN
   argument is processor dependent; a flag has no such case). Verified by T-PDLIM and its mutants.
4. **K-OZP** is row-parallel, not per column (above). Verified by T-OZN.
5. **Tracer on the device** (P0.7's device version) is implemented in Phase 5 (P5.0), when the model moves to the
   device; until then the host tracer sees current host data.
6. **Unported branches** (options `gpu_check_config` rejects) stop with `wrf_error_fatal` in the GPU view instead of
   running on the host.
7. **Work arrays** that replace existing automatic arrays are shared refactors made routine by routine, each with the
   protocol of `port/agent/WORKFLOW.md` §6 (bitwise evidence, then a move of the CPU-view base); GPU-only temporaries
   (`fqy3`, `scl`, `lim`) exist only in the GPU build.
8. **H100 development machine without root:** the toolchain runs in the NVHPC container image (Apptainer, rootless
   Podman or Docker); dependencies are built inside it into a user directory (`port/agent/ENV_H100.md`). CCR remains
   the place of the full-case reference and acceptance runs (G5).

