#!/bin/bash
# Build wrf.exe inside the image (plan.md P0.4, P0.9).
#
#   build.sh <mode> [tag]
#     mode: cpu-ref | cpu-ref-bench | gpu-repro | gpu-debug
#   -> $BUILDROOT/<mode>/<git sha>[-tag]/  with main/wrf.exe, configure.wrf,
#      compile.log, BUILD_INFO (git sha, image digest, md5 of wrf.exe)
#
# The configure stanza numbers are looked up by name, so they do not depend
# on the order in arch/configure.defaults.
set -eu
source "$(dirname "$0")/common.sh"
mode=${1:?mode}; tag=${2:-}
case $mode in
  cpu-ref|cpu-ref-bench) name="GPU port CPU-REF" ;;
  gpu-repro) name="GPU port GPU-REPRO" ;;
  gpu-debug) name="GPU port GPU-DEBUG" ;;
  *) die "unknown mode $mode" ;;
esac
sha=$(git -C "$PORT_REPO" rev-parse --short=12 HEAD)
dirty=$(git -C "$PORT_REPO" status --porcelain WRF | head -1)
[ -n "$dirty" ] && die "WRF/ has uncommitted changes; builds must come from a commit"
out=$BUILDROOT/$mode/$sha${tag:+-$tag}
[ -e "$out/main/wrf.exe" ] && { echo "exists: $out"; exit 0; }
mkdir -p "$out"
git -C "$PORT_REPO" archive "$sha" WRF | tar -x -C "$out" --strip-components=1
cd "$out"
opt=$(inimg bash -c "./configure < /dev/null 2>/dev/null" | grep "$name" | head -1 | sed -E 's/.*[^0-9]([0-9]+)\. \(dmpar\).*/\1/')
[ -n "$opt" ] || die "stanza '$name' not offered by configure"
inimg bash -c "printf '%s\n1\n' $opt | ./configure > configure.log 2>&1"
if [ "$mode" = cpu-ref-bench ]; then sed -i 's/^\(ARCH_LOCAL *=.*\)$/\1 -DBENCH/' configure.wrf; fi
inimg bash -c "./compile -j 8 em_real > compile.log 2>&1" || true
[ -x main/wrf.exe ] || { grep -n "Error" compile.log | head -40; die "build failed, see $out/compile.log"; }
{
  echo "mode: $mode"; echo "git: $(git -C "$PORT_REPO" rev-parse HEAD)"
  echo "image: $IMAGE"; echo "image sha256: $(sha256sum "$IMAGE" | cut -d' ' -f1)"
  echo "configure option: $opt ($name, dmpar)"; md5sum main/wrf.exe
  inimg bash -c "cat /opt/versions.txt" 2>/dev/null
} > BUILD_INFO
cat BUILD_INFO
