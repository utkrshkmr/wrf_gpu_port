# The WRF build, for the port

What you need to know to add files, change the Registry generator, read compile errors and iterate quickly. The
scripts do most of this (`port/h100/build.sh`); this page says what they do, so that you can tell a build problem
from a code problem.

## 1. Layout and build order

`./compile em_real` builds, in this order, and a directory can only USE modules of directories built before it:

| Order | Directory | What |
|---|---|---|
| 1 | `external/` | I/O libraries, `RSL_LITE` (MPI halo code, `module_dm`), `esmf_time_f90` (`module_utility`) |
| 2 | `tools/` | the Registry generator `tools/registry` (C) and `standard.exe`; then the Registry runs (§4) |
| 3 | `frame/` | `module_domain`, `module_configure`, `module_integrate`, the port's `module_gpu_*` (`module_gpu_map` is compiled before the `module_alloc_space_N` files that call it), `module_bittrace`, `module_repro_math` |
| 4 | `share/` | mediation layer (`mediation_integrate.F`, nest forcing), `module_bc`, `module_model_constants` |
| 5 | `phys/` | physics and fire |
| 6 | `dyn_em/` | dynamics, `solve_em.F` |
| 7 | `main/` | `module_wrf_top.F`, `wrf.F`; the link of `wrf.exe` |

Every object goes into `main/libwrflib.a`; `main/wrf.exe` is `wrf.o module_wrf_top.o libwrflib.a` + the external
libraries.

**Calling "upwards"** (a `frame/` routine that must call something in `phys/`, e.g. `module_integrate.F` calling
`gpu_update_tables`): write that entry point as an external subroutine outside any module (after `END MODULE`), and
call it without a `USE`. The linker resolves it from `libwrflib.a`. `check_deps.py` rule D2 catches a USE in the
wrong direction.

## 2. Configure and flags

`build.sh <mode>` runs `./configure` with the "GPU port CPU-REF / GPU-REPRO / GPU-DEBUG" stanza of
`WRF/arch/configure.defaults` (option `dmpar`) and writes `configure.wrf` into the build directory. The flags that
matter:

| Variable | Meaning |
|---|---|
| `FCOPTIM` | optimization and floating-point flags (`-O2 -Kieee -Mnofma -Mnoflushz -Mnodaz -Mvect=noassoc -tp=haswell`), identical in all three stanzas |
| `FCNOOPT` | the same at `-O0`, for the files listed in `arch/noopt_exceptions_f` (e.g. `module_alloc_space_*`, `module_configure`) |
| `OMP` | `-mp=gpu -gpu=cc80,cc90,nofma,noflushz -Minfo=mp` in the GPU stanzas, empty in CPU-REF |
| `ARCH_LOCAL` | the `-D` macros: `REPRO_MATH`, `WRF_POOL`, and `WRF_GPU` in the GPU stanzas; `build.sh --fine` adds `WRF_TRACE_FINE` |

`port/tools/check_build_flags.py` checks the arithmetic flags (static.sh; gates on every build). If the pinned
compiler spells a flag differently, fixing the stanza is a tool fix (WORKFLOW.md §8); changing what a flag does is
not allowed.

## 3. How one file is compiled

The rule `.F.o` of `arch/postamble` runs four commands in the file's directory:

1. `sed -e "s/^\!.*'.*//" ...  x.F > x.G`: deletes comment lines containing an apostrophe (so that `cpp` does not
   see unbalanced quotes). **A `!$omp` line with an apostrophe disappears silently.**
2. `cpp -P -traditional -I<build>/inc -D... x.G > x.bb`: `#include`, `#ifdef`. Includes come from `inc/`
   (Registry output) and the file's directory.
3. `tools/standard.exe x.bb | cpp -traditional > x.f90`. `standard.exe` does three things:
   - it deletes `!` comments, except lines with `!$omp`, `!$acc`, `!dir$`, `!dec$`;
   - it turns `CALL wrf_error_fatal(` into `wrf_error_fatal3(__FILE__,__LINE__,`;
   - it joins the multi-line calls of `radiation_driver`, `surface_driver`, `cumulus_driver` and `pbl_driver` into
     one statement. Do not put directives or `#ifdef` blocks inside the argument lists of those calls.
4. `$(FC) -o x.o -c $(FCFLAGS) $(OMP) $(MODULE_DIRS) ... x.f90`. The `.f90` file stays in the build directory:
   it is what the compiler really saw, and compiler messages refer to its line numbers.

The exact four commands of any file of your build:

```sh
python3 port/h100/build_cmds.py show $WORK/builds/gpu-repro/worktree dyn_em/module_small_step_em.F
```

**Fast single-file check (seconds):** `bash port/h100/compile_one.sh gpu-repro WRF/dyn_em/module_small_step_em.F
--minfo` compiles the working-tree file with those commands into `$WORK/compile_one/`, without touching the build,
and prints the errors and the `-Minfo` lines (which loops were offloaded). Use it after every edit, before the
incremental build.

## 4. The Registry

`WRF/Registry/Registry.EM` (and the files it includes) describes every state field, namelist option, package,
halo and I/O stream. The C program `tools/registry` (built from `WRF/tools/*.c`) reads it and writes:

- `inc/*.inc`: `allocs.inc`/`deallocs.inc` (field allocation, P1.2), `gpu_upd_*.inc` (P1.3, `tools/gen_gpu.c`),
  `i1_decl.inc`/`i1_assoc.inc` (solve_em scratch and the pool), `state_struct.inc` (the `grid%` components),
  `in_use_for_config_*.inc`, the halo and nest-interpolation files, ...;
- `frame/module_state_description.F` (species indices `P_QV`, ...).

The Registry runs when `frame/module_state_description.F` is older than the Registry, which a change in
`tools/*.c` does not make happen. **After changing `WRF/tools/*.c` or `WRF/Registry/*`, build with `--clean`.** Look
at the generated files in `<build>/inc/`; `port/tools/check_generated.py` checks the port's parts of them.

## 5. Dependencies: Makefiles, `main/depend.common`, CMakeLists

- Each directory's `Makefile` lists its objects (`MODULES = ...`, in `share/` `MODULES1 = ...`). An object not in a
  list is never compiled, and the link fails with `undefined reference`.
- `WRF/main/depend.common` (included by every directory's Makefile) says which objects need which module files:
  `solve_em.o: ../frame/module_gpu_updates.o ...`. Make builds a file only after the modules listed for it. A missing
  entry gives `Cannot open module file` or, with parallel make, a build that sometimes works.
- `CMakeLists.txt` of each directory is the alternative CMake build. `build.sh` does not use it; keep it consistent
  anyway.

Tools:

```sh
python3 port/tools/add_to_build.py WRF/frame/module_gpu_work.F          # a new file: Makefile, CMakeLists, depend.common
python3 port/tools/add_to_build.py --deps WRF/dyn_em/module_em.F        # you added USE lines to an existing file
python3 port/tools/check_deps.py                                        # rules D1-D3; part of static.sh
```

Then build with `--clean` (new files) or `--worktree` (new dependencies).

## 6. Incremental builds

`build.sh <mode> --worktree` copies the changed files of the working tree into `$WORK/builds/<mode>/worktree`
(`sync_tree.py`, new mtime) and runs `./compile em_real`. Make recompiles those files and the files that depend on
them through `depend.common`, updates `libwrflib.a` and links. `build.sh` then records the exact compile commands
(`build_cmds.py update`, used by `compile_one.sh` and `harness.sh`).

Build with `--clean` when you change the Registry or `tools/*.c`, add a file, change `arch/`, or when a build behaves
strangely after a module's interface changed (stale `.mod` files).

WRF runs make with `-i` (ignore errors): a file that fails to compile does not stop the build. The first error is
somewhere in `compile.log`, and the build only fails at the link (no `wrf.exe`). `build.sh` prints the first error
lines. Otherwise use `grep -n -E "Error|NVFORTRAN-S|NVFORTRAN-F" compile.log | head`; the first one is the one to fix.

## 7. Reading compiler output (NVHPC)

- `NVFORTRAN-S-...` is a severe error, `-F-` fatal, `-W-` a warning, `-I-` information. Line numbers refer to the
  `.f90` file in the build directory, not to the `.F` source. Find the statement in `x.f90`, then in `x.F`.
- `-Minfo=mp` lines, per kernel: `NNN, !$omp target teams distribute parallel do` then `Generating NVIDIA GPU code`
  and the loop schedule (`Loop parallelized across teams and threads`). A kernel with no "Generating NVIDIA GPU
  code" line was not offloaded. Get them for one file with `compile_one.sh <mode> <file> --minfo`.
- `-w` in `FCBASEOPTS` hides warnings. To see them for one file, run the `fc` command of `build_cmds.py show`
  without `-w`, in a scratch directory.

## 8. Common problems

| Symptom | Cause | Fix |
|---|---|---|
| `Cannot open module file 'module_x.mod'` | missing `depend.common` entry, or a USE of a later directory | `check_deps.py`; `add_to_build.py --deps` |
| `undefined reference to 'x_'` at the link | object not in a Makefile list; an external routine called with a module-procedure name, or the reverse | `add_to_build.py`; check where `x` is defined (`git grep -n "SUBROUTINE x"`) |
| `multiple definition of` | the same routine in two objects | rename or remove one |
| my change has no effect | the build uses an older copy (look at `BUILD_INFO`: HEAD + diff md5), or a stale `.mod` | rebuild; `--clean` |
| a directive has no effect, no `-Minfo` line | the `!$omp` line contains an apostrophe (removed by sed), or it is inside one of the four joined driver calls | remove the apostrophe; move it |
| `Symbol x conflicts with symbol from module y` | two USEs bring the same name | `USE y, ONLY : ...` |
| a Registry change is not visible | the Registry did not run | `build.sh <mode> --worktree --clean` |
| `configure does not offer 'GPU port ...'` | compiler not in PATH in the container, or `NETCDF` wrong | `setup_toolchain.sh check`; `ENV_H100.md` |

## 9. Fast iteration, summarized

| Step | Command | Time |
|---|---|---|
| guards | `bash port/gates/static.sh` | seconds |
| does the file compile, are the kernels offloaded | `bash port/h100/compile_one.sh gpu-repro <file> --minfo` | seconds to a few minutes |
| does the routine give the same bits on host and device, and as the CPU view | `bash port/h100/harness.sh <file> <routine>` (DEBUGGING.md §0) | about a minute |
| the real tests | `build.sh gpu-repro --worktree`, `t_ab.sh <route> W-20`, `t_trace.sh W-20` | 20-40 min |

Build the worktree builds of `cpu-ref` and `gpu-repro` once per session. The first two rows then only recompile one
file.
