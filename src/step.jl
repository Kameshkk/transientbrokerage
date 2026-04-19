"""
    step.jl

Main simulation loop: one period of the model (§9, Steps 0-6).

Step 0: Current-period match reset
Step 1: Demand generation and outsourcing decisions
Step 2: Candidate evaluation (train NNs and pre-period capture planning)
Step 3: Within-period round-based match formation
Step 4: Learning updates (histories already recorded in Step 3; satisfaction, reputation)
Step 5: Entry/exit
Step 6: Recording and measurement
"""

using Random: AbstractRNG, shuffle!
using Distributions: Binomial
using Graphs: neighbors, has_edge, rem_edge!
using LinearAlgebra: BLAS
using Base.Threads: @threads
using StatsBase: corspearman
using StableRNGs: StableRNG

# ─────────────────────────────────────────────────────────────────────────────

"""
    step_period!(state) -> Nothing

Execute one complete period of the simulation.
"""
agent_retrains_this_period(agent_id::Int, period::Int)::Bool = isodd(agent_id) == isodd(period)

function refresh_broker_roster!(state::ModelState)
    p = state.params
    broker = state.broker
    rng = state.rng
    N = p.N
    target_size = roster_target_size(N, p.alpha_R)

    if p.roster_churn > 0.0 && !isempty(broker.roster)
        for rid in collect(broker.roster)
            rand(rng) < p.roster_churn && delete!(broker.roster, rid)
        end
    end

    n_missing = target_size - length(broker.roster)
    if n_missing > 0
        candidates = Int[]
        sizehint!(candidates, max(N - length(broker.roster), 0))
        for i in 1:N
            (i in broker.roster) && continue
            push!(candidates, i)
        end
        shuffle!(rng, candidates)
        for idx in 1:min(n_missing, length(candidates))
            push!(broker.roster, candidates[idx])
        end
    end

    sync_broker_edges!(state.G, state.agents, broker)
    return nothing
end

function prefix_rmse(predicted::AbstractVector{<:Real},
                     realized::AbstractVector{<:Real},
                     n::Int)::Float64
    sq_err_sum = 0.0
    @inbounds for idx in 1:n
        err = predicted[idx] - realized[idx]
        sq_err_sum += err * err
    end
    return sqrt(sq_err_sum / n)
end

function step_period!(state::ModelState)
    state.period += 1
    p = state.params
    rng = state.rng
    N = p.N
    K = p.K
    d = p.d
    agents = state.agents
    broker = state.broker
    G = state.G
    env = state.env
    cal = state.cal
    ws = state.workspace

    reset_accumulators!(state.accum)
    state.accum.broker_confidence_mae =
        broker.capture_confidence_ready ? broker.capture_confidence_mae : NaN

    # ══════════════════════════════════════════════════════════════════════
    # Step 0: Current-period match reset
    # ══════════════════════════════════════════════════════════════════════
    for agent in agents
        empty!(agent.active_matches)
    end
    reset_principal_inventory!(ws, N)

    # Clear the current-client overlay from the prior period, then refresh the
    # standing roster after prior-period turnover and before current-period
    # demand realization.
    empty!(broker.current_clients)
    refresh_broker_roster!(state)

    # ══════════════════════════════════════════════════════════════════════
    # Step 1: Demand generation and outsourcing decisions
    # ══════════════════════════════════════════════════════════════════════
    # Reuse workspace vectors (avoid Dict/Set allocation every period)
    demand_agent_ids = ws.demand_agent_ids; empty!(demand_agent_ids)
    demand_channels = ws.demand_channels; empty!(demand_channels)
    demand_counts = ws.demand_counts; empty!(demand_counts)
    broker_clients = ws.broker_clients_ws; empty!(broker_clients)

    broker_rep = broker_reputation(broker)

    for i in 1:N
        agents[i].periods_alive += 1
        avail_cap = available_capacity(agents[i], K)
        avail_cap <= 0 && continue

        d_i = rand(rng, Binomial(avail_cap, p.p_demand))
        d_i <= 0 && continue

        # Call outsourcing_decision even when the ablation will override its
        # result — this keeps the RNG state consumption identical between paired
        # treatment and control arms when ablation==:NoBroker.
        raw_channel = outsourcing_decision(agents[i], broker_rep, rng)
        channel = p.ablation == :NoBroker ? :self : raw_channel

        push!(demand_agent_ids, i)
        push!(demand_channels, channel)
        push!(demand_counts, d_i)
        state.accum.n_demanders += 1
        state.accum.total_demand += d_i

        if channel == :broker
            push!(broker_clients, i)
            push!(broker.current_clients, i)
            state.accum.n_outsourced += 1
            state.accum.outsourced_slots += d_i
            state.accum.broker_demand_slots += d_i
        else
            state.accum.self_demand_slots += d_i
        end
    end
    sync_broker_edges!(G, agents, broker)

    # ══════════════════════════════════════════════════════════════════════
    # Step 2: Candidate evaluation
    # ══════════════════════════════════════════════════════════════════════

    # 2.1: Train neural networks (adaptive steps).
    # Agents retrain on an alternating parity schedule so each agent updates
    # every other period while still accumulating all new observations.
    # train_nn! materializes contiguous Matrix/Vector copies so train_step! sees
    # concrete types (no SubArray BLAS overhead).
    prev_blas = BLAS.get_num_threads()
    BLAS.set_num_threads(1)
    @threads for i in 1:N
        a = agents[i]
        a.history_count > 0 && a.n_new_obs > 0 &&
            agent_retrains_this_period(i, state.period) && train_agent_nn!(a, p)
    end
    BLAS.set_num_threads(prev_blas)
    # :FreezeBrokerLearning — retain initial warm-up but skip re-training during
    # production periods. Warm-up happens in initialize_model before period 1, so
    # gating here covers all production updates.
    if broker.history_count > 0 && broker.n_new_obs > 0 &&
       p.ablation != :FreezeBrokerLearning
        train_broker_nn!(broker, p)
    end

    # 2.2: Literal same-period acquisition planning (Model 1)
    plan_period_capture!(demand_agent_ids, demand_channels, demand_counts,
                         agents, broker, p, cal; ws=ws)

    # 2.3: Within-period round-based principal execution and residual match formation
    accepted = round_match_formation!(demand_agent_ids, demand_channels, demand_counts,
                                      agents, broker, env, G, p, cal, rng;
                                      ws=ws, accepted_matches=ws.accepted_matches)
    sync_broker_edges!(G, agents, broker)

    # ── Broker fill-failure breakdown ──
    # After round_match_formation!, ws.demand_remaining holds unfilled slot
    # counts per demander index and ws.demand_failed marks demanders that
    # exhausted their preference list without holding a final proposal.
    # Attribute each unfilled broker slot accordingly. Total unfilled slots
    # must equal broker_demand_slots - broker_filled_slots (asserted below).
    @inbounds for idx in eachindex(demand_agent_ids)
        demand_channels[idx] == :broker || continue
        unfilled = ws.demand_remaining[idx]
        unfilled > 0 || continue
        state.accum.broker_unfilled_slots += unfilled
        if ws.demand_failed[idx]
            state.accum.broker_unfilled_pref_exhausted += unfilled
        else
            state.accum.broker_unfilled_capacity_limited += unfilled
        end
    end

    # ══════════════════════════════════════════════════════════════════════
    # Step 4: Learning and state updates
    # ══════════════════════════════════════════════════════════════════════

    # 4.1: Histories already recorded during round_match_formation!

    # 4.2: Satisfaction update
    update_satisfaction!(agents, accepted, demand_agent_ids, demand_channels, demand_counts, cal, p;
                         demander_sum=ws.demander_q_sum,
                         broker_standard_count=ws.broker_standard_count)

    # 4.3: Broker reputation
    update_broker_reputation!(broker, agents, broker_clients)

    # Record accumulators
    for m in accepted
        # Selected-sample prediction quality (by channel)
        if m.channel == :self
            push!(state.accum.agent_predicted, m.q_predicted)
            push!(state.accum.agent_realized, m.q_realized)
        elseif m.channel == :broker
            push!(state.accum.broker_predicted, m.q_predicted)
            push!(state.accum.broker_realized, m.q_realized)
            exposure_qhat = m.is_principal ? m.capture_qhat : m.q_predicted
            state.accum.broker_error_abs_sum += abs(m.q_realized - exposure_qhat)
            state.accum.broker_error_count += 1
        end

        if m.channel == :self
            state.accum.n_self_matches += 1
            state.accum.self_filled_slots += 1
            state.accum.q_self_sum += m.q_realized
            push!(state.accum.q_self, m.q_realized)
        elseif m.is_principal
            state.accum.n_broker_principal += 1
            push!(state.accum.q_broker_principal, m.q_realized)
            push!(state.accum.capture_realized, m.q_realized)
            push!(state.accum.capture_ask, m.ask_j)
            push!(state.accum.capture_qhat, m.capture_qhat)
        else
            state.accum.n_broker_standard += 1
            state.accum.broker_filled_slots += 1
            state.accum.q_broker_sum += m.q_realized
            push!(state.accum.q_broker_standard, m.q_realized)
        end

        # Access vs assessment (uses per-round pre-finalization edge snapshots)
        wc_i = ws.was_connected_i
        wc_j = ws.was_connected_j
        wc_prior = ws.was_prior_partner
        if m.channel == :broker && !m.is_principal
            # Base-model three-way classification per BROKER_ADVANTAGE_ANALYSIS_SPEC §3.5:
            #   access_new_edge:               edge_pre == false
            #   assessment_reachable_no_prior: edge_pre == true  && prior_pair_history_pre == false
            #   assessment_prior_partner:      prior_pair_history_pre == true
            connected = false
            prior = false
            @inbounds for k in eachindex(wc_i)
                if wc_i[k] == m.demander_id && wc_j[k] == m.counterparty_id
                    connected = true
                    if k <= length(wc_prior)
                        prior = wc_prior[k]
                    end
                    break
                end
            end
            if connected
                state.accum.assessment_count += 1
                if prior
                    state.accum.n_broker_assessment_prior_partner += 1
                else
                    state.accum.n_broker_assessment_reachable_no_prior += 1
                end
            else
                state.accum.access_count += 1
                state.accum.n_broker_access_new_edge += 1
            end
            state.accum.n_broker_matches_classified += 1
        elseif m.channel == :broker && m.is_principal
            # Keep legacy two-way counters in lockstep for principal matches;
            # the new three-way counters are base-model-only and remain 0.
            # (The capture study uses different analysis paths.)
            wc_i_ref = ws.was_connected_i
            wc_j_ref = ws.was_connected_j
            connected = false
            @inbounds for k in eachindex(wc_i_ref)
                if wc_i_ref[k] == m.demander_id && wc_j_ref[k] == m.counterparty_id
                    connected = true; break
                end
            end
            if connected
                state.accum.assessment_count += 1
            else
                state.accum.access_count += 1
            end
        end
    end

    for counterparty_id in ws.principal_inventory_ids
        push!(state.accum.principal_acquired_ids, counterparty_id)
    end
    @inbounds for block_idx in eachindex(ws.principal_inventory_ids)
        ask_j = ws.principal_inventory_asks[block_idx]
        qhats = ws.principal_inventory_slot_qhats[block_idx]
        next_slot = ws.principal_inventory_next_slot[block_idx]
        for slot_idx in next_slot:length(qhats)
            qhat = qhats[slot_idx]
            push!(state.accum.capture_realized, 0.0)
            push!(state.accum.capture_ask, ask_j)
            push!(state.accum.capture_qhat, qhat)
            state.accum.broker_error_abs_sum += abs(qhat)
            state.accum.broker_error_count += 1
        end
    end

    update_capture_confidence_mae!(broker,
                                   state.accum.broker_error_abs_sum,
                                   state.accum.broker_error_count,
                                   p.omega)

    # ── Broker-advantage: period-level welfare (base-model decomposition) ──
    # welfare_agents_period: pair output counted once per accepted match, minus
    #   self-search cost on every self-demanded slot and broker fee on every
    #   successful standard brokered match. Principal matches carry no fee.
    # welfare_broker_period: broker fee revenue this period.
    # These exactly match the CalibrationConstants phi, c_s in use this period.
    welfare_total_q = state.accum.q_self_sum + state.accum.q_broker_sum +
                      sum(state.accum.q_broker_principal; init=0.0)
    self_cost_period = cal.c_s * state.accum.self_demand_slots
    broker_fee_period = cal.phi * state.accum.broker_filled_slots
    state.accum.welfare_agents_period = welfare_total_q - self_cost_period - broker_fee_period
    state.accum.welfare_broker_period = broker_fee_period

    # ── Broker-advantage: adoption heterogeneity ──
    # tried_broker flag set in update_satisfaction! when an agent demanded via broker.
    # Abandonment: tried AND current broker satisfaction is below self satisfaction.
    n_tried = 0
    n_abandoned = 0
    @inbounds for ag in agents
        if ag.tried_broker
            n_tried += 1
            if ag.satisfaction_broker < ag.satisfaction_self
                n_abandoned += 1
            end
        end
    end
    state.accum.n_agents_tried_broker = n_tried
    state.accum.n_agents_abandoned_broker = n_abandoned

    # Holdout evaluation: per-agent R² averaged over sampled agents.
    # For each sampled agent i, evaluate both agent i's NN and the broker's NN
    # on the same n_partners random partners. Compute per-agent R² for each,
    # then average across agents. This makes the two metrics directly comparable.
    n_sample_agents = min(100, N)
    n_partners = 40

    if length(ws.Ax_buf) != d || length(ws.Bx_buf) != d || length(ws.holdout_z_buf) != 2 * d
        ws.Ax_buf = Vector{Float64}(undef, d)
        ws.Bx_buf = Vector{Float64}(undef, d)
        ws.holdout_z_buf = Vector{Float64}(undef, 2 * d)
    end
    length(ws.holdout_agent_preds) == n_partners || resize!(ws.holdout_agent_preds, n_partners)
    length(ws.holdout_agent_trues) == n_partners || resize!(ws.holdout_agent_trues, n_partners)
    length(ws.holdout_broker_preds) == n_partners || resize!(ws.holdout_broker_preds, n_partners)
    length(ws.holdout_pred_order) == n_partners || resize!(ws.holdout_pred_order, n_partners)
    length(ws.holdout_true_order) == n_partners || resize!(ws.holdout_true_order, n_partners)
    length(ws.holdout_pred_ranks) == n_partners || resize!(ws.holdout_pred_ranks, n_partners)
    length(ws.holdout_true_ranks) == n_partners || resize!(ws.holdout_true_ranks, n_partners)
    Ax_buf = ws.Ax_buf; Bx_buf = ws.Bx_buf; z_buf = ws.holdout_z_buf
    agent_preds = ws.holdout_agent_preds
    agent_trues = ws.holdout_agent_trues
    broker_preds = ws.holdout_broker_preds
    pred_order = ws.holdout_pred_order
    true_order = ws.holdout_true_order
    pred_ranks = ws.holdout_pred_ranks
    true_ranks = ws.holdout_true_ranks

    agent_r2_sum = 0.0; agent_bias_sum = 0.0; agent_rank_sum = 0.0; agent_rmse_sum = 0.0
    broker_r2_sum = 0.0; broker_bias_sum = 0.0; broker_rank_sum = 0.0; broker_rmse_sum = 0.0
    n_agents_evaluated = 0; n_broker_evaluated = 0
    # Pooled + within-agent demeaned accumulators (broker-advantage diagnostic).
    pooled_agent = Float64[]; pooled_broker = Float64[]; pooled_true = Float64[]
    sizehint!(pooled_agent, n_sample_agents * n_partners)
    sizehint!(pooled_broker, n_sample_agents * n_partners)
    sizehint!(pooled_true, n_sample_agents * n_partners)
    agent_r2_dm_sum = 0.0; broker_r2_dm_sum = 0.0
    n_agents_r2_dm = 0; n_broker_r2_dm = 0

    for _ in 1:n_sample_agents
        i = rand(rng, 1:N)
        agents[i].history_count == 0 && continue  # exclude uninformed entrants
        n_valid = 0

        for _ in 1:n_partners
            j = rand(rng, 1:N)
            j == i && continue
            n_valid += 1

            q_true = Q_OFFSET + match_signal!(Ax_buf, Bx_buf, agents[i].type, agents[j].type, env)
            agent_preds[n_valid] = predict_nn!(agents[i].nn, agents[i].predict_buf, agents[j].type)
            agent_trues[n_valid] = q_true

            @inbounds for k in 1:d
                # :BlindBroker — zero the focal-agent half of the broker input so
                # the broker receives only partner-side information but retains
                # its cross-agent pooled training data.
                z_buf[k] = p.ablation == :BlindBroker ? 0.0 : agents[i].type[k]
                z_buf[d + k] = agents[j].type[k]
            end
            broker_preds[n_valid] = predict_nn!(broker.nn, broker.predict_buf, z_buf)
        end

        if n_valid >= 5
            se = env.sigma_eps
            prepare_true_ranks!(agent_trues, n_valid, true_order, true_ranks)

            pq_agent = compute_prediction_quality_with_true_ranks!(
                agent_preds, agent_trues, n_valid;
                sigma_eps=se,
                pred_order=pred_order,
                pred_ranks=pred_ranks,
                true_ranks=true_ranks,
            )
            if !isnan(pq_agent.r_squared)
                agent_r2_sum += pq_agent.r_squared
                agent_bias_sum += pq_agent.bias
                agent_rank_sum += pq_agent.rank_corr
                agent_rmse_sum += prefix_rmse(agent_preds, agent_trues, n_valid)
                n_agents_evaluated += 1
            end

            pq_broker = compute_prediction_quality_with_true_ranks!(
                broker_preds, agent_trues, n_valid;
                sigma_eps=se,
                pred_order=pred_order,
                pred_ranks=pred_ranks,
                true_ranks=true_ranks,
            )
            if !isnan(pq_broker.r_squared)
                broker_r2_sum += pq_broker.r_squared
                broker_bias_sum += pq_broker.bias
                broker_rank_sum += pq_broker.rank_corr
                broker_rmse_sum += prefix_rmse(broker_preds, agent_trues, n_valid)
                n_broker_evaluated += 1
            end

            # ── Pooled triples (for pooled rank / pooled R²) ──
            @inbounds for idx in 1:n_valid
                push!(pooled_agent, agent_preds[idx])
                push!(pooled_broker, broker_preds[idx])
                push!(pooled_true, agent_trues[idx])
            end

            # ── Within-agent de-meaned R² ──
            # Subtract the within-agent mean from both pred and true before
            # computing R². Affine-offset advantages are removed; only the
            # shape of the pred-vs-true mapping within one agent's partner set
            # counts.
            true_mean = 0.0
            @inbounds for idx in 1:n_valid
                true_mean += agent_trues[idx]
            end
            true_mean /= n_valid
            ss_tot = 0.0
            @inbounds for idx in 1:n_valid
                d_i = agent_trues[idx] - true_mean
                ss_tot += d_i * d_i
            end
            if ss_tot > 1e-12
                # Agent: de-mean preds and compute residual SS
                a_mean = 0.0
                @inbounds for idx in 1:n_valid
                    a_mean += agent_preds[idx]
                end
                a_mean /= n_valid
                ss_res_a = 0.0
                @inbounds for idx in 1:n_valid
                    err = (agent_preds[idx] - a_mean) - (agent_trues[idx] - true_mean)
                    ss_res_a += err * err
                end
                r2_a_dm = 1.0 - ss_res_a / ss_tot
                if !isnan(r2_a_dm)
                    agent_r2_dm_sum += r2_a_dm
                    n_agents_r2_dm += 1
                end
                # Broker: same
                b_mean = 0.0
                @inbounds for idx in 1:n_valid
                    b_mean += broker_preds[idx]
                end
                b_mean /= n_valid
                ss_res_b = 0.0
                @inbounds for idx in 1:n_valid
                    err = (broker_preds[idx] - b_mean) - (agent_trues[idx] - true_mean)
                    ss_res_b += err * err
                end
                r2_b_dm = 1.0 - ss_res_b / ss_tot
                if !isnan(r2_b_dm)
                    broker_r2_dm_sum += r2_b_dm
                    n_broker_r2_dm += 1
                end
            end
        end
    end

    state.accum.agent_holdout_r2 = n_agents_evaluated > 0 ? agent_r2_sum / n_agents_evaluated : NaN
    state.accum.agent_holdout_bias = n_agents_evaluated > 0 ? agent_bias_sum / n_agents_evaluated : NaN
    state.accum.agent_holdout_rank = n_agents_evaluated > 0 ? agent_rank_sum / n_agents_evaluated : NaN
    state.accum.agent_holdout_rmse = n_agents_evaluated > 0 ? agent_rmse_sum / n_agents_evaluated : NaN
    state.accum.broker_holdout_r2 = n_broker_evaluated > 0 ? broker_r2_sum / n_broker_evaluated : NaN
    state.accum.broker_holdout_bias = n_broker_evaluated > 0 ? broker_bias_sum / n_broker_evaluated : NaN
    state.accum.broker_holdout_rank = n_broker_evaluated > 0 ? broker_rank_sum / n_broker_evaluated : NaN
    state.accum.broker_holdout_rmse = n_broker_evaluated > 0 ? broker_rmse_sum / n_broker_evaluated : NaN

    # ── Pooled holdout metrics ──
    # Note: pooled rank gap tests ability to rank candidates ACROSS different
    # focal agents; the within-agent rank gap tests ability to rank within a
    # focal agent's candidate set. Pooled R² uses the global mean(pool_true)
    # for SS_tot, penalising any predictor that fails to capture per-agent
    # shifts (i.e., penalises agents' NNs which cannot see x_i).
    n_pool = length(pooled_true)
    if n_pool >= 10
        t_mean = sum(pooled_true) / n_pool
        ss_tot_p = 0.0
        @inbounds for k in 1:n_pool
            d_k = pooled_true[k] - t_mean
            ss_tot_p += d_k * d_k
        end
        if ss_tot_p > 1e-12
            ss_a = 0.0; ss_b = 0.0
            @inbounds for k in 1:n_pool
                err_a = pooled_agent[k] - pooled_true[k]
                err_b = pooled_broker[k] - pooled_true[k]
                ss_a += err_a * err_a
                ss_b += err_b * err_b
            end
            state.accum.agent_holdout_r2_pooled = 1.0 - ss_a / ss_tot_p
            state.accum.broker_holdout_r2_pooled = 1.0 - ss_b / ss_tot_p
        end
        state.accum.agent_holdout_rank_pooled = corspearman(pooled_agent, pooled_true)
        state.accum.broker_holdout_rank_pooled = corspearman(pooled_broker, pooled_true)
    end
    state.accum.agent_holdout_r2_demeaned = n_agents_r2_dm > 0 ? agent_r2_dm_sum / n_agents_r2_dm : NaN
    state.accum.broker_holdout_r2_demeaned = n_broker_r2_dm > 0 ? broker_r2_dm_sum / n_broker_r2_dm : NaN

    # ── Two-way residualized holdout metrics ──
    # Fixed-partner holdout so per-partner column means are estimable. Both
    # the truth and each predictor have the TRUE (grand + row + column) means
    # subtracted; R² and Spearman rank are then computed on the pair-specific
    # residual. A predictor that captures only global quality scores zero here
    # (by construction), so this metric isolates pair-conditioned signal.
    #
    # Uses a side-car RNG derived from (seed, period) so the main state.rng
    # stream is not perturbed — critical for preserving backward-compat of
    # legacy seed=42 dynamics. Without this, downstream match noise and
    # entry/exit draws would shift and the preflight QC numbers would differ.
    res_rng = StableRNG(hash((state.params.seed, :residualized, state.period)))
    n_res_agents_target = min(50, N)
    n_res_partners_target = min(40, N - 1)
    partner_ids_arr = Int[]
    seen_partners = Set{Int}()
    attempts = 0
    while length(partner_ids_arr) < n_res_partners_target && attempts < 20 * n_res_partners_target
        attempts += 1
        j = rand(res_rng, 1:N)
        if !(j in seen_partners)
            push!(seen_partners, j)
            push!(partner_ids_arr, j)
        end
    end
    np = length(partner_ids_arr)
    if np >= 10
        true_mat = Matrix{Float64}(undef, n_res_agents_target, np)
        agent_pred_mat = Matrix{Float64}(undef, n_res_agents_target, np)
        broker_pred_mat = Matrix{Float64}(undef, n_res_agents_target, np)
        ag_counter = 0
        agent_attempts = 0
        while ag_counter < n_res_agents_target && agent_attempts < 10 * n_res_agents_target
            agent_attempts += 1
            i = rand(res_rng, 1:N)
            agents[i].history_count == 0 && continue
            ag_counter += 1
            for (p_idx, j) in enumerate(partner_ids_arr)
                if j == i
                    # self-partner: substitute with another random partner
                    j2 = j
                    while j2 == i
                        j2 = rand(res_rng, 1:N)
                    end
                    j = j2
                end
                q_true = Q_OFFSET + match_signal!(Ax_buf, Bx_buf,
                                                  agents[i].type, agents[j].type, env)
                true_mat[ag_counter, p_idx] = q_true
                agent_pred_mat[ag_counter, p_idx] =
                    predict_nn!(agents[i].nn, agents[i].predict_buf, agents[j].type)
                @inbounds for k in 1:d
                    z_buf[k] = p.ablation == :BlindBroker ? 0.0 : agents[i].type[k]
                    z_buf[d + k] = agents[j].type[k]
                end
                broker_pred_mat[ag_counter, p_idx] =
                    predict_nn!(broker.nn, broker.predict_buf, z_buf)
            end
        end

        if ag_counter >= 10
            # TRUE main effects
            mu = 0.0
            @inbounds for i in 1:ag_counter, j in 1:np
                mu += true_mat[i, j]
            end
            mu /= ag_counter * np
            alpha = Vector{Float64}(undef, ag_counter)
            @inbounds for i in 1:ag_counter
                s = 0.0
                for j in 1:np
                    s += true_mat[i, j]
                end
                alpha[i] = s / np - mu
            end
            beta = Vector{Float64}(undef, np)
            @inbounds for j in 1:np
                s = 0.0
                for i in 1:ag_counter
                    s += true_mat[i, j]
                end
                beta[j] = s / ag_counter - mu
            end
            # Residualise using TRUE main effects
            npair = ag_counter * np
            res_true = Vector{Float64}(undef, npair)
            res_agent = Vector{Float64}(undef, npair)
            res_broker = Vector{Float64}(undef, npair)
            @inbounds for i in 1:ag_counter, j in 1:np
                k = (i - 1) * np + j
                adj = mu + alpha[i] + beta[j]
                res_true[k] = true_mat[i, j] - adj
                res_agent[k] = agent_pred_mat[i, j] - adj
                res_broker[k] = broker_pred_mat[i, j] - adj
            end
            ss_tot_res = 0.0
            @inbounds for k in 1:npair
                ss_tot_res += res_true[k] * res_true[k]
            end
            # Also compute the RAW (non-residualised) variance of the truth on
            # the same sample so we can apply a relative guard.
            true_mean_raw = 0.0
            @inbounds for i in 1:ag_counter, j in 1:np
                true_mean_raw += true_mat[i, j]
            end
            true_mean_raw /= npair
            ss_tot_raw = 0.0
            @inbounds for i in 1:ag_counter, j in 1:np
                d = true_mat[i, j] - true_mean_raw
                ss_tot_raw += d * d
            end
            # Gate: pair-specific variance must exceed (a) σ_ε² × npair / 6
            # (spec-consistent noise gate) AND (b) 1e-6 × raw variance
            # (additive-DGP guard — prevents blow-ups when the pair-specific
            # signal is essentially zero relative to the full signal). See
            # prompts/della_job_guide.md §11.4.
            se_gate = max(env.sigma_eps * env.sigma_eps, 1e-8) * npair / 6
            rel_gate = 1e-6 * ss_tot_raw
            if ss_tot_res > se_gate && ss_tot_res > rel_gate
                ss_a = 0.0; ss_b = 0.0
                @inbounds for k in 1:npair
                    da = res_agent[k] - res_true[k]
                    db = res_broker[k] - res_true[k]
                    ss_a += da * da
                    ss_b += db * db
                end
                state.accum.agent_holdout_r2_residualized = 1.0 - ss_a / ss_tot_res
                state.accum.broker_holdout_r2_residualized = 1.0 - ss_b / ss_tot_res
                # Rank correlation is well-defined here; compute it only when
                # pair signal is above noise so NaN'd R² and NaN'd rank align.
                state.accum.agent_holdout_rank_residualized = corspearman(res_agent, res_true)
                state.accum.broker_holdout_rank_residualized = corspearman(res_broker, res_true)
            end
            # When signal is below the gate, the residualized accumulators
            # remain at their NaN default from reset_accumulators! — the cell
            # row will show NaN for r2_residualized and rank_residualized,
            # which is the honest reading for additively separable DGPs.
        end
    end

    state.accum.roster_size = length(broker.roster)
    state.accum.broker_access_size = broker_access_size(broker)

    # ══════════════════════════════════════════════════════════════════════
    # Step 5: Entry/exit
    # ══════════════════════════════════════════════════════════════════════
    # :NoTurnover — entry/exit disabled (equivalent to eta=0). Skip the call so
    # no agents exit or are replaced. sync_broker_edges! still runs.
    if p.ablation != :NoTurnover
        process_entry_exit!(state, rng)
    end
    sync_broker_edges!(G, agents, broker)

    # ══════════════════════════════════════════════════════════════════════
    # Step 6: Recording and measurement
    # ══════════════════════════════════════════════════════════════════════
    if state.period % p.network_measure_interval == 0
        update_cached_network_measures!(state)
    end

    return nothing
end
