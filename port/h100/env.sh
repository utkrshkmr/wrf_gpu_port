# Settings of the H100 development machine (port/agent/ENV_H100.md).
# Copy to env.local.sh and edit; every script sources env.local.sh if it
# exists (ignored by git), otherwise this file.  Values already set in the
# environment win.  Nothing here needs root.

# This repository (default: the checkout these scripts are in)
export PORT_REPO=${PORT_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}

# Work area for builds, cases, runs, dependencies and gate logs (needs ~300 GB)
export WORK=${WORK:-$HOME/wrf_gpu_work}

# Folder with the Eaton case inputs wrfinput_d01, wrfinput_d02, wrfbdy_d01
# (copied from CCR, checked against cases/eaton_20250108/manifest.md5)
export CASE_INPUTS=${CASE_INPUTS:-$WORK/inputs/eaton_20250108}

# Toolchain: compilers, MPI and wrf.exe run inside a container (no root needed):
#   CONTAINER=apptainer  IMAGE=$WORK/images/nvhpc.sif      (apptainer pull, see container.sh)
#   CONTAINER=podman     IMAGE=nvcr.io/nvidia/nvhpc:<tag>  (rootless podman)
#   CONTAINER=docker     IMAGE=nvcr.io/nvidia/nvhpc:<tag>  (only if you may use docker)
#   CONTAINER=none       NVHPC installed natively (NVHPC_ROOT), no container
# The NVHPC image (one pinned tag for the whole port):
export NVHPC_IMAGE_REF=${NVHPC_IMAGE_REF:-nvcr.io/nvidia/nvhpc:25.1-devel-cuda12.6-ubuntu22.04}
export CONTAINER=${CONTAINER:-apptainer}
export IMAGE=${IMAGE:-$WORK/images/nvhpc.sif}
export NVHPC_ROOT=${NVHPC_ROOT:-}
# GPU options of the runtime (defaults: apptainer --nv, podman CDI, docker --gpus all)
export CONTAINER_GPU_FLAGS=${CONTAINER_GPU_FLAGS:-}

# Everything the image lacks is built inside the container into DEPS (a host
# directory mounted in the container): tcsh, m4, HDF5, netCDF (container.sh deps)
export DEPS=${DEPS:-$WORK/deps}
export NETCDF=${NETCDF:-$DEPS/netcdf}
# Python for the port's tools runs on the host: a user environment in PYENV
# (setup_toolchain.sh python), used if the system python3 lacks numpy/netCDF4
export PYENV=${PYENV:-$DEPS/pyenv}

# MPI launcher inside the container
export MPIRUN=${MPIRUN:-mpirun}
# Ranks for CPU-REF runs (the GPU build always runs 1 rank)
export CPU_RANKS=${CPU_RANKS:-$(( $(getconf _NPROCESSORS_ONLN) > 64 ? 64 : $(getconf _NPROCESSORS_ONLN) ))}
# GPU used by GPU runs (CUDA device number)
export GPU_ID=${GPU_ID:-0}
# Parallel make jobs for WRF builds
export BUILD_JOBS=${BUILD_JOBS:-16}
