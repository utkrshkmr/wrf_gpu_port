# Tool fixes (infrastructure scripts changed by the coding agent)

The build, run and setup scripts were written without access to the H100 machine, NVHPC or the Eaton inputs, so
first contact will find bugs in them. Those scripts are the **infrastructure tier** (`port/agent/infra.md5`,
written by `port/tools/protect.py`):

everything in `port/h100/` except `compare.sh` and `windows.txt` (builds, windows, dev case, the per-routine
harness `harness.sh`/`gen_harness.py`, `build_cmds.py`, `compile_one.sh`, container runner, setup);
`port/container/*`; `port/make_dev_case.py`, `port/nml.py`.

You may fix them, following the protocol in [WORKFLOW.md](WORKFLOW.md) §8. Every infrastructure file that differs
from `infra.md5` must be named in a row below, or `static.sh` fails (`check_tool_fixes.py`). Everything else under
`port/` (tests, checkers, gates, `compare.sh`, `windows.txt`, the comparison tools) is **locked**. A problem there
goes into BLOCKERS.md.

A tool fix must not change what is compared or how:
- the window definitions (`port/h100/windows.txt`, locked);
- trace levels and `OMP_TARGET_OFFLOAD=MANDATORY` for GPU runs (the gates check `window.info`);
- the compiler flags that fix the arithmetic (`port/tools/check_build_flags.py`, run by the gates on every build);
- the dev-case cut (d02 181×181 around the ignition, columns copied unchanged). If you fix
  `make_dev_case.py` after the dev references exist, remake the case and the references, and say so in the log.

| date | files | problem (command and error) | fix | unchanged (why the comparison is not affected) |
|---|---|---|---|---|
