#!/bin/bash
#SBATCH --job-name=ba-pilot
#SBATCH --partition=cpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=32
#SBATCH --mem=32G
#SBATCH --time=01:30:00
#SBATCH --array=0-4
#SBATCH --output=/home/kameshk/workspace/transientbrokerage-fork/slurm_logs/ba_pilot_%A_%a.out
#SBATCH --error=/home/kameshk/workspace/transientbrokerage-fork/slurm_logs/ba_pilot_%A_%a.err

set -euo pipefail
source /etc/profile.d/modules.sh 2>/dev/null || true
module load julia/1.11.3
unset OMP_NUM_THREADS

cd /home/kameshk/workspace/transientbrokerage-fork
echo "=== host: $(hostname)  date: $(date)  task=${SLURM_ARRAY_TASK_ID} ==="
time julia --project --threads=auto scripts/run_broker_advantage.jl \
    --stage pilot --cell-idx "$SLURM_ARRAY_TASK_ID" --rerun
