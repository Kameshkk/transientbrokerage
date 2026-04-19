# Agent Runbook v4: Broker-Advantage Analyses in the Existing Julia Repository

## 0. Scope

Use the existing Julia codebase for `TransientBrokerage.jl`. The goal is to add the minimum instrumentation and new scripts needed to run the broker-advantage experiments, not to rewrite the model or replace the plotting stack.

The analysis must answer:

1. When does the broker obtain a durable advantage from cross-agent information?
2. When do agents learn/search well enough to bypass the broker?
3. When is broker use explained by information, access, fees/costs, or sluggish adoption?

Only the **base model** is in scope. Do not use the capture/resource-principal variant unless explicitly requested.

## 1. Repository constraints

Follow these constraints unless the user approves otherwise.

### 1.1 Do not replace existing infrastructure

Use the repository's current Julia environment and libraries. The existing scripts already use the `TransientBrokerage.jl` package, seeded runs, JLD2 simulation caches, and figure output under `data/figures/<subdir>/`. Keep that pattern.

Do not add Python dependencies. Do not add a new Julia plotting stack if the existing scripts already have one. Do not introduce a new data format if JLD2 and CSV summaries are already sufficient.

### 1.2 Add dependencies only if unavoidable

Before adding a dependency, check whether the repository already has an equivalent package in `Project.toml` / `Manifest.toml`. If a new dependency is genuinely necessary, document:

```text
package name
why existing libraries are insufficient
which script needs it
whether it is required or optional
```

For the current plan, no new dependencies should be necessary.

### 1.3 Preserve existing behavior

The following existing commands must still work after your changes:

```bash
julia --project --threads=auto scripts/quick_diagnostic.jl
julia --project --threads=auto scripts/explore_base_model.jl --baseline
julia --project --threads=auto scripts/explore_phase_diagram.jl rho_delta
```

Do not rename existing metrics such as:

```text
outsourcing_rate
broker_holdout_r2
agent_holdout_r2
r2_gap
broker_holdout_rank
agent_holdout_rank
rank_gap
betweenness
q_self_mean
q_broker_standard_mean
n_self_matches
n_broker_standard
broker_access_size
roster_size
broker_history_size
```

Add new columns rather than breaking existing scripts.

## 2. Files to read before coding

Read these files first:

```text
model_description.tex
PLOTS.md
src/parameters.jl
src/<file containing run_simulation>
scripts/quick_diagnostic.jl
scripts/explore_base_model.jl
scripts/explore_phase_diagram.jl
scripts/figure_style.jl
```

Then read these broker-advantage specs:

```text
BROKER_ADVANTAGE_ANALYSIS_SPEC.md
BROKER_ADVANTAGE_INSTRUMENTATION_SPEC.md
BROKER_ADVANTAGE_PLOTTING_SPEC.md
```

Use `PLOTS.md` as the reference for current script conventions, current default parameters, existing metric names, cache locations, and figure style.

## 3. Deliverables

Create or update the following implementation artifacts in the repository.

### 3.1 New scripts

Required:

```text
scripts/run_broker_advantage.jl
scripts/plot_broker_advantage.jl
```

Optional only if useful:

```text
scripts/summarize_broker_advantage.jl
```

The scripts should follow the style of the existing `scripts/explore_*.jl` files: command-line flags, `--rerun`, JLD2 cache reuse, clear stdout summaries, and figures written under `data/figures/...`.

### 3.2 New output directories

Use:

```text
data/sims/broker_advantage/
data/figures/broker_advantage/
data/summaries/broker_advantage/
```

Do not overwrite existing `exploration`, `phase_diagram`, or `capture` outputs.

### 3.3 Updated model parameters

Add decoupled broker-fee and self-search-cost rates while preserving backward compatibility:

```text
broker_fee_rate
self_search_cost_rate
```

If these are absent, default both to the existing `search_cost_rate`. This keeps existing scripts behaviorally unchanged.

### 3.4 New metrics

Add period-level and run-level metrics listed in `BROKER_ADVANTAGE_INSTRUMENTATION_SPEC.md`. The minimum required new metrics are:

```text
self_demand_slots
broker_demand_slots
self_filled_slots
broker_filled_slots
self_fill_rate
broker_fill_rate
fill_rate_gap
q_self_per_demand_slot
q_broker_per_demand_slot
net_self_per_demand_slot
net_broker_per_demand_slot
net_value_gap
quality_selection_component
fill_access_component
fee_cost_component
access_new_edge_frac_brk
assessment_reachable_no_prior_frac_brk
assessment_prior_partner_frac_brk
tried_broker_frac
abandoned_broker_frac
welfare_agents_cum
welfare_broker_cum
```

## 4. Suggested command-line interface

Use this interface unless it conflicts with existing repo conventions.

### 4.1 Run simulations

```bash
julia --project --threads=auto scripts/run_broker_advantage.jl --stage sanity --rerun
julia --project --threads=auto scripts/run_broker_advantage.jl --stage pilot --rerun
julia --project --threads=auto scripts/run_broker_advantage.jl --stage sweep --sweep delta_rho --rerun
julia --project --threads=auto scripts/run_broker_advantage.jl --stage sweep --sweep fee_cost --rerun
julia --project --threads=auto scripts/run_broker_advantage.jl --stage sweep --sweep transparency_access --rerun
julia --project --threads=auto scripts/run_broker_advantage.jl --stage sweep --sweep learning_turnover --rerun
julia --project --threads=auto scripts/run_broker_advantage.jl --stage ablation --rerun
julia --project --threads=auto scripts/run_broker_advantage.jl --stage full_confirm --rerun
```

### 4.2 Render plots

```bash
julia --project scripts/plot_broker_advantage.jl --stage sanity
julia --project scripts/plot_broker_advantage.jl --stage pilot
julia --project scripts/plot_broker_advantage.jl --sweep delta_rho
julia --project scripts/plot_broker_advantage.jl --sweep fee_cost
julia --project scripts/plot_broker_advantage.jl --sweep transparency_access
julia --project scripts/plot_broker_advantage.jl --sweep learning_turnover
julia --project scripts/plot_broker_advantage.jl --stage ablation
julia --project scripts/plot_broker_advantage.jl --stage full_confirm
```

A combined plot command is acceptable if that matches the existing script style.

## 5. Preflight: verify existing repo behavior

From the repository root, run:

```bash
julia --project --threads=auto scripts/quick_diagnostic.jl
julia --project --threads=auto scripts/explore_base_model.jl --baseline
julia --project --threads=auto scripts/explore_phase_diagram.jl rho_delta
```

Confirm that at least the following files are created:

```text
data/figures/quick_diagnostic.png
data/figures/exploration/baseline_dynamics.png
data/figures/exploration/baseline_network_stats.png
data/figures/phase_diagram/rho_delta_base_outsourcing.png
data/figures/phase_diagram/rho_delta_base_r2_gap.png
```

Record:

```text
git commit hash
Julia version
Project.toml and Manifest.toml status
number of threads
runtime for each preflight command
```

Do not proceed if the baseline scripts fail.

## 6. Implementation order

Follow this order to keep the changes reviewable.

### Step 1: add fee/cost split only

Add `broker_fee_rate` and `self_search_cost_rate` with backward compatibility. Run `quick_diagnostic.jl` and confirm the output is unchanged when both new parameters are omitted.

### Step 2: add period-level demand/fill/value counters

Add the new counters but do not yet add paired counterfactuals or ablations. Run one default seed and verify accounting identities.

### Step 3: add pre-match access/assessment flags

For every brokered match, record the state before the match-created edge is added:

```text
edge_pre = whether j was in N_G(i) before this match
prior_pair_history_pre = whether i and j had prior realized matches before this match
```

Classify brokered matches into:

```text
access_new_edge                 edge_pre == false
assessment_reachable_no_prior   edge_pre == true and prior_pair_history_pre == false
assessment_prior_partner        prior_pair_history_pre == true
```

### Step 4: add paired no-broker counterfactual wrapper

Add a wrapper that runs:

```text
treatment: full base model
control: same exogenous initialization and market shocks, but all demand forced to self-search
```

See the instrumentation spec for random-number handling.

### Step 5: add sweeps

Implement the required sweeps:

```text
delta_rho
fee_cost
transparency_access
learning_turnover
```

Use simplified settings for pilot/main sweeps unless running Stage 4 full confirmation.

### Step 6: add ablations

Implement only after the main treatment/control pipeline is working.

Required ablations:

```text
NoBroker
NoRegime
BlindBroker
EqualCapacityBroker
NoAccessBroker
FrozenGraph
NoTurnover
FreezeBrokerLearning
```

Optional if straightforward:

```text
PublicInfoSelf
NativeAccessAudit
AssessmentOnlyAudit
```

### Step 7: add plotting

Add plots specified in `BROKER_ADVANTAGE_PLOTTING_SPEC.md`. Use the existing figure style and plotting libraries.

## 7. Accounting quality checks

After Step 2, run a single seed and assert or print checks for these identities:

```text
pi_broker_slot = broker_demand_slots / total_demand_slots
self_fill_rate = self_filled_slots / self_demand_slots
broker_fill_rate = broker_filled_slots / broker_demand_slots
fill_rate_gap = broker_fill_rate - self_fill_rate
net_value_gap = net_broker_per_demand_slot - net_self_per_demand_slot
net_value_gap ≈ quality_selection_component + fill_access_component + fee_cost_component
welfare_agents_cum[t] = cumulative sum of welfare_agents_period through t
welfare_broker_cum[t] = cumulative sum of broker_revenue_period through t
```

Use `missing` or `NaN` consistently where denominators are zero. Do not silently convert undefined rates to zero unless the plotting code explicitly handles that convention.

Also verify:

```text
self-search cost is charged on self-demanded slots
broker fee is charged only on successful brokered placements
access/assessment flags are computed before the new match edge is added
existing metrics have not changed names or meanings
```

Write a short QC file:

```text
data/summaries/broker_advantage/instrumentation_qc.txt
```

## 8. Stage 1: diagnostic sanity checks

Run controlled corners before interpreting any sweep.

Command:

```bash
julia --project --threads=auto scripts/run_broker_advantage.jl --stage sanity --rerun
julia --project scripts/plot_broker_advantage.jl --stage sanity
```

Expected outputs:

```text
data/sims/broker_advantage/sanity.jld2
data/summaries/broker_advantage/sanity_summary.csv
data/figures/broker_advantage/sanity_diagnostics.pdf
```

Required sanity checks:

| Test | Parameter change | Expected behavior |
|---|---|---|
| NoRegime | `delta = 0` | `rank_gap` and `r2_gap` shrink; remaining broker use is access/fee driven. |
| EasyQuality | `rho = 1` | broker information advantage weakens; self-search becomes more viable. |
| HardPairwise | `delta = 0.75`, `rho = 0.25` or `0.0` | positive broker rank/R² advantage. |
| HighTransparency | high `n_strangers`, high `k` | access advantage and broker share fall. |
| LowRosterAccess | low `alpha_R` | broker fill/adoption fall even if prediction is strong. |
| HighFee | high `broker_fee_rate` at default `self_search_cost_rate` | broker share or net value falls. |
| FreezeBrokerLearning | broker predictor not updated after initialization | broker prediction advantage collapses or weakens materially. |

If any expected sign fails, inspect implementation before running the main sweeps.

## 9. Stage 2: pilot

Run the five pilot cells:

```text
(delta=0.00, rho=0.00)
(delta=0.00, rho=1.00)
(delta=0.75, rho=0.00)
(delta=0.75, rho=1.00)
(delta=0.50, rho=0.50)
```

Use:

```text
N = 300
d = 6
T = 120
T_burn = 20
seeds_per_cell = 10
arms = treatment + nobroker_counterfactual
network_measure_interval = 5
```

Keep all other parameters at repository defaults unless the analysis spec says otherwise. If disabling the parity schedule is not already supported, do not add extensive code solely to disable it; record that the pilot used the existing training schedule.

Commands:

```bash
julia --project --threads=auto scripts/run_broker_advantage.jl --stage pilot --rerun
julia --project scripts/plot_broker_advantage.jl --stage pilot
```

Expected outputs:

```text
data/sims/broker_advantage/pilot_delta_rho.jld2
data/summaries/broker_advantage/pilot_cell_summaries.csv
data/figures/broker_advantage/pilot_phase_panels.pdf
data/figures/broker_advantage/pilot_temporal_overlay.pdf
```

Pilot acceptance criteria:

```text
rank_gap positive in at least one high-delta / low-rho cell
rank_gap near zero in no-regime or pure-quality anchor cells
paired delta_welfare_agents less noisy than raw treatment welfare
no severe missingness from zero denominators or variance gates
temporal broker share not dominated by unexplained period-to-period oscillation
```

If oscillation is severe, run a documented sensitivity with `omega = 0.1`. Do not silently change the baseline value.

## 10. Stage 3: main simplified sweeps

Run these required sweeps:

```text
delta_rho
fee_cost
transparency_access
learning_turnover
```

Use the simplified configuration:

```text
N = 300
d = 6
T = 120
T_burn = 20
network_measure_interval = 5
seeds_per_cell = 10 to 15
arms = treatment + nobroker_counterfactual
```

Run with 15 seeds if runtime is acceptable. If not, use 10 seeds and mark boundary cells for later rerun.

Commands:

```bash
julia --project --threads=auto scripts/run_broker_advantage.jl --stage sweep --sweep delta_rho --rerun
julia --project --threads=auto scripts/run_broker_advantage.jl --stage sweep --sweep fee_cost --rerun
julia --project --threads=auto scripts/run_broker_advantage.jl --stage sweep --sweep transparency_access --rerun
julia --project --threads=auto scripts/run_broker_advantage.jl --stage sweep --sweep learning_turnover --rerun

julia --project scripts/plot_broker_advantage.jl --sweep delta_rho
julia --project scripts/plot_broker_advantage.jl --sweep fee_cost
julia --project scripts/plot_broker_advantage.jl --sweep transparency_access
julia --project scripts/plot_broker_advantage.jl --sweep learning_turnover
```

Required outputs per sweep:

```text
data/sims/broker_advantage/<sweep>.jld2
data/summaries/broker_advantage/<sweep>_cell_summaries.csv
data/summaries/broker_advantage/<sweep>_regime_labels.csv
data/figures/broker_advantage/<sweep>_phase_panels.pdf
data/figures/broker_advantage/regime_map_<sweep>.pdf
```

## 11. Stage 4: ablations

Run ablations after the main sweeps identify anchor cells.

Anchor cells:

```text
baseline anchor: delta=0.50, rho=0.50
broker-dominant anchor: chosen from Stage 3
self-search anchor: chosen from Stage 3
boundary anchor: chosen from Stage 3 if runtime allows
```

Command:

```bash
julia --project --threads=auto scripts/run_broker_advantage.jl --stage ablation --rerun
julia --project scripts/plot_broker_advantage.jl --stage ablation
```

Required outputs:

```text
data/sims/broker_advantage/ablations.jld2
data/summaries/broker_advantage/ablation_summary.csv
data/figures/broker_advantage/ablation_bars.pdf
data/figures/broker_advantage/ablation_temporal_selected.pdf
```

## 12. Stage 5: full-model confirmation

Rerun selected cells at the original-scale settings used by the existing base-model scripts:

```text
N = 1000
d = 8
T = 200
T_burn = 30
h_a = 16
h_b = 32
network_measure_interval = 20
seeds_per_cell = 30 if feasible, otherwise 15 minimum
```

Use a fresh seed block not used in the pilot or main simplified sweeps.

Selected cells:

```text
clear broker-dominant cell
clear self-search-dominant cell
boundary cell
fee-induced bypass or rent-extraction cell if found
high-information-gap / low-access cell, e.g. high delta and alpha_R=0.05
```

Commands:

```bash
julia --project --threads=auto scripts/run_broker_advantage.jl --stage full_confirm --rerun
julia --project scripts/plot_broker_advantage.jl --stage full_confirm
```

Required outputs:

```text
data/sims/broker_advantage/full_confirm.jld2
data/summaries/broker_advantage/full_confirm_summary.csv
data/figures/broker_advantage/full_confirm_comparison.pdf
```

The full-confirmation plot must compare simplified-stage and full-scale classifications. If a classification flips, report it explicitly.

## 13. Required final figure set

At completion, the following figures must exist:

```text
sanity_diagnostics.pdf
pilot_phase_panels.pdf
pilot_temporal_overlay.pdf

delta_rho_phase_panels.pdf
fee_cost_phase_panels.pdf
transparency_access_phase_panels.pdf
learning_turnover_phase_panels.pdf

regime_map_delta_rho.pdf
regime_map_fee_cost.pdf
regime_map_transparency_access.pdf
regime_map_learning_turnover.pdf

temporal_cases_overlay.pdf
advantage_dynamics_broker_dominant.pdf
advantage_dynamics_self_search.pdf
phase_portraits_broker_dominant.pdf
phase_portraits_self_search.pdf
ablation_bars.pdf
full_confirm_comparison.pdf
```

Additional figures are allowed if they support debugging, but do not substitute them for the required set.

## 14. Completion checklist

Before handing off results, confirm:

```text
existing baseline scripts still run
new parameters are backward-compatible
all required sweeps completed or documented as skipped
each JLD2 cache has metadata and parameter values
each CSV summary has one row per cell or run as appropriate
all regime maps include threshold notes
all phase panels show broker share, welfare/net value, prediction gap, fill gap, and access/assessment split
full-confirmation cells are clearly identified
all deviations from this runbook are listed in a final notes file
```

Write final notes to:

```text
data/summaries/broker_advantage/final_run_notes.md
```
