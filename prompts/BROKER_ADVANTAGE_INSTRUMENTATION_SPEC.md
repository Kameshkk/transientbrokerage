# Broker Advantage Instrumentation Spec v4

## 1. Purpose

This file gives implementation instructions for modifying the existing Julia codebase. The changes should be additive and should preserve all existing scripts described in `PLOTS.md`.

Use existing repository libraries and conventions. Do not introduce new dependencies unless no current package can perform the task.

## 2. Nonbreaking design rules

1. Preserve `default_params()` behavior for existing scripts.
2. Preserve existing metric names and meanings.
3. Add new parameters with backward-compatible defaults.
4. Add new metrics as extra columns; do not remove old columns.
5. Save broker-advantage results under `data/sims/broker_advantage/` and figures under `data/figures/broker_advantage/`.
6. Keep the base model separate from the capture/principal model.

## 3. Parameter additions

The original model uses one `search_cost_rate` to set both broker fee and self-search cost. Add two optional parameters:

```julia
broker_fee_rate
self_search_cost_rate
```

Backward-compatible logic:

```julia
base_rate = params[:search_cost_rate]
broker_fee_rate = get(params, :broker_fee_rate, base_rate)
self_search_cost_rate = get(params, :self_search_cost_rate, base_rate)

phi = broker_fee_rate * (qbar_cal - r)
c_s = self_search_cost_rate * (qbar_cal - r)
```

If the repository uses symbols, keep symbols. If it uses strings, keep strings. Do not mix conventions.

Log these in run metadata:

```text
search_cost_rate
broker_fee_rate
self_search_cost_rate
phi
c_s
qbar_cal
r
```

## 4. Suggested new simulation wrapper

Do not force all new behavior into `run_simulation` if that makes the existing code fragile. Prefer a thin wrapper around the existing simulation API.

Suggested public functions or script-level helpers:

```julia
run_broker_advantage_cell(params; seeds, arm, ablation, stage)
run_paired_broker_advantage(params; seed, cell_id, ablation=nothing)
summarize_broker_advantage_runs(runs)
classify_broker_regime(cell_summary)
```

The actual names can follow repository style.

## 5. Random-number handling for paired counterfactuals

### 5.1 Goal

For each seed and parameter cell, run:

```text
treatment: full endogenous broker choice
control: all agents forced to self-search
```

The treatment and control should share the same initialization and exogenous market shocks as much as possible.

### 5.2 Use existing RNG tools

Use the repository's current RNG style. If it already uses `StableRNGs`, use that. If it uses Julia's standard `Random` module, use that. Do not add an RNG package unless necessary.

### 5.3 Recommended streams

Use separate deterministic streams derived from the cell seed:

```text
init stream:       types, DGP operators, initial graph, initial histories
market stream:     demand, match noise, turnover, roster churn/replenishment
strategy stream:   channel-choice tie breaks, stranger sampling, other endogenous strategy draws
learning stream:   model initialization/training randomness if applicable
```

Do not rely on the global RNG in threaded loops.

### 5.4 Practical implementation

Best implementation:

1. Pre-generate initialization objects once.
2. Pre-generate exogenous per-period market shocks once.
3. Replay the same initialization and market shocks in treatment and control.
4. Allow strategy streams to diverge if the endogenous path requires it.

Acceptable initial implementation:

1. Use deterministic stream seeds for each category.
2. Share `init` and `market` stream seeds between paired arms.
3. Document any draws that cannot yet be replayed exactly.

Do not claim full common-random-number control unless initialization and market shocks are actually shared.

## 6. Demand, fill, and value logging

Add per-period counters. These must be computed before any ensemble summaries.

### 6.1 Demand and fill counts

```text
total_demand_slots
self_demand_slots
broker_demand_slots
self_filled_slots
broker_filled_slots
self_unfilled_slots
broker_unfilled_slots
```

Derived metrics:

```text
pi_broker_slot = broker_demand_slots / total_demand_slots
self_fill_rate = self_filled_slots / self_demand_slots
broker_fill_rate = broker_filled_slots / broker_demand_slots
fill_rate_gap = broker_fill_rate - self_fill_rate
```

Keep existing `outsourcing_rate` if already present. If `outsourcing_rate` equals broker slot share, document that equivalence. If it differs, preserve both.

### 6.2 Match-quality sums

Log sums and conditional means:

```text
q_self_sum
q_broker_sum
q_self_mean_cond
q_broker_mean_cond
q_self_per_demand_slot
q_broker_per_demand_slot
```

Definitions:

```text
q_self_mean_cond = q_self_sum / self_filled_slots
q_broker_mean_cond = q_broker_sum / broker_filled_slots
q_self_per_demand_slot = q_self_sum / self_demand_slots
q_broker_per_demand_slot = q_broker_sum / broker_demand_slots
```

### 6.3 Net value per demanded slot

Use realized `phi` and `c_s`:

```text
net_self_per_demand_slot = q_self_per_demand_slot - c_s
net_broker_per_demand_slot = q_broker_per_demand_slot - phi * broker_fill_rate
net_value_gap = net_broker_per_demand_slot - net_self_per_demand_slot
```

This period-level value metric is required even when paired welfare is also computed.

### 6.4 Decomposition

When all needed terms are defined:

```text
quality_selection_component = broker_fill_rate * (q_broker_mean_cond - q_self_mean_cond)
fill_access_component = (broker_fill_rate - self_fill_rate) * q_self_mean_cond
fee_cost_component = c_s - broker_fill_rate * phi
```

Check:

```text
net_value_gap ≈ quality_selection_component + fill_access_component + fee_cost_component
```

The equality will be exact up to missing-value handling and floating-point tolerance.

## 7. Access versus assessment instrumentation

For each brokered match, evaluate the status of the pair **before** adding the new match edge and before updating histories for the current match.

Per brokered match flags:

```text
broker_match_edge_pre
broker_match_prior_pair_history_pre
broker_match_access_new_edge
broker_match_assessment_reachable_no_prior
broker_match_assessment_prior_partner
```

Definitions:

```text
broker_match_access_new_edge = !broker_match_edge_pre
broker_match_assessment_reachable_no_prior = broker_match_edge_pre && !broker_match_prior_pair_history_pre
broker_match_assessment_prior_partner = broker_match_prior_pair_history_pre
```

Period counters:

```text
n_broker_access_new_edge
n_broker_assessment_reachable_no_prior
n_broker_assessment_prior_partner
n_broker_matches_classified
```

Period fractions:

```text
access_new_edge_frac_brk = n_broker_access_new_edge / n_broker_matches_classified
assessment_reachable_no_prior_frac_brk = n_broker_assessment_reachable_no_prior / n_broker_matches_classified
assessment_prior_partner_frac_brk = n_broker_assessment_prior_partner / n_broker_matches_classified
assessment_total_frac_brk = assessment_reachable_no_prior_frac_brk + assessment_prior_partner_frac_brk
```

If the existing code has `access_count` and `assessment_count`, keep them, but add the more granular fields above.

## 8. Adoption heterogeneity logging

Per period:

```text
n_agents_tried_broker
tried_broker_frac
n_agents_abandoned_broker
abandoned_broker_frac
mean_broker_dependency
p90_broker_dependency
frac_broker_dependency_gt_half
broker_dependency_gini
```

Definitions:

```text
broker_dependency_i = cumulative broker-routed demanded slots by i / cumulative demanded slots by i
```

Abandonment default:

```text
agent has tried broker AND satisfaction_broker < satisfaction_self
```

If satisfaction values are unavailable for exited agents, compute over active agents and document that scope.

## 9. Welfare logging

### 9.1 Period-level welfare

Log:

```text
welfare_agents_period
welfare_broker_period
welfare_total_period
welfare_agents_cum
welfare_broker_cum
welfare_total_cum
```

Broker welfare/revenue:

```text
welfare_broker_period = phi * broker_filled_slots
```

Agent welfare should subtract:

```text
self-search costs: c_s * self_demand_slots
broker fees:       phi * broker_filled_slots
```

For pair output, use the repository's convention. If there is no existing welfare measure, count each realized match output once at the pair level. If computing agent-side welfare by summing over agents, divide pair output by two where necessary to avoid double counting.

### 9.2 Paired summaries

For each treatment/control pair, save:

```text
cell_id
seed
treatment_run_id
control_run_id
welfare_agents_treatment
welfare_agents_control
delta_welfare_agents
welfare_broker_treatment
terminal_pi_broker_slot
terminal_rank_gap
terminal_r2_gap
terminal_net_value_gap
terminal_access_new_edge_frac_brk
```

The no-broker control has zero broker revenue and zero broker adoption by construction.

## 10. Prediction diagnostics

Preserve existing holdout and selected-sample columns:

```text
agent_holdout_rank
broker_holdout_rank
rank_gap
agent_holdout_r2
broker_holdout_r2
r2_gap
agent_holdout_rmse
broker_holdout_rmse
rmse_gap
agent_selected_rank
broker_selected_rank
agent_selected_r2
broker_selected_r2
agent_selected_bias
broker_selected_bias
```

If `rank_gap` does not already exist, add it. The primary prediction metric for this analysis is `rank_gap`.

Keep the existing variance gate behavior for prediction diagnostics. Also log the number of gated or invalid observations:

```text
variance_gate_agent_holdout
variance_gate_broker_holdout
n_holdout_eval_agents
n_holdout_eval_pairs
```

## 11. Counterfactual arm behavior

The no-broker counterfactual should be as close as possible to the treatment except for channel availability.

Required behavior:

```text
all demand is forced to self-search
broker channel is not chosen
broker fee revenue is zero
broker histories should not receive brokered match triples because no brokered matches occur
self-search matching and graph updates continue normally
turnover and market shocks follow the paired market stream
```

The broker roster can still be updated or ignored in the counterfactual. Choose whichever is easier, but document it. It should not affect matching because broker use is forced to zero.

## 12. Ablation toggles

Implement ablations as parameter or mode flags, not by duplicating the entire model.

Recommended parameter:

```text
ablation = :none
```

Required modes:

### 12.1 `:NoBroker`

Equivalent to the no-broker counterfactual: force all demand to self-search.

### 12.2 `:NoRegime`

Set `delta = 0` while keeping other parameters fixed.

### 12.3 `:BlindBroker`

Broker predictor should not receive focal-agent pair input. Use an input comparable to the agents' partner-side input. Preserve the rest of the broker's role if feasible.

Purpose: test whether pair-conditioned input is necessary for the broker prediction gap.

### 12.4 `:EqualCapacityBroker`

Reduce broker model capacity to the agent-like capacity where feasible, for example by using agent hidden width. Do not change broker data access.

Purpose: test whether advantage is from input/data rather than larger model capacity.

### 12.5 `:NoAccessBroker`

Broker may recommend only candidates already reachable by the focal agent before the match:

```text
candidate j must satisfy j in N_G(i)
```

Purpose: isolate assessment value.

### 12.6 `:FrozenGraph`

Successful matches update histories and payoffs but do not add new graph edges between agents.

Purpose: isolate structural-hole erosion.

### 12.7 `:NoTurnover`

Set `eta = 0`.

### 12.8 `:FreezeBrokerLearning`

Broker predictor is initialized/warmed up as usual, then not retrained during production periods.

Purpose: verify that broker advantage is not purely from roster/access.

### 12.9 Optional audits

If easy with current code, add non-intervening audits rather than full ablation modes:

```text
NativeAccessAudit
AssessmentOnlyAudit
```

These should sample agents/candidate sets and evaluate counterfactual rankings without changing the actual simulation path.

## 13. Storage schema

Use JLD2 caches consistent with existing scripts.

Suggested file names:

```text
data/sims/broker_advantage/sanity.jld2
data/sims/broker_advantage/pilot_delta_rho.jld2
data/sims/broker_advantage/delta_rho.jld2
data/sims/broker_advantage/fee_cost.jld2
data/sims/broker_advantage/transparency_access.jld2
data/sims/broker_advantage/learning_turnover.jld2
data/sims/broker_advantage/ablations.jld2
data/sims/broker_advantage/full_confirm.jld2
```

Each JLD2 file should contain, using whatever data structures are natural for the repo:

```text
metrics_by_run      # per-period metrics, one DataFrame per run or one long DataFrame
metadata            # one row per run
paired_summaries    # one row per treatment/control pair, where applicable
cell_summaries      # one row per parameter cell
regime_labels       # one row per parameter cell
script_version_info # optional but recommended
```

If storing a dictionary of DataFrames, include keys that identify:

```text
stage
sweep
cell_id
seed
arm
ablation
```

## 14. CSV summaries

Also write CSV summaries for easier inspection:

```text
data/summaries/broker_advantage/<stage_or_sweep>_run_metadata.csv
data/summaries/broker_advantage/<stage_or_sweep>_paired_summaries.csv
data/summaries/broker_advantage/<stage_or_sweep>_cell_summaries.csv
data/summaries/broker_advantage/<stage_or_sweep>_regime_labels.csv
```

Use existing CSV/DataFrames libraries if already in the repository. If CSV output would require a new dependency and the repo does not already use one, JLD2-only output is acceptable, but document it.

## 15. Summary calculations

### 15.1 Per-run post-burn summary

For each run, compute means over:

```text
period > T_burn
```

Also compute final-window summaries over:

```text
last 30 periods if T >= 100
last 20 periods for pilot if preferred
```

Required summarized metrics:

```text
pi_broker_slot
pi_broker_agent
rank_gap
r2_gap
rmse_gap
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
betweenness
constraint_b
eff_size_b
broker_history_size
```

Use only columns that exist; if `constraint_b` or `eff_size_b` are not implemented, skip them and note that they are missing.

### 15.2 Cell summary

Across seeds, compute:

```text
mean
standard deviation
standard error
95% confidence interval lower/upper
number of valid seeds
number of total seeds
```

For signed metrics, also compute:

```text
share_positive
share_negative
```

This helps mark low-confidence regime cells.

## 16. Regime classification implementation

Implement a helper using the rules in `BROKER_ADVANTAGE_ANALYSIS_SPEC.md`.

Inputs:

```text
B = pi_broker_slot mean
V = delta_welfare_agents mean if available, otherwise net_value_gap mean
I = rank_gap mean
F = fill_rate_gap mean
G = gross_brk_per_demand - gross_self_per_demand mean
access = access_new_edge_frac_brk mean
confidence intervals for V and I if available
```

Outputs:

```text
regime_label
regime_code
regime_confidence
broker_dominant_subtype
thresholds_used
```

Recommended regime codes:

```text
BI = BrokerDominant_Assessment or information-heavy
BA = BrokerDominant_Access
BD = BrokerDominant_Dual
RE = RentExtraction
UI = Underadopted_Info
FB = FeeInducedBypass
SS = SelfSearchDominant
M  = Mixed
```

## 17. Performance guidance

Use existing Julia performance practices:

```text
preallocate arrays inside simulation loops where possible
avoid DataFrame row mutation inside inner loops
collect numeric arrays during a run, then build a DataFrame at the end
avoid global RNGs in threaded loops
avoid storing N x N matrices for every run when not needed
reuse existing DGP/holdout helper code where available
```

Do not optimize prematurely. First produce correct metrics for one seed, then scale to sweeps.

## 18. Instrumentation acceptance checklist

Before running full sweeps, verify:

```text
existing scripts still run
new fee/cost params default to old behavior
new metrics exist in one default run
accounting identities pass on one seed
access/assessment flags are pre-match
paired treatment/control runs share intended seed streams
JLD2 cache loads cleanly
cell summaries and regime labels are produced
plots can render from cache without rerunning simulations
```
