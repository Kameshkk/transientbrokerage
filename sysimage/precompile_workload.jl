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
