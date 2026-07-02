using JuMP, HiGHS, DataFrames, Dates, Statistics
import SDDP                  # qualified access (SDDP.X); avoids re-exporting
                             # SDDP.termination_status into Nephrite namespace
using SDDP: @stageobjective  # macro must be brought in explicitly
using Random
using JuMP: MOI

# ===========================================================================
# sddp.jl — Phase 2b SDDP engine.  A native SDDP.jl LinearPolicyGraph whose
# stage builder reuses build_dispatch! verbatim, declares per-reservoir storage
# as SDDP.State, and injects empirical stagewise-independent inflows into the
# storage-balance RHS via SDDP.parameterize.  Risk-neutral.  Deterministic
# master (master.jl) is left intact as the Phase 1 baseline.
# ===========================================================================

"""
    sddp_lower_bound(net, terminal_wv) -> Float64

A valid (loose) lower bound on the Min cost-to-go.  All stage costs are >= 0;
the only negative contribution is the subtracted terminal value `-tv`, bounded
above by `max(value) × max-aggregate-stored-energy`.  So the cost-to-go is
bounded below by the negative of that.  Returns a non-positive number.
"""
function sddp_lower_bound(net::HydroNetwork, terminal_wv::DataFrame)
    coeff = downstream_energy_coeff(net)
    emax = sum(isfinite(r.max_volume) ?
               r.max_volume * get(coeff, r.name, 0.0) * MWH_PER_MM3_PER_SP / 1000.0 : 0.0
               for r in net.reservoirs; init = 0.0)
    maxval = isempty(terminal_wv.value) ? 0.0 : maximum(terminal_wv.value)
    return -(abs(maxval) * emax + 1.0)
end

"""
    build_policy_graph(weeks, net, initial_vol, terminal_wv, anchor, inflow_scenarios;
                       optimizer=HiGHS.Optimizer) -> SDDP.PolicyGraph

Finite LinearPolicyGraph: one weekly stage per `weeks` entry, per-reservoir
storage state (Mm³), the 96-period representative-day dispatch via
`build_dispatch!`, the master's battery weekly periodic-close, stagewise-
independent inflow on the storage-balance RHS, the offer-implied anchor term,
and the JADE terminal-value envelope on the final stage.
"""
function build_policy_graph(weeks::Vector{WeekInputs}, net::HydroNetwork,
                            initial_vol::Dict{String,Float64}, terminal_wv::DataFrame,
                            anchor, inflow_scenarios::Dict{Int,Vector{Dict{String,Float64}}};
                            # Pin each stage-LP to 1 HiGHS thread.  HiGHS default threads=0
                            # (= all cores) spawns ~ncores workers per solve; for the tiny
                            # 96-period stage LP the spawn/sync overhead dwarfs the sub-ms
                            # solve, and SDDP calls optimize! tens of thousands of times, so
                            # on a many-core box this is an ~order-of-magnitude slowdown.
                            # Mirrors the pricing-path pin (subproblem.jl:93-94).
                            optimizer = optimizer_with_attributes(HiGHS.Optimizer,
                                                                  "threads" => 1, "parallel" => "off"))
    nW     = length(weeks)
    res    = net.reservoirs
    rnames = [r.name for r in res]
    coeff  = downstream_energy_coeff(net)
    lb     = sddp_lower_bound(net, terminal_wv)

    # Clamp initial volumes to [min_volume, max_volume] to guard against
    # floating-point overshoot from initial_volumes (e.g. 855.4000000000001
    # vs max_volume=855.4); SDDP strictly validates initial_value vs bounds.
    # Only sub-epsilon FP residuals are expected here (initial_volumes already
    # clamps + warns at the island level); a larger overshoot signals a real
    # data inconsistency from some other initial_vol source, so warn loudly
    # (tolerance mirrors hydroenergy.jl's 1e-6 guard) rather than masking it.
    initial_vol_clamped = Dict{String,Float64}()
    for r in res
        v  = get(initial_vol, r.name, 0.0)
        lo = max(0.0, r.min_volume)
        if isfinite(r.max_volume) && v > r.max_volume + 1e-6
            @warn "build_policy_graph: initial_vol[$(r.name)]=$v exceeds max_volume=$(r.max_volume); clamping"
        end
        initial_vol_clamped[r.name] = isfinite(r.max_volume) ? clamp(v, lo, r.max_volume) : max(v, lo)
    end

    return SDDP.LinearPolicyGraph(
        stages = nW, sense = :Min, lower_bound = lb, optimizer = optimizer
    ) do sp, t
        wk = weeks[t]

        # --- per-reservoir storage state (Mm³) ------------------------------
        @variable(sp, s[r in rnames] >= 0, SDDP.State,
                  initial_value = get(initial_vol_clamped, r, 0.0))
        for r in res
            set_lower_bound(s[r.name].out, max(0.0, r.min_volume))
            isfinite(r.max_volume) && set_upper_bound(s[r.name].out, r.max_volume)
        end

        # --- within-week dispatch (96-period rep day) -----------------------
        v = build_dispatch!(sp, wk.periods, wk.inp)

        # --- battery weekly periodic close (energy-neutral) -----------------
        add_weekly_battery_close!(sp, wk.periods, wk.inp.batteries, v)

        # --- spill, released volume, storage balance ------------------------
        @variable(sp, spill[r in rnames] >= 0)
        release_vol = Dict{String,AffExpr}()
        balance_con = Dict{String,ConstraintRef}()
        for r in res
            rel = released_volume(v, wk.periods, r.name)
            release_vol[r.name] = rel
            # s.out == s.in + inflow - rel - spill ; inflow injected below.
            balance_con[r.name] = @constraint(sp,
                s[r.name].out - s[r.name].in + rel + spill[r.name] == 0.0)
        end

        # --- inflow = stagewise random variable (RHS only) ------------------
        SDDP.parameterize(sp, inflow_scenarios[t]) do ω
            for r in res
                set_normalized_rhs(balance_con[r.name],
                                   get(ω, r.name, 0.0) * MM3_PER_CUMEC_HOUR * 168.0)
            end
        end

        # --- stage objective ------------------------------------------------
        stage_obj = dispatch_cost(sp, wk.periods, wk.inp, v)
        add_to_expression!(stage_obj, 1e-4 * sum(spill[r] for r in rnames; init = AffExpr(0.0)))

        # anchor (mechanism A): opportunity cost on near-term release.
        if anchor.weight != 0.0
            ww = t <= length(anchor.weights) ? anchor.weights[t] : 0.0
            if ww != 0.0
                for r in res
                    av = get(anchor.values, r.name, 0.0)
                    av == 0.0 && continue
                    c = get(coeff, r.name, 0.0)
                    add_to_expression!(stage_obj,
                        (anchor.weight * ww * av) * (release_vol[r.name] * (c * MWH_PER_MM3_PER_SP)))
                end
            end
        end

        # terminal value envelope on the final stage only.
        if t == nW
            E_end = aggregate_stored_energy_gwh(net, Dict(r.name => s[r.name].out for r in res))
            tv = add_terminal_value!(sp, E_end, terminal_wv)
            add_to_expression!(stage_obj, -tv)
        end

        @stageobjective(sp, stage_obj)
    end
end

"""
    train_policy!(graph; iteration_limit=200, seed=1) -> graph

Train risk-neutrally with an iteration cap plus bound-stalling early stop.
Seeded for reproducibility.  Trains in place; returns the graph.
"""
function train_policy!(graph::SDDP.PolicyGraph; iteration_limit::Int = 200, seed::Int = 1)
    Random.seed!(seed)
    SDDP.train(graph;
               iteration_limit = iteration_limit,
               stopping_rules = [SDDP.BoundStalling(10, 1e-4)],
               risk_measure = SDDP.Expectation(),
               print_level = 0)
    return graph
end

"""
    simulate_policy(graph, n_scenarios; seed=1) -> (trajectories, inflows)

Forward-simulate the trained policy.  Records the per-reservoir storage state and
the realized inflow noise per stage.  Returns two vectors (one entry per
scenario): end-of-week storage Mm³ and realized inflow cumecs, both keyed
`(reservoir_name, week)`.
"""
function simulate_policy(graph::SDDP.PolicyGraph, n_scenarios::Int; seed::Int = 1)
    Random.seed!(seed)
    sims = SDDP.simulate(graph, n_scenarios, [:s])
    trajectories = Vector{Dict{Tuple{String,Int},Float64}}(undef, n_scenarios)
    inflows      = Vector{Dict{Tuple{String,Int},Float64}}(undef, n_scenarios)
    for i in 1:n_scenarios
        traj = Dict{Tuple{String,Int},Float64}()
        infl = Dict{Tuple{String,Int},Float64}()
        for t in 1:length(sims[i])
            stage = sims[i][t]
            sval  = stage[:s]                      # container of SDDP.State values
            for r in axes(sval, 1)                 # reservoir-name axis
                traj[(String(r), t)] = sval[r].out
            end
            ω = stage[:noise_term]                 # the Dict realization for this stage
            for (rname, cumecs) in ω
                infl[(String(rname), t)] = Float64(cumecs)
            end
        end
        trajectories[i] = traj
        inflows[i]      = infl
    end
    return trajectories, inflows
end

# ===========================================================================
# Task 4: Scenario pricing + solve_sddp + SddpResult
# ===========================================================================

struct SddpResult
    lower_bound::Float64
    trajectories::Vector{Dict{Tuple{String,Int},Float64}}
    price_dist::Dict{Tuple{String,Int,Int},Vector{Float64}}
    policy::SDDP.PolicyGraph
end

"""
    price_scenarios(weeks, net, initial_vol, trajectories, inflows) -> price_dist

For each scenario and week, price the 336-step subproblem with the scenario's
start/end storage (week 1 starts at `initial_vol`) and realized weekly inflow.
Returns `price_dist[(hub, week, step)] = Vector` over scenarios.

Threaded over WEEKS: each week's LP is built ONCE (`build_week_model`) and
re-solved across all N scenarios (`solve_week!`, warm-started) on a single
thread — JuMP models are not thread-safe, so each lives on one thread.  Model
builds drop from N×nW to nW.  Results are merged in fixed (i, w) order, so the
output is independent of thread scheduling.  (The weekly LP can be degenerate in
hydro-release timing; warm re-solves are deterministic run-to-run but a priced
step's marginal value may differ from a fresh cold solve at such ties.)

Two-tier terminal pin: each (scenario, week) is solved first with the hard
`fix(s[T], end_vol)` (byte-identical to the deterministic path).  If that
reports non-OPTIMAL — the policy's coarse-stage end-storage is occasionally an
unreachable hard pin for the fine 336-step model (a wide-coefficient-range
presolve INFEASIBLE) — the week is re-solved on a lazily-built `soft_terminal`
model that pins end_vol via a penalised deviation and is always feasible.  Only
the affected scenarios use the soft model; feasible solves are unchanged.
"""
function price_scenarios(weeks::Vector{WeekInputs}, net::HydroNetwork,
                         initial_vol::Dict{String,Float64},
                         trajectories::Vector{Dict{Tuple{String,Int},Float64}},
                         inflows::Vector{Dict{Tuple{String,Int},Float64}})
    nW = length(weeks)
    rnames = [r.name for r in net.reservoirs]
    N = length(trajectories)
    results = Matrix{SubproblemResult}(undef, N, nW)
    Threads.@threads for w in 1:nW
        wm = build_week_model(weeks[w].periods336, weeks[w].inp)   # built ONCE per week (hard pin)
        softwm = nothing                                            # soft fallback, built lazily
        for i in 1:N
            traj = trajectories[i]; infl = inflows[i]
            start_vol = w == 1 ? initial_vol :
                        Dict(r => traj[(r, w - 1)] for r in rnames)
            end_vol   = Dict(r => traj[(r, w)] for r in rnames)
            inflow_w  = Dict(r => get(infl, (r, w), 0.0) for r in rnames)
            r = solve_week!(wm, start_vol, end_vol, inflow_w)
            if r.status != MOI.OPTIMAL
                softwm === nothing &&
                    (softwm = build_week_model(weeks[w].periods336, weeks[w].inp; soft_terminal = true))
                r = solve_week!(softwm, start_vol, end_vol, inflow_w)
            end
            results[i, w] = r
        end
    end
    price_dist = Dict{Tuple{String,Int,Int},Vector{Float64}}()
    for i in 1:N, w in 1:nW
        sp = results[i, w]
        sp.status == MOI.OPTIMAL ||
            error("price_scenarios: scenario $i week $w did not solve (status $(sp.status))")
        for ((hub, step), p) in sp.prices
            key = (hub, w, step)
            v = get!(price_dist, key, Vector{Float64}(undef, N))
            v[i] = p
        end
    end
    return price_dist
end

"""
    solve_sddp(mi, inflow_scenarios; n_scenarios=100, iteration_limit=200, seed=1, warm_start=:anchor)
        -> SddpResult

Top-level orchestrator: build the policy graph from `mi`, train it, forward-
simulate `n_scenarios`, and price each scenario through the 336-step subproblem.
`warm_start` selects the prior-WV injection: `:none` (cold), `:anchor` (objective anchor, default), `:cuts` (value-function cuts), `:both`.
"""
function solve_sddp(mi::ModelInputs, inflow_scenarios::Dict{Int,Vector{Dict{String,Float64}}};
                    n_scenarios::Int = 100, iteration_limit::Int = 200, seed::Int = 1,
                    warm_start::Symbol = :anchor)
    eff_anchor, inject_cuts = _warmstart_plan(warm_start, mi.anchor)
    graph = build_policy_graph(mi.weeks, mi.net, mi.initial_vol, mi.terminal_wv,
                               eff_anchor, inflow_scenarios)
    if inject_cuts
        lb = sddp_lower_bound(mi.net, mi.terminal_wv)
        # Skip the final-stage node: its Bellman function is identically 0
        # (no future stages), so injecting a cut there causes infeasibility
        # during the backward pass.  In production decay_weeks << nW so the
        # final-node weight is already 0; this clip is only material for short
        # toy/test runs.
        nW = length(mi.weeks)
        cut_weights = mi.anchor.weights[1:max(0, nW - 1)]
        cuts = wv_warmstart_cuts(mi.net, mi.initial_vol, mi.anchor.values,
                                 cut_weights, lb)
        apply_wv_warmstart!(graph, cuts)
    end
    train_policy!(graph; iteration_limit = iteration_limit, seed = seed)
    lb_bound = SDDP.calculate_bound(graph)
    traj, infl = simulate_policy(graph, n_scenarios; seed = seed)
    price_dist = price_scenarios(mi.weeks, mi.net, mi.initial_vol, traj, infl)
    return SddpResult(lb_bound, traj, price_dist, graph)
end
