# Container for the WRF GPU port (plan.md P0.0)

`wrf-gpu.def` builds one Apptainer image with the NVIDIA HPC SDK (nvfortran,
nvc, CUDA, OpenMPI), HDF5 and netCDF built with nvc/nvfortran, and Python 3
with numpy, netCDF4 and mpmath for the port tools.

```sh
apptainer build --build-arg NVHPC_TAG=25.1-devel-cuda12.6-ubuntu22.04 wrf-gpu.sif wrf-gpu.def
apptainer test wrf-gpu.sif
sha256sum wrf-gpu.sif           # record in port/ENVIRONMENT.md with the tag
```

Use the same `.sif` on CCR CPU nodes (CPU-REF) and on the A100/H100 nodes
(`apptainer exec --nv wrf-gpu.sif ...`).  Never compare runs made with
different images.

## Building WRF inside the image

```sh
apptainer exec wrf-gpu.sif bash -lc '
  cd WRF && ./clean -a && ./configure   # choose "NVHPC ... GPU port CPU-REF" (dmpar), nesting 1 (basic)
  ./compile -j 8 em_real >& compile.log'
```

The three GPU-port stanzas are listed by `./configure` as
"NVHPC (nvfortran/nvc) GPU port CPU-REF / GPU-REPRO / GPU-DEBUG" (plan.md 4).

## MPI on CCR

Runs inside one node can use the image's `mpirun` directly:
`apptainer exec wrf-gpu.sif mpirun -np 64 ./wrf.exe`.
Runs across nodes need the hybrid model (the host's `srun`/`mpirun` launching
`apptainer exec` on every rank) with a host MPI compatible with the image's
OpenMPI; check this once with a 2-node `T-DEC` run before relying on it.
