"""
    plot_broker_advantage.jl

Render the figure suite defined in `prompts/BROKER_ADVANTAGE_PLOTTING_SPEC.md`
from the caches produced by `scripts/run_broker_advantage.jl`.

Inputs (per stage, read from data/sims/broker_advantage/ and
data/summaries/broker_advantage/):
  - per-cell JLD2 caches            (data/sims/broker_advantage/<subdir>/)
  - stage-level JLD2                (data/sims/broker_advantage/<tag>.jld2)
  - *_cell_summaries.csv            (data/summaries/broker_advantage/)
  - *_regime_labels.csv
  - *_paired_summaries.csv  (optional)

Outputs (data/figures/broker_advantage/):
  - phase panels, regime maps, threshold maps, temporal overlays,
    advantage-dynamics dashboards, phase portraits, fee sensitivity,
    ablation bars/temporal, full_confirm_comparison, sanity/pilot.

CLI:
  julia -J data/sysimage/sys_ba.so --project --threads=auto \\
    scripts/plot_broker_advantage.jl [--stage <stage>] [--sweep <sweep>] [--all]

  --stage one of: sanity pilot sweep ablation diagnostic diagnostic_blind
                  full_confirm
  --sweep required with --stage sweep; one of: delta_rho fee_cost
          transparency_access learning_turnover
  --all   render every figure whose inputs exist; skip (with a note) those
          whose inputs are missing.
"""

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using CairoMakie
using DataFrames
using JLD2
using Printf
using Statistics
using StatsBase: mean, std
using Dates: now

include(joinpath(@__DIR__, "figure_style.jl"))

const REPO_ROOT = normpath(joinpath(@__DIR__, ".."))
const SIMS_ROOT = joinpath(REPO_ROOT, "data", "sims", "broker_advantage")
const SUM_ROOT  = joinpath(REPO_ROOT, "data", "summaries", "broker_advantage")
const FIG_ROOT  = joinpath(REPO_ROOT, "data", "figures", "broker_advantage")
const MISSING_NOTES = joinpath(SUM_ROOT, "missing_plots.md")

isdir(FIG_ROOT) || mkpath(FIG_ROOT)

# ─────────────────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────────────────

function parse_args(argv::Vector{String})
    args = Dict{Symbol,Any}(:stage => nothing, :sweep => nothing, :all => false)
    i = 1
    while i <= length(argv)
        a = argv[i]
        if a == "--stage"
            args[:stage] = Symbol(argv[i+1]); i += 2
        elseif a == "--sweep"
            args[:sweep] = Symbol(argv[i+1]); i += 2
        elseif a == "--all"
            args[:all] = true; i += 1
        elseif a == "-h" || a == "--help"
            println(first(@doc(plot_broker_advantage), 2000)); exit(0)
        else
            error("unknown arg: $a")
        end
    end
    return args
end

# ─────────────────────────────────────────────────────────────────────────────
# I/O helpers
# ─────────────────────────────────────────────────────────────────────────────

"""Note an unrenderable figure in missing_plots.md. Appends, creating if needed."""
function note_missing(figname::String, why::String)
    open(MISSING_NOTES, "a") do io
        ts = string(now())
        println(io, "- `$(figname)` — $(why) (logged $(ts))")
    end
    @warn "skipping $(figname): $(why)"
end

"""Minimal CSV reader (no CSV.jl dep). Returns DataFrame. Uses `repr` inverse
so reads numbers and quoted strings as produced by run_broker_advantage.jl's
`writecsv`. NaN is parsed to NaN; missing values to `missing`."""
function read_csv(path::String)::DataFrame
    open(path, "r") do io
        header = split(strip(readline(io)), ',')
        cols = [String[] for _ in header]
        for line in eachline(io)
            strip(line) == "" && continue
            vals = split_csv_line(line)
            length(vals) == length(header) ||
                error("csv parse mismatch in $(path): want $(length(header)) got $(length(vals))")
            for (j, v) in enumerate(vals)
                push!(cols[j], v)
            end
        end
        df = DataFrame()
        for (j, h) in enumerate(header)
            df[!, Symbol(h)] = try_parse_column(cols[j])
        end
        return df
    end
end

"""Split a CSV line respecting double-quoted strings."""
function split_csv_line(line::String)::Vector{String}
    parts = String[]
    buf = IOBuffer()
    in_q = false
    i = 1
    while i <= length(line)
        c = line[i]
        if c == '"'
            in_q = !in_q
            print(buf, c)
        elseif c == ',' && !in_q
            push!(parts, String(take!(buf)))
        else
            print(buf, c)
        end
        i = nextind(line, i)
    end
    push!(parts, String(take!(buf)))
    return parts
end

"""Heuristic column parser: if every value parses to Float64 (or equals 'NaN'),
return a Vector{Float64}. Else strip outer quotes from strings and return Vector{String}."""
function try_parse_column(vals::Vector{String})
    floats = Vector{Float64}(undef, length(vals))
    ok = true
    for (i, v) in enumerate(vals)
        vv = strip(v)
        if vv == "NaN"
            floats[i] = NaN
        else
            p = tryparse(Float64, vv)
            if p === nothing
                ok = false; break
            end
            floats[i] = p
        end
    end
    if ok
        return floats
    end
    # String column: strip surrounding quotes if present
    return [replace(strip(v), r"^\"(.*)\"$" => s"\1") for v in vals]
end

"""Load a stage-level JLD2 if it exists."""
function load_stage_jld(tag::String)
    p = joinpath(SIMS_ROOT, tag * ".jld2")
    isfile(p) || return nothing
    return JLD2.load(p)
end

"""Read cell_summaries CSV for a tag ("delta_rho", "fee_cost", …)."""
function read_cell_summaries(tag::String)
    p = joinpath(SUM_ROOT, "$(tag)_cell_summaries.csv")
    isfile(p) || return nothing
    return read_csv(p)
end

function read_regime_labels(tag::String)
    p = joinpath(SUM_ROOT, "$(tag)_regime_labels.csv")
    isfile(p) || return nothing
    return read_csv(p)
end

function read_paired(tag::String)
    p = joinpath(SUM_ROOT, "$(tag)_paired_summaries.csv")
    isfile(p) || return nothing
    return read_csv(p)
end

# ─────────────────────────────────────────────────────────────────────────────
# Cell-id parsing per sweep
# ─────────────────────────────────────────────────────────────────────────────

"""Parse a sweep cell_id back to a (x, y) point in the sweep's axis space.
Returns (xaxis_value, yaxis_value) or nothing if not parsable."""
function parse_sweep_id(sweep::Symbol, cid::AbstractString)
    s = replace(String(cid), r"^\""=>"", r"\"$"=>"")
    if sweep == :delta_rho
        m = match(r"^d([0-9.]+)_r([0-9.]+)$", s)
        m === nothing && return nothing
        return (x = parse(Float64, m.captures[2]), y = parse(Float64, m.captures[1]))
    elseif sweep == :fee_cost
        m = match(r"^bfr([0-9.]+)_ssc([0-9.]+)$", s)
        m === nothing && return nothing
        return (x = parse(Float64, m.captures[1]), y = parse(Float64, m.captures[2]))
    elseif sweep == :transparency_access
        m = match(r"^ns(\d+)_aR([0-9.]+)$", s)
        m === nothing && return nothing
        return (x = parse(Float64, m.captures[1]), y = parse(Float64, m.captures[2]))
    elseif sweep == :learning_turnover
        m = match(r"^pd([0-9.]+)_eta([0-9.]+)$", s)
        m === nothing && return nothing
        return (x = parse(Float64, m.captures[1]), y = parse(Float64, m.captures[2]))
    else
        error("unknown sweep: $sweep")
    end
end

function axis_labels(sweep::Symbol)
    return Dict(
        :delta_rho => (x = L"\rho", y = L"\delta", xcol=:rho, ycol=:delta),
        :fee_cost  => (x = "broker_fee_rate", y = "self_search_cost_rate",
                       xcol = :broker_fee_rate, ycol = :self_search_cost_rate),
        :transparency_access => (x = "n_strangers", y = L"\alpha_R",
                                 xcol = :n_strangers, ycol = :alpha_R),
        :learning_turnover   => (x = "p_demand", y = L"\eta",
                                 xcol = :p_demand, ycol = :eta),
    )[sweep]
end

"""Build (xvals_sorted, yvals_sorted, matrix) for a cell-level metric on a sweep."""
function sweep_matrix(cs::DataFrame, sweep::Symbol, metric::Symbol)
    xs = Float64[]
    ys = Float64[]
    pts = Tuple{Float64, Float64, Float64}[]
    for row in eachrow(cs)
        pt = parse_sweep_id(sweep, row.cell_id)
        pt === nothing && continue
        v = row[metric]
        push!(pts, (pt.x, pt.y, v isa Real ? Float64(v) : NaN))
    end
    isempty(pts) && return (Float64[], Float64[], Matrix{Float64}(undef, 0, 0))
    xs = sort!(unique!([p[1] for p in pts]))
    ys = sort!(unique!([p[2] for p in pts]))
    M = fill(NaN, length(xs), length(ys))
    for (x, y, v) in pts
        i = findfirst(==(x), xs); j = findfirst(==(y), ys)
        M[i, j] = v
    end
    return xs, ys, M
end

# ─────────────────────────────────────────────────────────────────────────────
# Colormap helpers
# ─────────────────────────────────────────────────────────────────────────────

"""Symmetric diverging colormap clamped by |max| of finite data."""
function symmetric_range(M::AbstractMatrix; cap=nothing)
    fv = filter(isfinite, vec(M))
    isempty(fv) && return -1.0, 1.0
    a = maximum(abs, fv)
    a = a == 0 ? 1.0 : a
    if cap !== nothing
        a = min(a, cap)
    end
    return -a, a
end

"""Sequential [0,1] colormap."""
const CMAP_SEQ = :viridis
"""Diverging zero-centered colormap."""
const CMAP_DIV = :RdBu
"""Categorical palette for regime codes."""
const REGIME_PALETTE = Dict(
    "BI" => :darkblue,       "BA" => :royalblue,
    "BD" => :mediumpurple,   "RE" => :crimson,
    "UI" => :goldenrod,      "FB" => :tomato,
    "SS" => :forestgreen,    "M"  => :lightgray,
)
const REGIME_ORDER = ["BI", "BA", "BD", "RE", "UI", "FB", "SS", "M"]

# ─────────────────────────────────────────────────────────────────────────────
# Heatmap helper (supports diverging or sequential)
# ─────────────────────────────────────────────────────────────────────────────

"""Draw a heatmap with x/y axes, title, and optional zero-centered color range.
Returns the heatmap object so a colorbar can be attached by the caller."""
function draw_heatmap!(ax, xs::Vector{<:Real}, ys::Vector{<:Real}, M::AbstractMatrix;
                       diverging::Bool=false, vmin=nothing, vmax=nothing,
                       cmap=nothing, highlight_zero::Bool=false)
    if diverging
        a, b = symmetric_range(M)
        vmin = vmin === nothing ? a : vmin
        vmax = vmax === nothing ? b : vmax
        cmap = cmap === nothing ? CMAP_DIV : cmap
    else
        fv = filter(isfinite, vec(M))
        vmin = vmin === nothing ? (isempty(fv) ? 0.0 : minimum(fv)) : vmin
        vmax = vmax === nothing ? (isempty(fv) ? 1.0 : maximum(fv)) : vmax
        cmap = cmap === nothing ? CMAP_SEQ : cmap
    end
    hm = heatmap!(ax, xs, ys, M;
                  colorrange=(vmin, vmax), colormap=cmap, nan_color=:gray70)
    return hm
end

"""Annotate cell center with short text (for regime maps or small grids)."""
function annotate_cells!(ax, xs::Vector{<:Real}, ys::Vector{<:Real},
                         labels::Matrix{String}; fontsize=9, color=:black)
    for i in eachindex(xs), j in eachindex(ys)
        isempty(labels[i, j]) && continue
        text!(ax, labels[i, j]; position=(xs[i], ys[j]),
              align=(:center, :center), fontsize=fontsize, color=color)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Phase panels per sweep (§7)
# ─────────────────────────────────────────────────────────────────────────────

"""3x3 phase-panels figure for a sweep.
Panels:
  (1,1) pi_broker_slot        [0,1] seq
  (1,2) delta_welfare_agents  div     (falls back to net_value_gap)
  (1,3) net_value_gap         div
  (2,1) rank_gap              div
  (2,2) r2_gap                div
  (2,3) fill_rate_gap         div
  (3,1) access_new_edge_frac_brk           [0,1] seq
  (3,2) assessment_prior_partner_frac_brk  [0,1] seq
  (3,3) regime classification (categorical, with text codes)"""
function plot_phase_panels(sweep::Symbol)
    tag = String(sweep)
    cs = read_cell_summaries(tag)
    rl = read_regime_labels(tag)
    if cs === nothing || rl === nothing
        note_missing("$(tag)_phase_panels.png", "missing cell_summaries or regime_labels CSV")
        return
    end

    ax_spec = axis_labels(sweep)
    n_seeds = try
        fst_col = getproperty(cs, :n_seeds_treatment)
        round(Int, first(fst_col))
    catch _; NaN end

    fig = Figure(size=(1400, 1250))
    Label(fig[0, 1:3], "Phase panels — $(String(sweep)) sweep (post-burn means, n_seeds=$(n_seeds))";
          fontsize=SUPTITLE_FS, tellwidth=false)

    function make_panel(r, c, metric_col::Symbol, title::String;
                        diverging::Bool=false, vmin=nothing, vmax=nothing,
                        cmap=nothing)
        xs, ys, M = sweep_matrix(cs, sweep, metric_col)
        ax = Axis(fig[r, c]; title=title, xlabel=ax_spec.x, ylabel=ax_spec.y,
                  titlesize=TITLE_FS, xlabelsize=LABEL_FS, ylabelsize=LABEL_FS,
                  xticklabelsize=TICK_FS, yticklabelsize=TICK_FS)
        if isempty(xs)
            text!(ax, "no data"; position=(0.5, 0.5), align=(:center, :center))
            return
        end
        hm = draw_heatmap!(ax, xs, ys, M; diverging=diverging,
                           vmin=vmin, vmax=vmax, cmap=cmap)
        Colorbar(fig[r, c, Right()], hm; width=8, ticklabelsize=TICK_FS)
    end

    make_panel(1, 1, :pi_broker_slot_mean, "Broker slot share π_b"; vmin=0.0, vmax=1.0)
    # Prefer paired welfare if present & non-all-NaN
    dw = hasproperty(cs, :delta_welfare_agents_mean) ? cs.delta_welfare_agents_mean : nothing
    use_welfare = dw !== nothing && any(!isnan, dw)
    make_panel(1, 2,
               use_welfare ? :delta_welfare_agents_mean : :net_value_gap_mean,
               use_welfare ? "Δ welfare_agents (paired)" : "(paired n/a) net_value_gap";
               diverging=true)
    make_panel(1, 3, :net_value_gap_mean, "Net channel value gap"; diverging=true)
    make_panel(2, 1, :rank_gap_mean, "Holdout rank gap"; diverging=true)
    make_panel(2, 2, :r2_gap_mean, "Holdout R² gap"; diverging=true)
    make_panel(2, 3, :fill_rate_gap_mean, "Fill-rate gap"; diverging=true)
    make_panel(3, 1, :access_new_edge_frac_brk_mean, "Access: new-edge fraction"; vmin=0.0, vmax=1.0)
    make_panel(3, 2, :assessment_prior_partner_frac_brk_mean, "Assessment: prior-partner fraction"; vmin=0.0, vmax=1.0)

    # (3,3) regime categorical panel
    draw_regime_map!(fig[3, 3], rl, sweep; title="Regime classification")

    out = joinpath(FIG_ROOT, "$(tag)_phase_panels.png")
    save(out, fig)
    println("wrote $(out)")
end

# ─────────────────────────────────────────────────────────────────────────────
# Regime maps (§8)
# ─────────────────────────────────────────────────────────────────────────────

"""Draw a standalone regime map panel onto `parent` (GridPosition)."""
function draw_regime_map!(parent, rl::DataFrame, sweep::Symbol;
                          title::String="Regime map", include_legend::Bool=false)
    ax_spec = axis_labels(sweep)
    # Build coordinate lists + code matrix
    xs = Float64[]; ys = Float64[]
    pts = Tuple{Float64, Float64, String}[]
    for row in eachrow(rl)
        pt = parse_sweep_id(sweep, String(row.cell_id))
        pt === nothing && continue
        code = row.regime_code isa AbstractString ? String(row.regime_code) : string(row.regime_code)
        push!(pts, (pt.x, pt.y, code))
    end
    xs = sort!(unique!([p[1] for p in pts]))
    ys = sort!(unique!([p[2] for p in pts]))
    codes = fill("", length(xs), length(ys))
    cat_idx = fill(NaN, length(xs), length(ys))
    for (x, y, c) in pts
        i = findfirst(==(x), xs); j = findfirst(==(y), ys)
        codes[i, j] = c
        k = findfirst(==(c), REGIME_ORDER)
        cat_idx[i, j] = k === nothing ? NaN : Float64(k)
    end

    ax = Axis(parent; title=title, xlabel=ax_spec.x, ylabel=ax_spec.y,
              titlesize=TITLE_FS, xlabelsize=LABEL_FS, ylabelsize=LABEL_FS,
              xticklabelsize=TICK_FS, yticklabelsize=TICK_FS)
    if isempty(xs)
        text!(ax, "no data"; position=(0.5, 0.5), align=(:center, :center))
        return ax
    end
    # Discrete colormap by ordered regime list
    palette = [REGIME_PALETTE[c] for c in REGIME_ORDER]
    heatmap!(ax, xs, ys, cat_idx;
             colorrange=(1, length(REGIME_ORDER)),
             colormap=palette, nan_color=:white)
    annotate_cells!(ax, xs, ys, codes; fontsize=9)

    if include_legend
        elems = [PolyElement(color=REGIME_PALETTE[c], strokecolor=:black, strokewidth=0.5)
                 for c in REGIME_ORDER]
        Legend(parent.layout.parent[parent.span.rows, parent.span.cols + 1],
               elems, REGIME_ORDER; labelsize=9, framewidth=0.5)
    end
    return ax
end

"""Standalone regime map figure per sweep."""
function plot_regime_map(sweep::Symbol; threshold_broker::Union{Nothing,Float64}=nothing)
    tag = String(sweep)
    cs = read_cell_summaries(tag)
    if cs === nothing
        suffix = threshold_broker === nothing ? "" : @sprintf("_threshold_broker%03d", round(Int, threshold_broker*100))
        note_missing("regime_map_$(tag)$(suffix).png", "missing cell_summaries CSV")
        return
    end

    # If threshold_broker override, recompute regime labels from cs
    if threshold_broker === nothing
        rl = read_regime_labels(tag)
        if rl === nothing
            note_missing("regime_map_$(tag).png", "missing regime_labels CSV")
            return
        end
    else
        rl = DataFrame(cell_id = String[], regime_code = String[],
                       regime_label = String[], broker_dominant_subtype = String[])
        for row in eachrow(cs)
            code, label, sub = classify_regime_row(row; threshold_broker=threshold_broker)
            push!(rl, (cell_id = String(row.cell_id),
                       regime_code = code, regime_label = label,
                       broker_dominant_subtype = sub))
        end
    end

    fig = Figure(size=(700, 520))
    suffix = threshold_broker === nothing ? "" : @sprintf(" (threshold π_b=%.2f)", threshold_broker)
    Label(fig[0, 1], "Regime map — $(tag)$(suffix)"; fontsize=SUPTITLE_FS, tellwidth=false)
    ax = draw_regime_map!(fig[1, 1], rl, sweep; title="", include_legend=false)

    # External legend
    elems = [PolyElement(color=REGIME_PALETTE[c], strokecolor=:black, strokewidth=0.5)
             for c in REGIME_ORDER]
    Legend(fig[1, 2], elems, REGIME_ORDER; labelsize=9, framewidth=0.5)

    # Footnote with thresholds
    thresh_B = threshold_broker === nothing ? 0.50 : threshold_broker
    Label(fig[2, 1:2],
          "Thresholds: π_b > $(thresh_B) defines broker-dominant; access>0.60 → BA; <0.30 → BI; else BD.";
          fontsize=FOOTER_FS, color=:gray30, tellwidth=false)

    out_suffix = threshold_broker === nothing ? "" :
        @sprintf("_threshold_broker%03d", round(Int, threshold_broker*100))
    out = joinpath(FIG_ROOT, "regime_map_$(tag)$(out_suffix).png")
    save(out, fig)
    println("wrote $(out)")
end

"""Row-level classify_regime re-implementation with configurable threshold_broker.
Mirrors the rules in scripts/run_broker_advantage.jl:classify_regime."""
function classify_regime_row(row; threshold_broker::Float64=0.50, threshold_access::Float64=0.60)
    B = row.pi_broker_slot_mean
    V = (hasproperty(row, :delta_welfare_agents_mean) && !isnan(row.delta_welfare_agents_mean)) ?
        row.delta_welfare_agents_mean : row.net_value_gap_mean
    I = row.rank_gap_mean
    G = NaN  # gross_gap not stored in cell_summaries, approximate via net_value_gap
    access = row.access_new_edge_frac_brk_mean
    is_pos(x, th=0.0) = !isnan(x) && x > th
    is_neg(x, th=0.0) = !isnan(x) && x < th

    if is_pos(B, threshold_broker) && is_pos(V) && is_pos(I)
        sub = isnan(access) ? "unknown" :
              (access > threshold_access ? "Access" :
               access < 0.30 ? "Assessment" : "Dual")
        code = sub == "Access" ? "BA" : sub == "Assessment" ? "BI" : "BD"
        return (code, "BrokerDominant_$(sub)", sub)
    elseif is_pos(B, threshold_broker) && is_neg(V)
        return ("RE", "RentExtraction", "")
    elseif is_neg(B - 0.20) && is_pos(V) && is_pos(I)
        return ("UI", "Underadopted_Info", "")
    elseif is_neg(B - 0.20) && is_pos(I) && !is_pos(V)
        return ("FB", "FeeInducedBypass", "")
    elseif is_neg(B - 0.20) && !is_pos(V) && !is_pos(I)
        return ("SS", "SelfSearchDominant", "")
    else
        return ("M", "Mixed", "")
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Fee sensitivity curves (§12)
# ─────────────────────────────────────────────────────────────────────────────

function plot_fee_sensitivity()
    cs = read_cell_summaries("fee_cost")
    if cs === nothing
        note_missing("fee_sensitivity_curves.png", "missing fee_cost_cell_summaries.csv")
        return
    end
    # parse axes
    fee = Float64[]; cost = Float64[]
    for row in eachrow(cs)
        pt = parse_sweep_id(:fee_cost, String(row.cell_id))
        push!(fee, pt === nothing ? NaN : pt.x)
        push!(cost, pt === nothing ? NaN : pt.y)
    end
    cs_df = copy(cs)
    cs_df[!, :fee] = fee
    cs_df[!, :cost] = cost

    unique_costs = sort!(unique(cost))
    fig = Figure(size=(1200, 900))
    Label(fig[0, 1:2], "Fee sensitivity — curves over broker_fee_rate per self_search_cost_rate";
          fontsize=SUPTITLE_FS, tellwidth=false)

    function panel(r, c, ycol::Symbol, title::String; ylabel::String=String(ycol), yzero::Bool=false)
        ax = Axis(fig[r, c]; title=title, xlabel="broker_fee_rate", ylabel=ylabel,
                  titlesize=TITLE_FS, xlabelsize=LABEL_FS, ylabelsize=LABEL_FS,
                  xticklabelsize=TICK_FS, yticklabelsize=TICK_FS)
        yzero && hlines!(ax, [0.0]; color=:gray50, linestyle=:dash)
        colors = Makie.wong_colors()
        for (k, ccost) in enumerate(unique_costs)
            sub = cs_df[cs_df.cost .== ccost, :]
            sub = sort!(sub, :fee)
            y = sub[:, ycol]
            ys = try Float64.(y) catch _; fill(NaN, length(y)) end
            lines!(ax, sub.fee, ys; color=colors[(k-1) % length(colors) + 1],
                   label=@sprintf("c_s=%.2f", ccost), linewidth=1.8)
            scatter!(ax, sub.fee, ys; color=colors[(k-1) % length(colors) + 1], markersize=6)
        end
        if r == 1 && c == 1
            axislegend(ax; position=:lt, labelsize=9, framewidth=0.5)
        end
    end
    panel(1, 1, :pi_broker_slot_mean, "Broker adoption π_b"; ylabel="π_b")
    panel(1, 2, :net_value_gap_mean,  "Net value gap";        ylabel="net_value_gap", yzero=true)
    panel(2, 1, :rank_gap_mean,       "Prediction rank gap";  ylabel="rank_gap",      yzero=true)
    dw_col = hasproperty(cs_df, :delta_welfare_agents_mean) ?
        :delta_welfare_agents_mean : :net_value_gap_mean
    panel(2, 2, dw_col, "Δ agent welfare (paired) or net value gap";
          ylabel=String(dw_col), yzero=true)

    out = joinpath(FIG_ROOT, "fee_sensitivity_curves.png")
    save(out, fig); println("wrote $(out)")
end

# ─────────────────────────────────────────────────────────────────────────────
# Ablation bars (§13)
# ─────────────────────────────────────────────────────────────────────────────

function plot_ablation_bars()
    cs = read_cell_summaries("ablations")
    if cs === nothing
        note_missing("ablation_bars.png", "missing ablations_cell_summaries.csv")
        return
    end
    # Parse cell_id = "<anchor>_<mode>"
    anchors = String[]; modes = String[]
    mode_re = r"^(.*?)_(none|NoBroker|NoRegime|BlindBroker|NoAccessBroker|FrozenGraph|NoTurnover|FreezeBrokerLearning)$"
    for row in eachrow(cs)
        cid = replace(String(row.cell_id), r"^\""=>"", r"\"$"=>"")
        m = match(mode_re, cid)
        if m === nothing
            push!(anchors, cid); push!(modes, "unknown")
        else
            push!(anchors, m.captures[1]); push!(modes, m.captures[2])
        end
    end
    cs_df = copy(cs)
    cs_df[!, :anchor] = anchors
    cs_df[!, :mode] = modes

    uniq_anchors = unique(anchors)
    mode_order = ["none", "NoBroker", "NoRegime", "BlindBroker", "NoAccessBroker",
                  "FrozenGraph", "NoTurnover", "FreezeBrokerLearning"]
    metrics = [
        (:pi_broker_slot_mean, "π_b", false),
        (:rank_gap_mean, "rank_gap", true),
        (:r2_gap_mean, "r²_gap", true),
        (:net_value_gap_mean, "net_value_gap", true),
        (:access_new_edge_frac_brk_mean, "access_new_edge_frac_brk", false),
    ]
    fig = Figure(size=(max(1200, 280 * length(uniq_anchors)), 1200))
    Label(fig[0, 1:length(uniq_anchors)],
          "Ablation bars by anchor (post-burn means ± SE)"; fontsize=SUPTITLE_FS, tellwidth=false)
    for (r, (met, ytitle, center0)) in enumerate(metrics)
        for (c, anc) in enumerate(uniq_anchors)
            sub = cs_df[cs_df.anchor .== anc, :]
            ys = Float64[]; es = Float64[]; labels = String[]
            for m in mode_order
                rows = sub[sub.mode .== m, :]
                if isempty(rows); continue; end
                push!(ys, Float64(rows[1, met]))
                se_col = Symbol(String(met) |> s -> replace(s, "_mean" => "_se"))
                push!(es, hasproperty(rows, se_col) ? Float64(rows[1, se_col]) : 0.0)
                push!(labels, m)
            end
            ax = Axis(fig[r, c]; title = (r == 1 ? anc : ""),
                      ylabel = ytitle, xticks=(1:length(labels), labels),
                      xticklabelsize=TICK_FS, xticklabelrotation=π/4,
                      titlesize=TITLE_FS, ylabelsize=LABEL_FS,
                      yticklabelsize=TICK_FS)
            if isempty(ys); continue; end
            center0 && hlines!(ax, [0.0]; color=:gray50, linestyle=:dash)
            barplot!(ax, 1:length(ys), ys; color=COL_BROKER)
            errorbars!(ax, 1:length(ys), ys, es; color=:black, whiskerwidth=6)
        end
    end
    out = joinpath(FIG_ROOT, "ablation_bars.png")
    save(out, fig); println("wrote $(out)")
end

"""Compare temporal trajectories of selected ablation modes at one anchor.
Per spec §13.2: compare Full (:none), BlindBroker, NoAccessBroker, FrozenGraph,
FreezeBrokerLearning over time for one broker-dominant anchor."""
function plot_ablation_temporal(anchor::String="broker_dominant")
    subdir = "ablations"
    if !isdir(joinpath(SIMS_ROOT, subdir))
        note_missing("ablation_temporal_selected.png",
                     "missing ablations per-cell caches")
        return
    end
    modes = ["none", "BlindBroker", "NoAccessBroker", "FrozenGraph",
             "FreezeBrokerLearning"]
    fig = Figure(size=(1300, 700))
    Label(fig[0, 1:3], "Ablation temporal — anchor: $(anchor)";
          fontsize=SUPTITLE_FS, tellwidth=false)
    specs = [
        (:pi_broker_slot, "π_b", 1, 1, false),
        (:rank_gap,       "rank_gap", 1, 2, true),
        (:net_value_gap,  "net_value_gap", 1, 3, true),
        (:access_new_edge_frac_brk, "access_new_edge", 2, 1, false),
        (:broker_fill_rate, "broker_fill_rate", 2, 2, false),
        (:welfare_agents_period, "welfare_agents_period", 2, 3, true),
    ]
    colors = Makie.wong_colors()
    axes = Dict{Symbol,Any}()
    for (col, title, r, c, z) in specs
        ax = Axis(fig[r, c]; title=title, xlabel="period", titlesize=TITLE_FS,
                  xlabelsize=LABEL_FS, ylabelsize=LABEL_FS,
                  xticklabelsize=TICK_FS, yticklabelsize=TICK_FS)
        z && hlines!(ax, [0.0]; color=:gray50, linestyle=:dash)
        axes[col] = ax
    end
    for (i, mode) in enumerate(modes)
        cid = "$(anchor)_$(mode)"
        dfs = load_cell_metrics(subdir, cid; arm=:treatment)
        isempty(dfs) && continue
        T = maximum(nrow, dfs)
        meanv(col) = begin
            M = fill(NaN, length(dfs), T)
            for (k, d) in enumerate(dfs)
                if hasproperty(d, col)
                    v = try Float64.(d[!, col]) catch; fill(NaN, nrow(d)) end
                    n = min(length(v), T); @inbounds M[k, 1:n] = v[1:n]
                end
            end
            [begin
                vv = filter(!isnan, view(M, :, t))
                isempty(vv) ? NaN : mean(vv)
             end for t in 1:T]
        end
        color = colors[(i-1) % length(colors) + 1]
        for (col, _, _, _, _) in specs
            try
                ys = meanv(col)
                lines!(axes[col], 1:T, ys; color=color, label=mode, linewidth=1.6)
            catch e
                @warn "ablation temporal: column $col unavailable for $cid" exception=e
            end
        end
    end
    axislegend(axes[:pi_broker_slot]; position=:lt, labelsize=8, framewidth=0.5)
    out = joinpath(FIG_ROOT, "ablation_temporal_selected.png")
    save(out, fig); println("wrote $(out)")
end

# ─────────────────────────────────────────────────────────────────────────────
# Temporal helpers: load per-period metrics for one cell (all seeds, one arm)
# ─────────────────────────────────────────────────────────────────────────────

function load_cell_metrics(subdir::String, cell_id::String; arm::Symbol=:treatment)
    dir = joinpath(SIMS_ROOT, subdir)
    isdir(dir) || return DataFrame[]
    pattern = "cell__$(cell_id)__seed_"
    dfs = DataFrame[]
    for f in sort!(readdir(dir, join=true))
        base = basename(f)
        if startswith(base, pattern) && endswith(f, "__arm_$(String(arm)).jld2")
            d = JLD2.load(f)
            push!(dfs, d["metrics"]::DataFrame)
        end
    end
    return dfs
end

# ─────────────────────────────────────────────────────────────────────────────
# Sanity diagnostics (§15.1)
# ─────────────────────────────────────────────────────────────────────────────

function plot_sanity_diagnostics()
    cs = read_cell_summaries("sanity")
    if cs === nothing
        note_missing("sanity_diagnostics.png", "missing sanity_cell_summaries.csv")
        return
    end
    fig = Figure(size=(1400, 800))
    Label(fig[0, 1:4], "Sanity diagnostics (post-burn means ± SE)"; fontsize=SUPTITLE_FS, tellwidth=false)
    cell_labels = [replace(String(c), r"^\""=>"", r"\"$"=>"") for c in cs.cell_id]
    metrics = [
        (:rank_gap_mean, :rank_gap_se, "rank_gap", true),
        (:r2_gap_mean, :r2_gap_pooled_se, "r²_gap", true),
        (:pi_broker_slot_mean, :pi_broker_slot_se, "π_b", false),
        (:fill_rate_gap_mean, :fill_rate_gap_se, "fill_rate_gap", true),
        (:net_value_gap_mean, :net_value_gap_se, "net_value_gap", true),
        (:access_new_edge_frac_brk_mean, nothing, "access_new_edge_frac_brk", false),
        (:assessment_prior_partner_frac_brk_mean, nothing, "assessment_prior_partner_frac_brk", false),
        (:betweenness_mean, nothing, "betweenness", false),
    ]
    for (i, (met, se_col, ytitle, center0)) in enumerate(metrics)
        r = div(i-1, 4) + 1; c = mod(i-1, 4) + 1
        ys = Float64.(cs[:, met])
        es = se_col === nothing ? zeros(length(ys)) :
             (hasproperty(cs, se_col) ? Float64.(cs[:, se_col]) : zeros(length(ys)))
        ax = Axis(fig[r, c]; title=ytitle, xticks=(1:length(ys), cell_labels),
                  xticklabelsize=TICK_FS-1, xticklabelrotation=π/3,
                  titlesize=TITLE_FS, yticklabelsize=TICK_FS)
        center0 && hlines!(ax, [0.0]; color=:gray50, linestyle=:dash)
        barplot!(ax, 1:length(ys), ys; color=COL_DIAG)
        errorbars!(ax, 1:length(ys), ys, es; color=:black, whiskerwidth=5)
    end
    out = joinpath(FIG_ROOT, "sanity_diagnostics.png")
    save(out, fig); println("wrote $(out)")
end

# ─────────────────────────────────────────────────────────────────────────────
# Pilot (§15.2) — table-style phase panels and temporal overlay
# ─────────────────────────────────────────────────────────────────────────────

function plot_pilot_panels()
    cs = read_cell_summaries("pilot_delta_rho")
    if cs === nothing
        note_missing("pilot_phase_panels.png", "missing pilot_delta_rho_cell_summaries.csv")
        return
    end
    fig = Figure(size=(1100, 650))
    Label(fig[0, 1:3], "Pilot — 5 anchor cells (post-burn means ± SE)";
          fontsize=SUPTITLE_FS, tellwidth=false)
    labels = [replace(String(c), r"^\""=>"", r"\"$"=>"") for c in cs.cell_id]
    metrics = [
        (:pi_broker_slot_mean, :pi_broker_slot_se, "π_b", false),
        (:rank_gap_mean, :rank_gap_se, "rank_gap", true),
        (:net_value_gap_mean, :net_value_gap_se, "net_value_gap", true),
        (:fill_rate_gap_mean, :fill_rate_gap_se, "fill_rate_gap", true),
        (:access_new_edge_frac_brk_mean, nothing, "access_new_edge", false),
        (:r2_gap_mean, nothing, "r²_gap", true),
    ]
    for (i, (met, se, ytitle, center0)) in enumerate(metrics)
        r = div(i-1, 3) + 1; c = mod(i-1, 3) + 1
        ys = Float64.(cs[:, met])
        es = se === nothing ? zeros(length(ys)) :
             (hasproperty(cs, se) ? Float64.(cs[:, se]) : zeros(length(ys)))
        ax = Axis(fig[r, c]; title=ytitle, xticks=(1:length(ys), labels),
                  xticklabelsize=TICK_FS-1, xticklabelrotation=π/3,
                  titlesize=TITLE_FS, yticklabelsize=TICK_FS)
        center0 && hlines!(ax, [0.0]; color=:gray50, linestyle=:dash)
        barplot!(ax, 1:length(ys), ys; color=COL_DIAG)
        errorbars!(ax, 1:length(ys), ys, es; color=:black, whiskerwidth=5)
    end
    out = joinpath(FIG_ROOT, "pilot_phase_panels.png")
    save(out, fig); println("wrote $(out)")
end

function plot_pilot_temporal()
    subdir = "pilot_delta_rho"
    if !isdir(joinpath(SIMS_ROOT, subdir))
        note_missing("pilot_temporal_overlay.png", "missing pilot_delta_rho per-cell caches")
        return
    end
    caches = filter(f -> endswith(f, "_arm_treatment.jld2"),
                    readdir(joinpath(SIMS_ROOT, subdir)))
    cell_ids = filter(!isempty, unique(
        map(caches) do f
            m = match(r"cell__(.+?)__seed_", f)
            m === nothing ? "" : String(m.captures[1])
        end
    ))
    isempty(cell_ids) && (note_missing("pilot_temporal_overlay.png", "no pilot cells cached"); return)

    fig = Figure(size=(1200, 700))
    Label(fig[0, 1:2], "Pilot — temporal overlay (treatment arm)"; fontsize=SUPTITLE_FS, tellwidth=false)
    colors = Makie.wong_colors()
    ax1 = Axis(fig[1, 1]; title="π_b", xlabel="period", ylabel="π_b",
               titlesize=TITLE_FS)
    ax2 = Axis(fig[1, 2]; title="net_value_gap", xlabel="period", ylabel="net_value_gap",
               titlesize=TITLE_FS)
    hlines!(ax2, [0.0]; color=:gray50, linestyle=:dash)
    ax3 = Axis(fig[2, 1]; title="rank_gap", xlabel="period", ylabel="rank_gap",
               titlesize=TITLE_FS)
    hlines!(ax3, [0.0]; color=:gray50, linestyle=:dash)
    ax4 = Axis(fig[2, 2]; title="access_new_edge_frac_brk", xlabel="period", ylabel="frac",
               titlesize=TITLE_FS)
    for (i, cid) in enumerate(cell_ids)
        dfs = load_cell_metrics(subdir, cid; arm=:treatment)
        isempty(dfs) && continue
        T = maximum(nrow, dfs)
        # Mean across seeds, NaN-safe
        meanv(col) = begin
            M = fill(NaN, length(dfs), T)
            for (k, d) in enumerate(dfs)
                v = try Float64.(d[!, col]) catch; fill(NaN, nrow(d)) end
                n = min(length(v), T)
                @inbounds M[k, 1:n] = v[1:n]
            end
            [begin
                col_vals = filter(!isnan, view(M, :, t))
                isempty(col_vals) ? NaN : mean(col_vals)
             end for t in 1:T]
        end
        periods = 1:T
        color = colors[(i-1) % length(colors) + 1]
        lines!(ax1, periods, meanv(:pi_broker_slot); color=color, label=cid)
        lines!(ax2, periods, meanv(:net_value_gap); color=color)
        lines!(ax3, periods, meanv(:rank_gap); color=color)
        lines!(ax4, periods, meanv(:access_new_edge_frac_brk); color=color)
    end
    axislegend(ax1; position=:lb, labelsize=8, framewidth=0.5)
    out = joinpath(FIG_ROOT, "pilot_temporal_overlay.png")
    save(out, fig); println("wrote $(out)")
end

# ─────────────────────────────────────────────────────────────────────────────
# Full-confirm comparison (§14)
# ─────────────────────────────────────────────────────────────────────────────

function plot_full_confirm_comparison()
    simple = read_cell_summaries("delta_rho")  # treat delta_rho as "simplified" source
    full   = read_cell_summaries("full_confirm")
    if full === nothing
        note_missing("full_confirm_comparison.png", "missing full_confirm_cell_summaries.csv")
        return
    end
    full_labels = [replace(String(c), r"^\""=>"", r"\"$"=>"") for c in full.cell_id]
    fig = Figure(size=(1200, 800))
    Label(fig[0, 1:2], "Full-confirm comparison (N=1000/T=200 vs N=300/T=120)";
          fontsize=SUPTITLE_FS, tellwidth=false)

    metrics = [(:pi_broker_slot_mean, "π_b"), (:net_value_gap_mean, "net_value_gap"),
               (:rank_gap_mean, "rank_gap"), (:r2_gap_mean, "r²_gap")]
    for (i, (met, ytitle)) in enumerate(metrics)
        r = div(i-1, 2) + 1; c = mod(i-1, 2) + 1
        ax = Axis(fig[r, c]; title=ytitle, xticks=(1:length(full_labels), full_labels),
                  xticklabelsize=TICK_FS, xticklabelrotation=π/4, titlesize=TITLE_FS,
                  yticklabelsize=TICK_FS)
        ys_full = Float64.(full[:, met])
        barplot!(ax, 1:length(ys_full), ys_full; color=COL_BROKER,
                 label="full (N=1000)")
        hlines!(ax, [0.0]; color=:gray50, linestyle=:dash)
        if simple !== nothing
            # Each full-confirm cell has an (approximate) simplified counterpart
            # only where parameter overrides match. For now overlay the
            # delta_rho Default cell as a reference dashed line.
            # Pilot/sanity are not directly comparable cell-by-cell.
        end
        if i == 1
            axislegend(ax; position=:lt, labelsize=8, framewidth=0.5)
        end
    end
    out = joinpath(FIG_ROOT, "full_confirm_comparison.png")
    save(out, fig); println("wrote $(out)")
end

# ─────────────────────────────────────────────────────────────────────────────
# Temporal cases overlay (§9) and dynamics dashboards (§10)
# ─────────────────────────────────────────────────────────────────────────────

"""Overlay the selected representative cells on time-series panels.
Cells are chosen from available sweeps; if none exist, logs missing."""
function plot_temporal_cases_overlay()
    # Use delta_rho and fee_cost caches.
    candidates = [
        ("delta_rho", "d0.75_r0.25", "broker-dom (δ=0.75, ρ=0.25)"),
        ("delta_rho", "d0.00_r1.00", "self-dom (δ=0.00, ρ=1.00)"),
        ("fee_cost",  "bfr0.60_ssc0.05", "fee-bypass (fee=0.60, cost=0.05)"),
        ("delta_rho", "d0.25_r0.75", "access-heavy (δ=0.25, ρ=0.75)"),
        ("delta_rho", "d0.50_r0.50", "boundary (δ=0.50, ρ=0.50)"),
    ]
    avail = Tuple{String,String,String}[]
    for (sd, cid, lab) in candidates
        any_cache = false
        dir = joinpath(SIMS_ROOT, sd)
        if isdir(dir)
            for f in readdir(dir)
                if startswith(f, "cell__$(cid)__seed_") && endswith(f, "_arm_treatment.jld2")
                    any_cache = true; break
                end
            end
        end
        any_cache && push!(avail, (sd, cid, lab))
    end
    if isempty(avail)
        note_missing("temporal_cases_overlay.png", "no representative cells found in sweeps")
        return
    end
    fig = Figure(size=(1300, 800))
    Label(fig[0, 1:3], "Representative cells — temporal overlay"; fontsize=SUPTITLE_FS, tellwidth=false)
    colors = Makie.wong_colors()
    ax_specs = [
        (:pi_broker_slot, "Broker slot share", 1, 1, false),
        (:net_value_gap,  "Net channel value gap", 1, 2, true),
        (:rank_gap,       "Prediction rank gap", 1, 3, true),
        (:access_new_edge_frac_brk, "Access: new-edge frac", 2, 1, false),
        (:betweenness,    "Broker betweenness", 2, 2, false),
        (:welfare_agents_period, "Period agent welfare", 2, 3, true),
    ]
    axes = Dict{Symbol,Any}()
    for (col, title, r, c, zero) in ax_specs
        ax = Axis(fig[r, c]; title=title, xlabel="period", titlesize=TITLE_FS,
                  xlabelsize=LABEL_FS, ylabelsize=LABEL_FS,
                  xticklabelsize=TICK_FS, yticklabelsize=TICK_FS)
        zero && hlines!(ax, [0.0]; color=:gray50, linestyle=:dash)
        axes[col] = ax
    end
    for (i, (sd, cid, lab)) in enumerate(avail)
        dfs = load_cell_metrics(sd, cid)
        isempty(dfs) && continue
        T = maximum(nrow, dfs)
        color = colors[(i-1) % length(colors) + 1]
        meanv(col) = begin
            M = fill(NaN, length(dfs), T)
            for (k, d) in enumerate(dfs)
                v = try Float64.(d[!, col]) catch; fill(NaN, nrow(d)) end
                n = min(length(v), T); @inbounds M[k, 1:n] = v[1:n]
            end
            [begin
                vv = filter(!isnan, view(M, :, t))
                isempty(vv) ? NaN : mean(vv)
             end for t in 1:T]
        end
        periods = 1:T
        for (col, _, _, _, _) in ax_specs
            try
                ys = meanv(col)
                lines!(axes[col], periods, ys; color=color, label=lab, linewidth=1.8)
            catch e
                @warn "temporal overlay: column $col unavailable for $cid" exception=e
            end
        end
    end
    axislegend(axes[:pi_broker_slot]; position=:lb, labelsize=9, framewidth=0.5)
    out = joinpath(FIG_ROOT, "temporal_cases_overlay.png")
    save(out, fig); println("wrote $(out)")
end

"""Build an advantage-dynamics dashboard for a single anchor cell.
Row 1: adoption/matching volume (pi_broker_slot, demand, fill rate, matches)
Row 2: value (q_cond, q/slot, net/slot, net_value_gap)
Row 3: decomposition (quality, fill/access, fee/cost, sum-check)
Row 4: info & structure (rank_gap, r2_gap, broker_history_size, betweenness)"""
function plot_advantage_dynamics(subdir::String, cell_id::String, label::String)
    dfs = load_cell_metrics(subdir, cell_id; arm=:treatment)
    if isempty(dfs)
        note_missing("advantage_dynamics_$(label).png",
                     "no cached treatment runs for $(subdir)/$(cell_id)")
        return
    end
    T = maximum(nrow, dfs)
    periods = 1:T
    meanv(col) = begin
        M = fill(NaN, length(dfs), T)
        for (k, d) in enumerate(dfs)
            if hasproperty(d, col)
                v = try Float64.(d[!, col]) catch; fill(NaN, nrow(d)) end
                n = min(length(v), T); @inbounds M[k, 1:n] = v[1:n]
            end
        end
        [begin
            vv = filter(!isnan, view(M, :, t))
            isempty(vv) ? NaN : mean(vv)
         end for t in 1:T]
    end

    fig = Figure(size=(1500, 1200))
    Label(fig[0, 1:4], "Advantage dynamics — $(label) ($(subdir)/$(cell_id))";
          fontsize=SUPTITLE_FS, tellwidth=false)
    # Row 1
    ax = Axis(fig[1, 1]; title="π_b", xlabel="period", titlesize=TITLE_FS)
    lines!(ax, periods, meanv(:pi_broker_slot); color=COL_BROKER, linewidth=2)
    ax = Axis(fig[1, 2]; title="demand by channel", xlabel="period", titlesize=TITLE_FS)
    lines!(ax, periods, meanv(:self_demand_slots);   color=COL_AGENT, label="self", linewidth=2)
    lines!(ax, periods, meanv(:broker_demand_slots); color=COL_BROKER, label="broker", linewidth=2)
    axislegend(ax; position=:lt, labelsize=8)
    ax = Axis(fig[1, 3]; title="fill rate by channel", xlabel="period", titlesize=TITLE_FS)
    lines!(ax, periods, meanv(:self_fill_rate);   color=COL_AGENT, label="self")
    lines!(ax, periods, meanv(:broker_fill_rate); color=COL_BROKER, label="broker")
    axislegend(ax; position=:lb, labelsize=8)
    ax = Axis(fig[1, 4]; title="matches by channel", xlabel="period", titlesize=TITLE_FS)
    lines!(ax, periods, meanv(:n_self_matches);    color=COL_AGENT, label="self")
    lines!(ax, periods, meanv(:n_broker_standard); color=COL_BROKER, label="broker")
    axislegend(ax; position=:lb, labelsize=8)

    # Row 2
    ax = Axis(fig[2, 1]; title="conditional match quality", xlabel="period", titlesize=TITLE_FS)
    lines!(ax, periods, meanv(:q_self_mean_cond);   color=COL_AGENT,  label="self")
    lines!(ax, periods, meanv(:q_broker_mean_cond); color=COL_BROKER, label="broker")
    axislegend(ax; position=:lb, labelsize=8)
    ax = Axis(fig[2, 2]; title="gross q / demanded slot", xlabel="period", titlesize=TITLE_FS)
    lines!(ax, periods, meanv(:q_self_per_demand_slot);   color=COL_AGENT,  label="self")
    lines!(ax, periods, meanv(:q_broker_per_demand_slot); color=COL_BROKER, label="broker")
    axislegend(ax; position=:lb, labelsize=8)
    ax = Axis(fig[2, 3]; title="net / demanded slot", xlabel="period", titlesize=TITLE_FS)
    lines!(ax, periods, meanv(:net_self_per_demand_slot);   color=COL_AGENT,  label="self")
    lines!(ax, periods, meanv(:net_broker_per_demand_slot); color=COL_BROKER, label="broker")
    axislegend(ax; position=:lb, labelsize=8)
    ax = Axis(fig[2, 4]; title="net value gap (broker − self)", xlabel="period", titlesize=TITLE_FS)
    hlines!(ax, [0.0]; color=:gray50, linestyle=:dash)
    lines!(ax, periods, meanv(:net_value_gap); color=COL_GAP, linewidth=2)

    # Row 3
    ax = Axis(fig[3, 1]; title="quality_selection component", xlabel="period", titlesize=TITLE_FS)
    hlines!(ax, [0.0]; color=:gray50, linestyle=:dash)
    lines!(ax, periods, meanv(:quality_selection_component); color=COL_DIAG)
    ax = Axis(fig[3, 2]; title="fill/access component", xlabel="period", titlesize=TITLE_FS)
    hlines!(ax, [0.0]; color=:gray50, linestyle=:dash)
    lines!(ax, periods, meanv(:fill_access_component); color=COL_ACCESS)
    ax = Axis(fig[3, 3]; title="fee/cost component", xlabel="period", titlesize=TITLE_FS)
    hlines!(ax, [0.0]; color=:gray50, linestyle=:dash)
    lines!(ax, periods, meanv(:fee_cost_component); color=COL_CAPTURE)
    ax = Axis(fig[3, 4]; title="decomposition check (sum vs net_value_gap)", xlabel="period", titlesize=TITLE_FS)
    hlines!(ax, [0.0]; color=:gray50, linestyle=:dash)
    qs = meanv(:quality_selection_component); fa = meanv(:fill_access_component);
    fc = meanv(:fee_cost_component); nv = meanv(:net_value_gap)
    lines!(ax, periods, qs .+ fa .+ fc; color=:black, linewidth=2, label="sum")
    lines!(ax, periods, nv; color=COL_GAP, linewidth=2, linestyle=:dash, label="net_value_gap")
    axislegend(ax; position=:lb, labelsize=8)

    # Row 4
    ax = Axis(fig[4, 1]; title="rank_gap", xlabel="period", titlesize=TITLE_FS)
    hlines!(ax, [0.0]; color=:gray50, linestyle=:dash)
    lines!(ax, periods, meanv(:rank_gap); color=COL_GAP, linewidth=2)
    ax = Axis(fig[4, 2]; title="r²_gap", xlabel="period", titlesize=TITLE_FS)
    hlines!(ax, [0.0]; color=:gray50, linestyle=:dash)
    lines!(ax, periods, meanv(:r2_gap); color=COL_GAP, linewidth=2)
    ax = Axis(fig[4, 3]; title="broker_history_size", xlabel="period", titlesize=TITLE_FS)
    lines!(ax, periods, meanv(:broker_history_size); color=COL_REPUTATION, linewidth=2)
    ax = Axis(fig[4, 4]; title="betweenness", xlabel="period", titlesize=TITLE_FS)
    lines!(ax, periods, meanv(:betweenness); color=COL_DIAG, linewidth=2)

    out = joinpath(FIG_ROOT, "advantage_dynamics_$(label).png")
    save(out, fig); println("wrote $(out)")
end

"""Phase portrait: 2x2 with period-ordered trajectory through (x,y) pairs for
one representative cell."""
function plot_phase_portraits(subdir::String, cell_id::String, label::String)
    dfs = load_cell_metrics(subdir, cell_id; arm=:treatment)
    if isempty(dfs)
        note_missing("phase_portraits_$(label).png",
                     "no cached runs for $(subdir)/$(cell_id)")
        return
    end
    T = maximum(nrow, dfs)
    meanv(col) = begin
        M = fill(NaN, length(dfs), T)
        for (k, d) in enumerate(dfs)
            if hasproperty(d, col)
                v = try Float64.(d[!, col]) catch; fill(NaN, nrow(d)) end
                n = min(length(v), T); @inbounds M[k, 1:n] = v[1:n]
            end
        end
        [begin
            vv = filter(!isnan, view(M, :, t))
            isempty(vv) ? NaN : mean(vv)
         end for t in 1:T]
    end
    fig = Figure(size=(900, 800))
    Label(fig[0, 1:2], "Phase portraits — $(label) ($(subdir)/$(cell_id))";
          fontsize=SUPTITLE_FS, tellwidth=false)
    pairs = [
        ((:rank_gap, "rank_gap"), (:pi_broker_slot, "π_b")),
        ((:net_value_gap, "net_value_gap"), (:pi_broker_slot, "π_b")),
        ((:betweenness, "betweenness"), (:rank_gap, "rank_gap")),
        ((:access_new_edge_frac_brk, "access_new_edge"),
         (:assessment_prior_partner_frac_brk, "assessment_prior_partner")),
    ]
    for (i, ((xc, xl), (yc, yl))) in enumerate(pairs)
        r = div(i-1, 2) + 1; c = mod(i-1, 2) + 1
        xs = meanv(xc); ys = meanv(yc)
        ax = Axis(fig[r, c]; xlabel=xl, ylabel=yl, title="$(yl) vs $(xl)",
                  titlesize=TITLE_FS, xlabelsize=LABEL_FS, ylabelsize=LABEL_FS,
                  xticklabelsize=TICK_FS, yticklabelsize=TICK_FS)
        # Color by period progression (darker = earlier)
        n = length(xs)
        scatter!(ax, xs, ys; color=1:n, colormap=:viridis, markersize=4)
        lines!(ax, xs, ys; color=:gray40, linewidth=0.8)
    end
    out = joinpath(FIG_ROOT, "phase_portraits_$(label).png")
    save(out, fig); println("wrote $(out)")
end

# ─────────────────────────────────────────────────────────────────────────────
# Driver
# ─────────────────────────────────────────────────────────────────────────────

function run_all()
    # Sanity & pilot
    plot_sanity_diagnostics()
    plot_pilot_panels()
    plot_pilot_temporal()
    # Main sweeps
    for sw in (:delta_rho, :fee_cost, :transparency_access, :learning_turnover)
        plot_phase_panels(sw)
        plot_regime_map(sw)
    end
    # Threshold robustness maps (delta_rho, fee_cost)
    for sw in (:delta_rho, :fee_cost)
        plot_regime_map(sw; threshold_broker=0.30)
        plot_regime_map(sw; threshold_broker=0.70)
    end
    # Fee sensitivity
    plot_fee_sensitivity()
    # Temporal overlay & dynamics dashboards
    plot_temporal_cases_overlay()
    plot_advantage_dynamics("delta_rho", "d0.75_r0.25", "broker_dominant")
    plot_advantage_dynamics("delta_rho", "d0.00_r1.00", "self_search")
    plot_phase_portraits("delta_rho", "d0.75_r0.25", "broker_dominant")
    plot_phase_portraits("delta_rho", "d0.00_r1.00", "self_search")
    # Ablation
    plot_ablation_bars()
    plot_ablation_temporal("broker_dominant")
    # Full-confirm
    plot_full_confirm_comparison()
end

function main()
    args = parse_args(ARGS)
    if args[:all]
        run_all()
        return
    end
    stage = args[:stage]
    if stage === nothing
        println("specify --stage or --all"); return
    end
    if stage == :sanity
        plot_sanity_diagnostics()
    elseif stage == :pilot
        plot_pilot_panels(); plot_pilot_temporal()
    elseif stage == :sweep
        sw = args[:sweep]
        sw === nothing && error("--sweep required with --stage sweep")
        plot_phase_panels(sw); plot_regime_map(sw)
        if sw in (:delta_rho, :fee_cost)
            plot_regime_map(sw; threshold_broker=0.30)
            plot_regime_map(sw; threshold_broker=0.70)
        end
        if sw == :fee_cost
            plot_fee_sensitivity()
        end
    elseif stage == :ablation
        plot_ablation_bars()
        plot_ablation_temporal("broker_dominant")
    elseif stage == :full_confirm
        plot_full_confirm_comparison()
    elseif stage == :diagnostic || stage == :diagnostic_blind
        # Reuse sanity-style bar panels for diagnostic tags
        tag = String(stage)
        cs = read_cell_summaries(tag)
        if cs === nothing
            note_missing("$(tag)_bars.png", "missing $(tag)_cell_summaries.csv"); return
        end
        fig = Figure(size=(1100, 650))
        Label(fig[0, 1:3], "$(tag) — post-burn means ± SE"; fontsize=SUPTITLE_FS, tellwidth=false)
        labels = [replace(String(c), r"^\""=>"", r"\"$"=>"") for c in cs.cell_id]
        metrics = [
            (:pi_broker_slot_mean, :pi_broker_slot_se, "π_b", false),
            (:rank_gap_mean, :rank_gap_se, "rank_gap", true),
            (:r2_gap_demeaned_mean, :r2_gap_demeaned_se, "r²_gap (demeaned)", true),
            (:rank_gap_residualized_mean, :rank_gap_residualized_se, "rank_gap (residualized)", true),
            (:net_value_gap_mean, :net_value_gap_se, "net_value_gap", true),
            (:fill_rate_gap_mean, :fill_rate_gap_se, "fill_rate_gap", true),
        ]
        for (i, (met, se, ytitle, c0)) in enumerate(metrics)
            r = div(i-1, 3) + 1; c = mod(i-1, 3) + 1
            ys = Float64.(cs[:, met])
            es = hasproperty(cs, se) ? Float64.(cs[:, se]) : zeros(length(ys))
            ax = Axis(fig[r, c]; title=ytitle, xticks=(1:length(ys), labels),
                      xticklabelsize=TICK_FS-1, xticklabelrotation=π/3,
                      titlesize=TITLE_FS, yticklabelsize=TICK_FS)
            c0 && hlines!(ax, [0.0]; color=:gray50, linestyle=:dash)
            barplot!(ax, 1:length(ys), ys; color=COL_DIAG)
            errorbars!(ax, 1:length(ys), ys, es; color=:black, whiskerwidth=5)
        end
        out = joinpath(FIG_ROOT, "$(tag)_bars.png"); save(out, fig); println("wrote $(out)")
    else
        error("unknown stage: $stage")
    end
end

main()
