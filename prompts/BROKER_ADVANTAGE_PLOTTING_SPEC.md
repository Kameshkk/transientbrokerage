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

Follow existing style conventions from the repository (`scripts/figure_style.jl` — same file as in the reference repo at `~/workspace/transientbrokerage/scripts/figure_style.jl`):

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
self / agents:       existing agent color   (COL_AGENT    = :steelblue)
broker:              existing broker color  (COL_BROKER   = :crimson)
gap metrics:         existing gap color     (COL_GAP      = :purple)
access metrics:      existing access color  (COL_ACCESS   = :goldenrod)
diagnostic counts:   existing diagnostic color (COL_DIAG  = :teal)
```

If the existing style file does not expose a needed color, define it locally in `plot_broker_advantage.jl` without changing old figures.

### 3.1 Output format — PDF (vector)

**All broker-advantage figures MUST be written as PDF**, not PNG. PDF keeps text as selectable vector text and scales losslessly when included in the LaTeX writeup. Use `save("path/file.pdf", fig)` with CairoMakie; do not set a raster `px_per_unit` multiplier that would bitmap the contents. Exception: pre-existing exploration scripts (`scripts/quick_diagnostic.jl`, `scripts/explore_base_model.jl`, `scripts/explore_phase_diagram.jl`) may keep their PNG outputs because they are legacy and checked against byte-identical preflight numbers.

File extension convention in this spec and the runbook: `.pdf` everywhere under `data/figures/broker_advantage/`.

### 3.2 Publication quality — A4 sheets, readable fonts

Figures are intended for inclusion in a manuscript laid out on A4 (210 × 297 mm). The LaTeX text width at 1-inch margins is ~160 mm (~6.3 in); figures should render cleanly at that width with no manual downscaling required. Font sizes must remain legible when the figure is scaled to fit the column.

**Required font-size floors** (CairoMakie `fontsize` values, points):

| Element              | Minimum size |
|----------------------|--------------|
| Suptitle / figure title | 16 pt      |
| Panel title             | 14 pt      |
| Axis x/y label          | 13 pt      |
| Tick label              | 12 pt      |
| Legend label            | 12 pt      |
| Footer / caption note   | 10 pt      |
| Text annotations in panels (regime codes, cell labels) | 11 pt |

These are floors. On dense multi-panel grids (e.g. 3×3 or 4×4) use the floor values; on sparse figures (1×1, 2×2) you may go 2 pt larger.

The current `scripts/figure_style.jl` constants (SUPTITLE_FS=16, TITLE_FS=12, LABEL_FS=10, TICK_FS=9) are too small for this target. Either raise those constants (breaking change for existing figures) or define publication-scale overrides inside `plot_broker_advantage.jl`:

```julia
const PUB_SUPTITLE_FS = 16
const PUB_TITLE_FS    = 14
const PUB_LABEL_FS    = 13
const PUB_TICK_FS     = 12
const PUB_LEG_FS      = 12
const PUB_FOOTER_FS   = 10
```

**Figure physical dimensions.** CairoMakie `size=(W, H)` is in points when saving PDF with default `pt_per_unit=1`. Target the LaTeX text width of ~460 pt (~160 mm). Use these defaults unless the figure is clearly half-column:

| Layout          | Suggested `size` (points) |
|-----------------|---------------------------|
| 1×1 single panel         | `(460, 340)`   (~160 × 120 mm) |
| 2×2 grid                 | `(460, 420)`   (~160 × 148 mm) |
| 2×3 grid (temporal overlays) | `(620, 360)` (~219 × 127 mm; accept 2-column or landscape float) |
| 3×3 grid (phase panels)  | `(620, 620)`   (landscape or full-page float) |
| 4×4 grid (advantage dynamics) | `(760, 760)` (full-page float, ~268 × 268 mm; place on own page) |

**Line widths** must remain visible at print scale: seed lines ≥ 0.8 pt (alpha 0.45), ensemble means ≥ 2.0 pt, zero-reference lines ≥ 1.0 pt (dashed, gray).

**Axis tick density.** No more than 6 major ticks per axis on small panels (< 80 mm). Use `xticks=0:step:T` with `step` chosen so text labels do not overlap; rotate tick labels 30° or 45° only when labels are inherently long (sweep cell IDs).

**Legends.** Place outside the plot area when the plot has thin lines or small markers. Legend `framewidth = 0.5`, `patchsize = (12, 12)`. Never let a legend cover axes.

**Colorbars.** Always attach to heatmaps. Width 8 pt. Tick labels at `PUB_TICK_FS`.

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
data/figures/broker_advantage/<sweep>_phase_panels.pdf
```

Required files:

```text
delta_rho_phase_panels.pdf
fee_cost_phase_panels.pdf
transparency_access_phase_panels.pdf
learning_turnover_phase_panels.pdf
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
data/figures/broker_advantage/regime_map_delta_rho.pdf
data/figures/broker_advantage/regime_map_fee_cost.pdf
data/figures/broker_advantage/regime_map_transparency_access.pdf
data/figures/broker_advantage/regime_map_learning_turnover.pdf
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
regime_map_delta_rho_threshold_broker030.pdf
regime_map_delta_rho_threshold_broker070.pdf
regime_map_fee_cost_threshold_broker030.pdf
regime_map_fee_cost_threshold_broker070.pdf
```

Optional for the other sweeps.

## 9. Representative temporal overlay

Create:

```text
data/figures/broker_advantage/temporal_cases_overlay.pdf
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
data/figures/broker_advantage/advantage_dynamics_broker_dominant.pdf
data/figures/broker_advantage/advantage_dynamics_self_search.pdf
```

Also create if applicable:

```text
advantage_dynamics_fee_bypass.pdf
advantage_dynamics_access_heavy.pdf
advantage_dynamics_boundary.pdf
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
advantage_dynamics_<case>_market_value.pdf
advantage_dynamics_<case>_info_structure.pdf
```

## 11. Phase portraits

Create:

```text
data/figures/broker_advantage/phase_portraits_broker_dominant.pdf
data/figures/broker_advantage/phase_portraits_self_search.pdf
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
data/figures/broker_advantage/fee_sensitivity_curves.pdf
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
data/figures/broker_advantage/ablation_bars.pdf
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
data/figures/broker_advantage/ablation_temporal_selected.pdf
```

This should compare Full, BlindBroker, NoAccessBroker, FrozenGraph, and FreezeBrokerLearning over time for one broker-dominant anchor.

## 14. Full-model confirmation plot

Create:

```text
data/figures/broker_advantage/full_confirm_comparison.pdf
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
data/figures/broker_advantage/sanity_diagnostics.pdf
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
data/figures/broker_advantage/pilot_phase_panels.pdf
data/figures/broker_advantage/pilot_temporal_overlay.pdf
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
fee_sensitivity_curves.pdf
ablation_bars.pdf
ablation_temporal_selected.pdf
full_confirm_comparison.pdf
```

If a required plot cannot be rendered because the necessary data were not generated, write a short note to:

```text
data/summaries/broker_advantage/missing_plots.md
```

The note should state which metric or cache is missing and which script should generate it.

## 18. Figures required in the writeup PDF report

The LaTeX report at `writeup/broker_advantage_progress.tex` MUST `\includegraphics{}` the following figures as first-class content (not just reference them in prose). All paths below are relative to the repo root; use `\graphicspath{{../data/figures/broker_advantage/}}` in the preamble so the file names alone suffice in the body.

**Required (priority 1):** must appear in the writeup as numbered figures with captions.

| Figure file                              | Where it belongs in the writeup |
|------------------------------------------|---------------------------------|
| `delta_rho_phase_panels.pdf`             | §Phase C3 sweeps — §delta_rho subsection |
| `fee_cost_phase_panels.pdf`              | §Phase C3 sweeps — §fee_cost subsection |
| `transparency_access_phase_panels.pdf`   | §Phase C3 sweeps — §transparency_access subsection |
| `learning_turnover_phase_panels.pdf`     | §Phase C3 sweeps — §learning_turnover subsection |
| `regime_map_delta_rho.pdf`               | next to the delta_rho phase panels |
| `fee_sensitivity_curves.pdf`             | §Summary of findings (part (ii) Fee-induced bypass) |
| `ablation_bars.pdf`                      | §Phase C4 ablations (next to Table~\ref{tab:c4}) |
| `full_confirm_comparison.pdf`            | §Stage 4 full-scale confirmation |
| `temporal_cases_overlay.pdf`             | §Summary of findings |

**Recommended (priority 2):** include in an appendix or a "supplementary figures" section.

| Figure file                              |
|------------------------------------------|
| `regime_map_fee_cost.pdf`, `regime_map_transparency_access.pdf`, `regime_map_learning_turnover.pdf` |
| `regime_map_delta_rho_threshold_broker{030,070}.pdf` (threshold robustness) |
| `regime_map_fee_cost_threshold_broker{030,070}.pdf` |
| `advantage_dynamics_broker_dominant.pdf`, `advantage_dynamics_self_search.pdf` |
| `phase_portraits_broker_dominant.pdf`, `phase_portraits_self_search.pdf` |
| `ablation_temporal_selected.pdf` |
| `sanity_diagnostics.pdf`, `pilot_phase_panels.pdf`, `pilot_temporal_overlay.pdf` |

**LaTeX pattern to use** (reference repo style; see `~/workspace/transientbrokerage/model_description.tex` preamble for typography):

```latex
% preamble
\usepackage[letterpaper,margin=1in]{geometry}  % or [a4paper,margin=25mm]
\usepackage{graphicx}
\graphicspath{{../data/figures/broker_advantage/}}

% body
\begin{figure}[t]
  \centering
  \includegraphics[width=\linewidth]{delta_rho_phase_panels.pdf}
  \caption{\texttt{delta\_rho} sweep phase panels. $\pi_b$, $\Delta W_{\text{ag}}$, net-value gap, rank/$R^2$ gaps, access/assessment fractions, and regime code over the 4$\times$5 grid. Values from \texttt{data/summaries/broker\_advantage/delta\_rho\_cell\_summaries.csv}.}
  \label{fig:dr-panels}
\end{figure}
```

Use `\linewidth` (the current column/page width) rather than hard-coded `\textwidth` so the figure fits whether the document is single-column or two-column. For 3×3 and 4×4 grids that exceed `\linewidth` naturally, use `[p]` or `[h!]` placement and a full-page float with `\includegraphics[width=\textwidth]{...}`.

**Do not resize below natural size** with `width=0.5\linewidth` unless the figure is already designed at that aspect ratio. Downscaling a 460 pt figure to 230 pt halves the on-paper font size.

**Captions** always cite the CSV row or specific metric they summarize (per the repo's data-integrity rule). Use `\texttt{...}` for file paths and column names.

**Cross-reference** figures with `\ref{fig:...}` from the Summary of findings section; every claim that depends on a visible pattern should name the figure by label.
