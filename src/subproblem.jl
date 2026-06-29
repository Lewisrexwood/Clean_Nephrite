using JuMP, HiGHS, DataFrames

# ---------------------------------------------------------------------------
# Result type
# ---------------------------------------------------------------------------

"""
Result from one weekly subproblem solve.

- `prices`     : `(hub_code, step_index) => \$/MWh` — dual of per-step hub balance.
- `generation` : miscellaneous dispatch values indexed by named tuples:
    `("gen", tranche, step)`, `("discharge", b, step)`, `("charge", b, step)`,
    `("soc", b, step)`, `("soc0", b)` (cyclic start SoC), `("unserved", hub, step)`.
- `flows`      : hydro values:
    `("arcflow", arc_idx, step)`, `("net_outflow", reservoir_name, step)`,
    `("storage", reservoir_name, step_t)` for t in 0..T,
    `("spill", reservoir_name, step)` for t in 1..T.
- `objective`  : optimal objective value.
- `status`     : solver termination status (MOI.TerminationStatusCode).
"""
struct SubproblemResult
    prices::Dict{Tuple{String,Int},Float64}
    generation::Dict{Any,Float64}
    flows::Dict{Any,Float64}
    objective::Float64
    status::JuMP.MOI.TerminationStatusCode
end

# ---------------------------------------------------------------------------
# Reusable week model
# ---------------------------------------------------------------------------

"""
A built-once weekly subproblem LP whose only scenario-dependent inputs —
start_vol, end_vol, and inflow — are re-pointed cheaply per solve (`solve_week!`)
instead of rebuilt.  Everything structural (dispatch variables, hub balance,
battery chaining, storage trajectory, objective) is fixed at build time.

The mass-balance constraints carry inflow on the RHS (`balance_con`), updated via
`set_normalized_rhs`; start/end storage are applied via `fix` on `s[(r,0)]`/`s[(r,T)]`.
This is the same parameterization the SDDP stage builder uses.
"""
struct WeekModel
    model::Model
    v                                          # build_dispatch! handles (NamedTuple)
    s::Dict{Tuple{String,Int},VariableRef}     # storage trajectory s[(r,t)], t in 0:T
    spill::Dict{Tuple{String,Int},VariableRef} # spill[(r,t)], t in 1:T
    balance_con::Dict{Tuple{String,Int},Any}   # mass-balance ConstraintRef (inflow on RHS)
    soc0::Vector{VariableRef}                   # cyclic battery start SoC (if periodic)
    periods::Vector{Period}
    inp::DispatchInputs
    soft_terminal::Bool                        # true → end_vol pinned softly (see below)
    term_con::Dict{String,Any}                 # soft-pin constraints (end_vol on RHS); empty if hard
end

# ---------------------------------------------------------------------------
# Build (once) and solve (cheap, re-pointable)
# ---------------------------------------------------------------------------

"""
    build_week_model(periods, inp; battery_periodic=true, soft_terminal=false,
                     terminal_penalty=1e6) -> WeekModel

Construct the full weekly subproblem LP (all structure, no scenario data).
start_vol/end_vol are fixed to 0.0 placeholders and inflow RHS to 0.0; both are
re-pointed by `solve_week!`.  See `solve_subproblem` for the formulation.

With `soft_terminal=true`, the end-of-week storage is NOT hard-`fix`ed; instead
`s[(r,T)]` stays bounded in `[lo, max]` and is pinned via a penalised deviation
(`s[(r,T)] − devp + devn == end_vol`, `terminal_penalty·Σ(devp+devn)` in the
objective).  This makes the LP always feasible: it hits `end_vol` exactly when
reachable (deviation 0, identical to the hard pin) and lands as close as the
water budget allows otherwise.  Used as the pricing fallback when the hard
`fix` reports a (wide-coefficient-range) presolve INFEASIBLE for a value that is
actually reachable; the default (`false`) keeps the deterministic/golden path
byte-identical.
"""
function build_week_model(periods::Vector{Period}, inp::DispatchInputs;
                          battery_periodic::Bool = true,
                          soft_terminal::Bool = false,
                          terminal_penalty::Float64 = 1e6)
    T  = length(periods)
    res = inp.net.reservoirs
    nb  = length(inp.batteries)

    model = Model(HiGHS.Optimizer)
    set_silent(model)
    # HiGHS keeps a process-global task executor for its own internal parallelism;
    # creating/destroying optimizers across many Julia threads races its lifecycle
    # (EXCEPTION_ACCESS_VIOLATION in dispose). Force each instance single-threaded so
    # the ONLY parallelism is the caller's Threads.@threads over weeks (thread-confined
    # models). One-shot solves are unaffected (threads=1 is already their effective mode).
    set_attribute(model, "threads", 1)
    set_attribute(model, "parallel", "off")

    # --- Shared per-step dispatch variables (gen, flows, battery bounds) ------
    v = build_dispatch!(model, periods, inp)

    # --- Per-step storage trajectory + spill ---------------------------------
    s = Dict{Tuple{String,Int},VariableRef}()
    reservoir_names = [r.name for r in res]
    spill = Dict{Tuple{String,Int},VariableRef}()
    for rname in reservoir_names, t in 1:T
        spill[(rname, t)] = @variable(model, base_name = "spill[$rname,$t]",
                                      lower_bound = 0.0)
    end

    balance_con = Dict{Tuple{String,Int},Any}()
    term_con = Dict{String,Any}()
    term_dev = VariableRef[]            # all devp/devn (soft mode only) for the penalty
    for r in res
        lo = max(0.0, r.min_volume)
        for t in 0:T
            sv = @variable(model, base_name = "s[$(r.name),$t]", lower_bound = lo)
            isfinite(r.max_volume) && set_upper_bound(sv, r.max_volume)
            s[(r.name, t)] = sv
        end
        # Placeholder boundary conditions — re-pointed per solve.
        fix(s[(r.name, 0)], 0.0; force = true)
        if soft_terminal
            # Soft end-of-week pin: s[T] stays bounded; deviation vars absorb any
            # gap to end_vol (RHS, set per-solve), penalised in the objective.
            devp = @variable(model, base_name = "devp[$(r.name)]", lower_bound = 0.0)
            devn = @variable(model, base_name = "devn[$(r.name)]", lower_bound = 0.0)
            push!(term_dev, devp); push!(term_dev, devn)
            term_con[r.name] = @constraint(model, s[(r.name, T)] - devp + devn == 0.0)
        else
            fix(s[(r.name, T)], 0.0; force = true)
        end

        # Mass balance with inflow on the RHS (set per-solve via set_normalized_rhs).
        # JuMP normalizes this to the SAME canonical constraint as the embedded
        # form `s[t] == s[t-1] + (inflow - net_outflow)·K·h - spill`, so the LP the
        # solver sees is identical — only the RHS constant moves with inflow.
        for t in 1:T
            h_t = periods[t].hours
            balance_con[(r.name, t)] = @constraint(model,
                s[(r.name, t)] - s[(r.name, t-1)] +
                v.net_outflow[(r.name, t)] * MM3_PER_CUMEC_HOUR * h_t +
                spill[(r.name, t)] == 0.0)
        end
    end

    # --- Battery SoC chaining (optional periodic close) ----------------------
    soc0 = VariableRef[]
    if battery_periodic && nb > 0
        for b in 1:nb
            cap = inp.batteries[b].energy_mwh
            eff = inp.batteries[b].eff
            sv0 = @variable(model, base_name = "soc0[$b]",
                            lower_bound = 0.0, upper_bound = cap)
            push!(soc0, sv0)
            h1 = periods[1].hours
            @constraint(model,
                v.soc[b, 1] == sv0 + eff * v.charge[b, 1] * h1 - v.discharge[b, 1] * h1)
            for t in 2:T
                h_t = periods[t].hours
                @constraint(model,
                    v.soc[b, t] ==
                        v.soc[b, t-1] + eff * v.charge[b, t] * h_t - v.discharge[b, t] * h_t)
            end
            @constraint(model, v.soc[b, T] == sv0)
        end
    end

    # --- Objective: dispatch cost + tiny spill penalty (+ soft terminal pin) --
    spill_penalty = isempty(reservoir_names) ? 0.0 :
        1e-4 * sum(spill[(rname, t)] for rname in reservoir_names, t in 1:T)
    terminal_pen = isempty(term_dev) ? 0.0 : terminal_penalty * sum(term_dev)
    @objective(model, Min, dispatch_cost(model, periods, inp, v) + spill_penalty + terminal_pen)

    return WeekModel(model, v, s, spill, balance_con, soc0, periods, inp, soft_terminal, term_con)
end

"""
    solve_week!(wm, start_vol, end_vol, inflow_cumecs) -> SubproblemResult

Re-point the three scenario inputs on a built `WeekModel` (start/end storage via
`fix`, inflow via `set_normalized_rhs`) and re-solve.  HiGHS warm-starts from the
previous optimal basis, so this is far cheaper than a rebuild.  Returns the same
`SubproblemResult` shape as `solve_subproblem`.
"""
function solve_week!(wm::WeekModel,
                     start_vol::Dict{String,Float64},
                     end_vol::Dict{String,Float64},
                     inflow_cumecs::Dict{String,Float64})
    inp = wm.inp
    periods = wm.periods
    T  = length(periods)
    res = inp.net.reservoirs
    nb  = length(inp.batteries)
    reservoir_names = [r.name for r in res]

    # Re-point start/end storage and inflow.
    for r in res
        fix(wm.s[(r.name, 0)], get(start_vol, r.name, 0.0); force = true)
        if wm.soft_terminal
            set_normalized_rhs(wm.term_con[r.name], get(end_vol, r.name, 0.0))
        else
            fix(wm.s[(r.name, T)], get(end_vol, r.name, 0.0); force = true)
        end
        for t in 1:T
            h_t = periods[t].hours
            set_normalized_rhs(wm.balance_con[(r.name, t)],
                               get(inflow_cumecs, r.name, 0.0) * MM3_PER_CUMEC_HOUR * h_t)
        end
    end

    optimize!(wm.model)
    status = termination_status(wm.model)
    status == MOI.OPTIMAL || @warn "solve_week!: solver status $status"

    if status != MOI.OPTIMAL
        return SubproblemResult(
            Dict{Tuple{String,Int},Float64}(),
            Dict{Any,Float64}(),
            Dict{Any,Float64}(),
            Inf,
            status,
        )
    end

    v = wm.v

    # --- Extract prices (duals of hub balance constraints) -------------------
    prices = Dict{Tuple{String,Int},Float64}()
    for h in [hub.code for hub in inp.topology.hubs], t in 1:T
        h_t = periods[t].hours
        prices[(h, t)] = h_t > 0 ? dual(v.balance[h, t]) / h_t : 0.0
    end

    # --- Extract generation values -------------------------------------------
    generation = Dict{Any,Float64}()
    for tr in 1:nrow(inp.thermal), t in 1:T
        generation[("gen", tr, t)] = value(v.gen[tr, t])
    end
    for h in [hub.code for hub in inp.topology.hubs], t in 1:T
        generation[("unserved", h, t)] = value(v.unserved[h, t])
        generation[("curtail",  h, t)] = value(v.curtail[h, t])
    end
    for b in 1:nb, t in 1:T
        generation[("charge",    b, t)] = value(v.charge[b, t])
        generation[("discharge", b, t)] = value(v.discharge[b, t])
        generation[("soc",       b, t)] = value(v.soc[b, t])
    end
    for b in 1:length(wm.soc0)
        generation[("soc0", b)] = value(wm.soc0[b])
    end

    # --- Extract flow / storage values ---------------------------------------
    flows = Dict{Any,Float64}()
    for ai in 1:length(inp.net.arcs), t in 1:T
        flows[("arcflow", ai, t)] = value(v.arcflow[ai, t])
    end
    for r in res, t in 1:T
        flows[("net_outflow", r.name, t)] = value(v.net_outflow[(r.name, t)])
    end
    for r in res, t in 0:T
        flows[("storage", r.name, t)] = value(wm.s[(r.name, t)])
    end
    for rname in reservoir_names, t in 1:T
        flows[("spill", rname, t)] = value(wm.spill[(rname, t)])
    end

    return SubproblemResult(prices, generation, flows, objective_value(wm.model), status)
end

# ---------------------------------------------------------------------------
# Public one-shot wrapper (build + solve)
# ---------------------------------------------------------------------------

"""
    solve_subproblem(periods, inp, start_vol, end_vol, inflow_cumecs;
                     battery_periodic=true) -> SubproblemResult

Build and solve one week as `length(periods)` chronological steps (usually 336
half-hour periods).  Returns per-step nodal prices (duals of hub balance
constraints) and auxiliary generation/flow values.  This is a thin wrapper over
`build_week_model` + `solve_week!` (one fresh build, one cold solve); callers that
solve the SAME week for many scenarios should reuse a `WeekModel` directly.

Arguments
---------
- `periods`         : chronological dispatch periods (each `hours=0.5` for 30-min).
- `inp`             : `DispatchInputs` (topology, hydro network, thermal, batteries).
- `start_vol`       : `reservoir_name => Mm³` — storage at the start of the week.
- `end_vol`         : `reservoir_name => Mm³` — storage target at end of week
                      (pinned by the master LP).
- `inflow_cumecs`   : `reservoir_name => cumecs` — constant natural inflow for
                      the week (mean over the steps).
- `battery_periodic`: if `true`, add SoC-chaining constraints across steps and
                      enforce that the end SoC returns to the cyclic start level.

Formulation
-----------
One `Model(HiGHS.Optimizer)`.  `build_dispatch!(model, periods, inp)` adds
per-step dispatch variables and hub balance constraints.

**Per-step reservoir storage trajectory** `s[r, t]` for `t in 0..T` (Mm³):
  - `s[r, 0] == start_vol[r]`          (fixed initial condition)
  - `s[r, t] == s[r, t-1] + (inflow_cumecs[r] − net_outflow[r, t]) × MM3_PER_CUMEC_HOUR × hours_t − spill[r, t]`
  - `s[r, T] == end_vol[r]`            (master's water budget pin)
  - Bounds: `max(0, min_volume) ≤ s[r, t] ≤ max_volume` (upper only if finite).
  - `spill[r, t] ≥ 0` (Mm³, direct sink to SEA) makes `end_vol` reachable when
    arc release alone cannot draw the reservoir down; tiny penalty in the objective.

**Battery SoC chaining** (when `battery_periodic=true`):
  - `soc0[b]` — free variable in `[0, energy_mwh]`, the cyclic start SoC.
  - `soc[b, 1] == soc0[b] + eff × charge[b, 1] × hours_1 − discharge[b, 1] × hours_1`
  - `soc[b, t] == soc[b, t-1] + eff × charge[b, t] × hours_t − discharge[b, t] × hours_t` for t ≥ 2
  - `soc[b, T] == soc0[b]`             (periodic close — returns to start)

**Objective**: `Min dispatch_cost(model, periods, inp, v)` (thermal SRMC + lost-load).
No terminal value — the master's `end_vol` pins the weekly water budget.
"""
function solve_subproblem(
    periods::Vector{Period},
    inp::DispatchInputs,
    start_vol::Dict{String,Float64},
    end_vol::Dict{String,Float64},
    inflow_cumecs::Dict{String,Float64};
    battery_periodic::Bool = true,
)
    wm = build_week_model(periods, inp; battery_periodic = battery_periodic)
    return solve_week!(wm, start_vol, end_vol, inflow_cumecs)
end
