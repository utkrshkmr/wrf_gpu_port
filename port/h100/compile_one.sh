#!/bin/bash
# Compile ONE WRF source file of the working tree against an existing build, in seconds to
# minutes, without touching the build (port/agent/BUILD_SYSTEM.md).  Infrastructure (fixable).
#
#   compile_one.sh <mode|build dir> <WRF file> [--minfo]
#
#   mode      cpu-ref | gpu-repro | gpu-debug | gnu (-> $WORK/builds/<mode>/worktree)
#   --minfo   print the compiler's -Minfo lines for this file (GPU builds: which loops were
#             offloaded and how; "Generating NVIDIA GPU code")
#
# Uses the exact preprocess and compile commands of the build (build_cmds.py; the build must
# exist: build.sh <mode> --worktree once).  The object and module files go to
# $WORK/compile_one/<mode>/.  Exit status 0 if the file compiles.  This checks syntax,
# directives and interfaces of one file quickly; it does not replace the build (files that
# USE a module you changed are not recompiled here).
set -uo pipefail
source "$(dirname "$0")/common.sh"
b=${1:?usage: compile_one.sh <mode|build dir> <WRF file> [--minfo]}; file=${2:?WRF file}; minfo=0
[ "${3:-}" = --minfo ] && minfo=1
[ -d "$b" ] || b=$WORK/builds/$b/worktree
b=$(cd "$b" 2>/dev/null && pwd) || die "no build $1 (build.sh <mode> --worktree first)"
rel=${file#*WRF/}; [ -f "$PORT_REPO/WRF/$rel" ] || die "no $PORT_REPO/WRF/$rel"
mode=$(build_mode "$b")
t=$WORK/compile_one/$mode; mkdir -p "$t"
[ -f "$b/compile_cmds.json" ] || python3 "$HERE_H100/build_cmds.py" update "$b" >/dev/null
python3 "$HERE_H100/build_cmds.py" script "$b" "$rel" "$PORT_REPO/WRF/$rel" "$t" > "$t/compile.sh" || exit 2
t0=$(date +%s)
(cd "$t" && x bash compile.sh) > "$t/compile.log" 2>&1; rc=$?
base=$(basename "${rel%.*}")
if [ $rc = 0 ] && [ -f "$t/$base.o" ]; then
  note "$rel compiles with $mode ($(( $(date +%s) - t0 )) s; log $t/compile.log)"
else
  grep -n -i -E -B2 -A3 "error|severe" "$t/compile.log" | head -60 >&2
  note "$rel does NOT compile with $mode (log $t/compile.log)"; rc=1
fi
if [ $minfo = 1 ]; then grep -E "^ *[0-9]+, |Generating|Loop|offload|NVIDIA GPU" "$t/compile.log" | head -200; fi
exit $rc
