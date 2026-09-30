# Cheat sheet (read at the start of every session after the first)

Goal: `wrf.exe` on one H100, **bit-for-bit** equal to the CPU reference (CPU-REF). The full rules are in
[AGENTS.md](../../AGENTS.md); read the long guides only when a task needs them (links below).

## Start of a session (about 10k tokens)

```sh
cat AGENTS.md; cat port/agent/CHEATSHEET.md
python3 port/tools/workbook.py resume        # state, next items, kernels in progress, last log, card section to read
git status --short; git log --oneline -5     # uncommitted WIP from the last session?
```
Then read only the phase-card section that `resume` names, and continue from "Next step".

## Context budget (250k tokens)

- **Never open a whole WRF file.** Several are larger than your context: `module_ra_rrtmg_lw.F` 217k tokens,
  `module_advect_em.F` 143k, `module_surface_driver.F` 132k, `module_diffusion_em.F` 101k, `solve_em.F` 94k.
  Use `python3 port/tools/ref.py <kernel|route|routine>` (paged, base-commit lines), `python3 port/tools/index.py
  <file>` (map of routines), and `sed -n 'a,bp'` / `grep -n ... | head`. Read at most about 300 lines at a time.
- Do not read `plan.md`, `KERNEL_REFS.md`, `kernels.csv` or `ROUTES.md` whole. Use `ref.py` or `grep -n <id>`.
- Never `cat` a log (`compile.log`, `rsl.error.*`, `bittrace*.txt`). The scripts print summaries; otherwise use
  `grep -n -m 20`, `head`, `tail`. For git, use `git diff --stat` and `git diff -- <file> | head -150`.
- **Checkpoint at about 60% of your context** (and after every task): run `static.sh` and commit (a WIP commit is
  fine), update the workbook "Current state" with an exact next step, push, then continue in a fresh session.
- Keep workbook log entries short (at most 25 lines; `static.sh` checks it). When `static.sh` says so, run
  `python3 port/tools/workbook.py archive`.

## The loop (one routine at a time)

```sh
python3 port/tools/workbook.py next                     # the next task / kernel
python3 port/tools/ref.py <kernel id>                   # its CPU lines (base commit), template, route
python3 port/tools/gen_island.py <file> <routine>       # the island (data movement) of the routine
# edit: GPU code only under #ifdef WRF_GPU; statements copied verbatim; ! K-... comment above each kernel
bash port/gates/static.sh                               # must PASS before every commit
bash port/h100/compile_one.sh gpu-repro <file> --minfo  # seconds: compiles? kernels offloaded?
bash port/h100/harness.sh <file> <routine> [--set rk_step=3]   # ~1 min: HOST vs DEVICE, CPU vs DEVICE
bash port/h100/build.sh gpu-repro --worktree            # then the real tests:
bash port/gates/t_ab.sh <route> W-20; bash port/gates/t_trace.sh W-20
git commit -m "Port <routine> to the GPU (<kernel ids>)" -m "<tests PASS lines>"; git push
python3 port/tools/workbook.py set <kernel> done --commit <sha> --tests "..."   # + WORKBOOK.md log entry
```

## Rules (AGENTS.md has the full text)

1. Never change arithmetic: same operations, same order, same operands (`arith_guard.py`).
2. Never change the CPU view: GPU code under `#ifdef WRF_GPU`. Shared refactors follow WORKFLOW.md §6.
3. Never touch locked files (tests, checkers, gates, `compare.sh`, `windows.txt`). A broken build/run script is a
   tool fix (WORKFLOW.md §8, TOOL_FIXES.md).
4. One routine per commit (WIP commits allowed for routines too large for one session: WORKFLOW.md §11).
5. `static.sh` PASS before every commit; T-AB and T-TRACE on W-20 before "done".
6. Keep the workbook current. 7. Push to `agent/phase-N` only; never force-push. 8. Do not guess: port what
   `ref.py` shows. 9. No root: toolchain in the container (`x`). 10. After three honest attempts: BLOCKERS.md, mark
   the kernel `blocked`, move on.

## Kernel templates (CODING_STANDARD.md §5; tested examples in `port/tests/templates/`, `port/tests/tools/`)

| Template | Use | Example |
|---|---|---|
| A pointwise | independent (i,k,j) loops: directive in front of the unchanged nest | `example_calc_alt.F` |
| B rolling buffer | flux of face j reused at j+1: Y1 fills a 3D flux array, Y2 takes differences | `t_tmpl_b.F90` |
| C column | k recurrence: `collapse(2)` over (j,i), k sequential, per-`j` slabs become private column arrays, range guards | `t_tmpl_c.F90` |
| D calls | kernel calls a procedure: `teams distribute parallel do`, callee `declare target` | CODING_STANDARD §5.4 |
| G strips | boundary strips: one kernel per strip, x strips before y strips | `t_tmpl_g.F90` |
| CP column physics | wrapper gathers a column, calls the core with its=ite=1 | PHASE3.md |

Default directive: `!$omp target teams distribute parallel do collapse(N) if(target: gpu_on(R_X)) default(none) &`
`!$omp& shared(<arrays>) firstprivate(<scalars read>) private(<scalars written>)`. Never an apostrophe in a
directive line.

## Top pitfalls (PITFALLS.md has all 43)

- Changing the order of a sum or a product regrouping: 1-ulp differences. Copy the statement, change only indices.
- A scalar written in the body that is not `private`: a race. T-AB differs from run to run.
- Different `i` ranges in one source loop body: range guards `IF (i >= lo .AND. i <= hi)`.
- An initialization done "once before the j loop" (`rhs(:,1)=0`) belongs inside the column kernel.
- An array the routine uses that is not an argument (module array, `grid%` in a callee): add it to the island by
  hand.
- Transcendentals only through `rp_*`. `x**2.0` becomes `x*x`, as the source already does.
- `config_flags%x` or `grid%x` inside a kernel: copy to a local before the kernel.

## When a test fails (DEBUGGING.md)

harness (§0) → coarse trace: first differing (step, tag, field) → `t_fine.sh` (§1b; restrict with
`WRF_BITTRACE_FROM/TO/DOMAIN`) → `bt_fine3` inside the routine → `kernel_off.py` to confirm one kernel (§2).

## Guides (open the section you need)

WORKFLOW.md (loop, commits, workbook, shared refactors, tool fixes, context §11) · CODING_STANDARD.md (templates,
islands, directives) · PITFALLS.md · DEBUGGING.md · BUILD_SYSTEM.md (build, adding files, errors) · ENV_H100.md
(machine) · PHASE<N>.md (tasks) · ROUTES.md and KERNEL_REFS.md (via `ref.py`).
