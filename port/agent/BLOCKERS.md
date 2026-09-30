# Blockers

Problems the coding agent cannot solve alone and that need the project owner: a tool or test that seems wrong, a
missing input, a compiler limitation that the fallbacks of plan.md §15 do not cover, a failure that DEBUGGING.md
could not explain after three honest attempts. Rules: [WORKFLOW.md](WORKFLOW.md) §8–9. Newest last. Mark resolved
entries `[resolved <date>: <how>]`; never delete them.

Format:

```
## B<n> <YYYY-MM-DD> <short title>   [open]
- Task / kernel: ...
- What happens (command and output): ...
- What was tried: ...
- What is needed: ...
```

## B1 2026-09-30 Ticking H0.1 breaks the locked workbook self-test   [open]
- Task / kernel: H0.1 bookkeeping. The toolchain check itself passed (`setup_toolchain.sh check` → `toolchain: PASS`, commit 10c3f22).
- What happens (command and output): `python3 port/tests/tools/test_agent_tools.py` does `saved.replace("- [ ] H0.1 Toolchain", "- [x] H0.1 Toolchain", 1)` and expects `workbook.py check` to fail. After H0.1 is already ticked, the replace matches nothing, the check still passes, and the test prints `FAIL  workbook: a ticked task without commit and log fails`. Then `bash port/gates/static.sh` prints `FAIL  tools` and `== static: FAIL`.
- What was tried: the checkbox was ticked in commit 78611a4 (that commit does not pass static.sh). It is unticked again so the negative control still fires. The pass is recorded in the log and in this entry instead.
- What is needed: change the locked test to mutate a line that stays unticked, or to build a scratch workbook, so a finished H0.1 can be ticked. Do not edit the test from this branch.
