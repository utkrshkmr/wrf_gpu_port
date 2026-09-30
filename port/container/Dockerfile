# Optional alternative to port/h100/setup_toolchain.sh deps, for machines where a
# rootless image build works (podman build, or docker build where allowed):
#   podman build -t wrf-gpu:25.1 -f port/container/Dockerfile port/container
# then set CONTAINER=podman IMAGE=localhost/wrf-gpu:25.1 and NETCDF=/opt/netcdf in
# port/h100/env.local.sh.  Same contents as port/container/wrf-gpu.def (Apptainer).
ARG NVHPC_TAG=25.1-devel-cuda12.6-ubuntu22.04
FROM nvcr.io/nvidia/nvhpc:${NVHPC_TAG}
ARG HDF5_VERSION=1.14.4-3
ARG NETCDF_C_VERSION=4.9.2
ARG NETCDF_F_VERSION=4.6.1
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends csh tcsh m4 perl make git curl ca-certificates \
        file time zlib1g-dev libcurl4-openssl-dev python3 python3-pip && \
    pip3 install --no-cache-dir numpy netCDF4 mpmath && rm -rf /var/lib/apt/lists/*
RUN set -e; MPIBIN=$(dirname $(ls -d /opt/nvidia/hpc_sdk/Linux_x86_64/*/comm_libs/mpi/bin/mpif90 | head -1)); \
    export PATH=$MPIBIN:$PATH CC=nvc FC=nvfortran F77=nvfortran CXX=nvc++ CFLAGS="-O2 -fPIC" FCFLAGS="-O2 -fPIC" FFLAGS="-O2 -fPIC"; \
    mkdir -p /opt/src /opt/netcdf && cd /opt/src; \
    H=hdf5-${HDF5_VERSION}; curl -fsSL -o $H.tar.gz https://github.com/HDFGroup/hdf5/releases/download/hdf5_${HDF5_VERSION}/$H.tar.gz; \
    tar xzf $H.tar.gz && cd hdf5-* && ./configure --prefix=/opt/netcdf --enable-fortran --disable-tests && make -j 8 && make install && cd /opt/src; \
    curl -fsSL -o nc.tar.gz https://github.com/Unidata/netcdf-c/archive/refs/tags/v${NETCDF_C_VERSION}.tar.gz; \
    tar xzf nc.tar.gz && cd netcdf-c-${NETCDF_C_VERSION} && CPPFLAGS=-I/opt/netcdf/include LDFLAGS=-L/opt/netcdf/lib \
      ./configure --prefix=/opt/netcdf --disable-dap --disable-byterange --disable-libxml2 && make -j 8 && make install && cd /opt/src; \
    curl -fsSL -o nf.tar.gz https://github.com/Unidata/netcdf-fortran/archive/refs/tags/v${NETCDF_F_VERSION}.tar.gz; \
    tar xzf nf.tar.gz && cd netcdf-fortran-${NETCDF_F_VERSION} && CPPFLAGS=-I/opt/netcdf/include LDFLAGS=-L/opt/netcdf/lib \
      LD_LIBRARY_PATH=/opt/netcdf/lib ./configure --prefix=/opt/netcdf && make -j 8 && make install; \
    rm -rf /opt/src
ENV NETCDF=/opt/netcdf LD_LIBRARY_PATH=/opt/netcdf/lib:$LD_LIBRARY_PATH PATH=/opt/netcdf/bin:$PATH
