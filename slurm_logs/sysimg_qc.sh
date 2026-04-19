#!/bin/bash
#SBATCH --job-name=ba-sysimg-qc
#SBATCH --partition=cpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=00:15:00
#SBATCH --output=/home/kameshk/workspace/transientbrokerage-fork/slurm_logs/sysimg_qc_%j.out
#SBATCH --error=/home/kameshk/workspace/transientbrokerage-fork/slurm_logs/sysimg_qc_%j.err

set -euo pipefail
source /etc/profile.d/modules.sh 2>/dev/null || true
module load julia/1.11.3
unset OMP_NUM_THREADS

cd /home/kameshk/workspace/transientbrokerage-fork

echo "=== host: $(hostname)  date: $(date) ==="
echo "=== sysimage mtime: $(stat -c '%y' data/sysimage/sys_ba.so) ==="
echo "=== running quick_diagnostic.jl with -J data/sysimage/sys_ba.so (seed=42) ==="
time julia -J data/sysimage/sys_ba.so --project --threads=auto scripts/quick_diagnostic.jl
echo "=== done: $(date) ==="
