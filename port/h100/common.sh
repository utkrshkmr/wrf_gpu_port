# Shared helpers of port/h100 and port/gates.  Source this file.
HERE_H100=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ -f "$HERE_H100/env.local.sh" ]; then source "$HERE_H100/env.local.sh"; else source "$HERE_H100/env.sh"; fi
PORT_TOOLS=$PORT_REPO/port
TABLES="LANDUSE.TBL VEGPARM.TBL SOILPARM.TBL GENPARM.TBL RRTMG_LW_DATA ozone.formatted ozone_lat.formatted ozone_plev.formatted"
DEV_CASE=$WORK/cases/eaton_small
DEV_REF=$WORK/reference/eaton_small
export LC_ALL=C OMP_NUM_THREADS=1 WRFIO_NCD_LARGE_FILE_SUPPORT=1
# the port's Python tools run on the host; use the user environment if there is one
[ -x "${PYENV:-/nonexistent}/bin/python3" ] && export PATH=$PYENV/bin:$PATH

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "--- $*" >&2; }

# x <cmd...>: run a toolchain command (compilers, make, mpirun, wrf.exe, nsys,
# nvidia-smi) in the container, in the current directory, with the port's
# environment (in_container.sh).  Directories $WORK, $PORT_REPO and
# $CASE_INPUTS are mounted at the same paths.
x() {
  local binds=("$WORK" "$PORT_REPO")
  [ -n "${CASE_INPUTS:-}" ] && [ -d "$CASE_INPUTS" ] && binds+=("$(cd "$CASE_INPUTS" && pwd -P)")
  case ${CONTAINER:-none} in
    none)
      bash "$HERE_H100/in_container.sh" "$@" ;;
    apptainer|singularity)
      local b=(); for d in "${binds[@]}"; do b+=(--bind "$d"); done
      $CONTAINER exec ${CONTAINER_GPU_FLAGS:---nv} "${b[@]}" --pwd "$PWD" "$IMAGE" \
        bash "$HERE_H100/in_container.sh" "$@" ;;
    podman|docker)
      local b=() e=() u=()
      for d in "${binds[@]}"; do b+=(-v "$d:$d"); done
      [ "$PWD" != "${PWD#$WORK}" ] || [ "$PWD" != "${PWD#$PORT_REPO}" ] || b+=(-v "$PWD:$PWD")
      for v in $(env | cut -d= -f1 | grep -E '^(WRF_|OMP_|CUDA_VISIBLE_DEVICES|NV_|NVCOMPILER_|J$|NETCDF|DEPS|NVHPC_ROOT|WORK|PORT_REPO|CASE_INPUTS|RUN_WRAPPER|LC_ALL|WRFIO_)'); do e+=(-e "$v"); done
      if [ "$CONTAINER" = podman ]; then u=(--userns=keep-id); gf=${CONTAINER_GPU_FLAGS:---device nvidia.com/gpu=all}
      else u=(--user "$(id -u):$(id -g)"); gf=${CONTAINER_GPU_FLAGS:---gpus all}; fi
      $CONTAINER run --rm -i --entrypoint= $gf "${u[@]}" --ipc=host --shm-size=8g "${b[@]}" "${e[@]}" -w "$PWD" "$IMAGE" \
        bash "$HERE_H100/in_container.sh" "$@" ;;
    *) echo "ERROR: unknown CONTAINER=$CONTAINER" >&2; return 2 ;;
  esac
}

cpu_view_base() { sed -e 's/#.*//' "$PORT_TOOLS/agent/cpu_view_base" | awk 'NF {print $1; exit}'; }

# build_mode <build dir>: the mode recorded in BUILD_INFO
build_mode() { awk '/^mode:/ {print $2}' "$1/BUILD_INFO" 2>/dev/null; }
# build_id <build dir>: mode + md5 of wrf.exe (keys the run cache)
build_id() { echo "$(build_mode "$1")-$(md5sum < "$1/main/wrf.exe" | cut -c1-10)"; }

# nml_set <namelist> key=value ...   (see port/nml.py)
nml_set() { local f=$1; shift; python3 "$PORT_TOOLS/nml.py" "$f" set "$@"; }

# decomp N -> "nproc_x nproc_y" as square as possible
decomp() { python3 -c "
import sys, math
n=int(sys.argv[1]); b=(1,n)
for x in range(1,int(math.isqrt(n))+1):
    if n%x==0: b=(x,n//x)
print(b[0], b[1])" "$1"; }

# run_ok <run dir>: wrf.exe finished normally
run_ok() { grep -q "SUCCESS COMPLETE WRF" "$1"/rsl.error.0000 2>/dev/null; }
