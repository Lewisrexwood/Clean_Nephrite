using JuMP, HiGHS, DataFrames

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

"""
One week of inputs:
- `periods`        : 96 representative-day dispatch periods for the MASTER LP
                     (weekday + weekend × 48 trading periods; hours = #days × 0.5).
- `periods336`     : 336 CHRONOLOGICAL 30-min steps (7 days × 48 tp, each
                     `hours = 0.5`) for the SUBPROBLEM LP.  Built by tiling the
                     week's forward-demand rows at 30-min resolution.
- `inp`            : DispatchInputs (topology, hydro net, thermal, mustrun, batteries)
- `inflow_cumecs`  : reservoir_name → week-mean natural inflow (cumecs)
"""
struct WeekInputs
    periods::Vector{Period}
    periods336::Vector{Period}
    inp::DispatchInputs
    inflow_cumecs::Dict{String,Float64}
end

# Master-only convenience: the master LP reads `periods` (the 96-period rep day)
# and never touches `periods336`.  This 3-arg form lets master tests/callers
# construct a WeekInputs without building a subproblem step list (left empty).
# The runner always uses the 4-arg form via `assemble_inputs`.
WeekInputs(periods::Vector{Period}, inp::DispatchInputs,
           inflow_cumecs::Dict{String,Float64}) =
    WeekInputs(periods, Period[], inp, inflow_cumecs)

"""
Master LP solution:
- `storage`     : (reservoir, week) → end-of-week volume (Mm³)
- `water_value` : (reservoir, week) → storage-balance dual converted to \$/MWh (>= 0)
- `price`       : (hub, week) → hours-weighted mean of the per-period hub
                  energy-balance duals (\$/MWh).  This is the master's COARSE
                  diagnostic nodal price; the ASX settlement prices come from
                  the higher-resolution subproblem, not from here.
- `objective`   : optimal objective value
- `status`      : solver termination status (MOI.TerminationStatusCode)
"""
struct MasterResult
    storage::Dict{Tuple{String,Int},Float64}
    water_value::Dict{Tuple{String,Int},Float64}
    price::Dict{Tuple{String,Int},Float64}
    objective::Float64
    status::JuMP.MOI.TerminationStatusCode
end

# ---------------------------------------------------------------------------
# 104-week master water-budget LP
# ---------------------------------------------------------------------------

"""
    solve_master(weeks, net, initial_vol, terminal_wv, anchor) -> MasterResult

Build and solve the multi-week master water-budget LP.  Each week's within-week
dispatch is built by `build_dispatch!`; weeks are linked by per-reservoir
storage-volume balance constraints (Mm³).  End-of-horizon storage is valued by
a concave piecewise-linear terminal-value envelope.  Near-term hydro release
carries an opportunity COST equal to the offer-implied anchor value θ (decayed
by the anchor weight), so anchored hydro bids θ into dispatch (mechanism A).

Everything is a pure LP (linear, convex).

Water value: the dual of the weekly storage-balance constraint is in \$/Mm³.
Dividing by the MWh-per-Mm³ conversion `coeff[r] × MWH_PER_MM3_PER_SP` yields
\$/MWh.  The balance is written `S[r,w] - S_prev - inflow + release + spill == 0`
(i.e. `S[r,w] == S_prev + inflow - release - spill`); with this orientation a
scarce reservoir whose released water displaces thermal at price π has a
balance dual of -π·(MWh/Mm³), so we negate to report a positive \$/MWh water
value.
"""
function solve_master(weeks::Vector{WeekInputs}, net::HydroNetwork,
                      initial_vol::Dict{String,Float64}, terminal_wv::DataFrame,
                      anchor)
    model = Model(HiGHS.Optimizer)
    set_silent(model)

    nW    = length(weeks)
    coeff = downstream_energy_coeff(net)
    res   = net.reservoirs

    # --- Storage + spill variables ------------------------------------------
    # S[r.name, w] end-of-week volume (Mm³); spill[r.name, w] >= 0 (Mm³).
    S    = Dict{Tuple{String,Int},VariableRef}()
    spill = Dict{Tuple{String,Int},VariableRef}()
    for r in res, w in 1:nW
        lo = max(0.0, r.min_volume)
        s  = @variable(model, base_name = "S[$(r.name),$w]", lower_bound = lo)
        isfinite(r.max_volume) && set_upper_bound(s, r.max_volume)
        S[(r.name, w)]     = s
        spill[(r.name, w)] = @variable(model, base_name = "spill[$(r.name),$w]", lower_bound = 0.0)
    end

    obj = AffExpr(0.0)
    balcon = Dict{Tuple{String,Int},ConstraintRef}()
    # release_vol[(r,w)] is the released VOLUME (Mm³) expression, kept for the anchor.
    release_vol = Dict{Tuple{String,Int},AffExpr}()
    # Retain each week's dispatch handles to extract per-hub balance duals (prices).
    vweeks = Vector{Any}(undef, nW)

    for w in 1:nW
        wk = weeks[w]
        v  = build_dispatch!(model, wk.periods, wk.inp)
        vweeks[w] = v
        add_to_expression!(obj, dispatch_cost(model, wk.periods, wk.inp, v))
        # build_dispatch! registers symbols (:gen, :balance, …) on the model;
        # unregister them so the next week's call can re-register.  The variable
        # and constraint objects themselves remain live via the returned `v`.
        for sym in (:gen, :fwd, :rev, :arcflow, :unserved, :curtail, :charge,
                    :discharge, :soc, :balance)
            unregister(model, sym)
        end

        # --- Battery within-week periodic close (energy-neutral) -------------
        # Batteries are bounded per-period only (NOT SoC-chained) in the master.
        # Without this constraint a battery could discharge free energy across
        # the week.  Force charge-in × eff == discharge-out over the whole week.
        add_weekly_battery_close!(model, wk.periods, wk.inp.batteries, v)

        for r in res
            # released VOLUME (Mm³) = Σ_i net_outflow(cumecs) × MM3_PER_CUMEC_HOUR × hours_i
            release_vol[(r.name, w)] = released_volume(v, wk.periods, r.name)

            inflow_vol = get(wk.inflow_cumecs, r.name, 0.0) * MM3_PER_CUMEC_HOUR * 168.0
            S_prev = w == 1 ? AffExpr(initial_vol[r.name]) : S[(r.name, w - 1)]

            # Mm³ balance — dual is the water value (in $/Mm³).
            balcon[(r.name, w)] = @constraint(model,
                S[(r.name, w)] == S_prev + inflow_vol - release_vol[(r.name, w)] - spill[(r.name, w)])
        end
    end

    # --- Terminal value envelope (concave piecewise-linear) -----------------
    # E_end = aggregate end-of-horizon stored energy (GWh).
    E_end = aggregate_stored_energy_gwh(net, Dict(r.name => S[(r.name, nW)] for r in res))
    tv = add_terminal_value!(model, E_end, terminal_wv)

    # --- Anchor term (mechanism A: opportunity COST on near-term release) ---
    # Price near-term hydro release at the offer-implied value θ as its
    # opportunity cost — the market behaving as if it offered hydro at its
    # water value.  Adding the per-MWh release cost (θ, decayed by the anchor
    # weight) makes hydro bid θ into the dispatch, so the near-term nodal price
    # is set to θ whenever anchored hydro is marginal.  Entered as a COST
    # (positive in the Min objective).  release_energy_mwh[r,w] = release_vol
    # (Mm³) × coeff[r] × MWH_PER_MM3_PER_SP.  With `weight==0` the term vanishes.
    anchor_term = AffExpr(0.0)
    if anchor.weight != 0.0
        for r in res, w in 1:nW
            ww = w <= length(anchor.weights) ? anchor.weights[w] : 0.0
            ww == 0.0 && continue
            av = get(anchor.values, r.name, 0.0)
            av == 0.0 && continue
            c = get(coeff, r.name, 0.0)
            rel_mwh = release_vol[(r.name, w)] * (c * MWH_PER_MM3_PER_SP)
            add_to_expression!(anchor_term, (anchor.weight * ww * av) * rel_mwh)
        end
    end

    # --- Spill penalty (tiny — discourages gratuitous spill) ----------------
    spill_pen = AffExpr(0.0)
    for r in res, w in 1:nW
        add_to_expression!(spill_pen, spill[(r.name, w)])
    end

    @objective(model, Min, obj + 1e-4 * spill_pen - tv + anchor_term)
    optimize!(model)

    status = termination_status(model)
    if status != MOI.OPTIMAL
        @warn "solve_master: solver status $status — returning sentinel result"
        return MasterResult(
            Dict{Tuple{String,Int},Float64}(),
            Dict{Tuple{String,Int},Float64}(),
            Dict{Tuple{String,Int},Float64}(),
            Inf,
            status,
        )
    end

    # --- Extract ------------------------------------------------------------
    storage     = Dict{Tuple{String,Int},Float64}()
    water_value = Dict{Tuple{String,Int},Float64}()
    for r in res
        c = get(coeff, r.name, 0.0)
        mwh_per_mm3 = c * MWH_PER_MM3_PER_SP
        for w in 1:nW
            storage[(r.name, w)] = value(S[(r.name, w)])
            d = dual(balcon[(r.name, w)])
            # Convert $/Mm³ dual to $/MWh and normalise sign to positive.
            # Reported as the fundamental storage dual (no post-solve anchor blend).
            water_value[(r.name, w)] = mwh_per_mm3 > 0 ? -d / mwh_per_mm3 : 0.0
        end
    end

    # Coarse diagnostic nodal price: hours-weighted mean of the per-period
    # hub energy-balance duals, per (hub, week).
    price = Dict{Tuple{String,Int},Float64}()
    for w in 1:nW
        v  = vweeks[w]
        ps = weeks[w].periods
        total_hours = sum(p.hours for p in ps)
        for h in inp_hubs(weeks[w].inp)
            acc = sum(dual(v.balance[h, i]) for i in 1:length(ps))   # Σ dual_i = Σ price_i × hours_i
            price[(h, w)] = total_hours > 0 ? acc / total_hours : 0.0  # hours-weighted mean $/MWh
        end
    end

    return MasterResult(storage, water_value, price, objective_value(model), status)
end

# Hub codes present in a week's dispatch inputs.
inp_hubs(inp::DispatchInputs) = [h.code for h in inp.topology.hubs]
