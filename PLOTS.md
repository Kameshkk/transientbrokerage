# Plot Inventory

Every figure produced by the `scripts/` tree, with the parameters used
and every panel's x-axis, y-axis, legend, and the specific column of the
metrics DataFrame that feeds it.

All runs use the `TransientBrokerage.jl` package; every draw is seeded.
Output directory is `data/figures/<subdir>/` relative to repo root,
created on first run.

### Model default parameters

From `default_params()` in `src/parameters.jl`. All scripts start from
this dictionary and apply per-config overrides. In what follows,
"default params" means this set.

```
N=1000, T=200, T_burn=30, d=8, s=8, k=6, p_rewire=0.1,
K=5, p_demand=0.50, rho=0.50, delta=0.5, sigma_x=0.5, sigma_eps=0.10,
omega=0.2, search_cost_rate=0.15, eta_lr=0.03, E_init=200,
h_a=16, h_b=32, n_strangers=5, eta=0.02, roster_churn=0.02,
alpha_R=0.20, enable_principal=false, network_measure_interval=20,
seed=42
```

### Global style conventions (`scripts/figure_style.jl`)

- Ensemble plots: thin per-seed lines (alpha 0.45) + thick ensemble
  mean (linewidth 2.5); the ensemble mean is NaN when fewer than half
  the seeds have valid data at that period.
- Smoothing: every time series is passed through a NaN-safe rolling
  mean with **window 20 periods** before plotting.
- Burn-in: vertical dashed line at `t = T_burn = 30`; all analysis
  summaries in the scripts aggregate over `period > T_burn`.
- Colors: `COL_AGENT=steelblue` (agents / self-search),
  `COL_BROKER=crimson` (broker / standard placement),
  `COL_CAPTURE=darkorange` (Model 1 principal mode),
  `COL_GAP=purple` (broker − agent gap),
  `COL_ACCESS=goldenrod`, `COL_REPUTATION=darkred`,
  `COL_DIAG=teal` (diagnostic counts),
  `COL_BASE_REF=gray60` (dashed gray base-model reference in capture
  plots).
- Variance gate: rows with `Var(q) < sigma_eps^2 / 6` are NaN-masked
  for R²/bias/rank columns so that winner's-curse prediction
  diagnostics don't dominate early periods.

---

## 1. `scripts/plot_type_curve.jl` — type curve visualization

**Purpose.** Show the 1D sinusoidal type curve on the unit sphere
together with 100 noisy agent-type draws, under a 3-D configuration for
visualization.

**Output.** `data/figures/type_curve_3d.png`. Figure size 1200×400.

**Parameters** (hard-coded in the script; *not* the model defaults):
- `d = 3`, `s = 3`, `sigma_x = 0.5`
- `n_curve = 500` smooth curve points, `n_agents = 100`
- `rng = StableRNG(42)`

**Panels (1×3 + colorbar).** Three orthogonal projections of the unit
sphere. In every panel curve points are connected by a thin line and
agent types are plotted as scatter; both are colored by depth along the
orthogonal axis (viridis).

| Panel | x-axis        | y-axis        | depth color       |
|-------|---------------|---------------|-------------------|
| XY    | dim 1 (X)     | dim 2 (Y)     | dim 3 (Z)         |
| XZ    | dim 1 (X)     | dim 3 (Z)     | dim 2 (Y)         |
| YZ    | dim 2 (Y)     | dim 3 (Z)     | dim 1 (X)         |

Panel 4: shared colorbar (viridis, label "Depth (orthogonal axis)").

---

## 2. `scripts/quick_diagnostic.jl` — single-seed dynamics check

**Purpose.** Fast sanity figure after code changes. One call to
`run_simulation(default_params())`.

**Output.** `data/figures/quick_diagnostic.png`. Figure size 1400×1600.

**Parameters.** `default_params()` exactly (`seed=42`); one seed,
`T=200`, no overrides. No rolling-mean smoothing in this script
(raw per-period series).

**Panels (4×2 grid).** All panels have `x = period (1..T)`. Sources are
DataFrame column names returned by `run_simulation`.

| Row,Col | Title                         | y-axis         | Lines (label → column, color)                             |
|---------|-------------------------------|----------------|-----------------------------------------------------------|
| 1,1     | Outsourcing Rate              | Rate           | outsourcing_rate (steelblue)                              |
| 1,2     | Holdout Prediction Quality R² | R²             | Broker→broker_holdout_r2 (crimson); Agent→agent_holdout_r2 (steelblue) |
| 2,1     | Betweenness Centrality (Broker) | C_B(broker)  | betweenness (steelblue)                                   |
| 2,2     | Mean Output by Channel        | Output         | Self→q_self_mean (steelblue); Broker (std)→q_broker_standard_mean (crimson) |
| 3,1     | Access Fraction of Brokered Matches | Fraction | access_count / (n_broker_standard + n_broker_principal) (darkorange) |
| 3,2     | Broker Access, Roster & History | Count        | Access set→broker_access_size (crimson); Standing roster→roster_size (steelblue, dashed); History→broker_history_size (darkorange) |
| 4,1     | Matches per Period            | Count          | Self→n_self_matches (steelblue); Broker (std)→n_broker_standard (crimson) |
| 4,2     | R² Gap (Broker − Agent)       | ΔR²            | r2_gap (purple) + horizontal zero line                    |

Stdout: `default_params` and simple means over the last 50 periods
(outsourcing rate, broker/agent holdout R², R² gap, betweenness, mean
output by channel, access-set size, roster size, broker history size,
total matches/period).

---

## 3. `scripts/explore_dgp.jl` — DGP-only (no time dynamics)

**Purpose.** Visualize the noiseless output matrix
`F[i,j] = Q + f(x_i, x_j)` for different matching-difficulty regimes
without running the simulation.

**Output directory.** `data/figures/dgp/`. Per config up to three files:
`{tag}_matrix.png`, `{tag}_svd.png`, `{tag}_regime.png`. JLD2 with
`F, G_regime, pc1, A, B, c, ...` saved to `data/dgp/{tag}.jld2`.

**Common parameters.** `default_params(seed=42)` with per-config override;
`N=1000` ⇒ 1000×1000 output matrix; agents sorted along rows/cols by
PC1 of their type vectors so the matrix shows block/low-rank structure.

**Config grid (12 configs).**

| tag                         | override                |
|-----------------------------|-------------------------|
| `baseline`                  | —                       |
| `rho00_pureinteraction`     | `rho=0.0`               |
| `rho10_weakquality`         | `rho=0.10`              |
| `rho30_mildinteraction`     | `rho=0.30`              |
| `rho70_mildquality`         | `rho=0.70`              |
| `rho90_strongquality`       | `rho=0.90`              |
| `rho100_purequality`        | `rho=1.0`               |
| `delta00_noregime`          | `delta=0.0`             |
| `delta25_weakregime`        | `delta=0.25`            |
| `delta75_strongregime`      | `delta=0.75`            |
| `s2_lowdim`                 | `s=2`                   |
| `s4_middim`                 | `s=4`                   |

### `{tag}_matrix.png` (figure size 800×650)

| Panel (row×col) | x-axis           | y-axis           | Content                                        |
|-----------------|------------------|------------------|------------------------------------------------|
| Top (1,1)       | Agent j (PC1 order), 1..N | Agent i (PC1 order), 1..N | Heatmap of `F`, RdBu, symmetric color range about mean(F); colorbar label "q = Q + signal" |
| Bottom (2,1)    | q                | Count            | Histogram of the upper triangle of `F` (80 bins, steelblue fill); dashed crimson vertical at `mean(vals)` |

### `{tag}_svd.png` (figure size 700×280)

Two panels side-by-side for the first `min(50, N)` singular values of
`F`:

| Panel | x-axis              | y-axis                       | Content                                              |
|-------|---------------------|------------------------------|------------------------------------------------------|
| 1     | Component (1..n_show) | sigma_k / sigma_1          | Normalized singular values, scatterlines (steelblue) |
| 2     | Number of components (0..n_show) | Fraction in [0, 1.05] | Cumulative variance explained, scatterlines (steelblue), gray dashed horizontals at 0.90 and 0.95 |

### `{tag}_regime.png` (figure size 700×600, only when `delta > 0`)

| Panel | x-axis               | y-axis               | Content                                                     |
|-------|----------------------|----------------------|-------------------------------------------------------------|
| 1,1   | Agent j (PC1 order)  | Agent i (PC1 order)  | Heatmap of `g(x_i, x_j) ∈ {1-δ, 1+δ}`, colormap RdYlGn, range `(1-δ-0.05, 1+δ+0.05)`; colorbar label "Gain" |

---

## 4. `scripts/explore_base_model.jl` — base-model dynamics sweep

**Purpose.** Full base-model dynamics (`enable_principal=false`) across
matching-difficulty configs, ensembled over seeds. This is the canonical
script for the base model.

**CLI.**
- `--baseline`: **run and plot only the `baseline` config** (all other
  configs skipped). Produces exactly four PNGs; see §4-baseline below.
- `--rerun`: force re-simulation, ignoring cached JLD2 at
  `data/sims/exploration/{tag}.jld2`.
- No flag: iterate all 14 configs below.

**Output directory.** `data/figures/exploration/`. Per config, four files:
`{tag}_dynamics.png`, `{tag}_network_stats.png`, `{tag}_matrix.png`,
`{tag}_svd.png`.

**Common simulation parameters.**
- `N = 1000`, `T = 200`, `T_burn = 30`
- `N_SEEDS = 5` (seeds `1..5`)
- `enable_principal = false`
- Rolling window for all time-series panels: **20 periods**
- All other params inherit from `default_params()` modulo per-config
  overrides

**Config grid (14 configs).**

| tag                         | override                |
|-----------------------------|-------------------------|
| `baseline`                  | —                       |
| `rho00_pureinteraction`     | `rho=0.0`               |
| `rho10_weakquality`         | `rho=0.10`              |
| `rho30_mildinteraction`     | `rho=0.30`              |
| `rho70_mildquality`         | `rho=0.70`              |
| `rho90_strongquality`       | `rho=0.90`              |
| `rho100_purequality`        | `rho=1.0`               |
| `delta00_noregime`          | `delta=0.0`             |
| `delta25_weakregime`        | `delta=0.25`            |
| `delta75_strongregime`      | `delta=0.75`            |
| `s2_lowdim`                 | `s=2`                   |
| `s4_middim`                 | `s=4`                   |
| `eta01_stable`              | `eta=0.01`              |
| `eta05_volatile`            | `eta=0.05`              |

### §4-baseline: Output when running `--baseline`

`julia --project --threads=auto scripts/explore_base_model.jl --baseline`
uses `default_params(seed=s, ...)` for `s in 1..5` (no other overrides),
`T=200`, `N=1000`, `T_burn=30`, `enable_principal=false`. Produces
exactly:

1. `data/figures/exploration/baseline_dynamics.png` — 5×4 dynamics
   panel. See §4-dynamics below.
2. `data/figures/exploration/baseline_network_stats.png` — 1×4 agent
   degree statistics. See §4-netstats below.
3. `data/figures/exploration/baseline_matrix.png` — DGP output matrix.
   Same panels as §3 `{tag}_matrix.png`, computed for
   `default_params(N=1000, seed=42)`.
4. `data/figures/exploration/baseline_svd.png` — DGP SVD spectrum,
   same panels as §3 `{tag}_svd.png`.

Also saves the ensemble of metric DataFrames to
`data/sims/exploration/baseline.jld2`. Stdout: summary means over the
last 50 periods pooled across seeds (outsourcing slot share, broker /
agent holdout R², R² gap, broker betweenness).

### §4-dynamics: `{tag}_dynamics.png` panels (5×4 + left row labels)

Figure size 1500×1100. All panels have `x = period (1..T)` unless noted.
Columns "Lines" read: `label → DataFrame column (color)`. For panels
with two lines the pair is (Agent, Broker). Every panel has a dashed
burn-in vertical at `t=T_burn=30`.

**Row 1 — Market.**

| Col | Title                              | y-axis  | y-limits    | Lines                                                                                                 |
|-----|------------------------------------|---------|-------------|-------------------------------------------------------------------------------------------------------|
| 1   | Outsourcing rate (slots)           | Rate    | [-0.02, 1.02] | outsourcing_rate (crimson)                                                                          |
| 2   | Matches by channel                 | Count   | [0, auto]   | Self→n_self_matches (steelblue); Broker→n_broker_standard (crimson)                                   |
| 3   | Total demand & matches             | Count   | [0, auto]   | Demand (slots)→total_demand (teal); Matches→n_total_matches (steelblue)                               |
| 4   | Available agents & broker access   | Count   | [0, auto]   | Available→n_available (teal); Broker access set→broker_access_size (crimson); Standing roster→roster_size (gray60, dashed) |

**Row 2 — Selected sample prediction quality** (over accepted matches
that period, so subject to winner's curse; two lines per panel: *Agents
(pooled)* steelblue, *Broker (pooled)* crimson).

| Col | Title                | y-axis     | y-limits      | Agent column / Broker column             |
|-----|----------------------|------------|---------------|------------------------------------------|
| 1   | Selected rank corr.  | Spearman ρ | [0, 1.02]     | agent_selected_rank / broker_selected_rank |
| 2   | Selected R²          | R²         | (auto, 1.02)  | agent_selected_r2 / broker_selected_r2; zero line |
| 3   | Selected RMSE        | RMSE       | [0, 1.02]     | agent_selected_rmse / broker_selected_rmse |
| 4   | Selected bias        | Bias       | auto          | agent_selected_bias / broker_selected_bias; zero line |

**Row 3 — Holdout sample prediction quality** (noiseless targets on
random partner samples, no selection bias; two lines per panel, same
colors as Row 2).

| Col | Title                | y-axis     | y-limits      | Agent column / Broker column             |
|-----|----------------------|------------|---------------|------------------------------------------|
| 1   | Holdout rank corr.   | Spearman ρ | [0, 1.02]     | agent_holdout_rank / broker_holdout_rank  |
| 2   | Holdout R²           | R²         | (auto, 1.02)  | agent_holdout_r2 / broker_holdout_r2; zero line |
| 3   | Holdout RMSE         | RMSE       | [0, 1.02]     | agent_holdout_rmse / broker_holdout_rmse  |
| 4   | Holdout bias         | Bias       | auto          | agent_holdout_bias / broker_holdout_bias; zero line |

**Row 4 — Advantage (broker − agent on holdout)**: single line per
panel, color `COL_GAP=purple`.

| Col | Title             | y-axis       | y-limits  | Column                          |
|-----|-------------------|--------------|-----------|---------------------------------|
| 1   | Holdout rank gap  | Δρ           | auto      | rank_gap; zero line             |
| 2   | Holdout R² gap    | ΔR²          | auto      | r2_gap; zero line               |
| 3   | Holdout RMSE gap  | ΔRMSE        | auto      | rmse_gap; zero line             |
| 4   | Access fraction   | Fraction     | [-0.02, 1.02] | access_count / (access_count + assessment_count), color goldenrod |

**Row 5 — Dynamics** (first three panels have `xlabel="Period"`;
fourth panel intentionally blank in base model).

| Col | Title                      | y-axis                    | y-limits   | Lines                                                                                    |
|-----|----------------------------|---------------------------|------------|------------------------------------------------------------------------------------------|
| 1   | Broker betweenness         | Betweenness centrality    | [0, 1.02]  | betweenness (crimson)                                                                    |
| 2   | Mean output by channel     | Output                    | [0, auto]  | Self→q_self_mean (steelblue); Broker→q_broker_standard_mean (crimson)                    |
| 3   | Satisfaction + reputation  | Satisfaction              | [0, auto]  | Self→mean_satisfaction_self (steelblue); Broker→mean_satisfaction_broker (crimson); Reputation→broker_reputation (darkred) |
| 4   | (empty)                    | —                         | —          | —                                                                                        |

Footer row: "Thin lines: individual seeds (N_SEEDS). Thick: ensemble
mean (shown when majority of seeds have data). Dashed vertical:
burn-in (t=T_burn). Smoothing: window-period rolling mean."

### §4-netstats: `{tag}_network_stats.png` panels (1×4)

Figure size 1500×360. All panels have `x = period`, `y = Degree`,
single-line plots in color `COL_DIAG=teal`, burn-in dashed at 30,
ensemble over 5 seeds.

| Col | Title         | Column          |
|-----|---------------|-----------------|
| 1   | Mean degree   | mean_degree     |
| 2   | Median degree | median_degree   |
| 3   | Min degree    | min_degree      |
| 4   | Max degree    | max_degree      |

### §4-dgp: `{tag}_matrix.png` and `{tag}_svd.png`

Generated from a fresh `default_params(N=1000, seed=42, <overrides>)`
draw, *not* from the simulation; same layout as §3.

---

## 5. `scripts/explore_phase_diagram.jl` — 2-D parameter heatmaps

**Purpose.** Steady-state heatmaps of key metrics across a 2-D parameter
grid, averaged over `period > T_burn` pooled across 5 seeds.

**CLI.**
- Positional arg: one of `rho_s` (default), `rho_eta`, `rho_delta`,
  `rho_snr`.
- `--m1`: also run with `enable_principal=true` and emit `m1_*` panels.
- `--rerun`: force re-simulation, ignoring
  `data/sims/phase_diagram/{sweep}.jld2`.

**Output directory.** `data/figures/phase_diagram/`, filenames
`{sweep}_base_{metric}.png` (and `{sweep}_m1_{metric}.png` with `--m1`).

**Common simulation parameters.**
- `N_run = 200` (smaller than base-model sweep to fit the grid budget)
- `T_run = 200`, `T_burn = 30`, `N_SEEDS = 5` (seeds `1..5`)
- All others = `default_params()` modulo per-cell override

**Sweep grids.** x-axis is always ρ; y-axis varies by sweep.

| sweep       | x: `rho`                                | y-axis label            | y values                                         |
|-------------|-----------------------------------------|-------------------------|--------------------------------------------------|
| `rho_s`     | 0, 0.10, 0.30, 0.50, 0.70, 0.90, 1.0    | `s` (active dimensions) | 2, 4, 6, 8                                       |
| `rho_eta`   | (same)                                  | `eta` (turnover)        | 0.01, 0.02, 0.03, 0.05, 0.07, 0.10               |
| `rho_delta` | (same)                                  | `delta` (regime gain)   | 0, 0.10, 0.25, 0.50, 0.75                        |
| `rho_snr`   | (same)                                  | `sigma_eps` (noise)     | 0.50, 0.30, 0.20, 0.10, 0.05, 0.025, 0.01        |

**Base-model panels.** Each is a single heatmap; figure size 700×500.
Per panel: `x = rho` (tick labels from the rho vector),
`y = <sweep y>` (tick labels from the y vector), `color = metric`.

| file                                  | Metric column       | colormap | color range         |
|---------------------------------------|---------------------|----------|---------------------|
| `{sweep}_base_r2_gap.png`             | r2_gap              | RdBu     | symmetric max\|M\|   |
| `{sweep}_base_broker_r2.png`          | broker_holdout_r2   | viridis  | data range          |
| `{sweep}_base_agent_r2.png`           | agent_holdout_r2    | viridis  | data range          |
| `{sweep}_base_outsourcing.png`        | outsourcing_rate    | YlOrRd   | [0, 1]              |
| `{sweep}_base_betweenness.png`        | betweenness         | viridis  | data range          |
| `{sweep}_base_broker_rank.png`        | broker_holdout_rank | viridis  | [0, 1]              |

**Model 1 panels (only with `--m1`).**

| file                                  | Metric column         | colormap | color range         |
|---------------------------------------|-----------------------|----------|---------------------|
| `{sweep}_m1_r2_gap.png`               | r2_gap                | RdBu     | symmetric           |
| `{sweep}_m1_principal_share.png`      | principal_mode_share  | YlOrRd   | [0, 1]              |
| `{sweep}_m1_outsourcing.png`          | outsourcing_rate      | YlOrRd   | [0, 1]              |
| `{sweep}_m1_betweenness.png`          | betweenness           | viridis  | data range          |

---

## 6. `scripts/explore_capture.jl` — Model 1 (resource-capture) dynamics sweep

**Purpose.** Full Model 1 dynamics (`enable_principal = true`) overlaid
on the corresponding base-model run (loaded from
`data/sims/exploration/{tag}.jld2`) as a dashed-gray reference. **Not
part of the base model.**

**CLI.** Same flags as `explore_base_model.jl` (`--baseline`,
`--rerun`). Ensembles 5 seeds, rolling window 20, burn-in line at 30,
same config grid (14 configs).

**Output directory.** `data/figures/capture/`. Primary file per config:
`{tag}_dynamics.png`. A supplementary `{tag}_suppl.png` is also
produced.

### §6-dynamics: `{tag}_dynamics.png` panels (5×4, size 1500×1100)

Same structure and x/y axes as §4-dynamics, with three additions:

- Matches-by-channel (Row 1, Col 2) gains a third line:
  `Broker (principal) → n_broker_principal (darkorange)`.
- Rows 1 (cols 3, 4), 3, and 4 also show a dashed gray `COL_BASE_REF`
  trace per panel, pulled from `data/sims/exploration/{tag}.jld2`
  (base-model ensemble mean). Legend entry "Base".
- Mean output by channel (Row 5, Col 2) gains a third line:
  `Broker (principal) → q_broker_principal_mean (darkorange)`.
- Row 5, Col 4 (empty in base model) is populated:

| Title                 | x-axis | y-axis | y-limits     | Line                                     |
|-----------------------|--------|--------|--------------|------------------------------------------|
| Principal-mode share  | Period | P^t    | [-0.02, 1.02]| principal_mode_share (darkorange); gray dotted horizontals at 0.0 and 1.0 |

### §6-suppl: `{tag}_suppl.png` panels (2×5, size 1800×600)

All panels have `x = period`, burn-in line, rolling-mean ensemble.
Single-line plots unless noted.

**Row 1 — Outcome & decision.**

| Col | Title                          | y-axis                    | y-limits      | Column (color)                  |
|-----|--------------------------------|---------------------------|---------------|----------------------------------|
| 1   | Mean capture surplus Δq̄       | q_ij − q̄_j               | auto          | capture_surplus_mean (darkorange); zero line |
| 2   | Capture loss rate              | share with Δq < 0         | [-0.02, 1.02] | capture_loss_rate (darkorange)   |
| 3   | Capture loss magnitude         | mean \|Δq\| \| Δq<0       | [0, auto]     | capture_loss_magnitude (darkorange) |
| 4   | Capture decision rank corr.    | Spearman ρ(Δq̂, Δq)       | [-1.02, 1.02] | capture_decision_rank (purple); zero line |
| 5   | Capture decision RMSE          | RMSE(q̂_b, q_ij) \| principal | [0, auto] | capture_decision_rmse (purple)   |

**Row 2 — Broker dependency across agents + end-state histogram.**

| Col | Title                                        | y-axis    | y-limits      | Column (color)                          |
|-----|----------------------------------------------|-----------|---------------|------------------------------------------|
| 1   | Mean broker dependency D_j                   | mean D_j  | [-0.02, 1.02] | broker_dependency_mean (crimson)         |
| 2   | D_j 90th percentile                          | D_j p90   | [-0.02, 1.02] | broker_dependency_p90 (crimson)          |
| 3   | Fraction of agents with D_j > 0.5            | share     | [-0.02, 1.02] | broker_dependency_frac_above_half (crimson) |
| 4   | Gini coefficient of D_j                      | Gini      | [-0.02, 1.02] | broker_dependency_gini (crimson)         |
| 5   | Mean Δq̄ distribution (last `hist_window=20` periods) | density (PDF) | auto   | Histogram of `capture_surplus_mean` pooled over the last 20 periods across all seeds; vertical line at pooled mean (darkorange); `x = mean Δq̄` |

---

## 7. `scripts/benchmark.jl` — runtime profiling

No plots. Emits timing tables to stdout; listed for completeness.

---

## Data caching

Every long-running script writes JLD2 under `data/sims/<subdir>/` so
subsequent invocations only re-render the plots:

- `data/sims/exploration/{tag}.jld2` — 5-seed metric DataFrames from
  `explore_base_model.jl`. Pass `--rerun` to force re-simulation.
- `data/sims/phase_diagram/{sweep}.jld2` — steady-state grid from
  `explore_phase_diagram.jl` (`base_results`, optional `m1_results`,
  the axis vectors). Pass `--rerun` to force re-simulation.
- `data/sims/capture/{tag}.jld2` — Model 1 ensemble from
  `explore_capture.jl`.
- `data/dgp/{tag}.jld2` — raw `F`, `G_regime`, and `A`, `B`, `c` from
  `explore_dgp.jl`.
