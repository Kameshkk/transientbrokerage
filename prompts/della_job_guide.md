# Della Job Guide: Broker-Advantage Study Handoff

This file is a self-contained handoff for a fresh Claude Code session on the Princeton della cluster. It captures the user's instructions, the environment, the progress made so far, and the remaining work. Read it end-to-end before touching anything. Cross-reference with `prompts/BROKER_ADVANTAGE_*.md` for full analysis/instrumentation/plotting details; this guide does **not** restate those specs.

---

## 0. Operating rules (from CLAUDE.md)

These override any default behavior and must be followed:

- **NEVER fabricate, interpolate, or make up data.** If a computation fails or data is missing, report the gap explicitly.
- **NEVER make assumptions without stating them explicitly.** If a parameter is ambiguous, ask the user.
- **Every claim in a report must be verifiable from a specific table cell or figure.** No overclaiming.

## 1. The task

Execute the broker-advantage study defined across these four spec files in `prompts/`:

- `BROKER_ADVANTAGE_AGENT_RUNBOOK.md` — the runbook to execute (stages, acceptance criteria, outputs).
- `BROKER_ADVANTAGE_ANALYSIS_SPEC.md` — outcome definitions, regime classification, sweeps, ablations.
- `BROKER_ADVANTAGE_INSTRUMENTATION_SPEC.md` — new params, metrics, paired-RNG, ablation toggles, storage schema.
- `BROKER_ADVANTAGE_PLOTTING_SPEC.md` — figure inventory and per-figure panel specs.

Only the **base model** is in scope (not the capture / principal variant).

Also read once: `PLOTS.md` (existing figure inventory + conventions), `src/parameters.jl`, `src/simulation.jl`, `src/step.jl`, `src/types.jl`, `src/matching.jl`, `src/matching_function.jl`. These are the files new instrumentation will touch.

## 2. User instructions and answers (verbatim context)

The user's original request:

> I am on a slurm cluster login node and julia is loaded as a module using module load. I want julia 1.12.1. I want you to thoroughly go over the repo and execute the steps in prompts/BROKER_ADVANTAGE_AGENT_RUNBOOK.md and the associated markdowns in that directory. You will first need to install julia packaged required and compile them. Next I want you to tell me your plan for running the instructions, and where you will save the plots and the data. Each job should not take more than 10 minutes so you can request that to get an allocation quickly.

After clarifying questions were asked, the user answered:

1. **Julia version**: `julia 1.11.X` is acceptable (prior session used `module load julia/1.11.3`). Do not force 1.12.1.
2. **Shared filesystem**: home directory (`$HOME`, NFS autofs) is shared across login and compute nodes — verified by running a compute-node `srun` that saw `~/workspace/transientbrokerage-fork` and `~/.julia`.
3. **Partition / resources**: `cpu` partition. Choose core count as needed. **32 GB memory** is more than enough per job.
4. **Job runtime**: the original "10 minutes per job" guidance was a guess — multi-hour jobs are fine. Request what is actually needed.
5. **Verification discipline**: "check every step of the implementation. Ideally have an agent on a tmux monitor this and you should evaluate the results but you can decide the best way. There should be no bugs and every run that is submitted should be constantly monitored and if there's a bug or issue the agent should iteratively debug and fix it." — i.e., monitor every slurm job, fix any bug before proceeding, do not silently skip failures.
6. **Seeds per cell**: `15` for main sweeps.
7. **Additive edits**: "small additive edits" to existing scripts are fine — do not rewrite; preserve existing behavior.

## 3. Environment (verified at handoff time)

- **Login node example**: varies; use `hostname` to check.
- **Compute node verified**: `della-r3c1n15` saw `~/workspace/transientbrokerage-fork/Project.toml` and `~/.julia` — shared FS confirmed.
- **Julia**: `module load julia/1.11.3` via `bash -l -c`. Path: `/usr/licensed/julia/1.11.3/bin/julia`. In non-interactive shells, `module` is not auto-available — either run `source /etc/profile.d/modules.sh` or use `bash -l -c '...'`.
- **Project.toml compat**: declares `julia = "1.11"`. Already instantiated successfully against 1.11.3; no compat bump needed.
- **Depot**: default `~/.julia` (NFS home — shared with compute nodes).
- **Scratch**: `/scratch` is **node-local**, do not use for shared data.
- **Projects**: `/projects` is NFS-shared but we are not using it.
- **OMP_NUM_THREADS**: unset on login node; this triggers benign `libgomp: Invalid value for environment variable OMP_NUM_THREADS` warnings during precompile. Workaround in sbatch scripts: `unset OMP_NUM_THREADS`.

**Working directory for all commands**: `/home/kameshk/workspace/transientbrokerage-fork`.

**Git state at handoff**: branch `KK-testing-branch`. Head commit `fee29d3 Expand PLOTS.md with per-panel x/y axes and --baseline walkthrough`. Pre-handoff edits: two `global` keywords added in `scripts/explore_phase_diagram.jl` (see Progress §5).

## 4. Slurm conventions established

All sbatch scripts live in `slurm_logs/`. Template:

```bash
#!/bin/bash
#SBATCH --job-name=tb-<purpose>
#SBATCH --partition=cpu
#SBATCH --cpus-per-task=32
#SBATCH --mem=32G
#SBATCH --time=<HH:MM:SS>
#SBATCH --output=/home/kameshk/workspace/transientbrokerage-fork/slurm_logs/<purpose>_%j.out
#SBATCH --error=/home/kameshk/workspace/transientbrokerage-fork/slurm_logs/<purpose>_%j.err

set -euo pipefail
source /etc/profile.d/modules.sh 2>/dev/null || true
module load julia/1.11.3
unset OMP_NUM_THREADS

cd /home/kameshk/workspace/transientbrokerage-fork
# ... commands ...
```

**Monitoring pattern**: after `sbatch`, use the Monitor tool tailing the `.out` and `.err` files with a grep filter that catches both progress milestones and error signatures (e.g. `ERROR|UndefVar|MethodError|Traceback|Failed|^real\s+|^Saved:`). The filter must cover failure cases — silence-on-crash hides real problems.

## 5. Progress made (what is done, what is observed)

### 5.1 Environment setup — DONE

- `module load julia/1.11.3` works; shared FS to compute nodes verified.
- `Pkg.instantiate()` + `Pkg.precompile()` finished in 5m02s (exit 0) against a fresh resolve (no prior Manifest.toml). A `Manifest.toml` is now present in the repo root from this resolve.
- Smoke test: `using TransientBrokerage; run_simulation(default_params(T=5, T_burn=0, network_measure_interval=5))` returns a 5-row DataFrame in 12s (mostly TTFX).

### 5.2 Preflight — 2/3 PASSED, 3/3 FIXED-AND-RESUBMITTED

Submitted as a single sbatch job `7139142` on `della-h16n15` with 32 cpus / 32 GB.

**1/3 `scripts/quick_diagnostic.jl`** — PASSED in `1m14.570s` (real). Output figure `data/figures/quick_diagnostic.png` created. Summary (last 50 periods) on seed=42:
- outsourcing_rate 0.266
- broker_holdout_r2 0.468, agent_holdout_r2 0.041, r2_gap 0.426
- betweenness 0.2766
- q_self_mean 1.604, q_broker_standard_mean 1.473
- broker_access_size 380, roster_size 200, broker_history_size 105951
- total matches/period 2084

**2/3 `scripts/explore_base_model.jl --baseline`** — PASSED in `5m15.250s` (real). Figures created:
- `data/figures/exploration/baseline_dynamics.png`
- `data/figures/exploration/baseline_network_stats.png`
- `data/figures/exploration/baseline_matrix.png`
- `data/figures/exploration/baseline_svd.png`

Cache: `data/sims/exploration/baseline.jld2`. Pooled last-50 summary: outsourcing 0.298, broker R² 0.292, agent R² -0.128, r2_gap 0.421, betweenness 0.301.

**3/3 `scripts/explore_phase_diagram.jl rho_delta`** — INITIALLY FAILED (exit after 10s) with `UndefVarError: cell not defined in local scope`. Root cause is a **pre-existing Julia 1.11 soft-scope issue** in the script:

- Line 37: `sweep_type = :rho_s` (top-level).
- Line 38–45: `for a in ARGS` loop reassigns `sweep_type = Symbol(a)`. Julia 1.11 treats this as a new local, so the CLI arg never updates the global; the script ran `rho_s` instead of `rho_delta`, as confirmed by the log line `Phase diagram: rho_s (28 cells, …)`.
- Line 149: `cell = 0` (top-level).
- Line 150–176: combined `for (j, yv) …, (i, rho) …` loop does `cell += 1`. Same soft-scope trap — the `+=` reads a local that has not been defined.

**Fix applied** (additive edits, authorized by user):
- `scripts/explore_phase_diagram.jl:41` — `sweep_type = Symbol(a)` → `global sweep_type = Symbol(a)`.
- `scripts/explore_phase_diagram.jl:151` — `cell += 1` → `global cell += 1`.

**Resubmitted as job `7139386`** (sbatch script `slurm_logs/preflight_rho_delta.sh`, same 32 cpu / 32 GB / 1h). Monitor is tailing `slurm_logs/preflight_rd_7139386.{out,err}`. Expected outputs on success:
- `data/figures/phase_diagram/rho_delta_base_outsourcing.png`
- `data/figures/phase_diagram/rho_delta_base_r2_gap.png`
- plus other `rho_delta_base_*.png` heatmaps
- cache `data/sims/phase_diagram/rho_delta.jld2`

### 5.3 Files modified so far

- `scripts/explore_phase_diagram.jl` — two `global` keywords added (lines 41 and 151). No behavior change on Julia < 1.11; fixes the 1.11 soft-scope bug.

No `src/*.jl` changes yet. No new scripts yet. No instrumentation yet.

### 5.4 Files and directories created so far

- `Manifest.toml` (from `Pkg.instantiate`)
- `slurm_logs/preflight.sh`, `slurm_logs/preflight_rho_delta.sh`, `slurm_logs/preflight_7139142.{out,err}`, `slurm_logs/preflight_rd_7139386.{out,err}` (latter growing).
- Preflight output figures and JLD2 caches listed above.

### 5.5 Still-running jobs at handoff

- Job `7139386` (preflight rho_delta rerun) — verify via `squeue -j 7139386` and tail the log file. If it has completed, both figures should exist; if not, keep the monitor armed.

## 6. Task list (created earlier, still the plan)

1. **Phase A — env + preflight** (in_progress; finishes when 7139386 passes).
2. **Phase B1 — fee/cost split params**: add `broker_fee_rate`, `self_search_cost_rate` to `ModelParams` / `default_params`, defaulting to `search_cost_rate` for backward compat. Modify `calibrate()` in `src/matching_function.jl` to use the split rates. Verify `scripts/quick_diagnostic.jl` output is unchanged when new params are omitted.
3. **Phase B2 — new per-period metrics**: self/broker demand/fill counts, `q_*_per_demand_slot`, `net_*`, decomposition components, welfare period/cum, pre-match `edge_pre` / `prior_pair_history_pre` flags classified into access/assessment. Write `data/summaries/broker_advantage/instrumentation_qc.txt` with accounting-identity checks.
4. **Phase B3 — paired RNG + ablation modes**: add separate RNG streams (init/market/strategy/learning) so treatment and no-broker control share init+market shocks. Add `ablation::Symbol` enum on params or a dedicated field; implement `:NoBroker`, `:NoRegime`, `:BlindBroker`, `:EqualCapacityBroker`, `:NoAccessBroker`, `:FrozenGraph`, `:NoTurnover`, `:FreezeBrokerLearning`.
5. **Phase C1 — new scripts**: `scripts/run_broker_advantage.jl` and `scripts/plot_broker_advantage.jl`, following the `scripts/explore_*.jl` style (CLI flags, JLD2 cache, `--rerun`, CSV summaries).
6. **Phase C2 — sanity (Stage 1) + pilot (Stage 2)**: run the 7 sanity corners from the runbook and the 5 pilot cells (δ×ρ ∈ {(0,0),(0,1),(0.75,0),(0.75,1),(0.5,0.5)}) with N=300, d=6, T=120, T_burn=20, seeds=10, treatment+no-broker counterfactual, `network_measure_interval=5`. Gate on runbook acceptance criteria before proceeding.
7. **Phase C3 — 4 main sweeps**: `delta_rho`, `fee_cost`, `transparency_access`, `learning_turnover` at N=300/d=6/T=120/T_burn=20, **seeds=15** (per user), treatment+control. Produce per-sweep `*_cell_summaries.csv`, `*_regime_labels.csv`, `*_phase_panels.pdf`, `regime_map_*.pdf`, plus threshold-robustness maps for delta_rho and fee_cost.
8. **Phase C4 — ablations**: 8 ablations × 2–4 anchor cells (baseline anchor δ=0.5 ρ=0.5 plus sweep-selected anchors), 15 seeds. Outputs `ablation_bars.pdf`, `ablation_temporal_selected.pdf`.
9. **Phase C5 — full-model confirmation**: N=1000, d=8, T=200, T_burn=30, h_a=16, h_b=32, `network_measure_interval=20`, seeds=15 (minimum; 30 preferred if runtime allows), fresh seed block, ~5 selected cells. Output `full_confirm_comparison.pdf`. Flag any classification flips vs simplified sweeps.

## 7. Required final figure set (runbook §13 + plotting spec §17)

Under `data/figures/broker_advantage/`:
- `sanity_diagnostics.pdf`, `pilot_phase_panels.pdf`, `pilot_temporal_overlay.pdf`
- `delta_rho_phase_panels.pdf`, `fee_cost_phase_panels.pdf`, `transparency_access_phase_panels.pdf`, `learning_turnover_phase_panels.pdf`
- `regime_map_delta_rho.pdf`, `regime_map_fee_cost.pdf`, `regime_map_transparency_access.pdf`, `regime_map_learning_turnover.pdf`
- `regime_map_delta_rho_threshold_broker030.pdf`, `regime_map_delta_rho_threshold_broker070.pdf`, `regime_map_fee_cost_threshold_broker030.pdf`, `regime_map_fee_cost_threshold_broker070.pdf`
- `temporal_cases_overlay.pdf`
- `advantage_dynamics_broker_dominant.pdf`, `advantage_dynamics_self_search.pdf`
- `phase_portraits_broker_dominant.pdf`, `phase_portraits_self_search.pdf`
- `fee_sensitivity_curves.pdf`
- `ablation_bars.pdf`, `ablation_temporal_selected.pdf`
- `full_confirm_comparison.pdf`

Storage:
- Sims cache: `data/sims/broker_advantage/*.jld2`
- Summaries: `data/summaries/broker_advantage/*.csv` + `instrumentation_qc.txt` + `final_run_notes.md` (and `missing_plots.md` if anything is unrenderable)

## 8. Invariants and preservation requirements

From the runbook and instrumentation spec:

- These existing commands must still work unchanged:
  - `julia --project --threads=auto scripts/quick_diagnostic.jl`
  - `julia --project --threads=auto scripts/explore_base_model.jl --baseline`
  - `julia --project --threads=auto scripts/explore_phase_diagram.jl rho_delta`
- These metric names must NOT be renamed: `outsourcing_rate`, `broker_holdout_r2`, `agent_holdout_r2`, `r2_gap`, `broker_holdout_rank`, `agent_holdout_rank`, `rank_gap`, `betweenness`, `q_self_mean`, `q_broker_standard_mean`, `n_self_matches`, `n_broker_standard`, `broker_access_size`, `roster_size`, `broker_history_size`. Add new columns; do not remove old ones.
- Default-params behavior for `scripts/quick_diagnostic.jl` must be byte-identical when `broker_fee_rate`/`self_search_cost_rate` are omitted. This is the test for Phase B1.

## 9. Concrete code-location map for instrumentation

- **Params**: `src/types.jl` lines 438–481 (`ModelParams` struct); `src/parameters.jl` (`default_params`, `validate_params`). Add fields at the tail of the struct + matching entries in `default_params` defaults dict + constructor call.
- **Calibration (phi, c_s)**: `src/matching_function.jl` lines 231–232 — replace `params.search_cost_rate` with `params.broker_fee_rate` / `params.self_search_cost_rate` (with fallback to `search_cost_rate` for backward compat). The `CalibrationConstants` struct `{q_cal, r, phi, c_s}` already separates them.
- **Demand counters**: `src/step.jl` lines 108–137 (demand generation). `state.accum.outsourced_slots`, `state.accum.total_demand` already exist — `self_demand_slots = total_demand - outsourced_slots`; `broker_demand_slots = outsourced_slots`. Add explicit fields to avoid re-deriving in every plot.
- **Fill counters**: `src/simulation.jl` `collect_period_metrics` — `self_filled_slots := a.n_self_matches`, `broker_filled_slots := a.n_broker_standard`.
- **Pre-match flags**: `src/matching.jl` lines 286–290 push `wc_i/wc_j` when `has_edge(G, pm.demander_id, pm.counterparty_id)`. To also record `prior_pair_history_pre`, check `agents[pm.demander_id].partner_count[pm.counterparty_id] > 0` at the same point, before `finalize_accepted_proposal!` mutates it. Add new workspace vectors mirroring `was_connected_i`/`was_connected_j`.
- **Welfare**: in `src/matching.jl` `update_satisfaction!` (lines 426–485), the self/broker per-agent net values already exist (`tilde_q = total_q / d_i - cal.c_s` for self; `(total_q - phi*broker_standard_count) / d_i` for broker). Aggregate across agents for a period-level welfare field, then running-sum into `welfare_agents_cum`. Keep broker revenue separate: `welfare_broker_period = phi * broker_filled_slots`.
- **Ablations**: add `ablation::Symbol` (or a dedicated struct on `ModelState`). In `src/step.jl`:
  - `:NoBroker` → after `outsourcing_decision`, force `channel = :self`.
  - `:NoRegime` → set `env.delta = 0` at init (cleanest) or equivalently at `ModelParams` construction time.
  - `:BlindBroker` / `:EqualCapacityBroker` → `src/learning.jl` + `src/initialization.jl` (broker NN input and width).
  - `:NoAccessBroker` → `src/search.jl` broker pref preparation: filter `rid` by `has_edge(G, did, rid)`.
  - `:FrozenGraph` → gate `add_match_edge!` in `src/matching.jl:finalize_accepted_proposal!`.
  - `:NoTurnover` → set `eta = 0` at init.
  - `:FreezeBrokerLearning` → skip `train_broker_nn!` after burn-in.
- **Paired RNG**: `src/initialization.jl:101` currently does `rng = StableRNG(params.seed)`. Replace with a bundle of named streams (init, market, strategy, learning) derived from seed via e.g. `StableRNG(hash((params.seed, :init)))`. Pass the right stream into each call site. Initial implementation can use 4 named streams; the tightest design pre-generates all market shocks from the market stream and replays them in treatment + control.

Read the three Broker-Advantage spec files for the canonical definitions before writing any of this.

## 10. Where to save what

- **Simulation caches**: `data/sims/broker_advantage/{sanity,pilot_delta_rho,delta_rho,fee_cost,transparency_access,learning_turnover,ablations,full_confirm}.jld2`. Each should include `metrics_by_run`, `metadata`, `paired_summaries`, `cell_summaries`, `regime_labels`, `script_version_info`.
- **CSV summaries**: `data/summaries/broker_advantage/<stage_or_sweep>_{run_metadata,paired_summaries,cell_summaries,regime_labels}.csv`.
- **QC / notes**: `data/summaries/broker_advantage/{instrumentation_qc.txt,final_run_notes.md,missing_plots.md}`.
- **Figures**: `data/figures/broker_advantage/` (full list in §7).
- **Slurm scripts**: `slurm_logs/<purpose>.sh` with matching `<purpose>_<jobid>.{out,err}`.

Do not overwrite existing `data/figures/{quick_diagnostic.png, exploration/, phase_diagram/}` outputs.

## 11. Data integrity and verification

Three layers of checks ensure the simulation data are sensible before any plot or claim depends on them. These are mandatory — never skip them. They are also what lets subagents independently confirm that results are real and not the product of a silent bug.

### 11.1 Layer 1: automatic identity checks inside `run_broker_advantage.jl`

On every run, compute and assert:

- `pi_broker_slot = broker_demand_slots / total_demand_slots` (NaN when denominator is 0).
- `self_fill_rate = self_filled_slots / self_demand_slots` (NaN when denominator is 0).
- `broker_fill_rate = broker_filled_slots / broker_demand_slots` (NaN when denominator is 0).
- `fill_rate_gap = broker_fill_rate - self_fill_rate`.
- `net_value_gap ≈ quality_selection_component + fill_access_component + fee_cost_component` — residual must be at floating-point tolerance (absolute < 1e-10 or relative < 1e-8). Print the max residual per run.
- `welfare_agents_cum[t] = Σ welfare_agents_period[1..t]` and `welfare_broker_cum[t] = Σ welfare_broker_period[1..t]`.
- Access/assessment flags computed **before** `finalize_accepted_proposal!` mutates the edge or `partner_count`. Enforced by where the flags are read (new workspace vectors populated alongside `was_connected_i`/`was_connected_j` at `src/matching.jl:286–290`).
- Self-search cost charged only on self-demanded slots; broker fee charged only on successful brokered placements. Checked by recomputing period agent welfare from raw match outcomes and comparing to the live counter.
- Every existing metric column name from the locked list in runbook §1.3 (see §8 of this guide) is still present and unrenamed. Checked by a column-name assertion at the end of each run against a constant list.

Identity failures abort the run with an explicit message. Never silently continue.

After Phase B3, write a single-run QC file:

```
data/summaries/broker_advantage/instrumentation_qc.txt
```

with the identity residuals and a pass/fail summary for each check.

### 11.2 Layer 2: stage-specific acceptance criteria

Each stage gates the next. If a stage's criteria fail, stop and debug before launching the next stage.

- **Stage 1 sanity** (runbook §8). 7 expected-sign tests written to `data/summaries/broker_advantage/sanity_summary.csv`:
  - NoRegime (`delta=0`) → `rank_gap` and `r2_gap` shrink.
  - EasyQuality (`rho=1`) → broker information advantage weakens.
  - HardPairwise (`delta=0.75`, `rho∈{0.25, 0.0}`) → positive `rank_gap`.
  - HighTransparency (high `n_strangers`, high `k`) → broker share falls.
  - LowRosterAccess (low `alpha_R`) → broker fill/adoption fall.
  - HighFee (high `broker_fee_rate`) → broker share or net value falls.
  - FreezeBrokerLearning → broker prediction advantage collapses or weakens materially.

  Any failing sign → stop; do not run main sweeps until the implementation is fixed.

- **Stage 2 pilot** (runbook §9). 5 criteria:
  - `rank_gap` positive in at least one high-δ / low-ρ cell.
  - `rank_gap` near zero in the no-regime or pure-quality anchor.
  - Paired `delta_welfare_agents` has smaller seed SD than raw `welfare_agents_treatment` (compute both and compare).
  - No severe missingness from zero denominators or variance gates.
  - Temporal broker share not dominated by unexplained period-to-period oscillation. If severe, run a documented sensitivity at `omega=0.1` — do not silently change the baseline value.

- **Stage 3 sweeps**. Cell-level CI sanity:
  - No cell with >50% NaN rows across seeds for headline metrics.
  - All fill rates and `pi_broker_slot` ∈ `[0, 1]` or `missing`.
  - `share_positive + share_negative ≤ 1` per cell.
  - Each sweep's predicted direction holds where theory is explicit (e.g., `fee_cost`: higher `broker_fee_rate` should not raise `pi_broker_slot` at fixed `self_search_cost_rate`).

- **Stage 4 full_confirm**. Write `full_confirm_summary.csv` with a side-by-side classification table (simplified vs. full). Every cell whose regime label differs between the two scales is listed in `data/summaries/broker_advantage/final_run_notes.md` with either an explanation or an "open question" marker.

### 11.3 Layer 3: independent subagent verification pass at each gate

At the end of each stage, spawn an Explore-type subagent (read-only) to verify the data independently of the script that produced them. The subagent's prompt should contain:

- The cache path (JLD2) and the summary CSV paths for the stage.
- The relevant spec section, pasted verbatim (not just a pointer).
- A specific task list:
  1. Load the JLD2 with `JLD2.load` and confirm all declared objects exist: `metrics_by_run`, `metadata`, `paired_summaries`, `cell_summaries`, `regime_labels`, `script_version_info`.
  2. Recompute the identity residuals from §11.1 on a sample of runs. Report the max absolute residual and any run_id whose residual exceeds tolerance.
  3. Spot-check value ranges against §11.4.
  4. For sanity: confirm each of the 7 expected-sign tests passes; cite the specific row of `sanity_summary.csv` for each.
  5. For pilot / sweeps: list any cell with >50% missing, any identity residual above tolerance, and any metric outside §11.4 ranges.
  6. Return a PASS / FAIL verdict **with a specific table cell or figure citation** for every claim (matching CLAUDE.md's "every claim must be verifiable from a specific table cell or figure" rule).

The subagent never writes data; it only reads and reports. If it flags a violation, do not advance to the next stage — re-investigate and fix.

### 11.4 Acceptance ranges for headline metrics

Values outside these are bugs. Report them; do not interpret them.

| Metric | Expected range | NaN allowed when |
|---|---|---|
| `pi_broker_slot` | `[0, 1]` | `total_demand_slots == 0` |
| `self_fill_rate`, `broker_fill_rate` | `[0, 1]` | respective `*_demand_slots == 0` |
| `fill_rate_gap` | `[-1, 1]` | either demand zero |
| `outsourcing_rate` (existing) | `[0, 1]` | `total_demand == 0` |
| `broker_holdout_r2`, `agent_holdout_r2` | `(-∞, 1]` (negative valid under misspecification) | variance gate triggered |
| `rank_gap` | `[-2, 2]` | either holdout NaN |
| `access_new_edge_frac_brk`, `assessment_*_frac_brk` | `[0, 1]` | no brokered matches in period |
| `net_value_gap` | bounded by calibration scale — typically `[-2, 2]` at default params | either channel's demand zero |
| `delta_welfare_agents` | paired difference; seed SD should be smaller than `welfare_agents_treatment` seed SD | — |
| identity residual | `abs < 1e-10` or `rel < 1e-8` | never — failure aborts the run |

## 12. Parallelization guidance

- One sbatch job per stage is fine. Within a stage, parallelize across cells × seeds using `Threads.@threads` on a 32-core node. BLAS multi-threading inside training is already set to 1 in the existing hot paths (`src/step.jl:149–156`), so per-thread simulations are thread-safe.
- For **full_confirm** (N=1000, T=200, 15 seeds × ~5 cells × 2 arms ≈ 150 runs), expect each run on the order of 1–3 min based on the 5m15s explore_base_model 5-seed N=1000 T=200 baseline. Plan ≥2h wallclock per sbatch; split by cell if desired.

## 13. Session continuity

The original session ran inside a non-tmux SSH session. To avoid losing state on laptop close, run future Claude Code sessions in tmux:

```bash
tmux new -s tb
claude   # or however you launch claude-code
# detach: Ctrl-b d
# reattach: tmux attach -t tb
```

If a session dies mid-work, any running slurm jobs continue (they are scheduler-managed). The new Claude session can pick up by reading this file, running `squeue -u $USER`, and tailing the existing `slurm_logs/*.out`.

## 14. Lessons learned and gotchas

Concrete mistakes or surprises from earlier sessions. Read this before writing any new code or sbatch script — several of these will bite again otherwise.

### 14.1 Slurm / cluster

- **QOS is auto-assigned from `--time`, NOT from `--qos`.** Della runs a site-wide `job_submit.lua` that maps `--time` to QOS:
  | Time limit | QOS | MaxJobsPU |
  |---|---|---|
  | ≤ 60 min | `test` | **2** |
  | 61–1441 min | `short` | 400 |
  | 1442–4321 min | `medium` | 200 |
  | > 4321 min | `vlong` | 60 |
  The `--qos=short` flag is silently ignored — the lua filter rewrites QOS based on `--time`. To get the 400-job `short` QOS, set `--time` to at least `01:30:00` (anything over 60 min). I learned this the hard way by wasting time on `--qos=short` flags that never stuck.
- **Rule**: every array-task sbatch in this project must use `--time=01:30:00` or more so it auto-maps to `short`. Single-job QCs can stay under 1h at `test`.
- **Check job QOS with** `scontrol show job <id> | grep QOS`. If it says `QOS=test` and you wanted `short`, bump `--time`.
- `module` is not a non-interactive-shell command. In sbatch scripts, always prefix with `source /etc/profile.d/modules.sh 2>/dev/null || true` before `module load julia/1.11.3`.
- **Compute nodes have NO internet.** `Pkg.add(...)` on a compute node fails with `Could not resolve host: github.com` / `pkg.julialang.org`. Always install new packages on the **login node** first (where internet works), then compute-node sbatch scripts can only call `Pkg.instantiate()` against the already-resolved manifest. Saw this when trying to bootstrap PackageCompiler inside an sbatch — it fails immediately.
- **`unset OMP_NUM_THREADS`** in every sbatch — otherwise Julia precompile emits `libgomp: Invalid value for environment variable OMP_NUM_THREADS: invalid` warnings on every module load. Harmless but noisy.
- **NFS home is shared with compute nodes; `/scratch` is node-local.** Install Julia packages under `~/.julia`. Never stage data under `/scratch` expecting another node to see it.
- **Array + reduce dependency pattern** works cleanly: `sbatch --dependency=afterok:$ARRAY_JOBID reduce.sh`.
- **Use `reportseff <jobid>` and `shistory -j <jobid>`** for post-run diagnostics on array tasks (Princeton KB recommendation).
- **`scontrol show job <id>` + `sstat -j <id>`** during run to see node, runtime, CPU state. `sstat` returns empty for very fresh jobs (stats take ~30 s to propagate).

### 14.2 Julia 1.11 soft-scope

- **Top-level `for` loops that reassign a previously-assigned top-level binding are treated as new locals in Julia 1.11.** Symptoms include `UndefVarError: <var> not defined in local scope` on a `+=` and `@warn Assignment to <var> in soft scope is ambiguous`. Fix: prefix the assignment with `global`.
  - Hit twice: once in `scripts/explore_phase_diagram.jl` (`cell += 1`, `sweep_type = Symbol(a)`), once in a one-liner test harness (`max_resid = max(...)` in a for loop).
  - Silent variant: `sweep_type = Symbol(a)` in the arg-parse loop was treated as a local, so the CLI arg `rho_delta` was silently ignored and the script ran the default `rho_s`.
- **Wrap multi-step test scripts in a function** to sidestep soft scope. `function run_checks() ... end; run_checks()`.

### 14.3 Julia gotchas

- **Escaped quotes inside `$(...)` interpolation do not parse.** `error("prefix $(join(xs, \"; \"))")` → `ParseError: not a unary operator`. Hoist: `msg = join(xs, "; "); error("prefix $msg")`.
- **`using Printf: @sprintf` does NOT bring in `@printf`.** Must name each macro: `using Printf: @sprintf, @printf`.
- **`names(df, Symbol)` is wrong in DataFrames ≥1.8.** Use `propertynames(df)` to get column symbols.
- **`rand(rng) < 0.5 ? :self : :broker`** in `outsourcing_decision` only runs when both scores are equal. For paired treatment vs. `:NoBroker` control, RNG consumption matches up to that branch (and the tie is rare), but downstream `match_output!` noise draws diverge once the broker actually matches. Documented limitation per `BROKER_ADVANTAGE_INSTRUMENTATION_SPEC.md §5`.

### 14.4 Output buffering

- **Julia's `println` is block-buffered when stdout is a file** (as in sbatch). A 5-minute job with per-cell progress prints shows nothing until it exits. Fix: call `flush(stdout)` after each progress line you want to see live, or route progress to `stderr` which is unbuffered.
- **Your monitor filter must cover failure cases**, not just success markers. A `grep "^Saved:"` filter goes silent on a crash looking exactly like "still running." Always include `ERROR|^Error|Failed|UndefVar|MethodError|Traceback`.

### 14.5 Instrumentation design

- **`ModelParams` is an immutable positional struct.** Adding new fields by appending to the END of the struct preserves every existing positional call site. Inserting in the middle breaks the `default_params` constructor silently (wrong field gets the wrong value).
- **Backward-compatible defaults via `nothing` sentinel**: `defaults[:broker_fee_rate] => nothing`, then after kwargs `broker_fee_rate = isnothing(defaults[:broker_fee_rate]) ? defaults[:search_cost_rate] : Float64(defaults[:broker_fee_rate])`. This lets users override or inherit without breaking existing scripts.
- **Always add the `validate_params` assert** for new params — otherwise silent out-of-range bugs.
- **Per-period metrics go in `PeriodAccumulators`** (reset every step), derived metrics in `collect_period_metrics` (return NamedTuple row). Adding new columns at the end of the return NamedTuple is safe; inserting in the middle is also safe (named), but don't rename or remove existing columns.

### 14.6 Runbook-vs-reality

- **Sanity expected-sign failures can be finite-sample artifacts, not bugs.** The spec's sanity theses assume large-N asymptotics. At N=300/T=120 simplified scale, two theses failed (EasyQuality did not weaken the broker advantage; NoRegime r2_gap grew rather than shrank). Before concluding the model is broken, verify the preflight baseline still matches pre-instrumentation byte-for-byte on seed=42 — if so, the instrumentation is sound and the finding is a real simplified-scale effect.
- **When in doubt, escalate to the user with a table** of observed-vs-expected signs and concrete options, rather than silently pushing on. The data-integrity rule ("never fabricate, never overclaim") means documenting ambiguity, not papering over it.

### 14.7 Tooling

- **WebFetch on `researchcomputing.princeton.edu`** returns 403 from the cluster (bot detection). Use `WebSearch` to get indexed summaries, or ask the user to paste the page.
- **Cron `/loop 2m`** reporting works well while long jobs run; set it once and you get free situation reports. Same cron job can drive both "poll the queue" and "trigger the user's attention when a blocking decision is needed."
- **Use `Monitor` with a `persistent` flag for long tails** and explicit failure grep — otherwise the monitor times out at 30–60 min even if the job is still alive.

## 15. State at handoff (2026-04-19 late evening)

This subsumes the earlier §5 progress snapshot, which reflected only Phases A–B. The latest state is:

### 15.1 Phases completed
- **Phase A — preflight**: done. All three baseline scripts produce the expected figures at default seed=42.
- **Phase B1 — fee/cost split**: done. `broker_fee_rate`, `self_search_cost_rate` in `ModelParams`. Default-mode byte-compat verified on seed=42.
- **Phase B2 — new per-period metrics**: done. 29+ columns added to `collect_period_metrics` return NamedTuple. Identity checks pass.
- **Phase B3 — ablation modes**: done. Six ablations plus `:none`. `alpha_R` param added.
- **Phase C1 — `run_broker_advantage.jl` + reducer**: done. Stages `sanity`, `pilot`, `sweep`, `ablation`, `full_confirm`, `diagnostic`, `diagnostic_blind`. `--cell-idx` for slurm array dispatch. `--reduce` stitches per-cell JLD2 into stage-level CSVs + JLD2.
- **Phase C2 — sanity + pilot**: sanity ran (5/7 spec signs pass, 2 understood via Phase C2c). Pilot ran and reduced. Acceptance criteria: 4/5 pass; criterion 2 fails strictly for the same reason as sanity and is now explained.
- **Phase C2b — full-scale diagnostic at N=1000**: done. Default, NoRegime, EasyQuality, HardPairwise × 5 seeds. Summary CSV at `data/summaries/broker_advantage/diagnostic_cell_summaries.csv`.
- **Phase C2c — BlindBroker + two-way residualized metrics**: done. `:BlindBroker` ablation implemented (zero-x_i mask on broker NN inputs at prediction and training). Pooled, within-agent demeaned, and two-way residualized holdout $R^2$/rank metrics added. Residualized metrics gated to NaN when pair-specific variance is below `max(σ_ε²·n_p/6, 10⁻⁸)·n_p` AND below `10⁻⁶·Var(Q)`.
- **Additional B-phase add-ons (2026-04-19 late)**: fill-failure reason buckets (`broker_unfilled_slots`, `broker_unfilled_pref_exhausted`, `broker_unfilled_capacity_limited`); full/blind/agent additive decomposition written by the reducer whenever the `ablation` stage contains both `:none` and `:BlindBroker` rows per anchor. Output: `data/summaries/broker_advantage/ablations_decomposition.csv` (one row per anchor).

### 15.2 What is currently running on the cluster
As of the handoff, the following 93-task burst was submitted and is cycling through QOS=short:
- `7142781` (1 task): sysimage rebuild → `data/sysimage/sys_ba.so`
- `7142782_[0-3]` (4 tasks): diagnostic at N=1000 re-run with patched residualized gate
- `7142783_[0-2]` (3 tasks): diagnostic_blind at N=1000 re-run
- `7142784_[0-19]` (20 tasks): **delta_rho sweep** at simplified scale
- `7142785_[0-24]` (25 tasks): **fee_cost sweep**
- `7142786_[0-19]` (20 tasks): **transparency_access sweep**
- `7142787_[0-19]` (20 tasks): **learning_turnover sweep**

Wallclock budget 1:30:00 each; each simplified-scale task runs 30 sims × ~12s ≈ 6 min, each full-scale diag task runs 5 sims × ~60s ≈ 5 min. Total wallclock for the burst ≈ 20–30 min depending on cluster turnover.

### 15.3 Decision points already resolved
- EasyQuality / NoRegime sanity "failure" is **understood, not a bug**. The preflight byte-compatibility proof rules out an instrumentation bug; the BlindBroker comparison shows that at $\rho=1$ the broker advantage is 94% pooled-data, which the spec's "broker advantage shrinks" expectation missed.
- QOS=test vs. QOS=short is auto-assigned by `--time`; every array sbatch in this project uses `--time=01:30:00` or more.
- Compute nodes have no internet; all Julia packages must be pre-installed on the login node. `sysimage/` has its own Project.toml with `PackageCompiler`.
- Paired RNG is at the "acceptable initial implementation" tier per spec §5.4 — init and demand shocks are shared between treatment and control; match noise diverges after the first brokered match in treatment. This is documented, not yet fully addressed.

### 15.4 Artefacts to read first as a new agent
1. `writeup/broker_advantage_progress.tex` — ICML-style progress report with equations, tables, and interpretations (written 2026-04-19).
2. `data/summaries/broker_advantage/final_run_notes.md` — running log of decisions, identity check thresholds, unresolved caveats.
3. `prompts/BROKER_ADVANTAGE_AGENT_RUNBOOK.md` + the three companion specs — the formal requirements. Everything in the B-phase and C-phase is an implementation of these.
4. This file, especially §11 (data integrity) and §14 (lessons).

### 15.5 What the new agent should do

The currently-running 93-task burst will finish shortly after handoff. Upon resume:

1. `squeue -u $USER` to see which tasks remain.
2. `sacct -j <jobid> --format=JobID,State,ExitCode` to check completions.
3. For each finished stage, run the reducer:
   ```bash
   julia --project -J data/sysimage/sys_ba.so scripts/run_broker_advantage.jl --stage diagnostic --reduce
   julia --project -J data/sysimage/sys_ba.so scripts/run_broker_advantage.jl --stage diagnostic_blind --reduce
   for sw in delta_rho fee_cost transparency_access learning_turnover; do
     julia --project -J data/sysimage/sys_ba.so scripts/run_broker_advantage.jl \
           --stage sweep --sweep $sw --reduce
   done
   ```
4. Check cell_summary rank_gap, net_value_gap, fill_rate_gap, and the access/assessment fractions against spec §4 regime labels. The regime_labels CSV per sweep is auto-produced.
5. Then start **Phase C4 ablations**: one 24-task array (3 anchors × 8 modes with `:none` baseline). The anchors can now be chosen informed by the delta_rho regime map (broker-dominant, self-search, boundary). Submit as another array with `--stage ablation`.
6. Then **Phase C5 full-confirm**: hand-picked cells at N=1000/T=200/h_b=32. 15 seeds preferred, 30 if budget allows. Submit as a 10-task array: 5 cells × 2 arms (treatment + NoBroker control).
7. Finally `scripts/plot_broker_advantage.jl` (not yet written). Per `BROKER_ADVANTAGE_PLOTTING_SPEC.md` the minimum required figures are phase panels per sweep, regime maps, advantage-dynamics dashboards, phase portraits, and a fee-sensitivity curves figure. CairoMakie is the plotting stack (already baked into the sysimage).

### 15.6 Open issues for the new agent to address or flag
- **Plot script not yet written** (`scripts/plot_broker_advantage.jl`). Required before Phase C5 claims a full final figure set.
- **`EqualCapacityBroker` ablation still errors at `initialize_model`**. Low-priority; only needed to quantify HardPairwise's capacity-limited gap.
- **Paired welfare RNG divergence** (match-noise diverges after first broker match) — worth a proper stream-separation refactor if a Stage 4 referee asks. Currently noted in `final_run_notes.md`.
- **Residualized R² at $\rho=1$ is NaN by design** (gate). Documented; plots must handle NaN explicitly.
- **Broker fill-failure bucket attribution is minimal** (2 buckets via `demand_failed` flag). If more granularity is needed (e.g., "rejected-by-partner"), instrument inside `round_match_formation!`.

## 16. Next action for the agent reading this

1. `squeue -j 7139386 -o "%i %T %M %R"` and read `slurm_logs/preflight_rd_7139386.{out,err}` to determine the status of the rho_delta preflight rerun. If it has succeeded, Phase A is done. If it is still running, monitor until it finishes; do not start Phase B while Phase A is unresolved.
2. On Phase A success: confirm `data/figures/phase_diagram/rho_delta_base_outsourcing.png` and `rho_delta_base_r2_gap.png` exist. Record runtime.
3. On Phase A failure: investigate and fix additively; do not proceed to Phase B until preflight passes.
4. Then begin Phase B1 (fee/cost split) as described in §9 and test with `scripts/quick_diagnostic.jl` before moving on. Phase B1 success criterion: the summary line numbers from `quick_diagnostic.jl` match the pre-instrumentation numbers in §5.2 1/3 to within floating-point tolerance on the same seed=42.
5. Continue down the task list, monitoring every sbatch job and fixing bugs before moving forward.

Do not fabricate results. If any stage fails acceptance criteria, report the failure and ask the user how to proceed rather than forcing a result.
