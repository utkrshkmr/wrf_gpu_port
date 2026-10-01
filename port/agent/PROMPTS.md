# Prompts for the coding agent (for the project owner)

Paste one of these as the agent's first message of a session. The agent's context is about 250k tokens, so the port
runs over many sessions. The workbook carries the state between them (WORKFLOW.md §11).

## First session

Replace the three `<...>` values.

````text
You are the coding agent for the GPU port of WRF v4.6.0 + WRF-Fire in https://github.com/utkrshkmr/wrf_gpu_port.
Goal: a wrf.exe that runs on one NVIDIA H100 and gives results bit-for-bit identical to the CPU reference build.
You have H100 GPUs and no sudo: compilers, make, MPI, wrf.exe and every GPU test run inside the NVHPC container
through the repository scripts (port/h100/common.sh, function x). Python tools run on the host.

Your context is about 250k tokens and this work takes many sessions. Several WRF source files are larger than your
whole context. Never open a whole WRF file, plan.md, KERNEL_REFS.md, kernels.csv or a log. Use port/tools/ref.py,
port/tools/index.py, sed ranges of at most about 300 lines, and grep | head. At about 60% of your context, and
after every task, checkpoint: static.sh, commit (WIP allowed), exact "Next step" in the workbook, push. Then stop and
say "CHECKPOINT: resume with the resume prompt".

1. Get the code:
       git clone https://github.com/utkrshkmr/wrf_gpu_port.git && cd wrf_gpu_port
       git checkout -b agent/phase-1 origin/claude/wrf-gpu-port-cpu-7doq8n
2. Read, in the order AGENTS.md gives under "First session": AGENTS.md, port/agent/README.md, ENV_H100.md,
   WORKFLOW.md, CODING_STANDARD.md, PITFALLS.md, BUILD_SYSTEM.md, PHASE1.md, WORKBOOK.md (about 35k tokens).
   Then write a log entry in port/agent/WORKBOOK.md, "### <today> SETUP Reading", of at most 20 lines. Cover in
   your own words: the 11 rules; the CPU view and arith_guard; islands and gpu_world_host; why P1.5 and P1.9 are one
   step; the task loop; what you do when a test fails; how you stay inside your context.
   Run bash port/gates/static.sh (must print "== static: PASS"), commit, git push -u origin agent/phase-1.
3. Machine setup: cp port/h100/env.sh port/h100/env.local.sh. In it set:
   - WORK=<a directory with at least 300 GB free>
   - CASE_INPUTS=<directory with wrfinput_d01, wrfinput_d02, wrfbdy_d01>; if the inputs are not on the machine
     yet, leave CASE_INPUTS at its default and follow PHASE1.md "Without the case data" (smoke case S-3M)
   - CONTAINER=<apptainer | podman | docker> (whichever runs without root; check with --version)
   - IMAGE as ENV_H100.md says
   - CPU_RANKS=<physical cores, at most 64>
   - GPU_ID=0
   Then do H0.1 to H0.9 of PHASE1.md §0 in order (without the case data: skip H0.6/H0.7, H0.8 on S-3M). A broken
   build/run script is a tool fix (WORKFLOW.md §8). Stop and report, after a BLOCKERS.md entry, if T-FMA fails
   (H0.2), if F-IFTARGET, F-PRESENT, F-DECLMOD or F-COMPMAP-ADDR fail (H0.3), or if the input md5s do not match
   (H0.6).
4. Phase 1 in the order PHASE1.md gives: P1.1, P1.2 and P1.3 (both already written: only their "Your steps"),
   P1.4, P1.6, P1.5+P1.9 together, P1.7, P1.8, P1.10-P1.12, then bash port/gates/g1.sh. Use the loop of
   CHEATSHEET.md for every task.
5. The rules of AGENTS.md are not suggestions:
   - never change arithmetic or the CPU view; never touch locked files;
   - push only to agent/phase-N; never force-push;
   - three honest attempts, then BLOCKERS.md;
   - keep the workbook current.
6. Stop when g1.sh prints "== G1: PASS", or when every remaining task is done or blocked (without the case data: every
   Phase 1 task written and smoke-checked or blocked), and report:
   - commits;
   - the checklist state;
   - gate results with their log paths;
   - open BLOCKERS.md entries;
   - the "Pending the case data" list, if any;
   - the Next step.
   Do not start Phase 2 until told.
````

## Resume (every later session)

````text
Continue the GPU port of WRF in this repository (branch agent/phase-<N>). Your context is about 250k tokens: follow
AGENTS.md rule 11 and WORKFLOW.md §11. Start with the resume read only:
    cat AGENTS.md port/agent/CHEATSHEET.md
    python3 port/tools/workbook.py resume
    git status --short; git log --oneline -5
Read the phase-card section that resume names, then continue from "Next step". Checkpoint at about 60% of your
context and after every task. After a checkpoint forced by the context, stop with "CHECKPOINT: resume with the
resume prompt". Stop at the phase gate (port/gates/g<N>.sh PASS) or when blockers stop all remaining tasks, and
report as in the first session.
````

## Next phase

````text
Start Phase <N>: git checkout -b agent/phase-<N> agent/phase-<N-1>. Do the resume read (AGENTS.md,
CHEATSHEET.md, workbook.py resume), then read the opening part of port/agent/PHASE<N>.md (up to its first task)
and the first task's section. Continue with
the same loop and rules. Stop when port/gates/g<N>.sh prints "== G<N>: PASS", and report.
````

## Owner update (the handoff branch moved while you work)

````text
The project owner pushed changes to the handoff branch. Do the resume read first (AGENTS.md, CHEATSHEET.md,
python3 port/tools/workbook.py resume), commit or checkpoint your work, then:
    git fetch origin claude/wrf-gpu-port-cpu-7doq8n
    git merge origin/claude/wrf-gpu-port-cpu-7doq8n        (a merge, never a rebase: your pushed history stays)
On a conflict in a file you did not write, take the owner's version; in a file you wrote, keep both changes; ask
nothing, write what you decided into the workbook log. Read the newest "HANDOFF" entry of the workbook log and the
card sections it names, redo the steps it says changed (e.g. a task now "provided"), run bash port/gates/static.sh,
commit the merge, push, and continue from "Next step".
````

