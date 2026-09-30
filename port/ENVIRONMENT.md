# Environment of the GPU port (plan.md P0.0, P0.1)

Fill in as the Phase 0 steps are done; every comparison in `RESULTS.md` refers to an image and binaries listed here.

## Container image

| Item | Value |
|---|---|
| Definition | `port/container/wrf-gpu.def` |
| NVHPC tag (`--build-arg NVHPC_TAG`) | `nvcr.io/nvidia/nvhpc:25.1-devel-cuda12.6-ubuntu22.04` (pulled, not built from `wrf-gpu.def`) |
| `.sif` sha256 | `3e394b4ba58886a5de76320135e369e7de08e2e5764c83d431b40cc1a822cf27` (`$WORK/images/nvhpc.sif`) |
| OCI base digest | `sha256:352424d86f2174349e4645419fa22a5091aebdf5100c3a5903da24fca3de3641` |
| `/opt/versions.txt` (nvfortran, MPI, netCDF, Python packages) | see "H100 machine" below; the image has no `/opt/versions.txt` |

## Build flags (plan.md §4)

| Mode | Stanza (`./configure`) | Fortran | Device | cpp |
|---|---|---|---|---|
| CPU-REF | NVHPC ... GPU port CPU-REF (dmpar) | `-O2 -Kieee -Mnofma -Mnoflushz -Mnodaz -Mvect=noassoc -tp=haswell -Mrecursive` | – | `-DREPRO_MATH -DWRF_POOL` |
| GPU-REPRO | NVHPC ... GPU port GPU-REPRO | same | `-mp=gpu -gpu=cc80,cc90,nofma,noflushz -Minfo=mp` | + `-DWRF_GPU` |
| GPU-DEBUG | NVHPC ... GPU port GPU-DEBUG | same + `-g -traceback` | + `-gpu=lineinfo` | + `-DWRF_TRACE_FINE` |

`-Mrecursive` (locals on the stack) is used in all three so that host code has the same storage semantics in the
CPU reference and in the GPU build.

Flag spelling check against the pinned NVHPC (`nvfortran -help`, `nvfortran -help -gpu`): _to do_.

## Nodes

| Use | Node type | CPU | GPU | Driver |
|---|---|---|---|---|
| CPU-REF | CCR | | – | – |
| GPU A100 | | | A100 80 GB | |
| GPU H100 | `iad-cmp2.cse.buffalo.edu` | Xeon Platinum 8562Y+, 2×32 cores | 4× H100 80 GB HBM3 | 570.211.01 |

## Compiler feature probes (P0.5b, T-OMP-FEAT)

Paste `port/tests/omp_features/probes_<host>_<date>.md` for the A100 and the H100 node here, and the decisions:

| Probe | A100 | H100 | Decision |
|---|---|---|---|
| F-IFTARGET | | | |
| F-CALLS | | | |
| F-DECLMOD | | | |
| F-PRESENT | | | |
| F-DEFMAP (+ negative) | | | |
| F-PRIVARR | | | |
| F-AUTO | | | |
| F-STMTFN, F-INTPROC, F-OPT, F-CHAR | | | |
| F-RED, F-NAN | | | |
| F-STACK (stack limit, NV_ACC_CUDA_STACKSIZE) | | | |

## H100 machine (iad-cmp2, 2026-09-30)

`setup_toolchain.sh check` printed `toolchain: PASS`.

| Item | Value |
|---|---|
| Runtime | Apptainer 1.5.4, user-space extract under `$HOME/.local`. Ubuntu 24.04 sets `kernel.apparmor_restrict_unprivileged_userns=1`, so `~/.local/bin/apptainer` runs the real binary inside `/usr/bin/rootlesskit` (profiled for user namespaces). |
| `nvfortran` / `nvc` / `mpif90` | 25.1-0, `-tp sapphirerapids`. `mpif90 -show` contains `nvfortran`. |
| MPI | HPC-X/OpenMPI in the image: `/opt/nvidia/hpc_sdk/Linux_x86_64/25.1/comm_libs/mpi/bin/mpirun` |
| netCDF | C 4.9.2 and Fortran 4.6.1, built with `nvc`/`nvfortran` into `$WORK/deps/netcdf`. HDF5 1.14.4-3. |
| Shell tools | tcsh 6.24.13 in `$WORK/deps/bin` (image has no csh). m4, perl 5.34, GNU make 4.3 from the image. |
| Profilers | Nsight Systems 2024.7.1.84; compute-sanitizer present. |
| Host Python | `$WORK/deps/pyenv`: numpy 2.5.3, netCDF4 1.7.4, mpmath 1.4.1 |
| Ranks / GPU | `CPU_RANKS=64`, `GPU_ID=0`. Eaton inputs are not on this machine (0/3). |

## Local development machine (Phase 0 work in this repository)

The Phase 0 code was developed in a container without NVHPC or a GPU (the NVIDIA download site is not reachable
from it). Host-side checks there used gfortran 13 (Ubuntu 24.04), netCDF-Fortran 4.5.4, Python 3 with numpy,
netCDF4 and mpmath. See `RESULTS.md`, "Local results".
