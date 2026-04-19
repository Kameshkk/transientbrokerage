"""
    types.jl

Agent types, model state, and supporting structs for the Transient Brokerage ABM (v0.2).
Unimodal matching market: N agents + 1 broker on a single network G.
"""

# ─────────────────────────────────────────────────────────────────────────────
# Neural network
# ─────────────────────────────────────────────────────────────────────────────

"""One-hidden-layer ReLU network: y = w2' * relu(W1 * z + b1) + b2."""
mutable struct NeuralNet
    W1::Matrix{Float64}   # h x d_in
    b1::Vector{Float64}   # h
    w2::Vector{Float64}   # h
    b2::Float64           # scalar
end

"""Pre-allocated gradient and activation buffers matching a NeuralNet's shape.
Owning these per-NN (rather than per-thread) keeps training thread-safe:
each agent's NN and its buffers can be trained concurrently without locks."""
mutable struct NNGradBuffers
    dW1::Matrix{Float64}  # h x d_in  (gradient of W1)
    db1::Vector{Float64}  # h         (gradient of b1)
    dw2::Vector{Float64}  # h         (gradient of w2)
    db2::Base.RefValue{Float64}       # scalar gradient of b2

    # Forward/backward activation scratch. Grow on demand to at most
    # TRAIN_WINDOW columns in the hot path.
    Z1::Matrix{Float64}   # h x n  pre-activations
    A::Matrix{Float64}    # h x n  post-ReLU activations
    dZ1::Matrix{Float64}  # h x n  gradient wrt pre-activations
    Y::Vector{Float64}    # n      predictions, reused as residuals
end

"""Create zero-initialized gradient buffers matching `nn`."""
function NNGradBuffers(nn::NeuralNet)
    h, d_in = size(nn.W1)
    return NNGradBuffers(
        zeros(h, d_in),
        zeros(h),
        zeros(h),
        Ref(0.0),
        Matrix{Float64}(undef, h, 0),
        Matrix{Float64}(undef, h, 0),
        Matrix{Float64}(undef, h, 0),
        Float64[],
    )
end

"""Ensure the activation scratch buffers are sized for at least n columns.
Grows with doubling to amortize resizes across training calls."""
function ensure_nn_buffers!(grad::NNGradBuffers, h::Int, n::Int)
    cur = size(grad.Z1, 2)
    if cur < n
        new_cap = max(n, 2 * cur, 16)
        grad.Z1 = Matrix{Float64}(undef, h, new_cap)
        grad.A = Matrix{Float64}(undef, h, new_cap)
        grad.dZ1 = Matrix{Float64}(undef, h, new_cap)
        resize!(grad.Y, new_cap)
    end
    return nothing
end

# ─────────────────────────────────────────────────────────────────────────────
# Current-period match tracking
# ─────────────────────────────────────────────────────────────────────────────

"""A single current-period match in an agent's match list. The same partner may
appear multiple times (concurrent matches with the same counterparty are allowed)."""
struct ActiveMatch
    partner_id::Int
    is_principal::Bool   # false = standard brokered or self-search; true = principal mode (Model 1)
    channel::Symbol      # :self or :broker
end

# ─────────────────────────────────────────────────────────────────────────────
# Agent
# ─────────────────────────────────────────────────────────────────────────────

"""Market participant with a type, prediction model, match history, and satisfaction scores."""
Base.@kwdef mutable struct Agent
    id::Int
    type::Vector{Float64}                    # x_i on the unit sphere, length d

    # Current-period matches (list, allows duplicates; length <= K)
    active_matches::Vector{ActiveMatch} = ActiveMatch[]

    # Experience history: d x capacity matrix (column-major, doubling growth)
    # Column j holds the partner type from the j-th match
    history_X::Matrix{Float64}               # d x capacity
    history_q::Vector{Float64}               # realized outputs, matching columns of history_X
    history_count::Int = 0                   # total observations recorded

    # Neural network and prediction buffer
    nn::NeuralNet
    nn_grad::NNGradBuffers                   # pre-allocated gradient buffers
    predict_buf::Vector{Float64}             # length h_a, for zero-alloc forward pass
    n_new_obs::Int = 0                       # observations since last training (for adaptive schedule)
    train_X::Matrix{Float64} = Matrix{Float64}(undef, 0, 0)  # contiguous training scratch
    train_q::Vector{Float64} = Float64[]                     # matching q scratch

    # Per-partner average tracking (direct-indexed by partner agent ID)
    partner_sum::Vector{Float64}             # length N; sum of realized q for matches with partner j
    partner_count::Vector{Int}               # length N; count of matches with partner j

    # Satisfaction indices (EWMA)
    satisfaction_self::Float64 = 0.0
    satisfaction_broker::Float64 = 0.0
    tried_broker::Bool = false

    # Tenure
    periods_alive::Int = 0

    # Cumulative match counters for broker-dependency D_j (§12i).
    # n_matches_any: every accepted match the agent has participated in, any role, any channel.
    # n_principal_acquired: subset where the agent was the counterparty acquired in principal mode.
    # Reset to zero on entry; not decremented on match expiration.
    n_matches_any::Int = 0
    n_principal_acquired::Int = 0
end

"""Number of valid history entries for an agent."""
effective_history_size(agent::Agent) = agent.history_count

"""Available capacity: K minus active matches."""
available_capacity(agent::Agent, K::Int) = K - length(agent.active_matches)

"""Available capacity after subtracting period-local reserved principal inventory."""
available_capacity(agent::Agent, K::Int, blocked_slots::Int) =
    max(K - length(agent.active_matches) - blocked_slots, 0)

"""True if the agent currently participates in at least one broker-channel match."""
has_active_broker_match(agent::Agent) = any(am -> am.channel == :broker, agent.active_matches)

"""Mean realized output with partner j, or NaN if no prior match."""
function partner_mean(agent::Agent, j::Int)
    c = agent.partner_count[j]
    return c > 0 ? agent.partner_sum[j] / c : NaN
end

"""Record a new observation to agent's history, growing the buffer if needed."""
function record_agent_history!(agent::Agent, partner_type::AbstractVector{Float64}, q::Float64)
    agent.history_count += 1
    agent.n_new_obs += 1
    n = agent.history_count
    cap = size(agent.history_X, 2)

    # Grow buffer if needed (doubling strategy)
    if n > cap
        new_cap = max(2 * cap, 16)
        d = size(agent.history_X, 1)
        new_X = Matrix{Float64}(undef, d, new_cap)
        new_X[:, 1:cap] .= agent.history_X
        agent.history_X = new_X
        resize!(agent.history_q, new_cap)
    end

    agent.history_X[:, n] .= partner_type
    agent.history_q[n] = q
    return nothing
end

"""Update per-partner sum and count after a match with partner j."""
function update_partner_mean!(agent::Agent, partner_id::Int, q::Float64)
    agent.partner_sum[partner_id] += q
    agent.partner_count[partner_id] += 1
    return nothing
end

# ─────────────────────────────────────────────────────────────────────────────
# Proposed match (for conflict resolution)
# ─────────────────────────────────────────────────────────────────────────────

"""A proposed match before acceptance/rejection in the sequential formation step.

`ask_j` caches the counterparty's acquisition reservation q̄_j at the time the
broker commits to principal capture. `capture_qhat` caches the broker's
acquisition-time slot forecast for principal inventory exposure. Both are NaN
for non-principal proposals. Caching keeps the recorded capture decision aligned
with the broker's ex-ante acquisition rule even if execution occurs later in
the period."""
struct ProposedMatch
    demander_id::Int
    counterparty_id::Int
    channel::Symbol         # :self or :broker
    evaluation::Float64     # q_hat (stranger) or q_bar (known neighbor) used for demander selection
    is_principal::Bool      # Model 1: broker takes one side
    ask_j::Float64          # acquisition reservation cached at mode selection; NaN if unused
    capture_qhat::Float64   # acquisition-time q̂ used for principal exposure; NaN if unused
end

"""Accepted match record emitted by sequential formation and consumed later in the same step."""
const AcceptedMatch = NamedTuple{
    (:demander_id, :counterparty_id, :channel, :is_principal, :q_realized,
     :q_predicted, :ask_j, :capture_qhat),
    Tuple{Int, Int, Symbol, Bool, Float64, Float64, Float64, Float64},
}

# ─────────────────────────────────────────────────────────────────────────────
# Broker
# ─────────────────────────────────────────────────────────────────────────────

"""Single intermediary with a standing roster, current clients, cross-agent history, and prediction model."""
Base.@kwdef mutable struct Broker
    node_id::Int                              # permanent node in G (= N + 1)
    roster::Set{Int} = Set{Int}()             # agent IDs on the broker's roster
    current_clients::Set{Int} = Set{Int}()    # agents outsourcing in the current period

    # Experience history: d x capacity matrices (column-major, doubling growth)
    history_Xi::Matrix{Float64}               # demander types
    history_Xj::Matrix{Float64}               # counterparty types
    history_q::Vector{Float64}                # realized outputs
    history_count::Int = 0

    # Neural network
    nn::NeuralNet
    nn_grad::NNGradBuffers
    predict_buf::Vector{Float64}              # length h_b
    n_new_obs::Int = 0

    # Pre-allocated training matrix for symmetry augmentation (2d x 2*capacity)
    train_X::Matrix{Float64}
    train_q::Vector{Float64}

    # Reputation
    last_reputation::Float64 = 0.0
    has_had_clients::Bool = false

    # Capture confidence:
    # - capture_confidence_mae: EWMA of recent broker-controlled exposure errors
    # - capture_confidence_ready: whether live broker activity has initialized κ
    capture_confidence_mae::Float64 = 0.0
    capture_confidence_ready::Bool = false
end

"""Number of valid history entries for the broker."""
effective_history_size(broker::Broker) = broker.history_count

"""Record a brokered observation to the broker's history, growing buffers if needed."""
function record_broker_history!(broker::Broker, xi::AbstractVector{Float64},
                                xj::AbstractVector{Float64}, q::Float64)
    broker.history_count += 1
    broker.n_new_obs += 1
    n = broker.history_count
    cap = size(broker.history_Xi, 2)

    # Grow buffers if needed
    if n > cap
        d = size(broker.history_Xi, 1)
        new_cap = max(2 * cap, 32)
        new_Xi = Matrix{Float64}(undef, d, new_cap)
        new_Xi[:, 1:cap] .= broker.history_Xi
        broker.history_Xi = new_Xi
        new_Xj = Matrix{Float64}(undef, d, new_cap)
        new_Xj[:, 1:cap] .= broker.history_Xj
        broker.history_Xj = new_Xj
        resize!(broker.history_q, new_cap)

        # Also grow symmetry-augmented training buffers
        new_train_cap = 2 * new_cap
        d2 = size(broker.train_X, 1)  # 2d
        new_train_X = Matrix{Float64}(undef, d2, new_train_cap)
        broker.train_X = new_train_X
        resize!(broker.train_q, new_train_cap)
    end

    broker.history_Xi[:, n] .= xi
    broker.history_Xj[:, n] .= xj
    broker.history_q[n] = q
    return nothing
end

# ─────────────────────────────────────────────────────────────────────────────
# Matching environment and calibration
# ─────────────────────────────────────────────────────────────────────────────

"""Matching environment: ideal type c, SPD interaction matrix A, symmetric regime
operator B, and noise scale."""
struct MatchingEnv
    d::Int
    rho::Float64
    c::Vector{Float64}       # ideal type vector
    A::Matrix{Float64}       # SPD interaction matrix (M_A'M_A)
    B::Matrix{Float64}       # symmetric regime operator, weighted-orthogonalized against A
    delta::Float64            # gain strength
    sigma_eps::Float64        # match output noise SD
end

"""Output-scale constants derived from Monte Carlo calibration."""
struct CalibrationConstants
    q_cal::Float64     # calibration reference E[q] (scales r, phi, c_s; not used for initialization)
    r::Float64         # outside option (0.60 * q_cal)
    phi::Float64       # successful standard-placement fee
    c_s::Float64       # self-search cost per demanded slot
end

"""Prediction quality metrics: R-squared, bias, and rank correlation."""
struct PredictionQuality
    r_squared::Float64
    bias::Float64
    rank_corr::Float64
end

# ─────────────────────────────────────────────────────────────────────────────
# Type curve geometry
# ─────────────────────────────────────────────────────────────────────────────

"""Sinusoidal curve on the unit sphere with s active dimensions out of d.
Agent types are drawn at random positions on this curve, then perturbed."""
struct CurveGeometry
    d::Int
    s::Int                        # active dimensions (1..s have nonzero curve amplitude)
    freqs::Vector{Int}            # per-dimension integer frequencies (length s), from U{1,...,5}
    phases::Vector{Float64}       # per-dimension phases (length s), from U[0, 2π)
end

# ─────────────────────────────────────────────────────────────────────────────
# Period accumulators
# ─────────────────────────────────────────────────────────────────────────────

"""Per-period counters and output vectors. All fields reset each tick."""
Base.@kwdef mutable struct PeriodAccumulators
    # Match counts by channel
    n_self_matches::Int = 0
    n_broker_standard::Int = 0
    n_broker_principal::Int = 0

    # Realized output by channel
    q_self::Vector{Float64} = Float64[]
    q_broker_standard::Vector{Float64} = Float64[]
    q_broker_principal::Vector{Float64} = Float64[]

    # Slot-level acquisition exposures in Model 1.
    # - capture_realized: realized value of the acquired slot, 0 if unplaced
    # - capture_ask: acquisition reservation q̄_j paid for the slot
    # - capture_qhat: acquisition-time forecast used to justify the slot
    # These feed both κ_b^t and the capture diagnostics (§12i).
    capture_realized::Vector{Float64} = Float64[]
    capture_ask::Vector{Float64} = Float64[]
    capture_qhat::Vector{Float64} = Float64[]

    # Distinct counterparties acquired in principal mode this period (for supply scarcity)
    principal_acquired_ids::Set{Int} = Set{Int}()

    # Access vs assessment decomposition
    access_count::Int = 0       # counterparty was NOT a neighbor of demander
    assessment_count::Int = 0   # counterparty WAS a neighbor

    # Broker-advantage pre-match classification (base model).
    # Computed using edge_pre and prior_pair_history_pre snapshots captured
    # before finalize_accepted_proposal! mutates G or partner_count.
    n_broker_access_new_edge::Int = 0                   # j was NOT a neighbor of i pre-match
    n_broker_assessment_reachable_no_prior::Int = 0     # j was a neighbor but no prior pair history
    n_broker_assessment_prior_partner::Int = 0          # i and j had prior realized match history
    n_broker_matches_classified::Int = 0                # sum of the three (sanity check)

    # Outsourcing rate and demand
    n_demanders::Int = 0
    n_outsourced::Int = 0           # demanders who chose the broker channel
    outsourced_slots::Int = 0       # demand slots routed through the broker channel
    total_demand::Int = 0           # total demand slots across all demanders

    # Broker-advantage demand/fill/value logging. These mirror the runbook's
    # self_demand_slots / broker_demand_slots / *_filled_slots terminology.
    # self_demand_slots + broker_demand_slots == total_demand (by construction).
    self_demand_slots::Int = 0
    broker_demand_slots::Int = 0
    self_filled_slots::Int = 0
    broker_filled_slots::Int = 0
    q_self_sum::Float64 = 0.0
    q_broker_sum::Float64 = 0.0
    n_agents_tried_broker::Int = 0       # cumulative: count of agents with tried_broker=true
    n_agents_abandoned_broker::Int = 0   # tried broker AND satisfaction_broker < satisfaction_self
    welfare_agents_period::Float64 = 0.0   # realized pair output minus agent-side costs
    welfare_broker_period::Float64 = 0.0   # phi * broker_filled_slots

    # Broker fill-failure breakdown (base model). broker_unfilled_slots always
    # equals broker_demand_slots − broker_filled_slots. The two reason buckets
    # attribute each unfilled slot to one of:
    #   broker_unfilled_pref_exhausted:  demander's broker preference list was
    #     walked to the end without holding an accepted proposal (every
    #     candidate either failed admissibility or was displaced).
    #   broker_unfilled_capacity_limited: max rounds were reached while the
    #     demander still had untried preferences — typically the partners
    #     ran out of open slots before the demander's turn to commit.
    broker_unfilled_slots::Int = 0
    broker_unfilled_pref_exhausted::Int = 0
    broker_unfilled_capacity_limited::Int = 0

    # Prediction/outcome pairs from actual matches (subject to selection bias)
    agent_predicted::Vector{Float64} = Float64[]
    agent_realized::Vector{Float64} = Float64[]
    broker_predicted::Vector{Float64} = Float64[]
    broker_realized::Vector{Float64} = Float64[]
    broker_error_abs_sum::Float64 = 0.0    # broker-controlled exposure errors for κ_b^t
    broker_error_count::Int = 0
    broker_confidence_mae::Float64 = NaN

    # Holdout: per-agent averaged over sampled agents (both agent and broker
    # evaluated on the same per-agent partner sets for comparability)
    agent_holdout_r2::Float64 = NaN
    agent_holdout_bias::Float64 = NaN
    agent_holdout_rank::Float64 = NaN
    agent_holdout_rmse::Float64 = NaN
    broker_holdout_r2::Float64 = NaN
    broker_holdout_bias::Float64 = NaN
    broker_holdout_rank::Float64 = NaN
    broker_holdout_rmse::Float64 = NaN
    # Pooled holdout metrics — Spearman and R² computed by concatenating every
    # sampled (agent_i, partner_j) triple across all sampled i's into one big
    # vector per predictor. Tests the predictor's ability to rank/fit across
    # DIFFERENT agents, not only within a single agent's partner set.
    agent_holdout_r2_pooled::Float64 = NaN
    broker_holdout_r2_pooled::Float64 = NaN
    agent_holdout_rank_pooled::Float64 = NaN
    broker_holdout_rank_pooled::Float64 = NaN
    # Within-agent de-meaned R² — per-agent R² computed after subtracting the
    # within-agent means of pred and true, then averaged across agents. Removes
    # any advantage the broker gets from simply modelling a per-agent offset.
    agent_holdout_r2_demeaned::Float64 = NaN
    broker_holdout_r2_demeaned::Float64 = NaN
    # Two-way residualized holdout metrics — the pooled holdout is treated as a
    # partially observed (i, j) matrix; grand, row (per focal i), and column
    # (per partner j) main effects are removed from both the truth and each
    # predictor; R² and Spearman rank are recomputed on the pair-specific
    # residuals. A predictor that merely captures global quality (like
    # :BlindBroker would) has low r²/rank on these; only predictors that
    # capture pair-conditioned signal score well.
    agent_holdout_r2_residualized::Float64 = NaN
    broker_holdout_r2_residualized::Float64 = NaN
    agent_holdout_rank_residualized::Float64 = NaN
    broker_holdout_rank_residualized::Float64 = NaN

    # Roster
    roster_size::Int = 0
    broker_access_size::Int = 0
end

"""Zero all per-period fields while preserving vector capacity for reuse."""
function reset_accumulators!(a::PeriodAccumulators)
    a.n_self_matches = 0
    a.n_broker_standard = 0
    a.n_broker_principal = 0
    empty!(a.q_self)
    empty!(a.q_broker_standard)
    empty!(a.q_broker_principal)
    empty!(a.capture_realized)
    empty!(a.capture_ask)
    empty!(a.capture_qhat)
    empty!(a.principal_acquired_ids)
    a.access_count = 0
    a.assessment_count = 0
    a.n_broker_access_new_edge = 0
    a.n_broker_assessment_reachable_no_prior = 0
    a.n_broker_assessment_prior_partner = 0
    a.n_broker_matches_classified = 0
    a.n_demanders = 0
    a.n_outsourced = 0
    a.outsourced_slots = 0
    a.total_demand = 0
    a.self_demand_slots = 0
    a.broker_demand_slots = 0
    a.self_filled_slots = 0
    a.broker_filled_slots = 0
    a.q_self_sum = 0.0
    a.q_broker_sum = 0.0
    a.n_agents_tried_broker = 0
    a.n_agents_abandoned_broker = 0
    a.welfare_agents_period = 0.0
    a.welfare_broker_period = 0.0
    a.broker_unfilled_slots = 0
    a.broker_unfilled_pref_exhausted = 0
    a.broker_unfilled_capacity_limited = 0
    empty!(a.agent_predicted)
    empty!(a.agent_realized)
    empty!(a.broker_predicted)
    empty!(a.broker_realized)
    a.broker_error_abs_sum = 0.0
    a.broker_error_count = 0
    a.broker_confidence_mae = NaN
    a.agent_holdout_r2 = NaN
    a.agent_holdout_bias = NaN
    a.agent_holdout_rank = NaN
    a.agent_holdout_rmse = NaN
    a.broker_holdout_r2 = NaN
    a.broker_holdout_bias = NaN
    a.broker_holdout_rank = NaN
    a.broker_holdout_rmse = NaN
    a.agent_holdout_r2_pooled = NaN
    a.broker_holdout_r2_pooled = NaN
    a.agent_holdout_rank_pooled = NaN
    a.broker_holdout_rank_pooled = NaN
    a.agent_holdout_r2_demeaned = NaN
    a.broker_holdout_r2_demeaned = NaN
    a.agent_holdout_r2_residualized = NaN
    a.broker_holdout_r2_residualized = NaN
    a.agent_holdout_rank_residualized = NaN
    a.broker_holdout_rank_residualized = NaN
    a.roster_size = 0
    a.broker_access_size = 0
    return nothing
end

# ─────────────────────────────────────────────────────────────────────────────
# Network measures cache
# ─────────────────────────────────────────────────────────────────────────────

"""Broker's network position measures, recomputed periodically."""
mutable struct CachedNetworkMeasures
    betweenness::Float64      # standard Freeman betweenness (broker node in G)
    constraint::Float64       # Burt's constraint (broker's ego network)
    effective_size::Float64   # Burt's effective size (non-redundant contacts)
end

CachedNetworkMeasures() = CachedNetworkMeasures(0.0, 1.0, 0.0)

# ─────────────────────────────────────────────────────────────────────────────
# Model parameters
# ─────────────────────────────────────────────────────────────────────────────

"""Immutable simulation parameters for the unimodal matching model."""
struct ModelParams
    # Population and types
    N::Int                       # agent count (default 1000)
    d::Int                       # type dimensionality (fixed at 8)
    s::Int                       # active dimensions of type curve (default 8; swept {2,4,6,8})

    # Matching function
    rho::Float64                 # quality-interaction mixing weight (default 0.50)
    delta::Float64               # regime gain strength (default 0.5)
    sigma_x::Float64             # type noise scale (default 0.5)
    sigma_eps::Float64           # match output noise SD (default 0.10)

    # Match accounting
    K::Int                       # match capacity (default 5)
    p_demand::Float64            # per-slot demand probability (default 0.50)

    # Network
    k::Int                       # Watts-Strogatz ring lattice degree (default 6)
    p_rewire::Float64            # rewiring probability (default 0.1)

    # Economics
    omega::Float64               # satisfaction recency weight (default 0.2)
    search_cost_rate::Float64    # shared search-cost rate on the surplus scale (default 0.15)

    # Neural network
    eta_lr::Float64              # learning rate (default 0.03)
    E_init::Int                  # initial training steps (default 200)
    h_a::Int                     # agent hidden layer width (default 16)
    h_b::Int                     # broker hidden layer width (default 32)

    # Search
    n_strangers::Int             # max strangers in self-search (default 5)
    eta::Float64                 # agent entry/exit rate (default 0.02)
    roster_churn::Float64        # standing-roster exogenous churn probability (default 0.02)

    # Model 1 toggle
    enable_principal::Bool       # resource capture mode (default false)

    # Simulation
    network_measure_interval::Int # M (default 20)
    T::Int                       # total periods (default 200)
    T_burn::Int                  # burn-in periods (default 30)
    seed::Int                    # RNG seed

    # Decoupled fee/cost rates (broker-advantage study).
    # Default to search_cost_rate in default_params when not specified — preserves
    # existing behavior of the legacy single-rate calibration.
    broker_fee_rate::Float64      # rate used to compute phi (successful broker fee)
    self_search_cost_rate::Float64 # rate used to compute c_s (self-demanded slot cost)

    # Broker roster share (fraction of population kept on the standing roster).
    # Default 0.20 matches the legacy ROSTER_TARGET_FRAC constant. Exposed as a
    # parameter so the transparency_access sweep can vary it.
    alpha_R::Float64

    # Ablation mode for broker-advantage experiments.
    # :none (default) leaves the base model unchanged. Supported modes:
    #   :NoBroker                — force all demand to :self (paired counterfactual).
    #   :NoRegime                — set delta=0 at env construction.
    #   :NoAccessBroker          — broker may only recommend current neighbors of demander.
    #   :FrozenGraph             — successful matches do not add graph edges.
    #   :NoTurnover              — entry/exit disabled (equivalent to eta=0).
    #   :FreezeBrokerLearning    — broker NN not retrained after initial warm-up.
    #   :BlindBroker             — (not yet implemented; errors at initialize_model).
    #   :EqualCapacityBroker     — (not yet implemented; errors at initialize_model).
    ablation::Symbol
end

# ─────────────────────────────────────────────────────────────────────────────
# Model state
# ─────────────────────────────────────────────────────────────────────────────

"""
Pre-allocated per-step scratch buffers reused across agents and calls.
Lives on ModelState; reset between uses via `empty!` on the vector fields.
"""
Base.@kwdef mutable struct SimWorkspace
    # Round-search scratch
    neighbor_ids::Vector{Int} = Int[]
    neighbor_evals::Vector{Float64} = Float64[]
    neighbor_caps::Vector{Int} = Int[]
    stranger_ids::Vector{Int} = Int[]
    stranger_evals::Vector{Float64} = Float64[]
    stranger_caps::Vector{Int} = Int[]
    eligible::Vector{Int} = Int[]
    # Neighbor bitset: nbr_mask[j] = true iff j is a neighbor of the current agent.
    # Length N+1 (extra slot for the broker node). Reset after each round-search call.
    nbr_mask::Vector{Bool} = Bool[]
    # Tracks which indices we set in nbr_mask this call, so we can clear only those.
    nbr_marked::Vector{Int} = Int[]

    roster_members::Vector{Int} = Int[]
    roster_capacity::Vector{Int} = Int[]
    access_seen::Vector{Bool} = Bool[]
    access_touched::Vector{Int} = Int[]  # sparse-clear markers for broker access deduplication
    # Quality matrix Q[demander_idx, access_idx] (unique demanders x broker access set)
    Q::Matrix{Float64} = Matrix{Float64}(undef, 0, 0)
    # Batched prediction scratch
    Z_batch::Matrix{Float64} = Matrix{Float64}(undef, 0, 0)  # 2d x n_pairs input
    H_batch::Matrix{Float64} = Matrix{Float64}(undef, 0, 0)  # h x n_pairs hidden
    Y_batch::Vector{Float64} = Float64[]                      # n_pairs output
    # Deduplication: demander_idx[agent_id] = position in unique_demanders (0 = unseen).
    # Length N, sparse-cleared after each call (like nbr_mask pattern).
    unique_demanders::Vector{Int} = Int[]
    demander_idx::Vector{Int} = Int[]
    demander_touched::Vector{Int} = Int[]  # which entries of demander_idx we set
    demander_remaining::Vector{Int} = Int[]  # slots remaining per unique demander
    # Sorted greedy: pre-allocated (negated_val, flat_index) pairs, sorted in-place.
    sort_pairs::Vector{Tuple{Float64, Int}} = Tuple{Float64, Int}[]

    # step_period! per-period scratch (avoids Dict/Set allocation each period)
    demand_agent_ids::Vector{Int} = Int[]     # agents with demand
    demand_channels::Vector{Symbol} = Symbol[]  # channel per demander
    demand_counts::Vector{Int} = Int[]        # d_i per demander
    demand_remaining::Vector{Int} = Int[]     # remaining slots by demander index during round matching
    demand_failed::Vector{Bool} = Bool[]      # demander exhausted feasible set this period
    broker_clients_ws::Vector{Int} = Int[]
    was_connected_i::Vector{Int} = Int[]  # pre-formation edge snapshot
    was_connected_j::Vector{Int} = Int[]
    # For each (was_connected_i[k], was_connected_j[k]) pre-match pair, records
    # whether i and j had any prior realized match history (partner_count > 0)
    # BEFORE the current match edge/history updates. Base-model invariant:
    # partner_count > 0 ⟹ edge exists pre-match, so this is meaningful only for
    # pairs already present in wc_i/wc_j. Non-connected-pre brokered pairs are
    # always access_new_edge and therefore never carry a prior-history flag.
    was_prior_partner::Vector{Bool} = Bool[]
    remaining_cap::Vector{Int} = Int[]    # capacity tracker for match formation
    principal_reserved_capacity::Vector{Int} = Int[]
    principal_reserved_touched::Vector{Int} = Int[]
    principal_inventory_ids::Vector{Int} = Int[]
    principal_inventory_asks::Vector{Float64} = Float64[]
    principal_inventory_slot_qhats::Vector{Vector{Float64}} = Vector{Vector{Float64}}()
    principal_inventory_next_slot::Vector{Int} = Int[]
    principal_inventory_round_ids::Vector{Int} = Int[]
    principal_inventory_round_blocks::Vector{Int} = Int[]
    principal_inventory_round_remaining::Vector{Int} = Int[]
    principal_round_taken::Vector{Bool} = Bool[]
    capture_plan_remaining::Vector{Int} = Int[]
    demander_q_sum::Vector{Float64} = Float64[]   # realized output by demander id
    broker_standard_count::Vector{Int} = Int[]    # successful standard broker matches by demander id
    all_proposals::Vector{ProposedMatch} = ProposedMatch[]
    accepted_matches::Vector{AcceptedMatch} = AcceptedMatch[]
    round_active_positions::Vector{Int} = Int[]
    round_open_agents::Vector{Int} = Int[]
    round_broker_indices::Vector{Int} = Int[]
    round_broker_demanders::Vector{Int} = Int[]
    round_pref_offsets::Vector{Int} = Int[]
    round_next_pref::Vector{Int} = Int[]
    round_pref_owner::Vector{Int} = Int[]
    round_queue::Vector{Int} = Int[]
    round_agent_to_active::Vector{Int} = Int[]
    round_agent_touched::Vector{Int} = Int[]
    round_outgoing_prop_idx::Vector{Int} = Int[]
    round_hold_counts::Vector{Int} = Int[]
    round_held_prop_idx::Matrix{Int} = Matrix{Int}(undef, 0, 0)
    round_held_scores::Matrix{Float64} = Matrix{Float64}(undef, 0, 0)
    round_broker_pref_matches::Vector{ProposedMatch} = ProposedMatch[]
    round_broker_pref_counts::Vector{Int} = Int[]
    period_broker_demanders::Vector{Int} = Int[]
    period_broker_access_ids::Vector{Int} = Int[]
    period_broker_open_cols::Vector{Int} = Int[]
    period_broker_ranked_cols::Matrix{Int} = Matrix{Int}(undef, 0, 0)
    period_broker_open_mask::Vector{Bool} = Bool[]
    period_broker_open_touched::Vector{Int} = Int[]

    # Holdout evaluation scratch (reused each period in step.jl)
    Ax_buf::Vector{Float64} = Float64[]
    Bx_buf::Vector{Float64} = Float64[]
    holdout_z_buf::Vector{Float64} = Float64[]
    holdout_agent_preds::Vector{Float64} = Float64[]
    holdout_agent_trues::Vector{Float64} = Float64[]
    holdout_broker_preds::Vector{Float64} = Float64[]
    holdout_pred_order::Vector{Int} = Int[]
    holdout_true_order::Vector{Int} = Int[]
    holdout_pred_ranks::Vector{Float64} = Float64[]
    holdout_true_ranks::Vector{Float64} = Float64[]
end

"""Complete simulation state: all agents, broker, network, environment, and accumulators."""
Base.@kwdef mutable struct ModelState
    params::ModelParams
    rng::StableRNG
    period::Int = 0
    env::MatchingEnv
    cal::CalibrationConstants
    curve_geo::CurveGeometry
    agents::Vector{Agent}
    broker::Broker
    G::SimpleGraph{Int}                       # N+1 nodes: agents 1:N, broker at N+1
    accum::PeriodAccumulators = PeriodAccumulators()
    cached_network::CachedNetworkMeasures = CachedNetworkMeasures()
    workspace::SimWorkspace = SimWorkspace()
end
