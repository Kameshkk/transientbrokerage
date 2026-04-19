#!/bin/bash
#SBATCH --job-name=tb-preflight
#SBATCH --partition=cpu
#SBATCH --cpus-per-task=32
#SBATCH --mem=32G
#SBATCH --time=02:00:00
#SBATCH --output=/home/kameshk/workspace/transientbrokerage-fork/slurm_logs/preflight_%j.out
#SBATCH --error=/home/kameshk/workspace/transientbrokerage-fork/slurm_logs/preflight_%j.err

set -euo pipefail
source /etc/profile.d/modules.sh 2>/dev/null || true
module load julia/1.11.3
unset OMP_NUM_THREADS

cd /home/kameshk/workspace/transientbrokerage-fork

echo "=== host: $(hostname)  date: $(date) ==="
echo "=== julia: $(julia --version) ==="
echo "=== cpus: ${SLURM_CPUS_PER_TASK:-?}  mem: ${SLURM_MEM_PER_NODE:-?} ==="

echo
echo "########## 1/3 quick_diagnostic.jl ##########"
time julia --project --threads=auto scripts/quick_diagnostic.jl

echo
echo "########## 2/3 explore_base_model.jl --baseline ##########"
time julia --project --threads=auto scripts/explore_base_model.jl --baseline

echo
echo "########## 3/3 explore_phase_diagram.jl rho_delta ##########"
time julia --project --threads=auto scripts/explore_phase_diagram.jl rho_delta

echo
echo "=== preflight complete: $(date) ==="
ls -la data/figures/quick_diagnostic.png \
       data/figures/exploration/baseline_dynamics.png \
       data/figures/exploration/baseline_network_stats.png \
       data/figures/phase_diagram/rho_delta_base_outsourcing.png \
       data/figures/phase_diagram/rho_delta_base_r2_gap.png
