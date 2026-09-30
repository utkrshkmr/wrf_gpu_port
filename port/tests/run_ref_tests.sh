#!/bin/bash
# Build and run the standalone reference tests of the hard kernels, their
# negative controls (mutants) and the verbatim check of their 'original' code.
#
#   port/tests/run_ref_tests.sh            nvfortran, GPU (the H100 machine)
#   port/tests/run_ref_tests.sh gnu        gfortran, host only (any machine)
#
# Tests: T-PDLIM (pdlim/), T-KISS (kiss/), T-OZN (ozn/), templates B, C, G
# (templates/).  Prints one PASS/FAIL line per item and a summary; exit
# status 0 only if everything passes.
#
# TC: prefix for compiler and test commands, e.g. TC="bash $PWD/port/h100/x.sh" (absolute path) to
# compile and run them in the port's container while Python runs on the host
# (port/gates/ref_tests.sh does this).
set -u
comp=${1:-nvhpc}
here=$(cd "$(dirname "$0")" && pwd)
fail=0
say() { printf '%-6s %s\n' "$1" "$2"; }
run_dir() {   # run_dir <dir> <make targets...> -- <commands...>
  local d=$1; shift
  ( cd "$here/$d" && make -s COMPILER=$comp clean >/dev/null 2>&1; ${TC:-} make -s COMPILER=$comp > build.log 2>&1 ) \
    || { say FAIL "$d: build (see port/tests/$d/build.log)"; fail=1; return; }
}
export ALLOW_HOST=$([ "$comp" = gnu ] && echo 1 || echo 0)
run_dir pdlim
run_dir kiss
run_dir ozn
run_dir templates
for t in "pdlim ./t_pdlim 200" "kiss ./t_kiss 1000000" "ozn ./t_ozn 20" \
         "templates ./t_tmpl_b 20" "templates ./t_tmpl_c 20" "templates ./t_tmpl_g 5"; do
  set -- $t; d=$1; shift
  [ -x "$here/$d/${1#./}" ] || continue
  out=$(cd "$here/$d" && ${TC:-} "$@" 2>&1); rc=$?
  line=$(echo "$out" | grep -E '^(PASS|FAIL)' | tail -1)
  if [ $rc -eq 0 ] && [[ $line == PASS* ]]; then say PASS "${line#PASS  }"; else say FAIL "$d $*: ${line:-rc=$rc}"; echo "$out" | tail -5; fail=1; fi
done
for m in pdlim/mutants.py templates/mutants_b.py templates/mutants_c.py templates/mutants_g.py; do
  out=$(python3 "$here/$m" "$comp" 2>&1); rc=$?
  if [ $rc -eq 0 ]; then say PASS "mutants $m"; else say FAIL "mutants $m"; echo "$out" | grep -v '^ok'; fail=1; fi
done
out=$(python3 "$here/../tools/check_verbatim.py" 2>&1); rc=$?
if [ $rc -eq 0 ]; then say PASS "check_verbatim ($(echo "$out" | tail -1))"; else say FAIL "check_verbatim"; echo "$out" | grep FAIL; fail=1; fi
echo "run_ref_tests ($comp): $([ $fail -eq 0 ] && echo PASS || echo FAIL)"
exit $fail
