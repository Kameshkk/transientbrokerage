#!/bin/bash
#SBATCH --job-name=ba-sanity
#SBATCH --partition=cpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=32
#SBATCH --mem=32G
#SBATCH --time=01:30:00
#SBATCH --output=/home/kameshk/workspace/transientbrokerage-fork/slurm_logs/ba_sanity_%j.out
#SBATCH --error=/home/kameshk/workspace/transientbrokerage-fork/slurm_logs/ba_sanity_%j.err

set -euo pipefail
source /etc/profile.d/modules.sh 2>/dev/null || true
module load julia/1.11.3
unset OMP_NUM_THREADS

cd /home/kameshk/workspace/transientbrokerage-fork

echo "=== host: $(hostname)  date: $(date) ==="
echo "=== julia: $(julia --version)  cpus: ${SLURM_CPUS_PER_TASK:-?} ==="

echo
echo "########## Stage 1 sanity: all 7 cells ##########"
time julia --project --threads=auto scripts/run_broker_advantage.jl --stage sanity --rerun

echo
echo "########## reduce ##########"
julia --project scripts/run_broker_advantage.jl --stage sanity --reduce

echo
echo "=== done: $(date) ==="
ls -la data/sims/broker_advantage/sanity.jld2 \
       data/summaries/broker_advantage/sanity_cell_summaries.csv \
       data/summaries/broker_advantage/sanity_regime_labels.csv
