"""
    run_broker_advantage.jl

Driver for the broker-advantage study (BROKER_ADVANTAGE_AGENT_RUNBOOK.md).

Supported stages:
    sanity          — seven controlled corners, per runbook §8.
    pilot           — 5 (delta, rho) cells, 10 seeds, treatment + no-broker control.
    sweep           — one of {delta_rho, fee_cost, transparency_access, learning_turnover}.
    ablation        — 8 ablation modes × anchor cells, 15 seeds.
    full_confirm    — selected cells at original-scale settings.

Key output directories (created on first run):

    data/sims/broker_advantage/<stage>[/<sweep>]/cell_<cellid>_seed_<seed>_arm_<arm>.jld2
    data/sims/broker_advantage/<stage>[/<sweep>].jld2     — stage-level reduce output
    data/summaries/broker_advantage/<stage>[_<sweep>]_*.csv
    data/figures/broker_advantage/                       — populated by plot_broker_advantage.jl

CLI:

    --stage <sanity|pilot|sweep|ablation|full_confirm>   (required)
    --sweep <delta_rho|fee_cost|transparency_access|learning_turnover>  (required for --stage sweep)
    --cell-idx <N>          run only cell N of the selected stage/sweep (0-indexed). Used for sbatch arrays.
    --seed <S>              optional seed override (applied to every run; overrides per-cell defaults).
    --rerun                 ignore existing per-cell JLD2 caches and re-simulate.
    --reduce                do not simulate; read all cell JLD2s for the stage/sweep and write stage-level cache + CSVs.
    --help                  print usage and exit.

Design notes:
  - Each (cell, seed, arm) pair runs independently and writes its own small JLD2
    file so large sweeps can be parallelised across cluster nodes via a slurm
    job array (1 cell per task). `--reduce` stitches the pieces into a
    stage-level cache at the end.
  - Identity checks from §11.1 of della_job_guide.md run after every simulation;
    failures abort with a clear message.
  - `ablation=:NoBroker` is the paired control arm; RNG seed is shared between
    treatment and control so market/initialization shocks line up. Match-noise
    divergence after the first broker match is documented per
    BROKER_ADVANTAGE_INSTRUMENTATION_SPEC §5 "acceptable initial implementation".
"""

using TransientBrokerage
using DataFrames: DataFrame, nrow, select
using JLD2
using Statistics: mean, std, quantile
using Printf: @sprintf, @printf
using Base: Filesystem

# ─────────────────────────────────────────────────────────────────────────────
# Paths
# ─────────────────────────────────────────────────────────────────────────────

const REPO_ROOT = normpath(joinpath(@__DIR__, ".."))
const SIMS_ROOT = joinpath(REPO_ROOT, "data", "sims", "broker_advantage")
const FIG_ROOT  = joinpath(REPO_ROOT, "data", "figures", "broker_advantage")
const SUM_ROOT  = joinpath(REPO_ROOT, "data", "summaries", "broker_advantage")
foreach(mkpath, [SIMS_ROOT, FIG_ROOT, SUM_ROOT])

# ─────────────────────────────────────────────────────────────────────────────
# CLI parsing
# ─────────────────────────────────────────────────────────────────────────────

const USAGE = """
Usage:
    julia --project --threads=auto scripts/run_broker_advantage.jl \\
        --stage {sanity|pilot|sweep|ablation|full_confirm} \\
        [--sweep {delta_rho|fee_cost|transparency_access|learning_turnover}] \\
        [--cell-idx N] [--seed S] [--rerun] [--reduce]
"""

function parse_args(argv::Vector{String})
    args = Dict{Symbol, Any}(
        :stage => nothing,
        :sweep => nothing,
        :cell_idx => nothing,
        :seed => nothing,
        :arm => nothing,
        :rerun => false,
        :reduce => false,
    )
    i = 1
    while i <= length(argv)
        a = argv[i]
        if a in ("--help", "-h")
            println(USAGE); exit(0)
        elseif a == "--stage"
            args[:stage] = Symbol(argv[i+1]); i += 2
        elseif a == "--sweep"
            args[:sweep] = Symbol(argv[i+1]); i += 2
        elseif a == "--cell-idx"
            args[:cell_idx] = parse(Int, argv[i+1]); i += 2
        elseif a == "--seed"
            args[:seed] = parse(Int, argv[i+1]); i += 2
        elseif a == "--arm"
            args[:arm] = Symbol(argv[i+1]); i += 2
        elseif a == "--rerun"
            args[:rerun] = true; i += 1
        elseif a == "--reduce"
            args[:reduce] = true; i += 1
        else
            error("Unknown argument: $a\n$USAGE")
        end
    end
    args[:stage] === nothing && error("--stage is required\n$USAGE")
    args[:stage] in (:sanity, :pilot, :sweep, :ablation, :full_confirm, :diagnostic, :diagnostic_blind) ||
        error("unknown --stage $(args[:stage]); expected one of sanity|pilot|sweep|ablation|full_confirm|diagnostic|diagnostic_blind")
    if args[:stage] == :sweep
        args[:sweep] === nothing && error("--sweep required when --stage sweep")
        args[:sweep] in (:delta_rho, :fee_cost, :transparency_access, :learning_turnover) ||
            error("unknown --sweep $(args[:sweep])")
    end
    return args
end

# ─────────────────────────────────────────────────────────────────────────────
# Stage configurations
# ─────────────────────────────────────────────────────────────────────────────

# Simplified-scale defaults used by sanity / pilot / all sweeps / ablations.
const SIMPLIFIED = (
    N = 300, d = 6, s = 6, k = 4, T = 120, T_burn = 20,
    network_measure_interval = 5, E_init = 100,
)

# Full-scale settings for Stage 4 confirmation (matches runbook §12).
const FULL_SCALE = (
    N = 1000, d = 8, s = 8, k = 6, T = 200, T_burn = 30,
    network_measure_interval = 20, E_init = 200, h_a = 16, h_b = 32,
)

"""Merge a NamedTuple of defaults with per-cell override kwargs into a Dict{Symbol,Any}."""
function merge_kw(base::NamedTuple, overrides::Dict)::Dict{Symbol,Any}
    d = Dict{Symbol,Any}(pairs(base))
    for (k, v) in overrides
        d[k] = v
    end
    return d
end

# Sanity stage: each "cell" is a named corner with override kwargs.
function sanity_cells()
    [
        (id="NoRegime",             overrides=Dict(:delta => 0.0, :rho => 0.5)),
        (id="EasyQuality",          overrides=Dict(:delta => 0.5, :rho => 1.0)),
        (id="HardPairwise",         overrides=Dict(:delta => 0.75, :rho => 0.25)),
        (id="HighTransparency",     overrides=Dict(:delta => 0.5, :rho => 0.5, :n_strangers => 20, :k => 20)),
        (id="LowRosterAccess",      overrides=Dict(:delta => 0.5, :rho => 0.5, :alpha_R => 0.05)),
        (id="HighFee",              overrides=Dict(:delta => 0.5, :rho => 0.5, :broker_fee_rate => 0.60)),
        (id="FreezeBrokerLearning", overrides=Dict(:delta => 0.5, :rho => 0.5, :ablation => :FreezeBrokerLearning)),
    ]
end

# Pilot stage: five (delta, rho) anchor cells.
function pilot_cells()
    pts = [(0.00, 0.00), (0.00, 1.00), (0.75, 0.00), (0.75, 1.00), (0.50, 0.50)]
    [(id=@sprintf("d%.2f_r%.2f", d, r), overrides=Dict(:delta => d, :rho => r))
     for (d, r) in pts]
end

# Main sweep grids.
function sweep_grid(sweep::Symbol)
    if sweep == :delta_rho
        rhos = [0.00, 0.25, 0.50, 0.75, 1.00]
        deltas = [0.00, 0.25, 0.50, 0.75]
        out = [(id = @sprintf("d%.2f_r%.2f", d, r),
                overrides = Dict(:delta => d, :rho => r))
               for d in deltas for r in rhos]
        return out
    elseif sweep == :fee_cost
        fees = [0.00, 0.05, 0.15, 0.30, 0.60]
        costs = [0.00, 0.05, 0.15, 0.30, 0.60]
        out = [(id = @sprintf("bfr%.2f_ssc%.2f", f, c),
                overrides = Dict(:broker_fee_rate => f, :self_search_cost_rate => c,
                                 :delta => 0.50, :rho => 0.50))
               for c in costs for f in fees]
        return out
    elseif sweep == :transparency_access
        ns = [0, 2, 5, 10, 20]
        aRs = [0.05, 0.10, 0.20, 0.40]
        out = [(id = @sprintf("ns%d_aR%.2f", n, a),
                overrides = Dict(:n_strangers => n, :alpha_R => a,
                                 :delta => 0.50, :rho => 0.50))
               for a in aRs for n in ns]
        return out
    elseif sweep == :learning_turnover
        pds = [0.25, 0.50, 0.75, 0.90]
        etas = [0.00, 0.01, 0.02, 0.05, 0.10]
        out = [(id = @sprintf("pd%.2f_eta%.2f", pd, e),
                overrides = Dict(:p_demand => pd, :eta => e,
                                 :delta => 0.50, :rho => 0.50))
               for e in etas for pd in pds]
        return out
    else
        error("unknown sweep: $sweep")
    end
end

# Ablation stage: (ablation mode, anchor cell).
# Anchor set is fixed; the broker-dominant / self-search / boundary anchors are
# selected from the delta_rho grid as per runbook §11. Without that sweep having
# run yet, we use the baseline anchor and the two extreme (delta, rho) corners.
function ablation_cells()
    anchors = [
        (anchor="baseline", overrides=Dict(:delta => 0.50, :rho => 0.50)),
        (anchor="broker_dominant", overrides=Dict(:delta => 0.75, :rho => 0.25)),
        (anchor="self_search", overrides=Dict(:delta => 0.00, :rho => 1.00)),
    ]
    # :none is included so every anchor has a full-broker baseline that the
    # reducer can pair with :BlindBroker / other ablations to compute the
    # full/blind/agent additive decomposition (see `write_decomposition_csv`).
    modes = [:none, :NoBroker, :NoRegime, :BlindBroker, :NoAccessBroker,
             :FrozenGraph, :NoTurnover, :FreezeBrokerLearning]
    out = [(id = "$(a.anchor)_$(m)",
            overrides = merge(a.overrides, Dict(:ablation => m)))
           for a in anchors for m in modes]
    return out
end

# Diagnostic stage (Phase C2b): targeted full-scale comparison for sanity
# expected-sign debugging. 4 cells at N=1000/T=200, 5 seeds each.
function diagnostic_cells()
    [
        (id="Default",      overrides=Dict(:delta => 0.50, :rho => 0.50)),
        (id="NoRegime",     overrides=Dict(:delta => 0.00, :rho => 0.50)),
        (id="EasyQuality",  overrides=Dict(:delta => 0.50, :rho => 1.00)),
        (id="HardPairwise", overrides=Dict(:delta => 0.75, :rho => 0.25)),
    ]
end

# Diagnostic-blind stage (Phase C2c): same 3 cells as diagnostic (minus the
# NoRegime anchor which is already confirmed consistent) under :BlindBroker
# ablation. Pair with the diagnostic outputs to decompose EasyQuality's
# broker advantage into (pooled data / pair input / capacity) — see
# della_job_guide.md §11 and BROKER_ADVANTAGE_ANALYSIS_SPEC §6.
function diagnostic_blind_cells()
    [
        (id="Default_blind",     overrides=Dict(:delta => 0.50, :rho => 0.50, :ablation => :BlindBroker)),
        (id="EasyQuality_blind", overrides=Dict(:delta => 0.50, :rho => 1.00, :ablation => :BlindBroker)),
        (id="HardPairwise_blind", overrides=Dict(:delta => 0.75, :rho => 0.25, :ablation => :BlindBroker)),
    ]
end

# Full-confirm stage: 5 hand-picked cells at original-scale settings.
function full_confirm_cells()
    [
        (id="broker_dominant", overrides=Dict(:delta => 0.75, :rho => 0.25)),
        (id="self_search_dominant", overrides=Dict(:delta => 0.00, :rho => 1.00)),
        (id="boundary", overrides=Dict(:delta => 0.50, :rho => 0.50)),
        (id="fee_bypass", overrides=Dict(:delta => 0.50, :rho => 0.50,
                                         :broker_fee_rate => 0.60, :self_search_cost_rate => 0.05)),
        (id="high_info_low_access", overrides=Dict(:delta => 0.75, :rho => 0.25, :alpha_R => 0.05)),
    ]
end

"""Return the list of cells and per-stage run configuration."""
function stage_plan(args::Dict)
    stage = args[:stage]
    if stage == :sanity
        return (cells=sanity_cells(), base=SIMPLIFIED, seeds=5, arms=(:treatment,),
                seed_base=1000, tag="sanity", subdir="sanity")
    elseif stage == :pilot
        return (cells=pilot_cells(), base=SIMPLIFIED, seeds=10, arms=(:treatment, :control),
                seed_base=2000, tag="pilot_delta_rho", subdir="pilot_delta_rho")
    elseif stage == :sweep
        sweep = args[:sweep]
        return (cells=sweep_grid(sweep), base=SIMPLIFIED, seeds=15,
                arms=(:treatment, :control),
                seed_base=3000, tag=string(sweep), subdir=string(sweep))
    elseif stage == :ablation
        return (cells=ablation_cells(), base=SIMPLIFIED, seeds=15, arms=(:treatment,),
                seed_base=4000, tag="ablations", subdir="ablations")
    elseif stage == :diagnostic
        return (cells=diagnostic_cells(), base=FULL_SCALE, seeds=5, arms=(:treatment,),
                seed_base=5000, tag="diagnostic", subdir="diagnostic")
    elseif stage == :diagnostic_blind
        return (cells=diagnostic_blind_cells(), base=FULL_SCALE, seeds=5, arms=(:treatment,),
                seed_base=5000, tag="diagnostic_blind", subdir="diagnostic_blind")
    elseif stage == :full_confirm
        return (cells=full_confirm_cells(), base=FULL_SCALE, seeds=15,
                arms=(:treatment, :control),
                seed_base=9000, tag="full_confirm", subdir="full_confirm")
    else
        error("unhandled stage: $stage")
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Identity checks (runbook §7 / della_job_guide §11.1)
# ─────────────────────────────────────────────────────────────────────────────

"""Check the accounting identities for a single run's DataFrame.
Returns (max_residual, issues). max_residual is the largest absolute decomposition
residual observed. issues is a list of human-readable problem strings."""
function check_identities(df::DataFrame)
    issues = String[]
    max_resid = 0.0

    # 1. Demand split
    if !all(df.self_demand_slots .+ df.broker_demand_slots .== df.total_demand)
        push!(issues, "self_demand_slots + broker_demand_slots != total_demand on some row")
    end
    # 2. Legacy aliases
    if !all(df.self_filled_slots .== df.n_self_matches)
        push!(issues, "self_filled_slots != n_self_matches")
    end
    if !all(df.broker_filled_slots .== df.n_broker_standard)
        push!(issues, "broker_filled_slots != n_broker_standard")
    end
    # 3. Access/assessment three-way sum
    if !all(df.n_broker_access_new_edge .+ df.n_broker_assessment_reachable_no_prior .+
            df.n_broker_assessment_prior_partner .== df.n_broker_matches_classified)
        push!(issues, "access/assessment counts do not sum to n_broker_matches_classified")
    end
    # 4. pi_broker_slot consistency
    for r in eachrow(df)
        if r.total_demand > 0
            expected = r.broker_demand_slots / r.total_demand
            abs(r.pi_broker_slot - expected) > 1e-12 &&
                (push!(issues, "pi_broker_slot mismatch at period $(r.period)"); break)
        end
    end
    # 5. Decomposition residual
    for r in eachrow(df)
        if !isnan(r.net_value_gap) && !isnan(r.quality_selection_component) &&
           !isnan(r.fill_access_component) && !isnan(r.fee_cost_component)
            expected = r.quality_selection_component + r.fill_access_component + r.fee_cost_component
            max_resid = max(max_resid, abs(r.net_value_gap - expected))
        end
    end
    max_resid > 1e-10 && push!(issues, "decomposition residual exceeds 1e-10: $(max_resid)")
    return (max_resid, issues)
end

# ─────────────────────────────────────────────────────────────────────────────
# Per-run execution
# ─────────────────────────────────────────────────────────────────────────────

"""Cache file path for one (cell_id, seed, arm) triple."""
function run_cache_path(subdir::String, cell_id::String, seed::Int, arm::Symbol)
    dir = joinpath(SIMS_ROOT, subdir)
    mkpath(dir)
    return joinpath(dir, "cell__$(cell_id)__seed_$(seed)__arm_$(arm).jld2")
end

"""Run one simulation, save a compact JLD2, return (metrics_df, metadata_row)."""
function run_one(cell_id::String, seed::Int, arm::Symbol, base::NamedTuple,
                 overrides::Dict, subdir::String; rerun::Bool)
    cache = run_cache_path(subdir, cell_id, seed, arm)
    if !rerun && isfile(cache)
        loaded = JLD2.load(cache)
        return (loaded["metrics"]::DataFrame, loaded["metadata"]::NamedTuple)
    end

    kw = merge_kw(base, overrides)
    # Control arm forces :NoBroker (unless the cell already specifies an ablation).
    if arm == :control && !haskey(overrides, :ablation)
        kw[:ablation] = :NoBroker
    elseif arm == :control && overrides[:ablation] != :NoBroker
        # Treatment-mandated ablation overrides the default control pairing.
        kw[:ablation] = overrides[:ablation]
    end
    kw[:seed] = seed

    p = default_params(; kw...)
    t_sim = @elapsed (state, df) = run_simulation(p)

    # Run identity checks
    max_resid, issues = check_identities(df)
    metadata = (
        cell_id = cell_id,
        seed = seed,
        arm = String(arm),
        ablation = String(p.ablation),
        N = p.N, d = p.d, s = p.s, k = p.k, T = p.T, T_burn = p.T_burn,
        rho = p.rho, delta = p.delta, p_demand = p.p_demand, eta = p.eta,
        n_strangers = p.n_strangers, alpha_R = p.alpha_R,
        broker_fee_rate = p.broker_fee_rate,
        self_search_cost_rate = p.self_search_cost_rate,
        search_cost_rate = p.search_cost_rate,
        phi = state.cal.phi, c_s = state.cal.c_s,
        q_cal = state.cal.q_cal, r_out = state.cal.r,
        seconds = t_sim,
        identity_max_residual = max_resid,
        identity_issues = join(issues, "; "),
    )
    if !isempty(issues)
        msg = join(issues, "; ")
        error("Identity check failed for $cell_id seed=$seed arm=$arm: $msg")
    end

    jldsave(cache; metrics=df, metadata=metadata)
    return (df, metadata)
end

"""Run one cell: iterate seeds × arms, return vectors of (metrics, metadata)."""
function run_cell(cell::NamedTuple, plan::NamedTuple; rerun::Bool)
    metrics = DataFrame[]
    metas = NamedTuple[]
    for seed_offset in 0:(plan.seeds - 1)
        seed = plan.seed_base + seed_offset
        for arm in plan.arms
            df, md = run_one(cell.id, seed, arm, plan.base, cell.overrides, plan.subdir;
                             rerun=rerun)
            push!(metrics, df)
            push!(metas, md)
        end
    end
    return (metrics, metas)
end

# ─────────────────────────────────────────────────────────────────────────────
# Post-burn summary + cell summary + regime classification
# ─────────────────────────────────────────────────────────────────────────────

nanmean(v) = begin
    total = 0.0; n = 0
    for x in v
        isnan(x) && continue
        total += x; n += 1
    end
    n == 0 ? NaN : total / n
end

"""Post-burn scalar summary of a single run (per runbook §15.1)."""
function run_summary(df::DataFrame, T_burn::Int)
    tail = df[df.period .> T_burn, :]
    return (
        pi_broker_slot = nanmean(tail.pi_broker_slot),
        rank_gap = nanmean(tail.rank_gap),
        r2_gap = nanmean(tail.r2_gap),
        rank_gap_pooled = nanmean(tail.rank_gap_pooled),
        r2_gap_pooled = nanmean(tail.r2_gap_pooled),
        r2_gap_demeaned = nanmean(tail.r2_gap_demeaned),
        rank_gap_residualized = nanmean(tail.rank_gap_residualized),
        r2_gap_residualized = nanmean(tail.r2_gap_residualized),
        rmse_gap = nanmean(tail.rmse_gap),
        self_fill_rate = nanmean(tail.self_fill_rate),
        broker_fill_rate = nanmean(tail.broker_fill_rate),
        fill_rate_gap = nanmean(tail.fill_rate_gap),
        q_self_per_demand_slot = nanmean(tail.q_self_per_demand_slot),
        q_broker_per_demand_slot = nanmean(tail.q_broker_per_demand_slot),
        net_self_per_demand_slot = nanmean(tail.net_self_per_demand_slot),
        net_broker_per_demand_slot = nanmean(tail.net_broker_per_demand_slot),
        net_value_gap = nanmean(tail.net_value_gap),
        quality_selection_component = nanmean(tail.quality_selection_component),
        fill_access_component = nanmean(tail.fill_access_component),
        fee_cost_component = nanmean(tail.fee_cost_component),
        access_new_edge_frac_brk = nanmean(tail.access_new_edge_frac_brk),
        assessment_reachable_no_prior_frac_brk = nanmean(tail.assessment_reachable_no_prior_frac_brk),
        assessment_prior_partner_frac_brk = nanmean(tail.assessment_prior_partner_frac_brk),
        tried_broker_frac = nanmean(tail.tried_broker_frac),
        abandoned_broker_frac = nanmean(tail.abandoned_broker_frac),
        welfare_agents_period_mean = nanmean(tail.welfare_agents_period),
        welfare_broker_period_mean = nanmean(tail.welfare_broker_period),
        welfare_agents_cum = sum(tail.welfare_agents_period),
        welfare_broker_cum = sum(tail.welfare_broker_period),
        betweenness = nanmean(tail.betweenness),
        broker_history_size = nanmean(Float64.(tail.broker_history_size)),
    )
end

"""Mean, SE (over seeds), 95% CI, valid-seed count, share_positive/negative for a vector of scalars."""
function cell_stats(vals::Vector{<:Real})
    vals_c = collect(skipmissing(filter(!isnan, vals)))
    n = length(vals_c)
    if n == 0
        return (mean=NaN, sd=NaN, se=NaN, ci_lo=NaN, ci_hi=NaN, n=0,
                share_positive=NaN, share_negative=NaN)
    end
    m = mean(vals_c)
    sd = n >= 2 ? std(vals_c) : 0.0
    se = n >= 2 ? sd / sqrt(n) : 0.0
    ci_lo = m - 1.96 * se
    ci_hi = m + 1.96 * se
    sp = count(>(0.0), vals_c) / n
    sn = count(<(0.0), vals_c) / n
    return (mean=m, sd=sd, se=se, ci_lo=ci_lo, ci_hi=ci_hi, n=n,
            share_positive=sp, share_negative=sn)
end

"""Write full/blind/agent additive decomposition. One row per anchor with both
full (`:none`) and blind (`:BlindBroker`) rows in cell_rows. Columns report the
pooled_data_component (= blind_broker gap) and pair_input_component (= full − blind)
per gap metric. Rows are inferred by matching on the anchor prefix of cell_id."""
function write_decomposition_csv(cell_rows::Vector, path::String)
    # Parse cell_id => (anchor, mode)
    parsed = NamedTuple[]
    for r in cell_rows
        cid = r.cell_id
        m = match(r"^(.*?)_(none|NoBroker|NoRegime|BlindBroker|NoAccessBroker|FrozenGraph|NoTurnover|FreezeBrokerLearning)$", cid)
        m === nothing && continue
        push!(parsed, (anchor = m.captures[1], mode = m.captures[2], row = r))
    end
    anchors = unique([p.anchor for p in parsed])
    decomp_rows = NamedTuple[]
    for a in anchors
        full = findfirst(p -> p.anchor == a && p.mode == "none", parsed)
        blind = findfirst(p -> p.anchor == a && p.mode == "BlindBroker", parsed)
        if full === nothing || blind === nothing
            continue
        end
        f = parsed[full].row
        b = parsed[blind].row
        push!(decomp_rows, (
            anchor = a,
            # within-agent rank
            full_rank_within = f.rank_gap_mean,
            blind_rank_within = b.rank_gap_mean,
            pooled_data_rank_within = b.rank_gap_mean,
            pair_input_rank_within = f.rank_gap_mean - b.rank_gap_mean,
            # demeaned R²
            full_r2_demeaned = getfield(f, :r2_gap_demeaned_mean),
            blind_r2_demeaned = getfield(b, :r2_gap_demeaned_mean),
            pooled_data_r2_demeaned = getfield(b, :r2_gap_demeaned_mean),
            pair_input_r2_demeaned = getfield(f, :r2_gap_demeaned_mean) -
                                      getfield(b, :r2_gap_demeaned_mean),
            # residualized rank
            full_rank_residualized = getfield(f, :rank_gap_residualized_mean),
            blind_rank_residualized = getfield(b, :rank_gap_residualized_mean),
            pooled_data_rank_residualized = getfield(b, :rank_gap_residualized_mean),
            pair_input_rank_residualized = getfield(f, :rank_gap_residualized_mean) -
                                            getfield(b, :rank_gap_residualized_mean),
            # residualized R²
            full_r2_residualized = getfield(f, :r2_gap_residualized_mean),
            blind_r2_residualized = getfield(b, :r2_gap_residualized_mean),
            pooled_data_r2_residualized = getfield(b, :r2_gap_residualized_mean),
            pair_input_r2_residualized = getfield(f, :r2_gap_residualized_mean) -
                                          getfield(b, :r2_gap_residualized_mean),
            # broker adoption
            full_pi_broker = f.pi_broker_slot_mean,
            blind_pi_broker = b.pi_broker_slot_mean,
        ))
    end
    isempty(decomp_rows) && return
    df = DataFrame(decomp_rows)
    open(path, "w") do io
        cols = names(df)
        println(io, join(cols, ","))
        for row in eachrow(df)
            println(io, join((repr(row[c]) for c in cols), ","))
        end
    end
    println("reduce: wrote decomposition → $(path)  ($(nrow(df)) anchor rows)")
    return
end

"""Regime classification per BROKER_ADVANTAGE_ANALYSIS_SPEC §4."""
function classify_regime(cs::Dict)::NamedTuple
    B = get(cs, :pi_broker_slot, NaN)
    V = get(cs, :delta_welfare_agents, get(cs, :net_value_gap, NaN))
    I = get(cs, :rank_gap, NaN)
    G = get(cs, :gross_gap, NaN)
    access = get(cs, :access_new_edge_frac_brk, NaN)

    is_pos(x, th=0.0) = !isnan(x) && x > th
    is_neg(x, th=0.0) = !isnan(x) && x < th

    label, code, subtype = if is_pos(B, 0.50) && is_pos(V) && is_pos(I)
        # BrokerDominant; subtype by access/assessment
        sub = isnan(access) ? "unknown" :
              (access > 0.60 ? "Access" : access < 0.30 ? "Assessment" : "Dual")
        code = sub == "Access" ? "BA" : sub == "Assessment" ? "BI" : "BD"
        ("BrokerDominant_$(sub)", code, sub)
    elseif is_pos(B, 0.50) && is_neg(V)
        ("RentExtraction", "RE", "")
    elseif is_neg(B - 0.20) && is_pos(V) && is_pos(I)
        ("Underadopted_Info", "UI", "")
    elseif is_neg(B - 0.20) && is_pos(I) && is_pos(G) && !is_pos(V)
        ("FeeInducedBypass", "FB", "")
    elseif is_neg(B - 0.20) && !is_pos(V) && !is_pos(I)
        ("SelfSearchDominant", "SS", "")
    else
        ("Mixed", "M", "")
    end
    return (label=label, code=code, subtype=subtype)
end

# ─────────────────────────────────────────────────────────────────────────────
# Reduce: stitch per-run caches into stage-level outputs
# ─────────────────────────────────────────────────────────────────────────────

"""List all cell caches for a stage/sweep."""
function list_run_caches(subdir::String)::Vector{String}
    dir = joinpath(SIMS_ROOT, subdir)
    isdir(dir) || return String[]
    return sort!(filter(f -> endswith(f, ".jld2"),
                        readdir(dir, join=true)))
end

"""Load all per-run caches for a stage, produce cell_summaries + regime_labels
and write both JLD2 and CSV outputs."""
function reduce_stage(args::Dict)
    plan = stage_plan(args)
    subdir = plan.subdir
    tag = plan.tag
    caches = list_run_caches(subdir)
    if isempty(caches)
        error("no cell caches found in $(joinpath(SIMS_ROOT, subdir))")
    end
    # Load every (metrics, metadata) pair; build long-form metadata and a dict
    # of (cell_id, arm, seed) -> per-run scalar summary.
    run_meta = NamedTuple[]
    run_summ = Tuple{String, Symbol, Int, NamedTuple}[]
    for f in caches
        loaded = JLD2.load(f)
        df = loaded["metrics"]::DataFrame
        md = loaded["metadata"]::NamedTuple
        push!(run_meta, md)
        push!(run_summ, (md.cell_id, Symbol(md.arm), md.seed, run_summary(df, md.T_burn)))
    end

    # Build per-cell aggregation across seeds × arms.
    cells = unique([r[1] for r in run_summ])
    cell_rows = NamedTuple[]
    paired_rows = NamedTuple[]
    regime_rows = NamedTuple[]
    for cid in cells
        # collect seed-level values by arm
        t_summ = [s for (c, a, _, s) in run_summ if c == cid && a == :treatment]
        c_summ = [s for (c, a, _, s) in run_summ if c == cid && a == :control]
        t_seeds = [sd for (c, a, sd, _) in run_summ if c == cid && a == :treatment]
        n_t = length(t_summ)
        n_c = length(c_summ)

        # Per-metric aggregation helper across seeds.
        agg(metric::Symbol, arr) = cell_stats([getfield(s, metric) for s in arr])

        # Paired welfare
        paired_deltas = Float64[]
        if n_c > 0
            for (cs_i, cs_summ) in enumerate(c_summ)
                # match by seed
                seed_c = [sd for (c, a, sd, _) in run_summ if c == cid && a == :control][cs_i]
                # find treatment with same seed
                idx = findfirst(==( (cid, :treatment, seed_c) ),
                                [(c, a, sd) for (c, a, sd, _) in run_summ])
                if idx !== nothing
                    ts = run_summ[idx][4]
                    push!(paired_deltas,
                          ts.welfare_agents_cum - cs_summ.welfare_agents_cum)
                end
            end
        end
        dwa_stats = cell_stats(paired_deltas)

        # Headline summary for classification (use treatment arm)
        B = agg(:pi_broker_slot, t_summ)
        V = n_c > 0 ? dwa_stats : agg(:net_value_gap, t_summ)
        I = agg(:rank_gap, t_summ)
        F = agg(:fill_rate_gap, t_summ)
        access = agg(:access_new_edge_frac_brk, t_summ)

        # Gross gap (broker - self per-demand) approximation
        # Compute gross_self and gross_broker means per seed, then diff
        gross_diffs = Float64[
            s.q_broker_per_demand_slot - s.q_self_per_demand_slot for s in t_summ
            if !isnan(s.q_broker_per_demand_slot) && !isnan(s.q_self_per_demand_slot)
        ]
        Gstats = cell_stats(gross_diffs)

        cls = classify_regime(Dict(
            :pi_broker_slot => B.mean,
            :delta_welfare_agents => dwa_stats.mean,
            :net_value_gap => V.mean,
            :rank_gap => I.mean,
            :gross_gap => Gstats.mean,
            :access_new_edge_frac_brk => access.mean,
        ))

        push!(cell_rows, (
            cell_id = cid,
            n_seeds_treatment = n_t,
            n_seeds_control = n_c,
            pi_broker_slot_mean = B.mean, pi_broker_slot_se = B.se,
                pi_broker_slot_ci_lo = B.ci_lo, pi_broker_slot_ci_hi = B.ci_hi,
            rank_gap_mean = I.mean, rank_gap_se = I.se,
                rank_gap_share_positive = I.share_positive,
                rank_gap_ci_lo = I.ci_lo, rank_gap_ci_hi = I.ci_hi,
            rank_gap_pooled_mean = agg(:rank_gap_pooled, t_summ).mean,
                rank_gap_pooled_se = agg(:rank_gap_pooled, t_summ).se,
            r2_gap_mean = agg(:r2_gap, t_summ).mean,
            r2_gap_pooled_mean = agg(:r2_gap_pooled, t_summ).mean,
                r2_gap_pooled_se = agg(:r2_gap_pooled, t_summ).se,
            r2_gap_demeaned_mean = agg(:r2_gap_demeaned, t_summ).mean,
                r2_gap_demeaned_se = agg(:r2_gap_demeaned, t_summ).se,
            r2_gap_residualized_mean = agg(:r2_gap_residualized, t_summ).mean,
                r2_gap_residualized_se = agg(:r2_gap_residualized, t_summ).se,
            rank_gap_residualized_mean = agg(:rank_gap_residualized, t_summ).mean,
                rank_gap_residualized_se = agg(:rank_gap_residualized, t_summ).se,
            fill_rate_gap_mean = F.mean, fill_rate_gap_se = F.se,
            net_value_gap_mean = agg(:net_value_gap, t_summ).mean,
                net_value_gap_se = agg(:net_value_gap, t_summ).se,
            delta_welfare_agents_mean = dwa_stats.mean,
                delta_welfare_agents_se = dwa_stats.se,
                delta_welfare_agents_n = dwa_stats.n,
            welfare_broker_cum_mean = agg(:welfare_broker_cum, t_summ).mean,
            access_new_edge_frac_brk_mean = access.mean,
            assessment_prior_partner_frac_brk_mean =
                agg(:assessment_prior_partner_frac_brk, t_summ).mean,
            tried_broker_frac_mean = agg(:tried_broker_frac, t_summ).mean,
            abandoned_broker_frac_mean = agg(:abandoned_broker_frac, t_summ).mean,
            betweenness_mean = agg(:betweenness, t_summ).mean,
            broker_history_size_mean = agg(:broker_history_size, t_summ).mean,
        ))
        push!(regime_rows, (
            cell_id = cid,
            regime_label = cls.label,
            regime_code = cls.code,
            broker_dominant_subtype = cls.subtype,
            threshold_broker = 0.50,
            threshold_access = 0.60,
        ))
        for d in paired_deltas
            push!(paired_rows, (cell_id = cid, delta_welfare_agents = d))
        end
    end

    # Write CSVs + stage-level JLD2
    md_df = DataFrame(run_meta)
    cell_df = DataFrame(cell_rows)
    reg_df = DataFrame(regime_rows)
    paired_df = isempty(paired_rows) ? DataFrame() : DataFrame(paired_rows)

    csv_prefix = joinpath(SUM_ROOT, tag)
    writecsv(path, df) = begin
        open(path, "w") do io
            cols = names(df)
            println(io, join(cols, ","))
            for row in eachrow(df)
                println(io, join((repr(row[c]) for c in cols), ","))
            end
        end
    end
    writecsv(csv_prefix * "_run_metadata.csv", md_df)
    writecsv(csv_prefix * "_cell_summaries.csv", cell_df)
    writecsv(csv_prefix * "_regime_labels.csv", reg_df)
    !isempty(paired_rows) && writecsv(csv_prefix * "_paired_summaries.csv", paired_df)

    # ── Full/blind/agent additive decomposition (ablation stage only) ──
    # For each anchor cell that has both a :none (full broker) and a
    # :BlindBroker row, write a decomposition CSV:
    #   pooled_data_component = blind_gap        (what blind-broker delivers over agent)
    #   pair_input_component  = full_gap - blind (additional lift from pair input)
    # Rows with missing blind or full are omitted with a note.
    if args[:stage] == :ablation
        write_decomposition_csv(cell_rows, csv_prefix * "_decomposition.csv")
    end

    stage_jld = joinpath(SIMS_ROOT, tag * ".jld2")
    jldsave(stage_jld;
            metadata = md_df,
            cell_summaries = cell_df,
            regime_labels = reg_df,
            paired_summaries = paired_df,
            stage = String(args[:stage]),
            sweep = args[:sweep] === nothing ? "" : String(args[:sweep]),
            n_cells = length(cells),
    )

    println("reduce: wrote $(stage_jld)")
    println("        run_metadata: $(nrow(md_df)) rows")
    println("        cell_summaries: $(nrow(cell_df)) cells")
    println("        regime_labels: $(nrow(reg_df)) cells")
    return stage_jld
end

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

function main()
    args = parse_args(ARGS)
    plan = stage_plan(args)
    # Restrict to a single arm if --arm supplied. Used for splitting large
    # stages (e.g. full_confirm) across an array job indexed by (cell, arm).
    if args[:arm] !== nothing
        args[:arm] in plan.arms ||
            error("--arm $(args[:arm]) not in plan arms $(plan.arms)")
        plan = merge(plan, (arms = (args[:arm],),))
    end
    println("stage=$(args[:stage])  sweep=$(args[:sweep])  n_cells=$(length(plan.cells))  " *
            "seeds=$(plan.seeds)  arms=$(plan.arms)")
    flush(stdout)

    if args[:reduce]
        reduce_stage(args)
        return
    end

    cells = plan.cells
    # Single cell-idx mode (for slurm job arrays)
    if args[:cell_idx] !== nothing
        idx = args[:cell_idx]
        0 <= idx < length(cells) || error("--cell-idx $idx out of range [0, $(length(cells) - 1)]")
        selected = [cells[idx + 1]]
        println("  running single cell idx=$idx: $(selected[1].id)")
    else
        selected = cells
    end

    t0 = time()
    n_done = 0
    for cell in selected
        tc = @elapsed run_cell(cell, plan; rerun=args[:rerun])
        n_done += 1
        @printf("  [%d/%d] %-36s runs=%d arms=%d  %.1fs\n",
                n_done, length(selected), cell.id,
                plan.seeds * length(plan.arms), length(plan.arms), tc)
        flush(stdout)
    end
    println("done: $(round(time() - t0, digits=1))s total")
    flush(stdout)
end

main()
