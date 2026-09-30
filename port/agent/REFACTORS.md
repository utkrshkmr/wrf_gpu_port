# Shared refactors and moves of the CPU-view base

A shared refactor changes the CPU view (the code CPU-REF compiles), so it can only be made with bitwise evidence and
then becomes the new CPU-view base (`port/agent/cpu_view_base`). Protocol: [WORKFLOW.md](WORKFLOW.md) §6.
`port/tools/workbook.py check` requires the current base to appear in this table.

| Base (sha) | Refactor commit | What | Evidence (PASS lines) | Date |
|---|---|---|---|---|
| `f8eae70b2acb` | (Phase 0) | rp_* rewrite, i1 pool (`-DWRF_POOL`), zolri defined result, YSU BEP guard, SNUPGRD PARAMETER, sections for pooled arguments | port/RESULTS.md: T-SHARED-1, T-SHARED-POOL, T-UNINIT identical (local, gfortran) | 2026-09-29 |
