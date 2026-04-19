# Broker Advantage Analysis Spec v4

## 1. Purpose

Use the existing Julia implementation of the base `TransientBrokerage.jl` model to map when the broker wins and when agents bypass it.

The substantive distinction is not simply whether the broker is used. Each parameter cell must be evaluated along four linked dimensions:

```text
prediction:       does the broker rank/predict match quality better?
allocation:       does the broker produce better filled matches or higher fill rates?
adoption:         do agents route demand to the broker?
access/assessment: is broker value coming from reaching unavailable partners or from ranking reachable partners?
```

The final output must include both temporal dynamics and two-dimensional phase diagrams.

## 2. Mechanisms to preserve

Do not simplify away either core force.

### 2.1 Informational asymmetry favoring the broker

The true match value contains pair-level structure. The broker observes cross-agent triples of the form:

```text
(x_i, x_j, q_ij)
```

Agents observe only their own histories with partner-side inputs:

```text
(x_j, q_ij)
```

The broker can therefore learn pair-conditioned structure that individual agents cannot identify with the same input information.

### 2.2 Structural-hole erosion favoring self-search

Every successful match creates a direct edge in the evolving graph and updates the participating agents' histories. As matches accumulate, some of the broker's access value should self-liquidate: previously brokered partners become directly reachable or empirically known.

The analysis must therefore track whether the broker's advantage is transient access value, persistent assessment value, or a combination.

## 3. Outcome definitions

Use post-burn-in averages unless stated otherwise. For simplified sweeps, use `period > T_burn`; for selected temporal plots, show the full series with a burn-in marker.

### 3.1 Prediction advantage

Primary metric:

```text
rank_gap = broker_holdout_rank - agent_holdout_rank
```

Secondary metrics:

```text
r2_gap   = broker_holdout_r2 - agent_holdout_r2
rmse_gap = broker_holdout_rmse - agent_holdout_rmse
```

`rank_gap` is the primary prediction metric because the matching decision is a ranking problem. `r2_gap` remains useful but should not be the only headline metric.

### 3.2 Allocation and value advantage

For each period, log demanded slots and filled slots by channel:

```text
self_demand_slots
broker_demand_slots
self_filled_slots
broker_filled_slots
```

Fill rates:

```text
self_fill_rate   = self_filled_slots / self_demand_slots
broker_fill_rate = broker_filled_slots / broker_demand_slots
fill_rate_gap    = broker_fill_rate - self_fill_rate
```

Conditional accepted-match quality:

```text
q_self_cond = sum(q for self accepted matches) / self_filled_slots
q_brk_cond  = sum(q for broker accepted matches) / broker_filled_slots
```

Gross value per demanded slot:

```text
gross_self_per_demand = sum(q for self accepted matches) / self_demand_slots
gross_brk_per_demand  = sum(q for broker accepted matches) / broker_demand_slots
```

Net value per demanded slot:

```text
net_self_per_demand = gross_self_per_demand - c_s
net_brk_per_demand  = gross_brk_per_demand - phi * broker_fill_rate
net_value_gap       = net_brk_per_demand - net_self_per_demand
```

Here `c_s` is charged on self-routed demanded slots and `phi` only on successful brokered placements.

Recommended decomposition:

```text
quality_selection_component = broker_fill_rate * (q_brk_cond - q_self_cond)
fill_access_component       = (broker_fill_rate - self_fill_rate) * q_self_cond
fee_cost_component          = c_s - broker_fill_rate * phi
net_value_gap               ≈ quality_selection_component + fill_access_component + fee_cost_component
```

When a denominator is zero, record `missing` or `NaN` consistently and exclude from mean calculations unless the plotting script has an explicit rule.

### 3.3 Paired welfare advantage versus no-broker counterfactual

For each treatment run, run a paired no-broker counterfactual with the same initialization and market shocks where all agents are forced to self-search.

Treatment:

```text
full base model with endogenous broker choice
```

Counterfactual:

```text
same model and same exogenous shocks, but broker channel unavailable
```

Run-level welfare summaries:

```text
welfare_agents_treatment
welfare_agents_control
delta_welfare_agents = welfare_agents_treatment - welfare_agents_control
welfare_broker_treatment = broker fee revenue
```

For agent welfare, use the repository's economic conventions. If implementing from the specification, count realized pair output once per pair, subtract self-search costs on self-routed demanded slots, and subtract broker fees from agents on successful brokered placements. Keep broker fee revenue separate so that agent welfare and broker revenue are not conflated.

### 3.4 Adoption

Required metrics:

```text
pi_broker_slot  = broker_demand_slots / total_demand_slots
pi_broker_agent = number of demanders choosing broker / total demanders
tried_broker_frac
abandoned_broker_frac
```

Define abandonment as the fraction of agents who have tried the broker and whose terminal broker satisfaction is below terminal self-search satisfaction. If the model already has a better defection concept, keep the existing concept but document it.

### 3.5 Access versus assessment

For every brokered match, classify the pair using the graph and pair history **before** adding the new match-created edge:

```text
access_new_edge:
    j was not in N_G(i) at match time.

assessment_reachable_no_prior:
    j was already in N_G(i), but i and j had no prior realized match history.

assessment_prior_partner:
    i and j had prior realized match history.
```

Aggregate to period and cell shares:

```text
access_new_edge_frac_brk
assessment_reachable_no_prior_frac_brk
assessment_prior_partner_frac_brk
assessment_total_frac_brk = assessment_reachable_no_prior_frac_brk + assessment_prior_partner_frac_brk
```

Interpretation:

```text
high access_new_edge fraction: broker mainly bridges structural holes
high assessment_prior_partner fraction: broker mainly selects/ranks known or already reachable partners
rising assessment share over time: access value is being converted into direct relational knowledge
```

### 3.6 Transient dynamics

For each seed and cell, compute:

```text
pi_broker_peak
period_peak_broker_share
post_peak_half_life
terminal_pi_broker_slot
```

Classify terminal adoption dynamically:

```text
persistent: terminal_pi_broker_slot > 0.30
eroded:     terminal_pi_broker_slot < 0.10
mixed:      otherwise
```

## 4. Regime classification

Use seed-level post-burn-in summaries aggregated to cell-level means and confidence intervals.

Recommended signs:

```text
B = mean(pi_broker_slot)
V = mean(delta_welfare_agents) if paired control is available, otherwise mean(net_value_gap)
I = mean(rank_gap)
F = mean(fill_rate_gap)
G = mean(gross_brk_per_demand - gross_self_per_demand)
```

Use confidence flags where possible:

```text
positive if 95% confidence interval is entirely above zero
negative if 95% confidence interval is entirely below zero
uncertain otherwise
```

### 4.1 Main labels

| Label | Conditions | Interpretation |
|---|---|---|
| `BrokerDominant` | `B > 0.50`, `V > 0`, `I > 0` | Broker information/value advantage is adopted. |
| `RentExtraction` | `B > 0.50`, `V < 0` | Broker is used, but agents would be better off without it. |
| `Underadopted_Info` | `B < 0.20`, `V > 0`, `I > 0` | Broker would help, but adoption does not tip. |
| `FeeInducedBypass` | `B < 0.20`, `I > 0`, `G > 0`, `V <= 0` | Broker predicts/selects well, but fees erase value. |
| `SelfSearchDominant` | `B < 0.20`, `V <= 0`, `I <= 0` | No durable broker advantage. |
| `Mixed` | otherwise | Boundary or ambiguous cell. |

When confidence intervals straddle zero, mark the regime as low-confidence or boundary even if the point estimate satisfies a label.

### 4.2 Broker-dominant subtypes

Within `BrokerDominant`, classify by access/assessment composition:

| Subtype | Condition | Interpretation |
|---|---|---|
| `BrokerDominant_Access` | `access_new_edge_frac_brk > 0.60` | Broker is primarily an access provider. Expect erosion over time. |
| `BrokerDominant_Assessment` | `access_new_edge_frac_brk < 0.30` | Broker is primarily an assessment/ranking provider. Expect persistence. |
| `BrokerDominant_Dual` | otherwise | Broker provides both access and assessment. |

Report threshold robustness for broker-share thresholds `{0.30, 0.50, 0.70}` and access thresholds `{0.30, 0.50, 0.60}` on the main regime maps.

## 5. Required experimental stages

### 5.1 Stage 0: preflight baseline

Before adding or interpreting new results, run the existing scripts:

```bash
julia --project --threads=auto scripts/quick_diagnostic.jl
julia --project --threads=auto scripts/explore_base_model.jl --baseline
julia --project --threads=auto scripts/explore_phase_diagram.jl rho_delta
```

This verifies that the current model and plotting stack work.

### 5.2 Stage 1: sanity checks

Run controlled cases with a small number of seeds. These are implementation checks, not final results.

| Test | Overrides | Expected behavior |
|---|---|---|
| NoRegime | `delta = 0` | prediction gap shrinks; remaining broker use is access/cost driven. |
| PureQuality | `rho = 1` | broker information advantage shrinks. |
| HardPairwise | `delta = 0.75`, `rho = 0.25` or `0.0` | positive `rank_gap` and possibly positive `net_value_gap`. |
| HighTransparency | high `n_strangers`, high `k` | broker access advantage falls. |
| LowRosterAccess | `alpha_R = 0.05` | broker fill and adoption fall. |
| HighFee | high `broker_fee_rate`, default `self_search_cost_rate` | broker adoption or net value falls. |
| FreezeBrokerLearning | broker model fixed after initialization | broker prediction advantage weakens. |

Recommended simplified settings:

```text
N = 300
d = 6
T = 120
T_burn = 20
seeds = 5
network_measure_interval = 5
```

### 5.3 Stage 2: pilot

Run five cells:

```text
(delta=0.00, rho=0.00)
(delta=0.00, rho=1.00)
(delta=0.75, rho=0.00)
(delta=0.75, rho=1.00)
(delta=0.50, rho=0.50)
```

Settings:

```text
N = 300
d = 6
T = 120
T_burn = 20
seeds_per_cell = 10
arms = treatment + nobroker_counterfactual
network_measure_interval = 5
```

Pilot success criteria:

```text
rank_gap positive in at least one high-delta / low-rho cell
rank_gap near zero in no-regime or pure-quality anchors
paired delta_welfare_agents less noisy than raw treatment welfare
no severe missingness from zero denominators or variance gates
plots identify at least one plausible broker-dominant and one self-search cell
```

### 5.4 Stage 3: main simplified sweeps

Use simplified settings:

```text
N = 300
d = 6
T = 120
T_burn = 20
seeds_per_cell = 10 to 15
network_measure_interval = 5
arms = treatment + nobroker_counterfactual
```

If runtime is tight, use 10 seeds initially and rerun boundary cells with 15 to 30 seeds.

#### Required sweep A: information complexity, `delta_rho`

| Axis | Values |
|---|---|
| `rho` | `0.00, 0.25, 0.50, 0.75, 1.00` |
| `delta` | `0.00, 0.25, 0.50, 0.75` |

Purpose: detect when regime-gated pair structure creates a broker prediction and allocation advantage.

#### Required sweep B: price/cost wedge, `fee_cost`

Decouple broker fee and self-search cost.

| Axis | Values |
|---|---|
| `broker_fee_rate` | `0.00, 0.05, 0.15, 0.30, 0.60` |
| `self_search_cost_rate` | `0.00, 0.05, 0.15, 0.30, 0.60` |

Purpose: distinguish genuine broker value from fee-induced bypass and rent extraction.

Use default information-complexity settings unless the pilot indicates a better anchor. The default anchor should be:

```text
delta = 0.50
rho = 0.50
```

Optionally rerun the same price grid at a high-information-gap anchor:

```text
delta = 0.75
rho = 0.25
```

#### Required sweep C: self-search transparency versus broker access, `transparency_access`

| Axis | Values |
|---|---|
| `n_strangers` | `0, 2, 5, 10, 20` |
| `alpha_R` | `0.05, 0.10, 0.20, 0.40` |

Purpose: identify when agents bypass the broker because their own search reach is sufficient, and when the broker wins because its accessible set is larger.

Use default `delta = 0.50`, `rho = 0.50` unless the pilot suggests a more informative anchor.

#### Required sweep D: learning asymmetry, `learning_turnover`

| Axis | Values |
|---|---|
| `p_demand` | `0.25, 0.50, 0.75, 0.90` |
| `eta` | `0.00, 0.01, 0.02, 0.05, 0.10` |

Purpose: test whether broker relevance depends on market volume feeding pooled broker learning and turnover resetting individual-agent histories.

### 5.5 Optional secondary sweeps

Run these only after the required sweeps are complete.

#### Optional sweep: stranger search versus network density, `strangers_degree`

| Axis | Values |
|---|---|
| `n_strangers` | `0, 2, 5, 10, 20` |
| `k` | `2, 4, 6, 10, 20` |

Purpose: direct transparency/bypass test.

#### Optional sweep: noise robustness, `sigmaeps_delta`

| Axis | Values |
|---|---|
| `sigma_eps` | `0.025, 0.05, 0.10, 0.20, 0.30, 0.50` |
| `delta` | `0.00, 0.25, 0.50, 0.75` |

Purpose: test whether prediction/allocation advantage survives noisy outcomes.

#### Optional one-at-a-time sensitivities

At `delta = 0.50`, `rho = 0.50`:

```text
s:        2, 4, 6, 8
K:        2, 5, 10, 20
p_rewire: 0.00, 0.10, 0.30
sigma_x:  0.20, 0.50, 1.00
```

## 6. Ablations

Run ablations at two to four anchor cells:

```text
baseline anchor:        delta=0.50, rho=0.50
broker-dominant anchor: selected from main sweep
self-search anchor:     selected from main sweep
boundary anchor:        selected from main sweep if runtime allows
```

Use at least 10 seeds per anchor; 15 is preferred.

| Label | Change | Identifies |
|---|---|---|
| `NoBroker` | Force all demand to self-search. | Welfare baseline. |
| `NoRegime` | Set `delta = 0`. | Whether regime gate is the information source. |
| `BlindBroker` | Broker predictor receives only partner-side input comparable to agents. | Pair-input information advantage. |
| `EqualCapacityBroker` | Broker uses agent-like hidden width/training capacity where feasible. | Compute/capacity confound. |
| `NoAccessBroker` | Broker may recommend only candidates already in `N_G(i)` before the match. | Pure assessment value. |
| `FrozenGraph` | Successful matches do not add graph edges; histories still update. | Structural-hole erosion. |
| `NoTurnover` | Set `eta = 0`. | Dependence on cold starts and history reset. |
| `FreezeBrokerLearning` | Broker predictor fixed after initialization/warm-up. | Broker learning contribution. |

Optional, only if easy with existing architecture:

| Label | Change | Identifies |
|---|---|---|
| `PublicInfoSelf` | Agents self-search but rank their own reachable candidate set using a public broker-style pair predictor. | Whether broker information would help without broker access. |
| `NativeAccessAudit` | For sampled agents, compare best self-accessible candidate under agent ranking to best broker-accessible candidate under broker ranking using true noiseless value. | Total channel opportunity advantage. |
| `AssessmentOnlyAudit` | Use the same candidate set for agent and broker predictions. | Pure ranking advantage. |

Do not implement `EqualDataAgents` by simply injecting other agents' labels into each agent's own single-input model; those labels are not generally valid for the focal agent's payoff function. Use `PublicInfoSelf` or an audit instead.

## 7. Stage 4 full-model confirmation

After simplified sweeps and ablations, rerun selected cells at the original scale used by the existing base-model exploration scripts.

Settings:

```text
N = 1000
d = 8
T = 200
T_burn = 30
h_a = 16
h_b = 32
network_measure_interval = 20
seeds_per_cell = 30 preferred, 15 minimum if runtime constrained
```

Use a fresh seed block. Do not reuse pilot or simplified sweep seeds.

Selected cells:

```text
clear broker-dominant cell
clear self-search-dominant cell
boundary cell
rent-extraction or fee-induced-bypass cell if found
high-information-gap / low-access cell, e.g. high delta with alpha_R=0.05
```

The full-model confirmation should answer whether the simplified-stage classifications survive the original model scale and training settings.

## 8. Headline plots required

The plotting spec gives exact layouts. At a minimum, the final analysis must include:

1. `delta_rho_phase_panels.png`
2. `fee_cost_phase_panels.png`
3. `transparency_access_phase_panels.png`
4. `learning_turnover_phase_panels.png`
5. `regime_map_delta_rho.png`
6. `regime_map_fee_cost.png`
7. `regime_map_transparency_access.png`
8. `regime_map_learning_turnover.png`
9. `temporal_cases_overlay.png`
10. `advantage_dynamics_broker_dominant.png`
11. `advantage_dynamics_self_search.png`
12. `phase_portraits_broker_dominant.png`
13. `phase_portraits_self_search.png`
14. `ablation_bars.png`
15. `full_confirm_comparison.png`

Every phase-panel figure must show, at minimum:

```text
broker adoption
agent welfare or net channel value
rank_gap
r2_gap
fill_rate_gap
access/assessment composition
regime classification
```

## 9. Falsifiable predictions

Treat these as hypotheses to evaluate, not assumptions to force.

1. Broker share is highest when `delta` is high and `rho` is low/intermediate.
2. Broker share and broker value fall as `n_strangers` and `k` make self-search more transparent.
3. Higher `broker_fee_rate` creates a region with positive prediction advantage but low or negative net value.
4. Higher `self_search_cost_rate` increases broker adoption even when prediction advantage is modest.
5. Turnover increases broker relevance if it resets agent histories faster than it erodes broker learning.
6. Access-heavy broker dominance is more transient than assessment-heavy broker dominance.
7. `BlindBroker` closes most of the prediction gap if pair-conditioned information is the source of broker advantage.
8. `NoAccessBroker` retains value only in assessment-heavy regimes.
9. `FrozenGraph` increases broker persistence if structural-hole erosion is a real force.
10. Full-model confirmation should preserve the broad phase classifications; any flips are important findings.

## 10. Risks and robustness checks

### 10.1 Roster effects at zero information gap

Even when `delta = 0`, the broker may still have access value through the roster. Use `NoRegime`, `BlindBroker`, and `NoAccessBroker` to separate access-only value from pair-information value.

### 10.2 Fee/cost calibration

The original model ties `phi` and `c_s` through one `search_cost_rate`. The broker-advantage analysis must split them. Always log realized `phi`, realized `c_s`, `broker_fee_rate`, and `self_search_cost_rate`.

### 10.3 Missing values from zero denominators

Some cells will have no broker demand or no self demand in some periods. Keep missingness explicit. The plotting code should report valid seed counts and avoid treating missing rates as true zeros.

### 10.4 Selected-sample bias

Selected-sample prediction diagnostics are endogenous. Use holdout rank and holdout R² as primary prediction metrics. Selected-sample bias remains useful for winner's-curse diagnostics but should be supplementary.

### 10.5 Simplification validation

The simplified sweeps are screening tools. Stage 4 full-model confirmation is mandatory before making final claims about the original-scale model.
