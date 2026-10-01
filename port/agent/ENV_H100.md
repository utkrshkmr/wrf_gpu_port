# Setting up the H100 machine

This is task H0.1–H0.8 of [PHASE1.md](PHASE1.md). Do it once; record every version in
[port/ENVIRONMENT.md](../ENVIRONMENT.md) and tick the tasks in the [workbook](WORKBOOK.md).

## 1. No root: everything runs in a container

The machine gives you **no sudo**. Do not try to install system packages. The toolchain is NVIDIA's HPC SDK
container image; the compilers, `make`, MPI, `wrf.exe`, `nsys` and `compute-sanitizer` run inside it, started by
the port's scripts through `x` (`port/h100/common.sh`). What the image lacks is built from source **inside the
container** into `$DEPS` (a directory you own, mounted into the container). Python for the port's tools runs on the
host from a user environment. Nothing is written outside `$WORK` and your home directory.

| Item | Where it comes from | Check |
|---|---|---|
| Container runtime, rootless: Apptainer/Singularity (usual on HPC), or rootless Podman, or Docker if you are allowed to use it | the machine | `apptainer --version` / `podman --version` |
| NVIDIA H100 visible in the container (driver on the host) | the machine | `setup_toolchain.sh check` runs `nvidia-smi` in the container |
| NVHPC image `nvcr.io/nvidia/nvhpc:25.1-devel-cuda12.6-ubuntu22.04` (one pinned tag for the whole port) | `setup_toolchain.sh image` | `x nvfortran --version` |
| tcsh (WRF's `compile` is a csh script), m4, perl (only if the image lacks them) | built by `setup_toolchain.sh deps` into `$DEPS` | `check` |
| HDF5, netCDF-C, netCDF-Fortran built with `nvc`/`nvfortran` | built by `setup_toolchain.sh deps` into `$DEPS/netcdf` | `nf-config --fc` is `nvfortran` |
| netCDF-Fortran built with the image gfortran (only for T-UNINIT, PHASE1.md H0.9) | `setup_toolchain.sh deps-gnu` into `$DEPS/netcdf-gnu` | `nf-config --fc` is `gfortran` |
| Python 3 with numpy, netCDF4, mpmath (host) | system python3, else a venv or micromamba env in `$DEPS/pyenv` (`setup_toolchain.sh python`) | `check` |
| ≥ 64 GB RAM, ≥ 16 cores, ≥ 300 GB free for `$WORK` | the machine | `check` |
| The Eaton case inputs (see 3) | copied from CCR | `dev_case.sh make` checks the md5s |

Pinning matters: T-FMA, T-IEEE and the F-* probes are only valid for the compiler version they ran with. Never switch
the image tag in the middle of a phase; if you must, rerun H0.2–H0.4 and the reference builds (H0.5, H0.7), and write
it into the workbook.

## 2. Toolchain setup (all without root)

```sh
cp port/h100/env.sh port/h100/env.local.sh
# edit env.local.sh:
#   export WORK=/path/with/300GB/wrf_gpu_work
#   export CASE_INPUTS=$WORK/inputs/eaton_20250108
#   export CONTAINER=apptainer            # or podman (rootless) or docker
#   export IMAGE=$WORK/images/nvhpc.sif    # podman/docker: IMAGE=nvcr.io/nvidia/nvhpc:25.1-devel-cuda12.6-ubuntu22.04
#   export CPU_RANKS=<physical cores, at most 64>
#   export GPU_ID=0
bash port/h100/setup_toolchain.sh image     # pull the NVHPC image (~10 GB; Apptainer converts it to a .sif)
bash port/h100/setup_toolchain.sh deps      # tcsh, m4, perl if missing, HDF5 + netCDF (30-60 min, in the container)
bash port/h100/setup_toolchain.sh deps-gnu  # optional, for T-UNINIT (H0.9): netCDF-Fortran with gfortran
bash port/h100/setup_toolchain.sh python    # numpy, netCDF4, mpmath for the host tools (if missing)
bash port/h100/setup_toolchain.sh check     # must end with "toolchain: PASS"
bash port/h100/setup_toolchain.sh shell     # prints the command for an interactive shell in the container
```

Notes:

- **Apptainer**: `pull` needs no root (it converts the Docker image). Caches go to `$WORK/tmp`. GPUs are passed with
  `--nv`. Your home, `/tmp`, `$WORK`, the repository and `$CASE_INPUTS` are mounted at the same paths.
- **Rootless Podman**: GPUs via CDI (`--device nvidia.com/gpu=all`); if the machine is configured differently set
  `CONTAINER_GPU_FLAGS`. `--userns=keep-id` keeps your user id, so files you create stay yours.
- **Docker** only if you are allowed to use it; the scripts run as your user id (`--user`).
- If the machine cannot reach `nvcr.io`, pull the image on another machine (`apptainer pull nvhpc.sif
  docker://nvcr.io/nvidia/nvhpc:25.1-devel-cuda12.6-ubuntu22.04`) and copy the `.sif`; if source downloads for
  `deps` fail, download the tarballs listed in `setup_toolchain.sh` elsewhere into `$DEPS/src`.
- The image's MPI (HPC-X/OpenMPI of the SDK) is used for all runs; `OMPI_ALLOW_RUN_AS_ROOT` is set inside the
  container because rootless runtimes may present you as root there.
- Where a rootless image build works (`podman build`), `port/container/Dockerfile` bakes tcsh, m4, Python and netCDF
  into an image instead of `deps` (then `NETCDF=/opt/netcdf`); the Apptainer equivalent is
  `port/container/wrf-gpu.def` (needs `--fakeroot` support to build).
- If NVHPC happens to be installed natively and usable, `CONTAINER=none` with `NVHPC_ROOT=<.../Linux_x86_64/<ver>>`
  works too (the netCDF and tcsh builds of `deps` then run natively).
- Record in `port/ENVIRONMENT.md`: runtime and version, image tag and digest (`apptainer inspect`, `podman image
  inspect`), driver version, `x nvfortran --version`, the deps versions (`setup_toolchain.sh check` output).
- Everything the scripts run in the container goes through `x`. If you run commands by hand, use the `shell`
  command above, or `source port/h100/common.sh; x <command>`.

## 3. Inputs

Copy the three input files of the reference case from CCR (the run folder in `cases/eaton_20250108/README.md`) to
`$CASE_INPUTS`: `wrfinput_d01` (289 MB), `wrfinput_d02` (876 MB), `wrfbdy_d01` (122 MB). The md5s must match
`cases/eaton_20250108/manifest.md5`; `dev_case.sh make` checks them. Copies with other md5s are a different case
and must not be used. The runtime tables come from the build tree (`WRF/run/`), their md5s are in the same manifest.

If the inputs are not available, stop after H0.5 and write a BLOCKERS.md entry: the Phase 1–5 tests need them.

## 4. Directory layout of `$WORK`

```
$WORK/images/nvhpc.sif                    the NVHPC container image (Apptainer)
$WORK/deps/{bin,lib,include}              tcsh, m4, ncurses (built in the container)
$WORK/deps/netcdf                         HDF5 + netCDF built with NVHPC (in the container)
$WORK/deps/pyenv                          Python for the tools (host), if the system python3 lacks numpy/netCDF4
$WORK/builds/<mode>/<sha12>               clean builds of commits      (build.sh <mode> --commit REV)
$WORK/builds/<mode>/worktree              incremental working-tree builds (build.sh <mode> --worktree)
$WORK/cases/eaton_small                   the dev case (dev_case.sh make)
$WORK/reference/eaton_small/run0220       CPU-REF 00:00 -> 02:20, restarts at 02:00 and 02:20
$WORK/reference/eaton_small/win1h         CPU-REF 02:00 -> 03:00 (T-DRIFT reference)
$WORK/runs/<mode>-<md5>/<window>[-<env>]  window runs (window.sh), reused while the binary is the same
$WORK/gates/<sha12>[-dirty]/              gate logs and results.txt
```

## 5. Costs to expect (plan your time)

The GPU build runs one MPI rank. Until a routine is ported, it runs on **one host core**. The dev case has the full
450×450×60 d01 and a 181×181×60 d02, so in Phase 1 a d01 step (with its 9 d02 steps) takes minutes:

| Window | Model time | d01 / d02 steps | GPU build, Phase 1 (all on 1 core) | CPU-REF, 32–64 ranks |
|---|---|---|---|---|
| W-T0, W-20 | 9 s | 3 / 27 | roughly 10–20 min | < 1 min |
| W-100 | 36 s | 12 / 108 | 40–80 min | 1–2 min |
| W-RAD | 240 s | 80 / 720 | hours (fast once dynamics and physics are ported) | 5–10 min |
| W-FIRE, W-IGN, W-1H | 35–60 min | 700–1200 / 6300–10800 | only at G4/G5 (by then everything is ported) | 20–60 min |

So: develop with **W-20**, run W-100/W-RAD only for sub-phase gates, and run independent windows in parallel
(CPU-REF runs use CPU ranks; a GPU run uses one core and one GPU; with several GPUs set `GPU_ID` per shell).
The dev references (H0.7) take a few hours once.

Build times: a clean NVHPC build of WRF takes 30–90 min (`BUILD_JOBS`); an incremental `--worktree` build after
editing one file takes a few minutes (the file, its dependents, the link).

## 6. First commands (H0.5–H0.8)

```sh
bash port/h100/build.sh cpu-ref --commit "$(sed 's/#.*//' port/agent/cpu_view_base | awk 'NF{print $1;exit}')"
bash port/h100/build.sh cpu-ref --worktree
source port/h100/common.sh; x bash port/sym_audit.sh $WORK/builds/cpu-ref/worktree   # T-SYM (in the container: nm)
bash port/h100/dev_case.sh make
nohup bash port/h100/dev_case.sh reference > $WORK/dev_reference.log 2>&1 &   # hours
bash port/h100/dev_case.sh status
# when done:
b=$WORK/builds/cpu-ref/worktree
bash port/h100/window.sh $b W-20 --tag run1
bash port/h100/window.sh $b W-20 --tag run2
bash port/h100/compare.sh $WORK/runs/*/W-20-run1 $WORK/runs/*/W-20-run2      # determinism: PASS
bash port/gates/t_cpu_view.sh                                                   # PASS (nothing changed yet)
```
