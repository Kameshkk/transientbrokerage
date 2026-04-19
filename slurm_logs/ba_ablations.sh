#!/bin/bash
#SBATCH --job-name=ba-abl
#SBATCH --partition=cpu
#SBATCH --nodes=1
#SBATCH --cpus-per-task=32
#SBATCH --mem=32G
#SBATCH --time=01:30:00
#SBATCH --array=0-23
#SBATCH --output=/home/kameshk/workspace/transientbrokerage-fork/slurm_logs/ba_abl_%A_%a.out
#SBATCH --error=/home/kameshk/workspace/transientbrokerage-fork/slurm_logs/ba_abl_%A_%a.err
set -euo pipefail
source /etc/profile.d/modules.sh 2>/dev/null || true
module load julia/1.11.3
unset OMP_NUM_THREADS
cd /home/kameshk/workspace/transientbrokerage-fork
echo "=== host: $(hostname)  date: $(date)  task=${SLURM_ARRAY_TASK_ID} ==="
time julia -J data/sysimage/sys_ba.so --project --threads=auto \
    scripts/run_broker_advantage.jl \
    --stage ablation --cell-idx "$SLURM_ARRAY_TASK_ID" --rerun
