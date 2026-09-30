# Shared helpers of the gate scripts (port/gates/*.sh).  Source this file.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../h100" && pwd)/common.sh"
H100=$PORT_REPO/port/h100
head_id() {
  local s; s=$(git -C "$PORT_REPO" rev-parse --short=12 HEAD)
  if [ -n "$(git -C "$PORT_REPO" status --porcelain -- WRF port | head -1)" ]; then s="$s-dirty"; fi
  echo "$s"
}
GATE_DIR=${GATE_DIR:-$WORK/gates/$(head_id)}
mkdir -p "$GATE_DIR"
GATE_FAIL=0
# result <name> <PASS|FAIL|SKIP> <detail>
result() {
  printf '%-5s %-28s %s\n' "$2" "$1" "$3" | tee -a "$GATE_DIR/results.txt"
  [ "$2" = FAIL ] && GATE_FAIL=1
  return 0
}
# gate_end <gate name>: summary line, exit status
gate_end() {
  local s; s=$([ $GATE_FAIL = 0 ] && echo PASS || echo FAIL)
  echo "== $1: $s  (results: $GATE_DIR/results.txt)" | tee -a "$GATE_DIR/results.txt"
  exit $GATE_FAIL
}
# build_for <mode>: incremental build of the working tree (the edit-build-test loop);
# prints the build dir.  Set GATE_BUILD_<MODE> (e.g. GATE_BUILD_GPU_REPRO) to reuse a build.
build_for() {
  local var=GATE_BUILD_$(echo "$1" | tr 'a-z-' 'A-Z_')
  if [ -n "${!var:-}" ]; then echo "${!var}"; return; fi
  "$H100/build.sh" "$1" --worktree | tail -1
}
# base_build: CPU-REF of the CPU-view base commit (the dev references were made with it)
base_build() { if [ -n "${GATE_BASE_BUILD:-}" ]; then echo "$GATE_BASE_BUILD"; else "$H100/build.sh" cpu-ref --commit "$(cpu_view_base)" | tail -1; fi; }
# window <build> <window> [args]: run (or reuse) a window, print the run dir; empty on failure
window() { "$H100/window.sh" "$@" | tail -1; }
# routes_for_phase <2|3|4|5>: route names of that phase, from the section
# comments of WRF/frame/module_gpu_route.F (7.x -> 2, 8.x -> 3, 9.x -> 4, 10 -> 5)
routes_for_phase() {
  awk -v ph="$1" '
    /^ *! *7\./ {p=2} /^ *! *8\./ {p=3} /^ *! *9\./ {p=4} /^ *! *10 / {p=5} /^ *! *5 \(tools\)/ {p=0}
    /INTEGER, PARAMETER, PUBLIC :: R_/ {exit}
    p==ph { while (match($0, /'"'"'[a-z0-9_]+ *'"'"'/)) { s=substr($0, RSTART+1, RLENGTH-2); gsub(/ /,"",s); print s; $0=substr($0, RSTART+RLENGTH) } }
  ' "$PORT_REPO/WRF/frame/module_gpu_route.F"
}
# ported_routes <phase>: routes of the phase that have at least one kernel in WRF
# (a target construct with if(target: gpu_on(R_<ROUTE>)))
ported_routes() {
  local r
  for r in $(routes_for_phase "$1"); do
    grep -rqi "gpu_on *( *R_$r *)" "$PORT_REPO/WRF" --include='*.F' --include='*.F90' --include='*.inc' 2>/dev/null && echo "$r"
  done
}
