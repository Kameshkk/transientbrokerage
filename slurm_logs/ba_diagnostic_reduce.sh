#!/bin/bash
#SBATCH --job-name=ba-diag-red
#SBATCH --partition=cpu
#SBATCH --nodes=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=8G
#SBATCH --time=00:05:00
#SBATCH --output=/home/kameshk/workspace/transientbrokerage-fork/slurm_logs/ba_diag_red_%j.out
#SBATCH --error=/home/kameshk/workspace/transientbrokerage-fork/slurm_logs/ba_diag_red_%j.err
set -euo pipefail
source /etc/profile.d/modules.sh 2>/dev/null || true
module load julia/1.11.3
unset OMP_NUM_THREADS
cd /home/kameshk/workspace/transientbrokerage-fork
echo "=== $(date) reduce diagnostic ==="
julia --project scripts/run_broker_advantage.jl --stage diagnostic --reduce
echo "=== done $(date) ==="
ls -la data/summaries/broker_advantage/diagnostic_*.csv data/sims/broker_advantage/diagnostic.jld2
