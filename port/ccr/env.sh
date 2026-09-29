# Settings for the Phase 0 scripts on CCR and on the GPU nodes (plan.md 5).
# Copy to env.local.sh, edit, and every script sources env.local.sh if it
# exists (it is ignored by git), otherwise this file.

# Apptainer image built from port/container/wrf-gpu.def (plan.md P0.0)
export IMAGE=${IMAGE:-$HOME/wrf-gpu/wrf-gpu.sif}

# This repository on the cluster
export PORT_REPO=${PORT_REPO:-$HOME/wrf_gpu_port}

# Case input folder with wrfinput_d01, wrfinput_d02, wrfbdy_d01 (the CCR run
# folder of the reference case, plan.md 2.1)
export CASE_INPUTS=${CASE_INPUTS:-/path/to/runs/20260928_124741}

# Where builds, runs and the reference archive go (needs ~2 TB for the 17 h
# reference with hourly restarts and level-1 traces)
export WORKROOT=${WORKROOT:-/scratch/$USER/wrf_gpu_port}
export BUILDROOT=$WORKROOT/builds
export RUNROOT=$WORKROOT/runs
export REFROOT=$WORKROOT/reference

# Slurm settings of your CCR allocation
export SLURM_ACCOUNT=${SLURM_ACCOUNT:-your_account}
export SLURM_PARTITION_CPU=${SLURM_PARTITION_CPU:-general-compute}
export SLURM_QOS_CPU=${SLURM_QOS_CPU:-general-compute}
export SLURM_PARTITION_GPU=${SLURM_PARTITION_GPU:-gpu}
export SLURM_QOS_GPU=${SLURM_QOS_GPU:-}
export CORES_PER_NODE=${CORES_PER_NODE:-56}

# MPI launch inside the image: runs within one node use the image's mpirun
# (see port/container/README.md for multi-node runs)
export MPIRUN=${MPIRUN:-mpirun}
