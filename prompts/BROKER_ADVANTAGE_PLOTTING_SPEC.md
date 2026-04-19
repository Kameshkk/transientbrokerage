# Broker Advantage Plotting Spec v4

## 1. Purpose

Generate the new broker-advantage figures using the existing Julia plotting infrastructure. The existing repository already produces base-model dynamics, network statistics, DGP plots, and phase diagrams. This spec adds plots focused on broker advantage, bypass, access/assessment, and fee/cost effects.

Use the existing plotting libraries and `scripts/figure_style.jl` where possible. Do not install a new plotting stack unless the repository's current stack cannot produce a required figure.

## 2. Output location

All new figures go under:

```text
data/figures/broker_advantage/
```

All new simulation caches should be read from:

```text
data/sims/broker_advantage/
```

All summaries should be read from or written to:

```text
data/summaries/broker_advantage/
```

## 3. Style conventions

Follow existing style conventions from the repository:

```text
thin per-seed lines + thick ensemble mean for temporal plots
NaN-safe rolling smoothing for displayed time series
burn-in vertical line at T_burn
post-burn-in summaries for heatmaps
sequential colormap for shares/rates
zero-centered diverging colormap for signed gaps
categorical colors for regime maps
```

Use existing colors if available:

```text
self / agents:       existing agent color
broker:              existing broker color
gap metrics:         existing gap color
access metrics:      existing access color
diagnostic counts:   existing diagnostic color
```

If the existing style file does not expose a needed color, define it locally in `plot_broker_advantage.jl` without changing old figures.

## 4. Input objects expected from simulations

Each JLD2 cache should expose these objects or easy equivalents:

```text
metrics_by_run      # per-period metrics
metadata            # one row per run
paired_summaries    # one row per treatment/control pair where applicable
cell_summaries      # one row per parameter cell
regime_labels       # one row per parameter cell
```

The plotting script may build `cell_summaries` and `regime_labels` from `metrics_by_run` if they are not stored, but the preferred workflow is to save them during the run stage.

## 5. Required helper functions

Implement plotting helpers inside `scripts/plot_broker_advantage.jl` or a small included helper file.

### 5.1 `steady_state_summary`

Inputs:

```text
one run's per-period metrics
window = :postburn or :final30
```

Outputs post-burn or final-window means for headline metrics.

### 5.2 `cell_summary`

Inputs:

```text
seed-level summaries for one cell
```

Outputs:

```text
mean
standard error
95% confidence interval
valid seed count
share positive / share negative for signed metrics
```

### 5.3 `classify_regime`

Use the regime rules from `BROKER_ADVANTAGE_ANALYSIS_SPEC.md`.

Return:

```text
regime_label
regime_code
confidence_flag
broker_dominant_subtype
```

### 5.4 Heatmap helper

Create one reusable helper for two-dimensional sweeps:

```text
plot_heatmap_with_optional_contours(matrix, xvals, yvals; metric_name, range, colormap, contours)
```

Contour overlays required where applicable:

```text
net_value_gap = 0 or delta_welfare_agents = 0
pi_broker_slot = 0.50
rank_gap = 0
```

If contouring support is awkward in the existing plotting stack, draw cell borders or line annotations instead. Do not add a new plotting package only for contours.

## 6. Required sweeps and axes

Required phase sweeps:

| Sweep name | x-axis | y-axis |
|---|---|---|
| `delta_rho` | `rho` | `delta` |
| `fee_cost` | `broker_fee_rate` | `self_search_cost_rate` |
| `transparency_access` | `n_strangers` | `alpha_R` |
| `learning_turnover` | `p_demand` | `eta` |

Optional:

| Sweep name | x-axis | y-axis |
|---|---|---|
| `strangers_degree` | `n_strangers` | `k` |
| `sigmaeps_delta` | `sigma_eps` | `delta` |

## 7. Main phase-panel figures

Create one 3×3 panel figure per required sweep:

```text
data/figures/broker_advantage/<sweep>_phase_panels.png
```

Required files:

```text
delta_rho_phase_panels.png
fee_cost_phase_panels.png
transparency_access_phase_panels.png
learning_turnover_phase_panels.png
```

### 7.1 Panel layout

| Row, Col | Panel title | Metric | Range / scale | Notes |
|---|---|---|---|---|
| 1,1 | Broker slot share | `pi_broker_slot` | `[0,1]` | show 0.50 threshold if possible |
| 1,2 | Agent welfare gain vs no broker | `delta_welfare_agents` | centered at 0 | if unavailable, use `net_value_gap` |
| 1,3 | Net channel value gap | `net_value_gap` | centered at 0 | core channel-value metric |
| 2,1 | Holdout rank gap | `rank_gap` | centered at 0 | primary prediction metric |
| 2,2 | Holdout R² gap | `r2_gap` | centered at 0 | secondary prediction metric |
| 2,3 | Fill-rate gap | `fill_rate_gap` | centered at 0 | access/liquidity effect |
| 3,1 | Access: new-edge fraction | `access_new_edge_frac_brk` | `[0,1]` | broker as structural-hole bridge |
| 3,2 | Assessment: prior-partner fraction | `assessment_prior_partner_frac_brk` | `[0,1]` | broker as ranking/assessment provider |
| 3,3 | Regime classification | `regime_code` | categorical | text labels in cells |

For cells with no brokered matches, access/assessment shares are undefined. Display them as blank/hatched/missing rather than zero.

### 7.2 Required annotations

Each phase-panel figure should include:

```text
sweep name
axis parameter values
number of seeds per cell
post-burn-in or final-window summary window
regime thresholds used
whether paired counterfactual welfare is available
```

## 8. Standalone regime maps

Create one categorical regime map per required sweep:

```text
data/figures/broker_advantage/regime_map_delta_rho.png
data/figures/broker_advantage/regime_map_fee_cost.png
data/figures/broker_advantage/regime_map_transparency_access.png
data/figures/broker_advantage/regime_map_learning_turnover.png
```

Requirements:

```text
same axes as phase-panel figure
categorical color by regime label
short text code in each cell
marker or hatch for low-confidence cells
legend outside the heatmap
footnote with thresholds
```

Use these short codes:

| Code | Regime |
|---|---|
| `BI` | BrokerDominant_Assessment / information-heavy |
| `BA` | BrokerDominant_Access |
| `BD` | BrokerDominant_Dual |
| `RE` | RentExtraction |
| `UI` | Underadopted_Info |
| `FB` | FeeInducedBypass |
| `SS` | SelfSearchDominant |
| `M` | Mixed |

### 8.1 Threshold robustness maps

Required for `delta_rho` and `fee_cost`:

```text
regime_map_delta_rho_threshold_broker030.png
regime_map_delta_rho_threshold_broker070.png
regime_map_fee_cost_threshold_broker030.png
regime_map_fee_cost_threshold_broker070.png
```

Optional for the other sweeps.

## 9. Representative temporal overlay

Create:

```text
data/figures/broker_advantage/temporal_cases_overlay.png
```

Use representative cells selected after the main sweeps:

```text
broker-dominant cell
self-search-dominant cell
fee-induced-bypass or rent-extraction cell if found
access-heavy broker cell
boundary/mixed cell
```

Use 10–90% seed bands if the existing plotting stack can do them. If not, show thin seed lines and thick means, matching existing style.

Panel layout, 2×3 or 3×2:

| Panel | y-axis metric |
|---|---|
| Broker adoption | `pi_broker_slot` |
| Net channel value | `net_value_gap` |
| Prediction advantage | `rank_gap` |
| Welfare advantage | cumulative or final-window `delta_welfare_agents` if available |
| Access fraction | `access_new_edge_frac_brk` |
| Broker structural position | `betweenness` and optionally `constraint_b` / `eff_size_b` |

Every panel has `x = period` and a burn-in marker.

## 10. Advantage-dynamics dashboards

Create one dashboard for each key representative case:

```text
data/figures/broker_advantage/advantage_dynamics_broker_dominant.png
data/figures/broker_advantage/advantage_dynamics_self_search.png
```

Also create if applicable:

```text
advantage_dynamics_fee_bypass.png
advantage_dynamics_access_heavy.png
advantage_dynamics_boundary.png
```

Use a 4×4 layout.

### Row 1: adoption and matching volume

| Col | Title | Metrics |
|---|---|---|
| 1 | Broker slot share | `pi_broker_slot` |
| 2 | Demand by channel | `self_demand_slots`, `broker_demand_slots` |
| 3 | Fill rate by channel | `self_fill_rate`, `broker_fill_rate` |
| 4 | Matches by channel | existing `n_self_matches`, `n_broker_standard` or new filled-slot counts |

### Row 2: value

| Col | Title | Metrics |
|---|---|---|
| 1 | Conditional match quality | `q_self_mean_cond`, `q_broker_mean_cond` |
| 2 | Gross value per demanded slot | `q_self_per_demand_slot`, `q_broker_per_demand_slot` |
| 3 | Net value per demanded slot | `net_self_per_demand_slot`, `net_broker_per_demand_slot` |
| 4 | Net value gap | `net_value_gap` |

### Row 3: decomposition

| Col | Title | Metrics |
|---|---|---|
| 1 | Quality-selection contribution | `quality_selection_component` |
| 2 | Fill/access contribution | `fill_access_component` |
| 3 | Fee/cost contribution | `fee_cost_component` |
| 4 | Decomposition check | all three components plus `net_value_gap` if legible |

### Row 4: information and structure

| Col | Title | Metrics |
|---|---|---|
| 1 | Holdout rank gap | `rank_gap` |
| 2 | Holdout R² gap | `r2_gap` |
| 3 | History accumulation | `broker_history_size` and mean agent history size if available |
| 4 | Broker structure | `betweenness`, optionally `constraint_b`, `eff_size_b` |

If 4×4 is too dense using the existing plotting stack, split into two files:

```text
advantage_dynamics_<case>_market_value.png
advantage_dynamics_<case>_info_structure.png
```

## 11. Phase portraits

Create:

```text
data/figures/broker_advantage/phase_portraits_broker_dominant.png
data/figures/broker_advantage/phase_portraits_self_search.png
```

Additional cases optional.

Use a 2×2 layout:

| Panel | x-axis | y-axis | Purpose |
|---|---|---|---|
| Information vs adoption | `rank_gap` | `pi_broker_slot` | broker information adopted or ignored |
| Value vs adoption | `net_value_gap` | `pi_broker_slot` | EWMA adoption versus realized value |
| Structure vs information | `betweenness` | `rank_gap` | erosion versus informational compounding |
| Access vs assessment | `access_new_edge_frac_brk` | `assessment_prior_partner_frac_brk` | transition from access to assessment |

Connect period points in time order. Add arrows only if the existing plotting stack makes this easy; otherwise use a line with point markers.

## 12. Fee-sensitivity figure

Create:

```text
data/figures/broker_advantage/fee_sensitivity_curves.png
```

Use the `fee_cost` sweep. Plot curves over `broker_fee_rate`, with separate lines for selected `self_search_cost_rate` values.

Required panels:

| Panel | y-axis |
|---|---|
| Adoption | `pi_broker_slot` |
| Net value | `net_value_gap` |
| Prediction | `rank_gap` |
| Welfare | `delta_welfare_agents` if available |

This plot should make fee-induced bypass and rent-extraction regions visible without relying only on heatmaps.

## 13. Ablation plots

Create:

```text
data/figures/broker_advantage/ablation_bars.png
```

Bar chart grouped by ablation, optionally faceted by anchor cell.

Required metrics:

```text
pi_broker_slot
rank_gap
r2_gap
net_value_gap
delta_welfare_agents if available
access_new_edge_frac_brk
```

Use error bars for seed standard errors if available.

Also create:

```text
data/figures/broker_advantage/ablation_temporal_selected.png
```

This should compare Full, BlindBroker, NoAccessBroker, FrozenGraph, and FreezeBrokerLearning over time for one broker-dominant anchor.

## 14. Full-model confirmation plot

Create:

```text
data/figures/broker_advantage/full_confirm_comparison.png
```

Purpose: compare simplified-sweep classification to full-scale model classification.

Suggested layout:

| Panel | Content |
|---|---|
| 1 | Broker share: simplified vs full |
| 2 | Net value or welfare: simplified vs full |
| 3 | Rank gap: simplified vs full |
| 4 | Regime label table or categorical comparison |

The plot or companion summary must explicitly flag cells whose classification changes.

## 15. Sanity and pilot plots

### 15.1 Sanity diagnostics

Create:

```text
data/figures/broker_advantage/sanity_diagnostics.png
```

Recommended 2×4 layout:

```text
NoRegime prediction gap
PureQuality prediction gap
HardPairwise prediction gap
HighTransparency broker share
LowRosterAccess fill/adoption
HighFee net value/adoption
FreezeBrokerLearning rank gap
Accounting identity residuals
```

### 15.2 Pilot phase panels

Create:

```text
data/figures/broker_advantage/pilot_phase_panels.png
data/figures/broker_advantage/pilot_temporal_overlay.png
```

The pilot phase panel can be sparse because it has only five cells; use point/table style if a heatmap would be misleading.

## 16. Missing data handling

Rules:

```text
missing broker metrics when broker_demand_slots == 0
missing self metrics when self_demand_slots == 0
missing access/assessment fractions when no brokered matches occur
show valid seed count in summaries
hatch or mark cells with fewer than half valid seeds for a metric
```

Do not coerce undefined access fractions to zero.

## 17. Final figure checklist

The final broker-advantage plot suite must include:

```text
sanity_diagnostics.png
pilot_phase_panels.png
pilot_temporal_overlay.png

delta_rho_phase_panels.png
fee_cost_phase_panels.png
transparency_access_phase_panels.png
learning_turnover_phase_panels.png

regime_map_delta_rho.png
regime_map_fee_cost.png
regime_map_transparency_access.png
regime_map_learning_turnover.png

temporal_cases_overlay.png
advantage_dynamics_broker_dominant.png
advantage_dynamics_self_search.png
phase_portraits_broker_dominant.png
phase_portraits_self_search.png
fee_sensitivity_curves.png
ablation_bars.png
ablation_temporal_selected.png
full_confirm_comparison.png
```

If a required plot cannot be rendered because the necessary data were not generated, write a short note to:

```text
data/summaries/broker_advantage/missing_plots.md
```

The note should state which metric or cache is missing and which script should generate it.
