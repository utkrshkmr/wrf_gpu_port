#!/bin/bash
# T-SYM (plan.md P0.6): no vendor math-library calls may remain in the code
# covered by port/rp_subst_files.txt.
#
#   host   : undefined symbols of each covered object file (nm -u) that name a
#            math-library function (libm, NVHPC libpgmath/libnvhpcmath,
#            libgcc integer powers, ...)
#   device : SASS of the executable (cuobjdump) searched for hardware
#            approximations of transcendentals (MUFU.EX2, MUFU.LG2, MUFU.SIN,
#            MUFU.COS, MUFU.TANH); MUFU.RCP/RSQ are the first step of IEEE
#            division and square root and are allowed
#
# Usage: port/sym_audit.sh <WRF build dir> [wrf.exe]
# Exit status 0 only if nothing outside port/sym_allow.txt is found.
set -u
B=${1:?usage: sym_audit.sh <WRF build dir> [wrf.exe]}
EXE=${2:-$B/main/wrf.exe}
HERE=$(cd "$(dirname "$0")" && pwd)
LIST=$HERE/rp_subst_files.txt
ALLOW=$HERE/sym_allow.txt

MATH_RE='^(_+)?(exp|expf|exp2|exp2f|expm1|expm1f|log|logf|log10|log10f|log2|log1p|log1pf|pow|powf|sin|sinf|cos|cosf|tan|tanf|asin|asinf|acos|acosf|atan|atanf|atan2|atan2f|sinh|sinhf|cosh|coshf|tanh|tanhf|fmod|fmodf|sincos|sincosf|cbrt|hypot|erf|erfc|lgamma|tgamma)(_finite)?$'
VENDOR_RE='(mth_i_|pgmath|fmth|__fs_|__fd_|__fvs|__fvd|__rpowr|__dpowd|nvhpcmath|__powi[sd]f2|_gfortran_pow_)'

status=0
echo "== host objects"
while read -r src; do
  case "$src" in ''|'#'*) continue ;; esac
  obj="$B/${src%.*}.o"
  if [ ! -f "$obj" ]; then echo "  missing object: $obj"; continue; fi
  hits=$(nm -u "$obj" 2>/dev/null | awk '{print $NF}' | grep -E "$MATH_RE|$VENDOR_RE" || true)
  for h in $hits; do
    if [ -f "$ALLOW" ] && grep -qxF "$src $h" "$ALLOW"; then
      echo "  allowed  $src  $h"
    else
      case "$h" in
        *powi*|_gfortran_pow_*) echo "  INTEGER-POWER  $src  $h   (check with T-IPOW)" ;;
        *) echo "  FOUND    $src  $h"; status=1 ;;
      esac
    fi
  done
done < "$LIST"

echo "== device code"
if command -v cuobjdump >/dev/null 2>&1 && [ -f "$EXE" ]; then
  n=$(cuobjdump -sass "$EXE" 2>/dev/null | grep -cE 'MUFU\.(EX2|LG2|SIN|COS|TANH)' || true)
  if [ "${n:-0}" -gt 0 ]; then
    echo "  FOUND $n hardware transcendental approximations (MUFU.EX2/LG2/SIN/COS/TANH):"
    cuobjdump -sass "$EXE" | grep -B30 -E 'MUFU\.(EX2|LG2|SIN|COS|TANH)' | grep -E 'Function :' | sort -u | head -50
    status=1
  else
    echo "  none"
  fi
else
  echo "  skipped (no cuobjdump or no executable; run on a GPU build)"
fi
echo "T-SYM: $([ $status -eq 0 ] && echo PASS || echo FAIL)"
exit $status
