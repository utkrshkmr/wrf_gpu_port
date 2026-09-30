# Environment of the GPU port (plan.md P0.0, P0.1)

Fill in as the Phase 0 steps are done; every comparison in `RESULTS.md` refers to an image and binaries listed here.

## Container image

| Item | Value |
|---|---|
| Definition | `port/container/wrf-gpu.def` |
| NVHPC tag (`--build-arg NVHPC_TAG`) | |
| `.sif` sha256 | |
| `/opt/versions.txt` (nvfortran, MPI, netCDF, Python packages) | |

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
| GPU H100 | | | H100 80 GB | |

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

## Local development machine (Phase 0 work in this repository)

The Phase 0 code was developed in a container without NVHPC or a GPU (the NVIDIA download site is not reachable
from it). Host-side checks there used gfortran 13 (Ubuntu 24.04), netCDF-Fortran 4.5.4, Python 3 with numpy,
netCDF4 and mpmath. See `RESULTS.md`, "Local results".
