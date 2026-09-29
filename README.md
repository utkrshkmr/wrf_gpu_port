# WRF / WRF-Fire v4.6.0 (CPU reference)

Unmodified copy of the WRF v4.6.0 modeling pipeline, including WRF-Fire. It is the
CPU baseline that the GPU port is verified against, so nothing newer than v4.6.0 is
included.

| Directory          | Upstream                                              | Version                       | Commit                                     |
|--------------------|-------------------------------------------------------|-------------------------------|--------------------------------------------|
| `WRF/`             | [wrf-model/WRF](https://github.com/wrf-model/WRF)     | v4.6.0                        | `0a11865f97680fdd6865b278ea29d910e5db3ed7` |
| `WRF/phys/noahmp/` | [NCAR/noahmp](https://github.com/NCAR/noahmp)         | submodule pinned by WRF v4.6.0 | `848f54ad3d28c4303151fe5ad83724e232694422` |
| `WPS/`             | [wrf-model/WPS](https://github.com/wrf-model/WPS)     | v4.6.0                        | `335c76a111f84503e8b963abaf273ea8053645bb` |

The upstream git histories aren't included; the table records the exact upstream commits. To
check a directory against its release, fetch that commit and diff (fetching only reads from the
upstream repositories):

```sh
git fetch --depth 1 https://github.com/wrf-model/WRF refs/tags/v4.6.0
git diff --stat FETCH_HEAD HEAD:WRF               # only phys/noahmp (submodule link -> vendored files)
git fetch --depth 1 https://github.com/wrf-model/WPS refs/tags/v4.6.0
git diff --stat FETCH_HEAD HEAD:WPS               # empty
git fetch --depth 1 https://github.com/NCAR/noahmp 848f54ad3d28c4303151fe5ad83724e232694422
git diff --stat FETCH_HEAD HEAD:WRF/phys/noahmp   # empty
```

## WRF-Fire

- Fire model code is built into WRF: `WRF/phys/module_fr_fire_*.F`.
- Ideal fire case: `WRF/test/em_fire` (`./compile em_fire`).
- Real-data fire runs use WPS `geogrid/GEOGRID.TBL.FIRE` and `namelist.wps.fire`.

## Build

`WRF/` and `WPS/` are siblings, so WPS finds the WRF build in `../WRF` on its own:

```sh
cd WRF && ./configure && ./compile em_real    # or em_fire
cd ../WPS && ./configure && ./compile
```

Noah-MP is stored as plain files instead of a submodule; the WRF build links them from
`WRF/phys/noahmp` as usual.
