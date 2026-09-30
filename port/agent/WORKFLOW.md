# Workflow

How to work on the port, from picking a task to pushing it. The rules behind it are in [AGENTS.md](../../AGENTS.md).

## 1. Branches and commits

- Work on your own branch created from the handoff branch: `git checkout -b agent/phase-1 origin/claude/wrf-gpu-port-cpu-7doq8n`.
  Start a new branch per phase (`agent/phase-2` from the tip of `agent/phase-1`, ...). Push after every commit.
- One commit = one coherent step that passes `port/gates/static.sh`. During Phases 2–4, one routine per commit.
- Commit message: first line `Port <routine> to the GPU (<kernel IDs>)` or `P1.2: <what>`; the body lists the tests
  that passed, e.g. `T-AB-calc_ww_cp W-20 PASS; T-TRACE W-20 PASS; static PASS`.
- Never commit build products, run directories, or files under `$WORK`.
- Never rewrite pushed history; never force-push; never push to `main`.

## 2. The task loop

```
1. python3 port/tools/workbook.py next          -> the next task / kernel
2. read its section in the phase card (PHASE<N>.md) and plan.md
3. open the CPU lines:  KERNEL_REFS.md row  ->  git show <base>:<file> | sed -n 'a,bp'
4. write the code (CODING_STANDARD.md), under #ifdef WRF_GPU, with its island (gen_island.py)
5. bash port/gates/static.sh                    -> must PASS (fix, repeat)
6. fast:   bash port/h100/compile_one.sh gpu-repro <file> --minfo;  bash port/h100/harness.sh <file> <routine>
           (seconds to a minute; DEBUGGING.md §0; repeat 4-6 until both PASS)
7. build:  bash port/h100/build.sh gpu-repro --worktree   (and cpu-ref --worktree when the CPU view could change)
   test:   bash port/gates/t_ab.sh <route> W-20;  bash port/gates/t_trace.sh W-20
8. on FAIL: DEBUGGING.md (harness -> coarse trace -> t_fine.sh -> bt_fine3 inside the routine -> kernel_off.py);
   at most three honest attempts per failure mode, then BLOCKERS.md
9. commit, workbook.py set <kernel> done ..., update WORKBOOK.md, commit, push
```

### When is a routine "done"

All of these, on the current working tree:

1. `bash port/gates/static.sh` → PASS (arith_guard, kernel_lint including the island rule E9, protected files, workbook).
2. `bash port/gates/t_ab.sh <route> W-20` → PASS (device execution equals host execution of the same code).
3. `bash port/gates/t_trace.sh W-20` → PASS (GPU-REPRO equals CPU-REF).
4. `bash port/gates/t_cpu_view.sh W-20` → PASS whenever the CPU view of any file could have changed (if static.sh
   passes, it cannot; run it anyway at least once per sub-phase).
5. `-Minfo=mp` in the build log shows each new kernel as offloaded (`Generating NVIDIA GPU code`), with the loops
   you intended parallel. Save the relevant lines in the log entry.

A sub-phase (P2.A, ..., P3.E, P4.x) is done when every kernel row of its sections in kernels.csv is `done` or
`n/a`, and `t_ab.sh <route> W-100` (radiation: `W-RAD`) passes for each of its routes and `t_trace.sh W-100` passes.
A phase is done when its gate script (`port/gates/g<N>.sh`) prints `== G<N>: PASS`.

## 3. Builds

```sh
bash port/h100/build.sh gpu-repro --worktree     # incremental, working tree -> $WORK/builds/gpu-repro/worktree
bash port/h100/build.sh cpu-ref --worktree       # the CPU-REF build of the working tree
bash port/h100/build.sh cpu-ref --commit <sha>   # clean build of a commit (references, base)
bash port/h100/build.sh gpu-debug --worktree     # -g -traceback -gpu=lineinfo, WRF_TRACE_FINE
bash port/h100/build.sh gpu-repro --worktree --fine   # fine tracing (and cpu-ref --fine): DEBUGGING.md §1b
```

- Builds and runs happen in the container (`x`, ENV_H100.md); the scripts do that for you. For a command by hand:
  `source port/h100/common.sh; x <command>` or `bash port/h100/x.sh <command>`.
- The gates build what they need (`--worktree`); set `GATE_BUILD_GPU_REPRO=<dir>` / `GATE_BUILD_CPU_REF=<dir>` to
  reuse a build you just made.
- Incremental builds follow WRF's make dependencies. If a build behaves strangely after editing a module that many
  files use (e.g. `module_gpu_route.F`), rebuild clean: `build.sh <mode> --worktree --clean`.
- Changing `WRF/Registry/*`, `WRF/tools/*.c` (the Registry generator) or `arch/*` needs `--clean`.
- How the build works, adding files (`port/tools/add_to_build.py`), dependencies (`check_deps.py`, in static.sh),
  compile errors: [BUILD_SYSTEM.md](BUILD_SYSTEM.md). One file in seconds: `port/h100/compile_one.sh`.
- A failed compile leaves no `main/wrf.exe`; `build.sh` prints the first errors and the log path.
- WRF's build deletes comment lines that contain an apostrophe before preprocessing. A directive is a comment line:
  **never put `'` in a `!$omp` line** (it silently disappears).

## 4. Windows and runs

`port/h100/window.sh <build> <window> [VAR=value ...]` runs a window of the dev case and prints the run directory;
runs are cached by (binary md5, window, variables), so asking again is free. See the table in `window.sh --help`
(first lines of the script) and ENV_H100.md §5 for costs. Use W-20 while developing.

- GPU runs use one MPI rank on `$GPU_ID` with `OMP_TARGET_OFFLOAD=MANDATORY` (a kernel that cannot run on the
  device is an error, not a silent host fallback).
- `WRF_BITTRACE=2` (the default for the short windows) writes `bittrace.d0N.txt` with a hash of every field after
  every step of plan.md §7.1; `port/h100/compare.sh A B` names the first differing record.
- Run independent windows in parallel from different shells (CPU-REF runs use CPU cores, GPU runs one core + GPU).

## 5. The workbook

`port/agent/WORKBOOK.md` and the status columns of `port/agent/kernels.csv` are the project memory. Someone else
must be able to continue from them without asking you. `workbook.py check` (in static.sh) enforces the format.

- **Current state**: overwrite after every task and at the end of every session. `Next step` must be concrete
  ("port advect_v y-flux (K-ADVV-Y1/Y2), ADV:1964-2066 of the base; template B as in advect_u").
- **Task checklist**: tick with commit and tests: `- [x] P1.4 Module tables on the device (gpu_update_tables), T-TAB — commit 1a2b3c4 — tests T-TAB PASS, T-TRACE W-20 PASS`.
- **Log**: one entry per task or session, newest last:

  ```
  ### 2026-10-03 P2.B advect_u (K-ADVU-Y1, K-ADVU-Y2, K-ADVU-X, K-ADVU-Z)
  - Commit(s): 1a2b3c4, 5d6e7f8
  - Changed: WRF/dyn_em/module_advect_em.F advect_u: Y1/Y2 (template B), X (per-thread faces), Z (column); island.
  - Tests run: static PASS; T-AB-advect_u W-20 PASS; T-TRACE W-20 PASS (build gpu-repro-3f2a..., 14 min)
  - Notes: -Minfo shows the X kernel with 96 registers; consider X1/X2 in Phase 6.
  ```
- **kernels.csv**: `python3 port/tools/workbook.py set <key or kernel id> <status> --commit <sha> --tests "..."`.
  Statuses: `todo`, `in-progress`, `done`, `blocked` (note required, and a BLOCKERS.md entry), `n/a` (with a note
  saying why, e.g. "host scalar code, stays on the host").
- `python3 port/tools/workbook.py status` gives the overview.

## 6. Shared refactors (changes that must be in both builds)

Some changes cannot live under `#ifdef WRF_GPU` because the CPU reference must run the same code: the work arrays of
P1.7 (automatic arrays → pointers into zero-filled work arrays), the fire refactors of plan.md §9.0, the RRTMG
table flattening and Noah `iloc`/`LUTYPE` changes (P0.9a items 6, 7), skipping provable no-ops (item 8), the KISS
rewrite (item 9, only if T-KISS fails). They change the CPU view, so arith_guard rejects them against the current
base. Protocol:

1. Make the refactor alone in one commit (no GPU code in it). Title `Shared refactor: <what>`.
2. Prove it changes nothing, with the base CPU-REF build vs the CPU-REF build of that commit:
   - `bash port/gates/t_cpu_view.sh W-T0 W-20 W-100` → PASS (traces and output files bitwise);
   - `bash port/gates/t_drift.sh` → PASS (1 h window against the dev reference);
   - for fire refactors also `bash port/gates/t_cpu_view.sh W-IGN` (fire ignition active).
   (While the refactor commit is not yet the base, `static.sh` reports its CPU-view changes; that is expected for
   this one commit only. Run the tests above before committing anything else.)
3. Move the base: write the new commit's full sha into `port/agent/cpu_view_base` (keep the comment), add a row to
   `port/agent/REFACTORS.md` (sha, what, the PASS lines of step 2), commit `Move CPU-view base to <sha12>: <what>`.
4. From now on `static.sh` compares against the new base.

The dev references stay valid because step 2 proved bit-identical results. Never move the base for a change that
has not passed step 2. Never combine a shared refactor with GPU code in one commit.

## 7. When a test fails

Read [DEBUGGING.md](DEBUGGING.md). In short:

1. `compare.sh` / `bittrace_diff.py` name the first differing (domain, step, RK stage, tag, field). The tag is the
   checkpoint after a routine (plan.md §7.1 order); the first differing field after the first differing tag is the
   routine to look at.
2. Rerun with `WRF_GPU_OFF=<route>` for the suspect route: if T-TRACE then passes, the kernel is wrong; if not, look
   earlier.
3. Check the kernel against its CPU lines statement by statement (order, ranges, private variables, range guards,
   first/last k, halo rows written).
4. Check the island: does the routine read an array that is not a dummy (module variable, `grid%` inside a
   callee)? Is an OUT array only partly written?
5. Use the GPU-DEBUG build with `compute-sanitizer --tool memcheck` / `racecheck` via `RUN_WRAPPER`.

Never make a test pass by changing the CPU side, loosening a comparison, editing a reference copy, or leaving a
route switched off.

## 8. Tool problems

The port's own files come in two tiers (`python3 port/tools/protect.py --list` shows which file is in which):

- **Locked** (`port/agent/protected.md5`): tests, checkers, gate scripts, `port/h100/compare.sh`,
  `port/h100/windows.txt`, the comparison tools (`port/*.py` apart from the two below), the reproducible-math
  module, the case contract, the agent guides. They decide pass or fail; you never change them.
- **Infrastructure** (`port/agent/infra.md5`): everything in `port/h100/` except `compare.sh` and `windows.txt`
  (build, windows, dev case, harness, one-file compile, container runner, setup), `port/container/*`,
  `port/make_dev_case.py`, `port/nml.py`. They build, run and set up. They were written without the H100 machine,
  NVHPC or the Eaton inputs, so expect bugs on first contact (a container flag, an MPI launcher option, a configure
  prompt, a netCDF attribute in the real inputs). You may fix them.

**A locked tool is wrong** (for example arith_guard reports "new arithmetic" for a statement that is the source
statement with renamed indices): first check the rule in the tool's `--help`. If the tool is wrong:

- arith_guard only: add one line `file|normalized statement|reason` to `port/agent/arith_exceptions.txt` (it is not
  protected) and explain it in the workbook log. Each exception is reviewed later.
- any other locked file: do not edit it. Write a BLOCKERS.md entry with the command, the output and why you think it
  is wrong, mark the task blocked, and continue with another task.

**An infrastructure script is wrong**: fix it as a **tool fix**.

1. Reproduce the failure and keep the command and its error output.
2. Make the smallest change that fixes it, in the infrastructure file(s) only, with no WRF or GPU code in the same
   commit. Title: `Tool fix: <file>: <what>`.
3. The fix must not change what is compared or how:
   - windows: `windows.txt` is locked;
   - trace levels, and `OMP_TARGET_OFFLOAD=MANDATORY` for GPU runs: the gates check `window.info` and reject a run
     without them;
   - the arithmetic flags: `port/tools/check_build_flags.py` runs in static.sh on the stanzas and in the gates on
     every build;
   - the rank counts of CPU-REF runs;
   - the dev-case cut: d02 181×181 around the ignition, columns copied unchanged. If you fix `make_dev_case.py`
     after the dev references exist, remake the case and the references (`dev_case.sh make`, `dev_case.sh
     reference`) and say so in the log.

   Spelling fixes in the NVHPC stanzas of `WRF/arch/configure.defaults` (a flag the pinned compiler writes
   differently) are tool fixes too; `check_build_flags.py` must still pass.
4. Add a row to `port/agent/TOOL_FIXES.md`: date, files, problem (command and error), fix, and why the comparison is
   unaffected. `static.sh` fails while an infrastructure file differs from `infra.md5` without a row naming it
   (`check_tool_fixes.py`).
5. Rerun the command that failed, then `static.sh`; commit; push; one line in the workbook log.

## 9. BLOCKERS.md

One entry per problem the project owner must decide or fix: a tool bug, a missing input, a compiler limitation that
the fallbacks of plan.md §15 do not solve, a test that fails in a way you cannot explain after DEBUGGING.md. Format:

```
## B<n> <date> <short title>   [open | resolved <date>]
- Task / kernel: ...
- What happens (command and output): ...
- What was tried: ...
- What is needed: ...
```

## 10. End of session checklist

- [ ] everything committed and pushed;
- [ ] WORKBOOK.md: Current state rewritten, checklist ticked, log entry written;
- [ ] kernels.csv statuses current (`workbook.py status`);
- [ ] `bash port/gates/static.sh` PASS on the pushed commit;
- [ ] long runs that are still going are named in the log (run directory, what to check).
