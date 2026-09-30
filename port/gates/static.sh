#!/bin/bash
# Static checks, run before EVERY commit (port/agent/WORKFLOW.md).  Needs no
# GPU and no build.
#   static.sh            checks the WRF files changed since the CPU-view base
#   static.sh <files>    checks these files
# Items:
#   tools        self-tests of the guard tools (port/tests/tools/test_agent_tools.py)
#   protected    LOCKED files (tests, checkers, gates, windows, comparison tools, guides) unchanged
#                (port/agent/protected.md5)
#   infra        every changed infrastructure script is logged in port/agent/TOOL_FIXES.md
#                (port/agent/infra.md5, check_tool_fixes.py)
#   flags        the GPU-port configure stanzas keep the arithmetic flags (check_build_flags.py)
#   koff         no temporary kernel_off.py edit (KOFF-TEMP) is left in WRF/
#   deps         build dependencies of the changed WRF files (check_deps.py: depend.common, Makefiles)
#   verbatim     the 'original' code in port/tests is the WRF source (check_verbatim.py)
#   arith_guard  CPU view unchanged, no new arithmetic in GPU code
#   kernel_lint  directive rules of every kernel
#   rp_subst     no transcendental intrinsic or real power left in the rp_subst files
#   workbook     port/agent/WORKBOOK.md and kernels.csv are consistent (workbook.py check)
#   refs         KERNEL_REFS.md, kernels.csv and ROUTES.md match the CPU-view base
#                (after moving the base: python3 port/tools/gen_kernels_csv.py; python3 port/tools/gen_routes_md.py)
set -uo pipefail
source "$(dirname "$0")/lib.sh"
base=$(cpu_view_base)
cd "$PORT_REPO"
if [ $# -gt 0 ]; then files=("$@"); else
  mapfile -t files < <( { git diff --name-only "$base" -- WRF; git ls-files --others --exclude-standard -- WRF; } \
    | grep -E '\.(F|F90|f90|inc|h)$' | grep -v '^WRF/tools/' | sort -u)
fi
# WRF/tools/ is the C source of the Registry generator, not model code: its output (inc/*.inc) is checked by
# port/tools/check_generated.py and by T-CPU-VIEW (port/gates/t_cpu_view.sh).
out=$(python3 port/tests/tools/test_agent_tools.py 2>&1); rc=$?
result tools "$([ $rc = 0 ] && echo PASS || echo FAIL)" "$(echo "$out" | tail -1)"
[ $rc = 0 ] || echo "$out" | grep -v '^ok' | head -20
out=$(cd port/agent && md5sum -c --quiet protected.md5 2>&1); rc=$?
result protected "$([ $rc = 0 ] && echo PASS || echo FAIL)" "$([ $rc = 0 ] && echo 'tests/tools/gates unchanged' || echo "$out" | head -5 | tr '\n' ' ')"
out=$(python3 port/tools/check_tool_fixes.py 2>&1); rc=$?
result infra "$([ $rc = 0 ] && echo PASS || echo FAIL)" "$(echo "$out" | tail -1)"
[ $rc = 0 ] || echo "$out" | head -20
out=$(python3 port/tools/check_build_flags.py 2>&1); rc=$?
result flags "$([ $rc = 0 ] && echo PASS || echo FAIL)" "$(echo "$out" | tail -1)"
[ $rc = 0 ] || echo "$out" | head -20
koff=$(grep -rl "KOFF-TEMP" WRF --include='*.F' --include='*.F90' --include='*.inc' --include='*.h' 2>/dev/null | head -5 | tr '\n' ' ')
result koff "$([ -z "$koff" ] && echo PASS || echo FAIL)" \
  "$([ -z "$koff" ] && echo 'no kernel_off edits' || echo "kernel_off edits left, run port/tools/kernel_off.py --revert: $koff")"
out=$(python3 port/tools/check_deps.py 2>&1); rc=$?
result deps "$([ $rc = 0 ] && echo PASS || echo FAIL)" "$(echo "$out" | tail -1)"
[ $rc = 0 ] || echo "$out" | head -20
out=$(python3 port/tools/check_verbatim.py 2>&1); rc=$?
result verbatim "$([ $rc = 0 ] && echo PASS || echo FAIL)" "$(echo "$out" | tail -1)"
[ $rc = 0 ] || echo "$out" | grep FAIL
if [ ${#files[@]} -eq 0 ]; then
  result arith_guard SKIP "no changed WRF files"; result kernel_lint SKIP "no changed WRF files"
else
  fsrc=(); for f in "${files[@]}"; do [ -f "$f" ] && fsrc+=("$f"); done
  out=$(python3 port/tools/arith_guard.py --base "$base" "${fsrc[@]}" 2>&1); rc=$?
  result arith_guard "$([ $rc = 0 ] && echo PASS || echo FAIL)" "${#fsrc[@]} files"
  [ $rc = 0 ] || echo "$out" | tail -40
  out=$(python3 port/tools/kernel_lint.py "${fsrc[@]}" 2>&1); rc=$?
  result kernel_lint "$([ $rc = 0 ] && echo PASS || echo FAIL)" "$(echo "$out" | tail -1)"
  echo "$out" | grep -E '^(E[0-9]|W[0-9]|.*: (E|W)[0-9])' | head -40
fi
mapfile -t rpf < <(grep -v '^#' port/rp_subst_files.txt | sed '/^ *$/d; s|^|WRF/|')
out=$(python3 port/rp_subst.py --check "${rpf[@]}" 2>&1); rc=$?
result rp_subst "$([ $rc = 0 ] && echo PASS || echo FAIL)" "$(echo "$out" | tail -1)"
[ $rc = 0 ] || echo "$out" | tail -20
out=$(python3 port/tools/workbook.py check 2>&1); rc=$?
result workbook "$([ $rc = 0 ] && echo PASS || echo FAIL)" "$(echo "$out" | tail -1)"
[ $rc = 0 ] || echo "$out" | grep -v '^ok' | head -20
out=$(python3 port/tools/gen_kernels_csv.py --check 2>&1 && python3 port/tools/gen_routes_md.py --check 2>&1); rc=$?
result refs "$([ $rc = 0 ] && echo PASS || echo FAIL)" "$(echo "$out" | tr '\n' ' ')"
gate_end static
