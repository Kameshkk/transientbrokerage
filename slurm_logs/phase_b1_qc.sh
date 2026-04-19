#!/bin/bash
#SBATCH --job-name=tb-b1-qc
#SBATCH --partition=cpu
#SBATCH --cpus-per-task=32
#SBATCH --mem=32G
#SBATCH --time=00:30:00
#SBATCH --output=/home/kameshk/workspace/transientbrokerage-fork/slurm_logs/phase_b1_qc_%j.out
#SBATCH --error=/home/kameshk/workspace/transientbrokerage-fork/slurm_logs/phase_b1_qc_%j.err

set -euo pipefail
source /etc/profile.d/modules.sh 2>/dev/null || true
module load julia/1.11.3
unset OMP_NUM_THREADS

cd /home/kameshk/workspace/transientbrokerage-fork

echo "=== host: $(hostname)  date: $(date) ==="
echo
echo "########## quick_diagnostic.jl (must match pre-B1 numbers on seed=42) ##########"
time julia --project --threads=auto scripts/quick_diagnostic.jl
echo "=== done: $(date) ==="
