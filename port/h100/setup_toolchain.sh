#!/bin/bash
# Toolchain of the H100 machine, without root (port/agent/ENV_H100.md).
#
#   setup_toolchain.sh image    get the NVHPC container image ($NVHPC_IMAGE_REF):
#                               apptainer pull -> $IMAGE (.sif), or podman/docker pull
#   setup_toolchain.sh deps     build what the image lacks INSIDE the container into $DEPS
#                               (a host directory): ncurses + tcsh (WRF's compile is csh),
#                               m4, perl only if missing, HDF5 + netCDF-C + netCDF-Fortran
#                               with nvc/nvfortran into $NETCDF.  Sources are downloaded on
#                               the host into $DEPS/src (curl or python).
#   setup_toolchain.sh deps-gnu netCDF-Fortran built with the image gfortran into $NETCDF_GNU
#                               (default $DEPS/netcdf-gnu; netCDF-C shared with $NETCDF), for
#                               the gfortran builds of T-UNINIT (port/gates/t_uninit.sh)
#   setup_toolchain.sh python   Python with numpy, netCDF4, mpmath for the port's tools, on the
#                               host: the system python3 if it has them, else a venv or a
#                               micromamba environment in $PYENV (no root)
#   setup_toolchain.sh check    report every tool; exit 1 if an essential one is missing
#   setup_toolchain.sh shell    print the command for an interactive shell in the container
set -uo pipefail
source "$(dirname "$0")/common.sh"
HDF5_VERSION=1.14.4-3; NETCDF_C_VERSION=4.9.2; NETCDF_F_VERSION=4.6.1
NCURSES_VERSION=6.4; TCSH_VERSION=6.24.13; M4_VERSION=1.4.19; PERL_VERSION=5.38.2
row() { printf '%-6s %-26s %s\n' "$1" "$2" "$3"; }
fetch() {   # fetch <url> <file>: download on the host (curl, wget or python)
  [ -s "$2" ] && return 0
  curl -fsSL -o "$2" "$1" 2>/dev/null || wget -q -O "$2" "$1" 2>/dev/null || \
    python3 -c "import sys, urllib.request; urllib.request.urlretrieve(sys.argv[1], sys.argv[2])" "$1" "$2" \
    || { rm -f "$2"; return 1; }
}
case ${1:-check} in
  image)
    mkdir -p "$WORK/images" "$WORK/tmp"
    case $CONTAINER in
      apptainer|singularity)
        export APPTAINER_CACHEDIR=$WORK/tmp/apptainer_cache APPTAINER_TMPDIR=$WORK/tmp SINGULARITY_CACHEDIR=$WORK/tmp/apptainer_cache SINGULARITY_TMPDIR=$WORK/tmp
        [ -f "$IMAGE" ] && { note "image exists: $IMAGE"; exit 0; }
        $CONTAINER pull "$IMAGE" "docker://$NVHPC_IMAGE_REF" || die "pull failed (network to nvcr.io? try on another machine and copy the .sif)" ;;
      podman|docker)
        $CONTAINER pull "$NVHPC_IMAGE_REF" || die "pull failed"
        note "set IMAGE=$NVHPC_IMAGE_REF in env.local.sh" ;;
      none) note "CONTAINER=none: nothing to pull (NVHPC_ROOT=$NVHPC_ROOT)" ;;
    esac ;;
  deps)
    src=$DEPS/src; mkdir -p "$src" "$DEPS/bin" "$NETCDF"; cd "$src" || exit 1
    have() { x bash -c "command -v $1" >/dev/null 2>&1; }
    x bash -c "command -v nvfortran && command -v gcc && command -v make" >/dev/null || die "the container has no nvfortran/gcc/make (IMAGE=$IMAGE)"
    if ! have tcsh && ! have csh; then
      note "building ncurses $NCURSES_VERSION and tcsh $TCSH_VERSION into $DEPS"
      fetch https://ftp.gnu.org/gnu/ncurses/ncurses-$NCURSES_VERSION.tar.gz ncurses.tar.gz || die "download ncurses"
      fetch https://astron.com/pub/tcsh/tcsh-$TCSH_VERSION.tar.gz tcsh.tar.gz \
        || fetch https://github.com/tcsh-org/tcsh/archive/refs/tags/TCSH${TCSH_VERSION//./_}.tar.gz tcsh.tar.gz || die "download tcsh"
      rm -rf ncurses-*/ tcsh-*/; tar xzf ncurses.tar.gz; tar xzf tcsh.tar.gz
      x bash -c "cd ncurses-$NCURSES_VERSION && CC=gcc ./configure --prefix=$DEPS --without-shared --without-debug --without-ada --without-cxx-binding --with-termlib && make -j $BUILD_JOBS && make install" > ncurses.log 2>&1 || die "ncurses build failed ($src/ncurses.log)"
      x bash -c "cd tcsh-*/ && CC=gcc CPPFLAGS=-I$DEPS/include LDFLAGS=-L$DEPS/lib ./configure --prefix=$DEPS && make -j $BUILD_JOBS && make install && ln -sf tcsh $DEPS/bin/csh" > tcsh.log 2>&1 || die "tcsh build failed ($src/tcsh.log)"
    fi
    if ! have m4; then
      fetch https://ftp.gnu.org/gnu/m4/m4-$M4_VERSION.tar.gz m4.tar.gz || die "download m4"
      rm -rf m4-*/; tar xzf m4.tar.gz
      x bash -c "cd m4-$M4_VERSION && CC=gcc ./configure --prefix=$DEPS && make -j $BUILD_JOBS && make install" > m4.log 2>&1 || die "m4 build failed ($src/m4.log)"
    fi
    if ! have perl; then
      fetch https://www.cpan.org/src/5.0/perl-$PERL_VERSION.tar.gz perl.tar.gz || die "download perl"
      rm -rf perl-*/; tar xzf perl.tar.gz
      x bash -c "cd perl-$PERL_VERSION && CC=gcc ./Configure -des -Dprefix=$DEPS && make -j $BUILD_JOBS && make install" > perl.log 2>&1 || die "perl build failed ($src/perl.log)"
    fi
    if ! x bash -c "$NETCDF/bin/nf-config --fc 2>/dev/null | grep -q nvfortran"; then
      note "building HDF5, netCDF-C, netCDF-Fortran with nvc/nvfortran into $NETCDF (30-60 min)"
      H=hdf5-$HDF5_VERSION
      fetch https://github.com/HDFGroup/hdf5/releases/download/hdf5_$HDF5_VERSION/$H.tar.gz $H.tar.gz \
        || fetch https://support.hdfgroup.org/ftp/HDF5/releases/$H/src/$H.tar.gz $H.tar.gz || die "download HDF5"
      fetch https://github.com/Unidata/netcdf-c/archive/refs/tags/v$NETCDF_C_VERSION.tar.gz nc.tar.gz || die "download netCDF-C"
      fetch https://github.com/Unidata/netcdf-fortran/archive/refs/tags/v$NETCDF_F_VERSION.tar.gz nf.tar.gz || die "download netCDF-Fortran"
      rm -rf hdf5-*/ netcdf-c-*/ netcdf-fortran-*/; tar xzf $H.tar.gz; tar xzf nc.tar.gz; tar xzf nf.tar.gz
      E="CC=nvc FC=nvfortran F77=nvfortran CXX=nvc++ CFLAGS='-O2 -fPIC' FCFLAGS='-O2 -fPIC' FFLAGS='-O2 -fPIC'"
      x bash -c "cd hdf5-*/ && $E ./configure --prefix=$NETCDF --enable-fortran --disable-tests && make -j $BUILD_JOBS && make install" > hdf5.log 2>&1 || die "HDF5 build failed ($src/hdf5.log)"
      x bash -c "cd netcdf-c-$NETCDF_C_VERSION && $E CPPFLAGS=-I$NETCDF/include LDFLAGS=-L$NETCDF/lib ./configure --prefix=$NETCDF --disable-dap --disable-byterange --disable-libxml2 && make -j $BUILD_JOBS && make install" > netcdf-c.log 2>&1 || die "netCDF-C build failed ($src/netcdf-c.log)"
      x bash -c "cd netcdf-fortran-$NETCDF_F_VERSION && $E CPPFLAGS=-I$NETCDF/include LDFLAGS=-L$NETCDF/lib LD_LIBRARY_PATH=$NETCDF/lib ./configure --prefix=$NETCDF && make -j $BUILD_JOBS && make install" > netcdf-f.log 2>&1 || die "netCDF-Fortran build failed ($src/netcdf-f.log)"
    fi
    note "deps ready in $DEPS"; bash "$0" check ;;
  deps-gnu)
    x bash -c "command -v gfortran && command -v gcc" >/dev/null || die "the container has no gfortran: T-UNINIT cannot run (write it in the workbook)"
    x bash -c "$NETCDF/bin/nc-config --version" >/dev/null 2>&1 || die "build the nvfortran netCDF first: setup_toolchain.sh deps"
    G=${NETCDF_GNU:-$DEPS/netcdf-gnu}; src=$DEPS/src; mkdir -p "$src" "$G/include" "$G/lib"; cd "$src" || exit 1
    fetch https://github.com/Unidata/netcdf-fortran/archive/refs/tags/v$NETCDF_F_VERSION.tar.gz nf.tar.gz || die "download netCDF-Fortran"
    rm -rf netcdf-fortran-*/; tar xzf nf.tar.gz
    note "building netCDF-Fortran with gfortran into $G"
    x bash -c "cd netcdf-fortran-$NETCDF_F_VERSION && CC=gcc FC=gfortran F77=gfortran CFLAGS='-O2 -fPIC' FCFLAGS='-O2 -fPIC' FFLAGS='-O2 -fPIC' CPPFLAGS=-I$NETCDF/include LDFLAGS=-L$NETCDF/lib LD_LIBRARY_PATH=$NETCDF/lib ./configure --prefix=$G && make -j $BUILD_JOBS && make install" > netcdf-f-gnu.log 2>&1 || die "netCDF-Fortran (gfortran) build failed ($src/netcdf-f-gnu.log)"
    for d in include lib; do for f in "$NETCDF"/$d/libnetcdf.* "$NETCDF"/$d/netcdf.h "$NETCDF"/$d/netcdf_*.h "$NETCDF"/$d/libhdf5*; do
      [ -e "$f" ] && ln -sf "$f" "$G/$d/"; done; done
    [ -x "$G/bin/nf-config" ] && ln -sf "$NETCDF/bin/nc-config" "$G/bin/nc-config"
    note "gfortran netCDF ready in $G (build.sh gnu uses it)" ;;
  python)
    if python3 -c "import numpy, netCDF4, mpmath" 2>/dev/null; then note "system python3 has numpy, netCDF4, mpmath"; exit 0; fi
    if [ ! -x "$PYENV/bin/python3" ]; then
      if python3 -m venv "$PYENV" 2>/dev/null && "$PYENV/bin/pip" install -q numpy netCDF4 mpmath; then :
      else
        rm -rf "${PYENV:?}"; mkdir -p "$DEPS/src"
        fetch https://micro.mamba.pm/api/micromamba/linux-64/latest "$DEPS/src/micromamba.tar.bz2" || die "download micromamba"
        (cd "$DEPS" && tar xjf src/micromamba.tar.bz2 bin/micromamba) || die "unpack micromamba"
        MAMBA_ROOT_PREFIX=$DEPS/mamba "$DEPS/bin/micromamba" create -y -q -p "$PYENV" -c conda-forge python=3.11 numpy netcdf4 mpmath \
          || die "micromamba environment failed"
      fi
    fi
    "$PYENV/bin/python3" -c "import numpy, netCDF4, mpmath; print('python env ok:', numpy.__version__, netCDF4.__version__)" ;;
  check)
    bad=0
    chk() {   # chk <essential 0|1> <name> <command...>   (runs in the container)
      local ess=$1 name=$2; shift 2
      local out; out=$(x "$@" 2>&1 | grep -v '^$' | head -1)
      if x "$@" >/dev/null 2>&1; then row ok "$name" "$out"
      else row "$([ "$ess" = 1 ] && echo MISS || echo warn)" "$name" "${out:-not found}"; [ "$ess" = 1 ] && bad=1; fi
    }
    row info container "$CONTAINER  image: $IMAGE"
    [ "$CONTAINER" = none ] || command -v "$CONTAINER" >/dev/null || { row MISS "$CONTAINER" "runtime not found"; bad=1; }
    case $CONTAINER in apptainer|singularity) [ -f "$IMAGE" ] || { row MISS image "$IMAGE missing (setup_toolchain.sh image)"; bad=1; } ;; esac
    chk 1 nvidia-smi nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader
    chk 1 nvfortran nvfortran --version
    chk 1 nvc nvc --version
    chk 1 mpif90 mpif90 --version
    chk 1 "mpif90 wraps nvfortran" bash -c "(mpif90 -show 2>/dev/null || mpif90 --showme 2>/dev/null) | grep -o nvfortran | head -1 | grep ."
    chk 1 mpirun bash -c "command -v $MPIRUN && $MPIRUN --version 2>&1 | head -1"
    chk 1 "netCDF-Fortran (nvfortran)" bash -c "$NETCDF/bin/nf-config --version && $NETCDF/bin/nf-config --fc | grep -q nvfortran"
    chk 1 "netCDF-C" "$NETCDF/bin/nc-config" --version
    chk 1 "csh (for ./compile)" bash -c "command -v csh || command -v tcsh"
    chk 1 perl bash -c "perl -e 'print \"perl \$]\n\"'"
    chk 1 m4 bash -c "command -v m4"
    chk 1 make bash -c "make --version | head -1"
    chk 0 nsys nsys --version
    chk 0 compute-sanitizer compute-sanitizer --version
    if python3 -c "import numpy, netCDF4" 2>/dev/null; then row ok "python (host)" "$(python3 -c 'import numpy, netCDF4; print("numpy", numpy.__version__, "netCDF4", netCDF4.__version__)')"
    else row MISS "python (host)" "numpy/netCDF4 missing: setup_toolchain.sh python"; bad=1; fi
    command -v git >/dev/null && row ok git "$(git --version)" || { row MISS git "not found"; bad=1; }
    row info cores "$(getconf _NPROCESSORS_ONLN)  (CPU_RANKS=$CPU_RANKS)"
    row info "WORK free" "$(df -h "$WORK" 2>/dev/null | awk 'NR==2 {print $4 " free at " $6}')"
    row info "Eaton inputs" "$(ls "$CASE_INPUTS"/wrfinput_d01 "$CASE_INPUTS"/wrfinput_d02 "$CASE_INPUTS"/wrfbdy_d01 2>/dev/null | wc -l)/3 in $CASE_INPUTS"
    echo "toolchain: $([ $bad = 0 ] && echo PASS || echo 'FAIL (fix the MISS items, port/agent/ENV_H100.md)')"
    exit $bad ;;
  shell)
    case $CONTAINER in
      apptainer|singularity) echo "$CONTAINER exec --nv --bind $WORK --bind $PORT_REPO $IMAGE bash --rcfile <(echo 'source $HERE_H100/in_container.sh true 2>/dev/null')" ;;
      podman) echo "podman run --rm -it --entrypoint= --userns=keep-id --device nvidia.com/gpu=all -v $WORK:$WORK -v $PORT_REPO:$PORT_REPO -w \$PWD $IMAGE bash" ;;
      docker) echo "docker run --rm -it --entrypoint= --user \$(id -u):\$(id -g) --gpus all -v $WORK:$WORK -v $PORT_REPO:$PORT_REPO -w \$PWD $IMAGE bash" ;;
      none) echo "bash   # native toolchain" ;;
    esac
    echo "# inside: export DEPS=$DEPS NETCDF=$NETCDF; source <(sed '\$d' $HERE_H100/in_container.sh)" ;;
  *) die "usage: setup_toolchain.sh image|deps|python|check|shell" ;;
esac
