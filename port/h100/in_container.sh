#!/bin/bash
# Runs a command inside the container with the port's environment:
# DEPS tools and netCDF first in PATH, NVHPC's MPI and profilers found in the
# image, OpenMPI allowed to run as (container) root.  Used by x() in common.sh.
[ -d "${DEPS:-/nonexistent}/bin" ] && export PATH=$DEPS/bin:$PATH
[ -d "${NETCDF:-/nonexistent}/bin" ] && export PATH=$NETCDF/bin:$PATH LD_LIBRARY_PATH=$NETCDF/lib:${LD_LIBRARY_PATH:-}
if [ -n "${NVHPC_ROOT:-}" ]; then
  export PATH=$NVHPC_ROOT/compilers/bin:$NVHPC_ROOT/comm_libs/mpi/bin:$PATH
  export LD_LIBRARY_PATH=$NVHPC_ROOT/compilers/lib:$NVHPC_ROOT/comm_libs/mpi/lib:${LD_LIBRARY_PATH:-}
fi
sdk=$(ls -d /opt/nvidia/hpc_sdk/Linux_x86_64/[0-9]* 2>/dev/null | sort -V | tail -1)
if [ -n "$sdk" ]; then
  command -v nvfortran >/dev/null || export PATH=$sdk/compilers/bin:$PATH
  command -v mpif90 >/dev/null || { [ -d "$sdk/comm_libs/mpi/bin" ] && export PATH=$sdk/comm_libs/mpi/bin:$PATH; }
  command -v nsys >/dev/null || { d=$(ls -d "$sdk"/profilers/Nsight_Systems/bin 2>/dev/null | head -1); [ -n "$d" ] && export PATH=$PATH:$d; }
  command -v ncu >/dev/null || { d=$(ls -d "$sdk"/profilers/Nsight_Compute 2>/dev/null | head -1); [ -n "$d" ] && export PATH=$PATH:$d; }
  command -v compute-sanitizer >/dev/null || { d=$(ls -d "$sdk"/cuda/*/compute-sanitizer "$sdk"/cuda/compute-sanitizer 2>/dev/null | head -1); [ -n "$d" ] && export PATH=$PATH:$d; }
fi
export OMPI_ALLOW_RUN_AS_ROOT=1 OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1
export LC_ALL=C OMP_NUM_THREADS=${OMP_NUM_THREADS:-1} WRFIO_NCD_LARGE_FILE_SUPPORT=1
exec "$@"
