# Phase 6 — performance (bit-neutral only)

Plan: [plan.md §11](../../plan.md). Nothing in this phase may change a result: every optimization is its own commit
and must pass `t_trace.sh W-100`, `t_trace.sh W-RAD`, `t_reg20.sh` and `t_fire.sh W-IGN` before the next one starts.

## P6.1 Metrics

Profile the Phase 5 build on the dev case (and, if time allows, a short full-case window): `WRF_GPU_TIMING=1` logs,
`nsys` (`t_nsys.sh`), `ncu` on the top kernels (`x ncu --set full -k <kernel> ...` through `RUN_WRAPPER`). Write
`port/PERF.md` with the table of plan.md §11.1 (H100 column only) and the analysis of §11.2 (bandwidth floor,
memory- vs latency-bound kernels, launch gaps).

## P6.2 Optimizations O1–O11 (plan.md §11.3)

One commit per item, in the order of the expected gain from P6.1. Allowed: launch configuration
(`num_teams`, `thread_limit`), `-gpu=maxregcount` per file (in the GPU stanza's per-file overrides), `nowait`/
`depend` between independent kernels, merging strip kernels with an index map (no reordering of any arithmetic),
fusing consecutive pointwise kernels of one routine (no reordering), pinned buffers for output, lazy `o3rad` upload
(O10, with its restart caveat). Not allowed: anything that changes an expression, a sum order, or a math function.

## G6 (H100 part)

`port/PERF.md` complete for the H100; every merged optimization has its test lines in the log; `g5.sh` passes again
with the tuned build.
