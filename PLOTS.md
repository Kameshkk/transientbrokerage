# Plot Inventory

Every figure produced by the `scripts/` tree, with the parameters used to
generate it. Output directory is `data/figures/<subdir>/` relative to repo
root (created on first run). All runs use the `TransientBrokerage.jl`
package; seeds are fully deterministic given the settings below.

Defaults referenced here come from `default_params()` in
`src/parameters.jl`: `N=1000, T=200, T_burn=30, d=8, s=8, k=6, p_rewire=0.1,
K=5, p_demand=0.50, rho=0.50, delta=0.5, sigma_x=0.5, sigma_eps=0.10,
omega=0.2, search_cost_rate=0.15, eta_lr=0.03, E_init=200, h_a=16, h_b=32,
n_strangers=5, eta=0.02, roster_churn=0.02, alpha_R=0.20, seed=42`.

---

## 1. `scripts/plot_type_curve.jl` — type curve visualization

**Purpose.** Show the 1D sinusoidal agent-type curve on the unit sphere and
the noisy agent draws around it.

**Output.** `data/figures/type_curve_3d.png` — three orthogonal projections
(XY, XZ, YZ) of the curve + 100 sampled agent types, color = depth along the
orthogonal axis.

**Parameters** (hard-coded in script, NOT the model defaults):
- `d = 3`, `s = 3` (so the curve is visualizable)
- `sigma_x = 0.5`, `n_curve = 500` curve points, `n_agents = 100`
- `rng = StableRNG(42)`

---

## 2. `scripts/quick_diagnostic.jl` — single-seed dynamics check

**Purpose.** Fast sanity figure after code changes. One run of `run_simulation`.

**Output.** `data/figures/quick_diagnostic.png` — 4×2 multi-panel:
(1) outsourcing rate; (2) holdout R² broker vs. agent; (3) broker
betweenness; (4) mean output by channel; (5) access-fraction of brokered
matches; (6) access-set / roster / broker-history sizes; (7) match counts
by channel; (8) R² gap (broker − agent).

**Parameters.** `default_params()` with `seed=42`; a single seed, `T=200`.

---

## 3. `scripts/explore_dgp.jl` — DGP-only (no simulation) sweep

**Purpose.** Visualize the noiseless output matrix $F_{ij} = Q + f(\mathbf{x}_i, \mathbf{x}_j)$ across
parameters that control matching difficulty; no time dynamics.

**Output directory.** `data/figures/dgp/`. Three files per config:
- `{tag}_matrix.png` — heatmap of $F$ (rows/cols sorted by PC1 of
  type vectors) + histogram of upper-triangle values.
- `{tag}_svd.png` — normalized singular values + cumulative variance,
  with 90%/95% rule lines.
- `{tag}_regime.png` — heatmap of the regime gain $g(\mathbf{x}_i,\mathbf{x}_j) \in \{1-\delta, 1+\delta\}$
  (skipped when `delta = 0`).

**Common parameters.** `default_params(seed=42, ...)` with `N=1000`, i.e.
$1000 \times 1000$ matrices.

**Config grid** (12 configs, each overriding defaults):

| tag                         | override                |
|-----------------------------|-------------------------|
| `baseline`                  | none                    |
| `rho00_pureinteraction`     | `rho = 0.0`             |
| `rho10_weakquality`         | `rho = 0.10`            |
| `rho30_mildinteraction`     | `rho = 0.30`            |
| `rho70_mildquality`         | `rho = 0.70`            |
| `rho90_strongquality`       | `rho = 0.90`            |
| `rho100_purequality`        | `rho = 1.0`             |
| `delta00_noregime`          | `delta = 0.0`           |
| `delta25_weakregime`        | `delta = 0.25`          |
| `delta75_strongregime`      | `delta = 0.75`          |
| `s2_lowdim`                 | `s = 2`                 |
| `s4_middim`                 | `s = 4`                 |

Data also saved per config as `data/dgp/{tag}.jld2`.

---

## 4. `scripts/explore_base_model.jl` — base-model dynamics sweep

**Purpose.** Full base-model (`enable_principal=false`) dynamics across
matching-difficulty configs, ensembled over seeds.

**Output directory.** `data/figures/exploration/`. Four files per config:
- `{tag}_dynamics.png` — 5×4 panel grid:
  * **Row 1 (Market):** outsourcing-rate slots; match counts by channel;
    total demand + total matches; available agents, broker access set,
    standing roster.
  * **Row 2 (Selected):** rank correlation, R², RMSE, and bias on
    matched-sample predictions (broker vs. agent).
  * **Row 3 (Holdout):** same four metrics on the random-holdout sample.
  * **Row 4 (Advantage):** holdout rank gap, R² gap, RMSE gap, access
    fraction of brokered matches.
  * **Row 5 (Dynamics):** broker betweenness; mean output by channel;
    mean self-satisfaction + mean broker-satisfaction + broker
    reputation; (4th panel empty in base model).
  Ensembles over 5 seeds with a rolling window of 20 periods; dashed
  burn-in line at period 30.
- `{tag}_network_stats.png` — 1×4 agent-network degree statistics
  (mean / median / min / max degree per period).
- `{tag}_matrix.png` — DGP output matrix heatmap (same as `explore_dgp`).
- `{tag}_svd.png` — DGP SVD spectrum (same as `explore_dgp`).

**Common parameters.**
- `N = 1000`, `T = 200`, `N_SEEDS = 5` (seeds `1..5`)
- `T_burn = 30`, rolling window `= 20`
- `enable_principal = false` (base model)
- All other params = `default_params()` modulo the per-config override

**Config grid** (14 configs, each overriding defaults):

| tag                         | override              |
|-----------------------------|-----------------------|
| `baseline`                  | none                  |
| `rho00_pureinteraction`     | `rho = 0.0`           |
| `rho10_weakquality`         | `rho = 0.10`          |
| `rho30_mildinteraction`     | `rho = 0.30`          |
| `rho70_mildquality`         | `rho = 0.70`          |
| `rho90_strongquality`       | `rho = 0.90`          |
| `rho100_purequality`        | `rho = 1.0`           |
| `delta00_noregime`          | `delta = 0.0`         |
| `delta25_weakregime`        | `delta = 0.25`        |
| `delta75_strongregime`      | `delta = 0.75`        |
| `s2_lowdim`                 | `s = 2`               |
| `s4_middim`                 | `s = 4`               |
| `eta01_stable`              | `eta = 0.01`          |
| `eta05_volatile`            | `eta = 0.05`          |

Flags: `--baseline` (only run baseline), `--rerun` (force re-sim, ignore
JLD2 cache at `data/sims/exploration/{tag}.jld2`).

---

## 5. `scripts/explore_phase_diagram.jl` — 2-D parameter heatmaps

**Purpose.** Steady-state heatmaps of key metrics over a 2-D grid.

**Output directory.** `data/figures/phase_diagram/`. Filename pattern
`{sweep}_base_{metric}.png`; with `--m1` flag also
`{sweep}_m1_{metric}.png`.

**Common parameters.** `N = 200`, `T = 200`, `T_burn = 30`,
`N_SEEDS = 5` (seeds `1..5`), all others = `default_params()`. Per-cell
overrides come from the sweep axes.

**Sweep grids.** One chosen per invocation; x-axis is always ρ.

| sweep (CLI arg) | x: rho values                              | y: axis                 | y values                                   |
|-----------------|--------------------------------------------|-------------------------|--------------------------------------------|
| `rho_s` (def.)  | 0, 0.10, 0.30, 0.50, 0.70, 0.90, 1.0       | `s` (active dims)       | 2, 4, 6, 8                                 |
| `rho_eta`       | (same)                                     | `eta` (turnover)        | 0.01, 0.02, 0.03, 0.05, 0.07, 0.10         |
| `rho_delta`     | (same)                                     | `delta` (regime gain)   | 0, 0.10, 0.25, 0.50, 0.75                  |
| `rho_snr`       | (same)                                     | `sigma_eps` (noise)     | 0.50, 0.30, 0.20, 0.10, 0.05, 0.025, 0.01  |

Each cell ensembles 5 seeds; the metric is averaged over periods
$> T_{\text{burn}}$ pooled across seeds.

**Metrics plotted (base model).**
- `r2_gap` (broker − agent holdout R²) — RdBu, symmetric range
- `broker_r2`, `agent_r2` — viridis
- `outsourcing` rate — YlOrRd, `[0, 1]`
- `betweenness` of the broker node — viridis
- `broker_rank` (broker holdout rank correlation) — viridis, `[0, 1]`

With `--m1` (resource-capture variant), four additional panels per sweep:
`m1_r2_gap`, `m1_principal_share`, `m1_outsourcing`, `m1_betweenness`.

Flags: `--rerun` (ignore JLD2 cache at
`data/sims/phase_diagram/{sweep}.jld2`), `--m1` (also run principal mode).

---

## 6. `scripts/explore_capture.jl` — Model 1 (resource-capture) dynamics sweep

**Purpose.** Full Model 1 dynamics with `enable_principal = true`, overlaid
on the corresponding base-model run as a dashed-gray reference curve.
**Not part of the base model.** Mirrors `explore_base_model.jl` in layout.

**Output directory.** `data/figures/capture/`. Per config a 5×? panel
`{tag}_dynamics.png` (same rows as base model, plus principal-mode
metrics — e.g. principal-share, capture counts, broker-side realized
surplus).

**Common parameters.** Same as `explore_base_model.jl` (`N = 1000`, `T = 200`,
`N_SEEDS = 5`, `T_burn = 30`), except `enable_principal = true`. Same
config grid as `explore_base_model.jl`. Base-model reference data is
loaded from `data/sims/exploration/{tag}.jld2` when available.

Flags: `--baseline`, `--rerun`.

---

## 7. `scripts/benchmark.jl` — runtime profiling

No plots — emits timing tables to stdout. Listed for completeness.

---

## Shared style / conventions

Defined in `scripts/figure_style.jl` and used by `explore_base_model.jl`
and `explore_capture.jl`:
- Ensembles are drawn as mean-over-seeds of a rolling mean with window
  `= 20` periods; per-seed traces are not shown.
- Burn-in period (`T_burn = 30`) is indicated by a vertical dashed line.
- Color conventions: `COL_AGENT` (agents / self-search),
  `COL_BROKER` (broker / standard placement), `COL_GAP` (broker − agent
  gap), `COL_DIAG` (diagnostic counts), `COL_BASE_REF` (dashed gray
  base-model reference).
- Missing / undefined values are NaN-skipped in means; the variance
  gate `Var(q) < sigma_eps^2 / 6` masks under-informative rows.

## Data caching

Each long-running script writes JLD2 under `data/sims/...` so reruns just
re-plot unless `--rerun` is passed. Phase-diagram and exploration runs
share this pattern; DGP plots save `data/dgp/{tag}.jld2` with the raw
output and regime matrices for offline inspection.
