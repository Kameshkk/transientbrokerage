#!/bin/bash
#SBATCH --job-name=ba-reduce-lt
#SBATCH --partition=cpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=00:20:00
#SBATCH --output=/home/kameshk/workspace/transientbrokerage-fork/slurm_logs/ba_reduce_lt_%j.out
#SBATCH --error=/home/kameshk/workspace/transientbrokerage-fork/slurm_logs/ba_reduce_lt_%j.err

set -euo pipefail
source /etc/profile.d/modules.sh 2>/dev/null || true
module load julia/1.11.3
unset OMP_NUM_THREADS

cd /home/kameshk/workspace/transientbrokerage-fork

echo "=== host: $(hostname)  date: $(date) ==="
echo "=== reducing sweep learning_turnover ==="
time julia -J data/sysimage/sys_ba.so --project --threads=auto \
    scripts/run_broker_advantage.jl --stage sweep --sweep learning_turnover --reduce
echo "=== done: $(date) ==="
