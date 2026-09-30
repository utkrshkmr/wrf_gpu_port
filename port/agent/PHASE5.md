# Phase 5 — nest forcing, sync points, the device world

Plan: [plan.md §10](../../plan.md) (P5.1–P5.4, G5). After Phase 4 every per-step routine has kernels and an island.
Phase 5 moves the model into device memory for good (`gpu_world_host = .FALSE.`), removes the P1.9 bracket, ports
nest forcing, and verifies all host↔device traffic.

## P5.0 Tracer on the device (needed before P5.3)

`module_bittrace.F` hashes host arrays (`hash3`). In the device world the host copies are stale, so under
`#ifdef WRF_GPU`, when `.NOT. gpu_world_host`, compute the two hashes of `bt_field2/3/k/f` on the device: a kernel
over the same index ranges with integer reductions (`reduction(+: hs)` on INTEGER(8), and the position-weighted sum
modulo 2^31−1 computed exactly as `hash3` does — reduce per-term values already reduced modulo 2^31−1, then take the
modulus of the sum; INTEGER(8) cannot overflow for the array sizes here). The result must be bit-identical to the host
hash: test by running W-20 with the world still on the host and calling both versions (a temporary debug switch),
then remove the switch. `module_bittrace.F` is port infrastructure (not compared by arith_guard) but is protected by
T-SHARED results: its host path must not change.

## P5.1 `couple_or_uncouple_em` on the device (plan.md P5.1)

| Route | Routine(s), base commit | Kernel rows (KERNEL_REFS.md) | Called from (base commit) |
|---|---|---|---|
| `couple_or_uncouple_em` | - | K-CPL-MU-1, K-CPL-MU-2, K-CPL-MU-3, K-CPL-MU-4a, K-CPL-F, K-CPL-V | share/mediation_force_domain.F:117; share/mediation_force_domain.F:129; share/mediation_force_domain.F:184; share/mediation_force_domain.F:196 |

All loops over the patch clipped to the domain, as in the source. The five mu work arrays → work arrays (P1.7
protocol). The device must perform both couple and uncouple (they do not cancel bitwise).

## P5.2 `med_force_domain` rewiring (`WRF/share/mediation_force_domain.F`, plan.md P5.2 table)

Replace the S6 bridge (full-state round trip around `med_nest_force`, P1.5) by the eight steps of plan.md P5.2:
device couple (K-CPL-*) → j-slab host update of the parent's INTERP_DOWN fields (`gpu_upd_host_force_slab.inc`) →
device pack of the nest's FORCE_DOWN spec-zone strips → host `interp_domain_em_part1` / `force_domain_em_part2` →
`gpu_upd_dev_bdy(nest)` and `gpu_upd_dev_force_full(nest)` (`o3rad`) → device uncouple. The slab rows are the ones
the pack loop visits (`WRF/external/RSL_LITE/rsl_bcast.c:258-260`, `WRF/frame/module_dm.F:4296-4303` in v4.6.0;
use `python3 port/tools/locate.py` for current lines).

Tests: T-FORCE = `t_trace.sh W-FORCE` with level-2 checkpoints after steps 2, 6, 7 (add them); T-SLAB (GPU-DEBUG or a
debug switch `WRF_GPU_SLAB_POISON=1`: fill the host copies outside the slab/strips with a signalling-NaN pattern
before forcing; results must stay bitwise equal to CPU-REF; self-test line `gpu_selftest: T-SLAB PASS/FAIL`);
T-O3 (`gpu_selftest: T-O3 PASS/FAIL`: device `o3rad` checksum equals the host checksum after every forcing).

## P5.3 The device world: remove the bracket

1. After S1/S2 (initial uploads) set `gpu_world_host = .FALSE.`; the sync points S3/S4/S5 keep working.
2. Remove the P1.9 bracket calls from `solve_em`.
3. Every island now fires only for switched-off routes (T-AB still works). Any host code left inside `solve_em` that
   touches arrays reads stale data: find it with T-TRACE and move it into a route (a kernel) or an explicit update.
4. T-NSYS-CLEAN: `bash port/gates/t_nsys.sh W-100`; every copy must be one of: nest forcing (P5.2), `wrfbdy` read
   (S5), history (S3), restart (S4), reduction results and error flags. List them in the workbook log.

## P5.4 Output and input sync

T-OUT: `t_trace.sh W-1H` (history every 15 min, restart files) bitwise. T-BDY: a window across 03:00 (a `wrfbdy`
read) — W-1H ends at 03:00; add a window 02:50–03:10 if the read is not covered (window.sh is protected: ask in
BLOCKERS.md for a new window definition, or run it by hand with the same namelist edits and compare with compare.sh).

## G5 (H100 part)

`bash port/gates/g5.sh` → `== G5-H100: PASS`. The full 17-hour acceptance (G5 items 1–9 of plan.md) runs later on
CCR and the A100/H100 nodes by the project owner.
