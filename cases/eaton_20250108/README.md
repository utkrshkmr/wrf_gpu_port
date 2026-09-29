# Case `eaton_20250108` (reference case)

The run the GPU port is verified against (plan.md §2.1). Large files are not committed; they stay on CCR and on
the GPU nodes and are checked against [`manifest.md5`](manifest.md5) before every run:

```sh
python3 port/manifest.py check <run folder> -m cases/eaton_20250108/manifest.md5
```

## Source run

| Item | Value |
|---|---|
| CCR run folder | `runs/20260928_124741` (the Sep 9 run before it used the same inputs) |
| Executable | `/cvmfs/soft.ccr.buffalo.edu/.../wrf/4.6.0-dmpar/WRFV4.6.0/test/em_real/wrf.exe` |
| Period | 2025-01-08 00:00 → 17:00 UTC (17 h) |
| Ignition | 34.18604 N, −118.09325 W, radius 100 m, 8280–9080 s (02:18:00–02:31:20 UTC), ROS 0.1 m/s |

## Files

| File | Size | md5 | Content |
|---|---|---|---|
| `wrfinput_d01` | 289 MB | `4a50bf559d1486b00b486287fdd3c567` | d01 initial state, 450×450×60, dx 900 m |
| `wrfinput_d02` | 876 MB | `f53040929f3d0ec486cfe6ffb8a054a2` | d02 initial state, 811×811×60, dx 100 m; fire mesh 3244² (`NFUEL_CAT`, `ZSF`, slopes) |
| `wrfbdy_d01` | 122 MB | `51cffbc8a8c6f53203a35b301e519582` | d01 lateral BCs, every 3 h, Jan 8 00:00–21:00 |
| [`namelist.input`](namelist.input) | | | as run (`fire_fuel_read = -1, -1`) |

The inputs were made by `real.exe` v4.6.0 with `MODIFIED_IGBP_MODIS_NOAH` (21 land categories). Copies with other
md5s (for example Nisha's, about 6% larger) are different inputs and must never be mixed into a comparison.

Runtime tables (symlinked from `test/em_real`, i.e. `run/` of the WRF v4.6.0 installation): `LANDUSE.TBL`,
`VEGPARM.TBL`, `SOILPARM.TBL`, `GENPARM.TBL`, `RRTMG_LW_DATA`, `ozone.formatted`, `ozone_lat.formatted`,
`ozone_plev.formatted`, `CAMtr_volume_mixing_ratio` (→ `.SSP245`). Their md5s in `manifest.md5` are those of this
repository's `WRF/run/`; the first `manifest.py check` on CCR confirms the installation uses the same files.

## Known facts

- **No `namelist.fire`** in the run folder, so WRF uses its built-in 53-category fuel table and writes
  `namelist.fire.output`. Uniform fuel moisture `fuelmc_g = 0.08` (`fire_fmc_read = 1`). `FMC_GC` in
  `wrfinput_d02` is all zeros and unused.
- d02 history every 15 min (69 frames); d01 history off; restarts every 60 min on both domains.
- Not used: `met_em` files, a d02 boundary file, SST update, aerosol input, `URBPARM*`, `MPTABLE`, `RRTM_DATA`,
  `CAM_*`, `tr49t67`.

## Original CCR build (P0.2)

Fill in from `port/ccr/identify_build.sh` output:

| Item | Value |
|---|---|
| Compiler and version | |
| `FCOPTIM` / `FCBASEOPTS` | |
| MPI library | |
| Ranks, `nproc_x × nproc_y` | |
| Wall time per simulated hour | |
