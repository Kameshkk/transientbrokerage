"""
    build_sysimage.jl

Build a Julia sysimage baking TransientBrokerage + its heavy dependencies. Cuts
per-task TTFX on slurm tasks from ~60s to ~5s.

Usage:
    julia --project=sysimage sysimage/build_sysimage.jl

Writes:
    data/sysimage/sys_ba.so

Runs a short representative simulation first with --trace-compile so the
sysimage captures the hot-path specialisations actually used by the study.
"""

using Pkg

const REPO_ROOT = normpath(joinpath(@__DIR__, ".."))
const MAIN_PROJECT = REPO_ROOT
const OUT = joinpath(REPO_ROOT, "data", "sysimage", "sys_ba.so")

# NOTE: compute nodes on della have no internet. PackageCompiler must already
# be installed in this side-car env (do it on the login node once):
#     julia --project=sysimage -e 'using Pkg; Pkg.add("PackageCompiler")'
# We only activate and use it here.
println("=== activating sysimage env ===")
Pkg.activate(@__DIR__)
Pkg.instantiate()  # no network needed if Manifest already resolved; errors if missing
using PackageCompiler

# Representative workload that exercises the hot path so PackageCompiler's
# automatic precompile statement recorder picks up the actual JIT'd methods.
const PRECOMPILE_SCRIPT = joinpath(@__DIR__, "precompile_workload.jl")
open(PRECOMPILE_SCRIPT, "w") do io
    write(io, """
        using TransientBrokerage
        # Small representative run; exercises simulation, calibration, holdout,
        # and the broker-advantage metrics.
        p = default_params(seed=42, T=15, T_burn=3, N=120, d=4, s=4, k=4, E_init=20,
                           network_measure_interval=5)
        state, df = run_simulation(p)
        # Also exercise ablation paths.
        for ab in (:NoBroker, :NoRegime, :NoAccessBroker, :FrozenGraph,
                   :NoTurnover, :FreezeBrokerLearning)
            q = default_params(seed=1, T=5, T_burn=1, N=80, d=4, s=4, k=4, E_init=20,
                               network_measure_interval=5, ablation=ab)
            run_simulation(q)
        end
        # Ensure DataFrames / JLD2 / CSV-adjacent paths are specialised too.
        using DataFrames: DataFrame, eachrow, propertynames
        using JLD2
        io_tmp = tempname() * ".jld2"
        jldsave(io_tmp; df=df)
        _ = JLD2.load(io_tmp)
    """)
end

const PACKAGES = [
    :TransientBrokerage,
    :DataFrames,
    :JLD2,
    :Distributions,
    :StatsBase,
    :StableRNGs,
    :Graphs,
    :MultivariateStats,
    # Stdlib Statistics and LinearAlgebra are listed under [deps] in the main
    # Project.toml so PackageCompiler can bake them. Other stdlibs (Printf,
    # Random) are implicitly available at runtime; do not add them here or
    # PackageCompiler errors with "package(s) Printf not in project".
    :Statistics,
    :LinearAlgebra,
]

println("=== building sysimage to $OUT ===")
println("  packages: ", PACKAGES)
println("  project (for dep resolution): $MAIN_PROJECT")

create_sysimage(
    PACKAGES;
    sysimage_path = OUT,
    precompile_execution_file = PRECOMPILE_SCRIPT,
    project = MAIN_PROJECT,
)

println("=== done: wrote $OUT ===")
println("  file size: ", round(filesize(OUT) / 1024 / 1024; digits=1), " MB")
