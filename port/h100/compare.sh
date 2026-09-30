#!/bin/bash
# Compare two finished window runs bit for bit (plan.md P0.7, P0.12):
#   - every bittrace.d0N.txt (port/bittrace_diff.py: first differing record)
#   - every wrfout_d0* and wrfrst_d0* file written in both (compare_fields.py --bitwise)
#   compare.sh <run dir A> <run dir B> [--no-trace] [--no-files]
# Prints PASS or FAIL as the last line; exit status 0 on PASS.
set -uo pipefail
source "$(dirname "$0")/common.sh"
A=${1:?run dir A}; B=${2:?run dir B}; shift 2
trace=1; files=1
for o in "$@"; do case $o in --no-trace) trace=0 ;; --no-files) files=0 ;; *) die "unknown option $o" ;; esac; done
run_ok "$A" || die "$A did not finish"
run_ok "$B" || die "$B did not finish"
rc=0
if [ $trace = 1 ]; then
  if ls "$A"/bittrace.d0*.txt >/dev/null 2>&1; then
    python3 "$PORT_TOOLS/bittrace_diff.py" --dir "$A" "$B" || rc=1
  else
    echo "no bittrace files in $A"; rc=1
  fi
fi
if [ $files = 1 ]; then
  n=0
  for f in "$A"/wrfout_d0* "$A"/wrfrst_d0*; do
    [ -e "$f" ] || continue
    [ -L "$f" ] && continue            # input restart links
    g=$B/$(basename "$f")
    [ -e "$g" ] || { echo "missing in B: $(basename "$f")"; rc=1; continue; }
    python3 "$PORT_TOOLS/compare_fields.py" "$f" "$g" --bitwise > "$B/compare_$(basename "$f").txt" 2>&1 \
      || { rc=1; echo "DIFFERENT: $(basename "$f") (see $B/compare_$(basename "$f").txt)"; head -30 "$B/compare_$(basename "$f").txt"; }
    n=$((n + 1))
  done
  echo "compared $n output files"
fi
if [ $rc = 0 ]; then echo PASS; else echo FAIL; fi
exit $rc
