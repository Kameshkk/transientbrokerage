#!/bin/bash
#SBATCH --job-name=ba-sysimg
#SBATCH --partition=cpu
#SBATCH --qos=short
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=16G
#SBATCH --time=00:45:00
#SBATCH --output=/home/kameshk/workspace/transientbrokerage-fork/slurm_logs/ba_sysimg_%j.out
#SBATCH --error=/home/kameshk/workspace/transientbrokerage-fork/slurm_logs/ba_sysimg_%j.err

set -euo pipefail
source /etc/profile.d/modules.sh 2>/dev/null || true
module load julia/1.11.3
unset OMP_NUM_THREADS

cd /home/kameshk/workspace/transientbrokerage-fork

echo "=== host: $(hostname)  date: $(date) ==="
echo "=== julia: $(julia --version) ==="

time julia --project=sysimage sysimage/build_sysimage.jl

echo
echo "=== verify load speed with sysimage ==="
time julia -J data/sysimage/sys_ba.so --project -e '
  using TransientBrokerage
  state, df = run_simulation(default_params(T=5, T_burn=0, network_measure_interval=5, N=80, d=4, s=4, k=4, E_init=10))
  println("sysimage OK; df rows=", size(df, 1), ", cols=", length(propertynames(df)))
'
echo "=== done: $(date) ==="
ls -la data/sysimage/sys_ba.so
