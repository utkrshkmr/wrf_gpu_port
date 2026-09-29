# Shared helpers for port/ccr scripts.  Source after env.sh.
HERE_CCR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ -f "$HERE_CCR/env.local.sh" ]; then source "$HERE_CCR/env.local.sh"; else source "$HERE_CCR/env.sh"; fi
PORT_TOOLS=$PORT_REPO/port
CASE_REPO=$PORT_REPO/cases/eaton_20250108
TABLES="LANDUSE.TBL VEGPARM.TBL SOILPARM.TBL GENPARM.TBL RRTMG_LW_DATA ozone.formatted ozone_lat.formatted ozone_plev.formatted"

die() { echo "ERROR: $*" >&2; exit 1; }
inimg() { apptainer exec --bind "$WORKROOT","$PORT_REPO","$CASE_INPUTS" "$IMAGE" "$@"; }
inimg_gpu() { apptainer exec --nv --bind "$WORKROOT","$PORT_REPO","$CASE_INPUTS" "$IMAGE" "$@"; }

# setup_run <run dir> <wrf build dir> <namelist template> [inputs dir]
# Links wrf.exe, inputs and tables, copies the namelist, checks the manifest.
setup_run() {
  local rd=$1 bd=$2 nl=$3 inp=${4:-$CASE_INPUTS}
  mkdir -p "$rd" && cd "$rd" || die "cannot create $rd"
  ln -sf "$bd/main/wrf.exe" wrf.exe
  for f in wrfinput_d01 wrfinput_d02 wrfbdy_d01; do ln -sf "$inp/$f" "$f"; done
  for t in $TABLES; do ln -sf "$bd/run/$t" "$t"; done
  ln -sf "$bd/run/CAMtr_volume_mixing_ratio.SSP245" CAMtr_volume_mixing_ratio
  cp "$nl" namelist.input
  cp "$CASE_REPO/manifest.md5" manifest.md5
  python3 "$PORT_TOOLS/manifest.py" check . -m manifest.md5 > manifest.check.txt 2>&1 \
    || { cat manifest.check.txt; die "manifest check failed in $rd"; }
  md5sum "$bd/main/wrf.exe" > wrf.exe.md5
}

# nml_set <namelist> key=value ...
nml_set() { local f=$1; shift; python3 "$PORT_TOOLS/nml.py" "$f" set "$@"; }

# decomposition for N ranks (nproc_x*nproc_y = N, as square as possible)
decomp() { python3 -c "
import sys, math
n=int(sys.argv[1]); b=(1,n)
for x in range(1,int(math.isqrt(n))+1):
    if n%x==0: b=(x,n//x)
print(b[0], b[1])" "$1"; }
