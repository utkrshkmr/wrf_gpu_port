#!/bin/bash
# T-REG-20 (plan.md 12), the per-commit regression: on W-20,
#   (a) CPU-REF of the working tree equals CPU-REF of the CPU-view base commit
#   (b) GPU-REPRO of the working tree equals CPU-REF of the working tree
set -uo pipefail
source "$(dirname "$0")/lib.sh"
bash "$PORT_REPO/port/gates/t_cpu_view.sh" W-20 || GATE_FAIL=1
bash "$PORT_REPO/port/gates/t_trace.sh" W-20 || GATE_FAIL=1
gate_end T-REG-20
