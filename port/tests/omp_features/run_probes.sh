#!/bin/bash
# Build and run every probe separately (a compile failure is itself a result)
# and write probes_<host>_<date>.md, to be copied into port/ENVIRONMENT.md.
# T-OMP-FEAT (plan.md P0.5b) = this table exists for the pinned NVHPC version.
set -u
cd "$(dirname "$0")"
COMPILER=${COMPILER:-nvhpc}
out="probes_$(hostname -s)_$(date +%Y%m%d_%H%M%S).md"
{
  echo "# OpenMP feature probes: $(hostname) $(date)"
  echo; echo '```'; nvfortran --version 2>/dev/null | head -2; nvidia-smi -L 2>/dev/null; echo '```'; echo
  echo "| Probe | Build | Result |"; echo "|---|---|---|"
} > "$out"
make -s COMPILER=$COMPILER stack_shim.o >/dev/null 2>&1
for p in f_iftarget f_calls f_declmod f_present f_defmap f_defmap_neg f_privarr f_auto f_langfeat f_red f_stack; do
  if make COMPILER=$COMPILER $p > build_$p.log 2>&1; then
    b=ok
    res=$(timeout 300 ./$p 2>&1); rc=$?
    if [ $p = f_defmap_neg ]; then
      if [ $rc -ne 0 ] || ! echo "$res" | grep -q "reached the end"; then res="PROBE F-DEFMAP-NEG PASS (unmapped data rejected, exit $rc)"
      else res="PROBE F-DEFMAP-NEG FAIL (unmapped data accepted silently)"; fi
    fi
    res=$(echo "$res" | grep PROBE | tr '\n' ';')
    [ -z "$res" ] && res="no PROBE line (exit $rc)"
  else
    b="FAILED (see build_$p.log)"; res="-"
  fi
  echo "| $p | $b | $res |" | tee -a "$out"
done
echo; echo "-Minfo=mp messages are in build_*.log (check that F-CALLS loops are parallelized over teams and threads)."
echo "wrote $out"
