#!/bin/bash
#SBATCH --job-name=tb-preflight-rd
#SBATCH --partition=cpu
#SBATCH --cpus-per-task=32
#SBATCH --mem=32G
#SBATCH --time=01:00:00
#SBATCH --output=/home/kameshk/workspace/transientbrokerage-fork/slurm_logs/preflight_rd_%j.out
#SBATCH --error=/home/kameshk/workspace/transientbrokerage-fork/slurm_logs/preflight_rd_%j.err

set -euo pipefail
source /etc/profile.d/modules.sh 2>/dev/null || true
module load julia/1.11.3
unset OMP_NUM_THREADS

cd /home/kameshk/workspace/transientbrokerage-fork

echo "=== host: $(hostname)  date: $(date) ==="
echo "=== julia: $(julia --version)  cpus: ${SLURM_CPUS_PER_TASK:-?} ==="

echo
echo "########## explore_phase_diagram.jl rho_delta --rerun ##########"
time julia --project --threads=auto scripts/explore_phase_diagram.jl rho_delta --rerun

echo
echo "=== done: $(date) ==="
ls -la data/figures/phase_diagram/rho_delta_base_outsourcing.png \
       data/figures/phase_diagram/rho_delta_base_r2_gap.png
