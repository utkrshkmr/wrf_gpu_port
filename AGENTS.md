# Instructions for the coding agent

You are implementing Phases 1–7 of the GPU port of WRF v4.6.0 + WRF-Fire described in [plan.md](plan.md), on a
machine with NVIDIA H100 GPUs. Phase 0 is done (see [port/RESULTS.md](port/RESULTS.md)). The goal is a `wrf.exe`
that runs on one GPU and gives **bit-for-bit the same results** as the CPU reference build (CPU-REF). "Close" is a
failure: one differing bit changes where the fire spreads.

Your context window is about 250k tokens. The documents below take about 35k. The WRF sources are far larger:
several single files exceed your whole context. Rule 11 and [WORKFLOW.md §11](port/agent/WORKFLOW.md) say how to
work within that.

**First session** — read, in this order, before touching code:

1. this file;
2. [port/agent/README.md](port/agent/README.md): the map of the agent documents and tools;
3. [port/agent/ENV_H100.md](port/agent/ENV_H100.md): setting up the machine;
4. [port/agent/WORKFLOW.md](port/agent/WORKFLOW.md): the task loop, commits, the workbook, what to do when a test fails;
5. [port/agent/CODING_STANDARD.md](port/agent/CODING_STANDARD.md), [port/agent/PITFALLS.md](port/agent/PITFALLS.md) and
   [port/agent/BUILD_SYSTEM.md](port/agent/BUILD_SYSTEM.md) (how WRF is built; adding files; compile errors);
6. the card of your phase: [PHASE1.md](port/agent/PHASE1.md) ... [PHASE7.md](port/agent/PHASE7.md);
7. [port/agent/WORKBOOK.md](port/agent/WORKBOOK.md): where the work stands. Continue from its "Current state".

`plan.md` is the design behind the cards (about 31k tokens): open the section a card names, never the whole file.

**Every later session** (a fresh context, about 10k tokens): this file, [CHEATSHEET.md](port/agent/CHEATSHEET.md),
`python3 port/tools/workbook.py resume`, and the phase-card section it names. Open the other guides only for the
section a task needs.

## Rules (non-negotiable)

1. **Never change arithmetic.** A GPU kernel performs the same IEEE operations, in the same order, on the same
   operands as the CPU loop it replaces. Do not reorder, factor, distribute, fuse or simplify any expression, do not
   replace `a/b` by `a*(1/b)`, do not change the order of a sum, do not change a loop direction that carries a
   recurrence. Copy statements verbatim; only indices of arrays that change shape (a slab becomes a column) may
   change. `port/tools/arith_guard.py` checks this.
2. **Never change the CPU view.** All GPU restructuring goes under `#ifdef WRF_GPU`. With `WRF_GPU` undefined the
   file must compile to exactly what the CPU-view base commit (`port/agent/cpu_view_base`) compiles, apart from the
   allowed additions listed in `arith_guard.py --help` (USE of port modules, `CALL gpu_*`, island includes, route
   tests, directive lines). Shared refactors that must change both views follow the protocol in WORKFLOW.md and
   need bitwise evidence.
3. **Never edit, weaken, skip or delete a test, a checker, a gate script or a reference copy.** These are
   **locked**: `port/tests`, `port/tools`, `port/gates`, `port/h100/compare.sh`, `port/h100/windows.txt`, the
   comparison tools in `port/*.py`. Their checksums are in `port/agent/protected.md5`, which `static.sh` checks.
   If a locked file is wrong, stop and write it up in `port/agent/BLOCKERS.md` (WORKFLOW.md, "Tool problems").
   The **infrastructure** scripts are not locked: build, run and setup (everything in `port/h100/` apart from
   `compare.sh` and `windows.txt`, `port/container/*`, `port/make_dev_case.py`, `port/nml.py`; checksums in
   `port/agent/infra.md5`).
   They have never run on the real machine, so you may fix them, but only as a "tool fix": one commit per fix,
   logged in `port/agent/TOOL_FIXES.md`, never changing what is compared or how (WORKFLOW.md §8). Never change
   `plan.md`'s decisions; record deviations in the workbook log and in BLOCKERS.md.
4. **One routine per commit** (Phases 2–4). The commit message names the kernel IDs and the tests that passed:
   `Port calc_ww_cp to the GPU (K-PREP-5a, K-PREP-5b)` + a body with `T-AB-calc_ww_cp W-20 PASS`, `T-TRACE W-20 PASS`.
   A routine too large for one session may take extra `WIP <routine>: ...` commits first (WORKFLOW.md §11).
5. **Before every commit:** `bash port/gates/static.sh` must print `== static: PASS`. Before a routine is marked
   done: its T-AB and a T-TRACE window must pass on the GPU (WORKFLOW.md, "Done").
6. **Keep the workbook current** (`port/agent/WORKBOOK.md`, `port/tools/workbook.py`): after every task and at the
   end of every session. Another agent or person must be able to continue from it without asking you anything.
7. **Commit and push often** to your working branch (suggested: `agent/phase-N`, created from the handoff branch
   `claude/wrf-gpu-port-cpu-7doq8n`). Never force-push, never rewrite pushed history, never push to `main`.
8. **Do not guess.** Every kernel lists the exact CPU lines to port in `port/agent/KERNEL_REFS.md` (generated from
   plan.md, line numbers of the CPU-view base commit). Show them with `python3 port/tools/ref.py <kernel id>` and port
   what is there, not what you think is there.
9. **No root.** The machine gives you no sudo; do not try to install system packages. Compilers, MPI, `wrf.exe`,
   `nsys` and the GPU tests run in the NVHPC container through `x` (`port/h100/common.sh`); missing tools are built
   into `$WORK/deps` inside the container ([ENV_H100.md](port/agent/ENV_H100.md)). Python tools run on the host.
10. **When stuck** after three honest attempts on the same failure, follow WORKFLOW.md "When a test fails", then
   record the problem in BLOCKERS.md and in the workbook, mark the kernel `blocked`, and continue with the next
   independent task. Never "fix" a mismatch by changing the CPU side, loosening a comparison, or turning a route off
   permanently.
11. **Stay inside your context.**
   - Never open a whole WRF source file, `plan.md`, `KERNEL_REFS.md`, `kernels.csv` or a log. Read code with
     `port/tools/ref.py` and `port/tools/index.py`, or `sed -n` ranges of at most about 300 lines, and search with
     `grep ... | head`.
   - At about 60% of your context, and after every task, checkpoint: `static.sh`, commit (WIP is fine), a
     "Current state" with an exact next step, push. Then continue in a fresh session (WORKFLOW.md §11).

## The shortest possible summary of the loop

```sh
python3 port/tools/workbook.py resume                  # new session: where the work stands
python3 port/tools/workbook.py next                    # what to do
python3 port/tools/ref.py <kernel id>                  # its CPU lines (paged); the template in CODING_STANDARD.md
# edit WRF/... under #ifdef WRF_GPU
bash port/gates/static.sh                              # guards (no GPU needed)
bash port/h100/compile_one.sh gpu-repro <file> --minfo # one file, seconds
bash port/h100/harness.sh <file> <routine>             # one routine, host vs device vs CPU view, ~1 min
bash port/h100/window.sh <gpu build> W-20 WRF_GPU_CALLCHECK=<route>   # one routine on real data (DEBUGGING.md §0b)
bash port/gates/t_ab.sh <route> W-20                   # device vs host of this routine, real data
bash port/gates/t_trace.sh W-20                        # GPU-REPRO vs CPU-REF
git commit ...; python3 port/tools/workbook.py set <kernel> done --commit <sha> --tests "..."
# update WORKBOOK.md (Current state, checklist, log); commit; push
```
