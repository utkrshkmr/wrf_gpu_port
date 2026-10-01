#!/bin/bash
# Build and run the standalone reference tests of the hard kernels, their
# negative controls (mutants) and the verbatim check of their 'original' code.
#
#   port/tests/run_ref_tests.sh            nvfortran, GPU (the H100 machine)
#   port/tests/run_ref_tests.sh gnu        gfortran, host only (any machine)
#
# Tests: T-PDLIM (pdlim/), T-KISS (kiss/), T-OZN (ozn/), templates B, C, G, CP
# (templates/), T-CALLCHECK (callcheck/: the call check of the islands).
# Prints one PASS/FAIL line per item and a summary; exit status 0 only if
# everything passes.
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
# templates: if the compiler rejects statement functions in device code (probe F-STMTFN),
# template B is built in its module-function form (t_tmpl_b.F90, TMPL_NO_STMTFN)
tflags=
if ! ( cd "$here/templates" && make -s COMPILER=$comp clean >/dev/null 2>&1; \
       ${TC:-} make -s COMPILER=$comp t_tmpl_b t_tmpl_c t_tmpl_g > build.log 2>&1 ); then
  if ( cd "$here/templates" && make -s COMPILER=$comp clean >/dev/null 2>&1; \
       ${TC:-} make -s COMPILER=$comp TMPL_B_FLAGS=-DTMPL_NO_STMTFN t_tmpl_b t_tmpl_c t_tmpl_g > build.log 2>&1 ); then
    say NOTE "templates: statement functions rejected in device code; template B built with -DTMPL_NO_STMTFN (module functions): use that form in WRF (CODING_STANDARD.md)"
    export MUTANT_EXTRA_FLAGS=-DTMPL_NO_STMTFN
    tflags=-DTMPL_NO_STMTFN
  else
    say FAIL "templates: build (see port/tests/templates/build.log)"; fail=1
  fi
fi
# template CP (column physics) on its own: assumed-shape sections of private
# arrays, declare target module data, fixed-size locals (PHASE3.md P3.0)
if ! ( cd "$here/templates" && ${TC:-} make -s COMPILER=$comp TMPL_B_FLAGS="$tflags" t_tmpl_cp > build_cp.log 2>&1 ); then
  say FAIL "templates: t_tmpl_cp build (column physics in device code; see port/tests/templates/build_cp.log, PHASE3.md P3.0)"; fail=1
fi
for t in "pdlim ./t_pdlim 200" "kiss ./t_kiss 1000000" "ozn ./t_ozn 20" \
         "templates ./t_tmpl_b 20" "templates ./t_tmpl_c 20" "templates ./t_tmpl_g 5" "templates ./t_tmpl_cp 20"; do
  set -- $t; d=$1; shift
  [ -x "$here/$d/${1#./}" ] || { say FAIL "$d $1: not built"; fail=1; continue; }
  out=$(cd "$here/$d" && ${TC:-} "$@" 2>&1); rc=$?
  line=$(echo "$out" | grep -E '^(PASS|FAIL)' | tail -1)
  if [ $rc -eq 0 ] && [[ $line == PASS* ]]; then say PASS "${line#PASS  }"; else say FAIL "$d $*: ${line:-rc=$rc}"; echo "$out" | tail -5; fail=1; fi
done
out=$(bash "$here/callcheck/run_callcheck.sh" "$comp" 2>&1); rc=$?
echo "$out" | grep -E '^(PASS|FAIL)'
[ $rc -eq 0 ] || { echo "$out" | grep -v -E '^(PASS|FAIL)' | tail -14; fail=1; }
for m in pdlim/mutants.py templates/mutants_b.py templates/mutants_c.py templates/mutants_g.py templates/mutants_cp.py; do
  out=$(python3 "$here/$m" "$comp" 2>&1); rc=$?
  if [ $rc -eq 0 ]; then say PASS "mutants $m"; else say FAIL "mutants $m"; echo "$out" | grep -v '^ok'; fail=1; fi
done
out=$(python3 "$here/../tools/check_verbatim.py" 2>&1); rc=$?
if [ $rc -eq 0 ]; then say PASS "check_verbatim ($(echo "$out" | tail -1))"; else say FAIL "check_verbatim"; echo "$out" | grep FAIL; fail=1; fi
echo "run_ref_tests ($comp): $([ $fail -eq 0 ] && echo PASS || echo FAIL)"
exit $fail
