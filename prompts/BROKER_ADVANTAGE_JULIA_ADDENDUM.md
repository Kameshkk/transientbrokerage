# Julia Implementation Notes for Broker-Advantage Analyses

This file is now a short addendum. The main instructions are integrated into:

```text
BROKER_ADVANTAGE_AGENT_RUNBOOK.md
BROKER_ADVANTAGE_ANALYSIS_SPEC.md
BROKER_ADVANTAGE_INSTRUMENTATION_SPEC.md
BROKER_ADVANTAGE_PLOTTING_SPEC.md
```

## 1. Core instruction

Use the existing Julia repository and its current libraries. Do not port the analysis to Python. Do not add new Julia dependencies unless the existing environment cannot perform a required task.

Expected existing infrastructure:

```text
TransientBrokerage.jl package
src/parameters.jl with default_params()
scripts/quick_diagnostic.jl
scripts/explore_base_model.jl
scripts/explore_phase_diagram.jl
scripts/figure_style.jl
JLD2 simulation caches
figures under data/figures/<subdir>/
```

## 2. New scripts

Add:

```text
scripts/run_broker_advantage.jl
scripts/plot_broker_advantage.jl
```

Optional:

```text
scripts/summarize_broker_advantage.jl
```

These scripts should mirror the existing `scripts/explore_*.jl` conventions rather than introducing a separate framework.

## 3. Libraries

Use packages already present in the repository. Likely examples include:

```text
Random / StableRNGs if already used
Statistics
LinearAlgebra
DataFrames if already used
JLD2 if already used
CSV if already used
existing plotting package and figure_style.jl
Threads or Distributed if already used
```

Do not add `SALib`, Python, or a new plotting library. The Morris screen mentioned in earlier planning is optional and should be skipped unless it can be done natively with existing tools. The required fixed grids are sufficient.

## 4. Performance notes

For Julia performance:

```text
avoid DataFrame mutation inside the inner simulation loop
collect numeric vectors and build DataFrames after each run
avoid global RNGs in threaded loops
precompute stable quantities only when memory permits
use @views and broadcasting where natural, not as a rewrite mandate
```

Correctness and compatibility come before optimization.

## 5. Backward compatibility

Existing commands must remain valid:

```bash
julia --project --threads=auto scripts/quick_diagnostic.jl
julia --project --threads=auto scripts/explore_base_model.jl --baseline
julia --project --threads=auto scripts/explore_phase_diagram.jl rho_delta
```

The new fee/cost split must default to old behavior when the new parameters are not supplied:

```text
broker_fee_rate = search_cost_rate
self_search_cost_rate = search_cost_rate
```

## 6. Superseded guidance

Any earlier instruction that implied Python packages, Python plotting, or external sensitivity-analysis libraries should be treated as conceptual only. The current implementation path is native Julia using the existing repository environment.
