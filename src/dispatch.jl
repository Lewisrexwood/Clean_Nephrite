using JuMP, DataFrames, Dates, Statistics

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

"""
A single representative dispatch period.
- `label`  : human-readable name (e.g. "weekday_tp1")
- `hours`  : duration in hours (weight for cost summation)
- `demand` : hub_code → MW
"""
struct Period
    label::String
    hours::Float64
    demand::Dict{String,Float64}
end

"""
All inputs consumed by `build_dispatch!` (shared between master and subproblem).
- `topology`        : grid hubs and corridors
- `net`             : hydro network (reservoirs, arcs, stations)
- `thermal`         : DataFrame(hub, price, mw) — one row per tranche
- `mustrun`         : DataFrame(hub, mw)  — fixed must-run output (may be empty)
- `batteries`       : Vector of NamedTuple (name, hub, power_mw, energy_mwh, eff)
- `lost_load_price` : NZD/MWh for unserved energy slack
"""
struct DispatchInputs
    topology::Topology
    net::HydroNetwork
    thermal::DataFrame
    mustrun::DataFrame
    batteries::Vector
    lost_load_price::Float64
end

# ---------------------------------------------------------------------------
# Shared builder
# ---------------------------------------------------------------------------

"""
    build_dispatch!(model, periods, inp) -> NamedTuple

Add per-period dispatch variables and constraints to `model`.
Returns variable/constraint handles:
  gen, fwd, rev, arcflow, hydro_gen_expr, unserved, charge, discharge, soc,
  balance, net_outflow

`balance[h, i]` are the hub energy-balance ConstraintRefs whose duals equal
nodal prices.  Storage dynamics (SoC chaining) are added by the CALLER.
"""
function build_dispatch!(model::Model, periods::Vector{Period}, inp::DispatchInputs)
    H    = [h.code for h in inp.topology.hubs]
    np   = length(periods)
    T    = nrow(inp.thermal)
    corr = inp.topology.corridors
    nc   = length(corr)
    arcs = inp.net.arcs
    na   = length(arcs)
    nb   = length(inp.batteries)

    # ------------------------------------------------------------------
    # Variables
    # ------------------------------------------------------------------

    # Thermal generation per tranche per period
    @variable(model, gen[1:T, 1:np] >= 0)

    # Corridor forward / reverse flow
    @variable(model, fwd[1:nc, 1:np] >= 0)
    @variable(model, rev[1:nc, 1:np] >= 0)

    # Hydro arc flow (cumecs)
    @variable(model, arcflow[1:na, 1:np] >= 0)

    # Unserved energy (load-shedding) slack per hub per period
    @variable(model, unserved[H, 1:np] >= 0)

    # Over-generation (curtailment) slack per hub per period.  Fixed must-run
    # injection plus inflexible hydro can exceed demand at a hub whose export
    # corridors are capped (e.g. a low-demand hydro hub).  Without a sink the
    # equality balance is infeasible; real systems curtail.  Penalised tinily so
    # it only absorbs genuine oversupply and never sets the price when demand>0.
    @variable(model, curtail[H, 1:np] >= 0)

    # Battery charge / discharge / state-of-charge (SoC chaining by caller)
    @variable(model, charge[1:nb, 1:np] >= 0)
    @variable(model, discharge[1:nb, 1:np] >= 0)
    @variable(model, soc[1:nb, 1:np] >= 0)

    # ------------------------------------------------------------------
    # Bounds
    # ------------------------------------------------------------------

    for t in 1:T, i in 1:np
        @constraint(model, gen[t, i] <= inp.thermal.mw[t])
    end

    for (ci, c) in enumerate(corr), i in 1:np
        @constraint(model, fwd[ci, i] <= c.capacity_fwd_mw)
        @constraint(model, rev[ci, i] <= c.capacity_rev_mw)
    end

    for (ai, a) in enumerate(arcs), i in 1:np
        isfinite(a.max_flow) && @constraint(model, arcflow[ai, i] <= a.max_flow)
    end

    for b in 1:nb, i in 1:np
        @constraint(model, charge[b, i]    <= inp.batteries[b].power_mw)
        @constraint(model, discharge[b, i] <= inp.batteries[b].power_mw)
        @constraint(model, soc[b, i]       <= inp.batteries[b].energy_mwh)
    end

    # ------------------------------------------------------------------
    # Hydro generation: station_s generation = arcflow[arc_of_s] × specific_power
    # Build a lookup: station_name → arc index
    # ------------------------------------------------------------------
    station_arc = Dict{String,Int}()
    for (ai, a) in enumerate(arcs)
        if a.station != ""
            haskey(station_arc, a.station) && error("dispatch: station $(a.station) appears on multiple arcs")
            station_arc[a.station] = ai
        end
    end

    # Electrical capacity cap: arcflow (cumecs) × specific_power ≤ capacity_mw
    for (sname, s) in inp.net.stations
        haskey(station_arc, sname) || continue
        ai = station_arc[sname]
        for i in 1:np
            @constraint(model, arcflow[ai, i] * s.specific_power <= s.capacity_mw)
        end
    end

    # ------------------------------------------------------------------
    # Hub energy-balance constraints  (dual = nodal price)
    #
    # supply + imports(×(1-loss)) − exports + unserved == demand
    #
    # For each corridor ci:
    #   fwd[ci]: power leaves corr[ci].from, arrives corr[ci].to × (1-loss)
    #   rev[ci]: power leaves corr[ci].to,   arrives corr[ci].from × (1-loss)
    # ------------------------------------------------------------------

    @constraint(model, balance[h in H, i in 1:np],
        # Thermal supply at hub h
        sum(gen[t, i] for t in 1:T if inp.thermal.hub[t] == h; init = AffExpr(0.0))
        # Hydro station generation at hub h
        + sum(
            arcflow[station_arc[sname], i] * s.specific_power
            for (sname, s) in inp.net.stations
            if get(inp.net.station_hub, sname, "") == h && haskey(station_arc, sname);
            init = AffExpr(0.0)
        )
        # Must-run fixed injection
        + (isempty(inp.mustrun) ? 0.0 :
           sum(inp.mustrun.mw[k] for k in 1:nrow(inp.mustrun) if inp.mustrun.hub[k] == h; init = 0.0))
        # Battery net injection  (discharge - charge)
        + sum(discharge[b, i] - charge[b, i]
              for b in 1:nb if inp.batteries[b].hub == h; init = AffExpr(0.0))
        # Corridor imports (net power arriving at h)
        + sum(fwd[ci, i] * (1.0 - corr[ci].loss_factor)
              for ci in 1:nc if corr[ci].to == h; init = AffExpr(0.0))
        + sum(rev[ci, i] * (1.0 - corr[ci].loss_factor)
              for ci in 1:nc if corr[ci].from == h; init = AffExpr(0.0))
        # Corridor exports (power leaving h)
        - sum(fwd[ci, i] for ci in 1:nc if corr[ci].from == h; init = AffExpr(0.0))
        - sum(rev[ci, i] for ci in 1:nc if corr[ci].to == h; init = AffExpr(0.0))
        # Unserved energy slack (under-supply)
        + unserved[h, i]
        # Over-generation curtailment slack (over-supply sink)
        - curtail[h, i]
        ==
        get(periods[i].demand, h, 0.0)
    )

    # ------------------------------------------------------------------
    # Flow continuity at non-reservoir, non-sea junction nodes
    # ------------------------------------------------------------------
    if na > 0
        resset = Set(r.name for r in inp.net.reservoirs)
        nodes  = union(Set(a.from for a in arcs), Set(a.to for a in arcs))
        for n in nodes
            (n in resset || n == "SEA") && continue
            for i in 1:np
                @constraint(model,
                    sum(arcflow[ai, i] for (ai, a) in enumerate(arcs) if a.to   == n; init = AffExpr(0.0))
                    ==
                    sum(arcflow[ai, i] for (ai, a) in enumerate(arcs) if a.from == n; init = AffExpr(0.0))
                )
            end
        end
    end

    # ------------------------------------------------------------------
    # Net outflow per reservoir per period (cumecs) — returned for caller
    # ------------------------------------------------------------------
    net_outflow = Dict{Tuple{String,Int},Any}()
    for r in inp.net.reservoirs, i in 1:np
        net_outflow[(r.name, i)] =
            sum(arcflow[ai, i] for (ai, a) in enumerate(arcs) if a.from == r.name; init = AffExpr(0.0)) -
            sum(arcflow[ai, i] for (ai, a) in enumerate(arcs) if a.to   == r.name; init = AffExpr(0.0))
    end

    return (
        gen         = gen,
        fwd         = fwd,
        rev         = rev,
        arcflow     = arcflow,
        unserved    = unserved,
        curtail     = curtail,
        charge      = charge,
        discharge   = discharge,
        soc         = soc,
        balance     = balance,
        net_outflow = net_outflow,
    )
end

# ---------------------------------------------------------------------------
# Cost expression (reused by master and subproblem)
# ---------------------------------------------------------------------------

# Tiny per-MWh penalty on over-generation curtailment — small enough never to
# be the marginal cost when load is served, large enough to keep curtailment
# at zero whenever export/load can absorb supply.  Defined ABOVE its first use
# in `dispatch_cost`.
const CURTAIL_PENALTY = 1e-3

"""
    dispatch_cost(model, periods, inp, v) -> AffExpr

Period-hour-weighted total dispatch cost: thermal SRMC + lost-load penalty +
a tiny curtailment penalty.  Hydro is costless here; value enters through
storage dynamics + water values.  The curtailment penalty (`CURTAIL_PENALTY`,
\$/MWh) is far below any real SRMC so it never sets a price when demand>0; it
only keeps the equality balance feasible when fixed must-run/hydro exceed
demand at an export-capped hub.
"""
function dispatch_cost(model::Model, periods::Vector{Period}, inp::DispatchInputs, v)
    return sum(
        periods[i].hours * (
            sum(inp.thermal.price[t] * v.gen[t, i]
                for t in 1:nrow(inp.thermal); init = AffExpr(0.0))
            + inp.lost_load_price *
              sum(v.unserved[h.code, i] for h in inp.topology.hubs)
            + CURTAIL_PENALTY *
              sum(v.curtail[h.code, i] for h in inp.topology.hubs)
        )
        for i in 1:length(periods)
    )
end

# ---------------------------------------------------------------------------
# Representative-day bucketing
# ---------------------------------------------------------------------------

"""
    bucket_demand(fd, week_start; periods_per_day=48) -> Vector{Period}

Build representative-day periods for the week starting `week_start` from a
`forward_demand` DataFrame with columns (date, tp, hub, mw).

For each day-type (weekday/weekend) × trading period:
  - demand = mean MW across that week's matching days at each hub
  - hours  = #days_of_type × 0.5 h  (one half-hour trading period)

Returns 2 × periods_per_day periods (fewer if a day-type is absent from the week).
"""
function bucket_demand(fd::DataFrame, week_start::Date; periods_per_day::Int = 48)
    days = [week_start + Day(k) for k in 0:6]
    sub  = fd[in.(fd.date, Ref(Set(days))), :]
    isempty(sub) && error("bucket_demand: no demand rows for week of $week_start")

    # Tag each row with its day-type
    sub = copy(sub)
    sub[!, :daytype] = [dayofweek(d) <= 5 ? "weekday" : "weekend" for d in sub.date]

    periods = Period[]
    for dt in ("weekday", "weekend")
        ndays = count(d -> (dayofweek(d) <= 5) == (dt == "weekday"), days)
        ndays == 0 && continue
        for tp in 1:periods_per_day
            rows = sub[(sub.daytype .== dt) .& (sub.tp .== tp), :]
            isempty(rows) && continue
            dem = Dict(
                h => mean(rows[rows.hub .== h, :mw])
                for h in unique(rows.hub)
            )
            push!(periods, Period("$(dt)_tp$(tp)", ndays * 0.5, dem))
        end
    end
    return periods
end

# ---------------------------------------------------------------------------
# Shared water-budget / battery / terminal-value helpers
# (used by both the deterministic master and the SDDP stage builder)
# ---------------------------------------------------------------------------

"Released VOLUME (Mm³) by reservoir `rname` over `periods`: Σ net_outflow × MM3_PER_CUMEC_HOUR × hours."
function released_volume(v, periods::Vector{Period}, rname::AbstractString)
    rel = AffExpr(0.0)
    for i in 1:length(periods)
        add_to_expression!(rel,
            v.net_outflow[(rname, i)] * (MM3_PER_CUMEC_HOUR * periods[i].hours))
    end
    return rel
end

"""
Battery weekly periodic-close: per battery, charge-in × eff == discharge-out over
the whole week (energy-neutral).  Batteries are bounded per-period only (not
SoC-chained) in the master/SDDP stage; this prevents free cross-week discharge.
"""
function add_weekly_battery_close!(model::Model, periods::Vector{Period}, batteries, v)
    for b in 1:length(batteries)
        eff = batteries[b].eff
        @constraint(model,
            sum(eff * v.charge[b, i] * periods[i].hours for i in 1:length(periods)) ==
            sum(v.discharge[b, i] * periods[i].hours for i in 1:length(periods)))
    end
    return nothing
end

"Aggregate end-of-horizon stored energy (GWh) from `reservoir-name => end-storage` refs/exprs."
function aggregate_stored_energy_gwh(net::HydroNetwork, end_storage)
    coeff = downstream_energy_coeff(net)
    E = AffExpr(0.0)
    for r in net.reservoirs
        c = get(coeff, r.name, 0.0)
        add_to_expression!(E, end_storage[r.name] * (c * MWH_PER_MM3_PER_SP / 1000.0))
    end
    return E
end

"""
Concave piecewise-linear terminal-value envelope on aggregate stored energy
`E_end` (GWh).  Adds a free `tv` variable and one `tv <= slope·E_end + intercept`
constraint per consecutive curve pair; returns `tv` (maximised via `-tv` in a Min
objective).  `terminal_wv` has columns `stored_energy`, `value`.
"""
function add_terminal_value!(model::Model, E_end::AffExpr, terminal_wv::DataFrame)
    tv = @variable(model, base_name = "tv")
    se = terminal_wv.stored_energy
    val = terminal_wv.value
    for k in 1:length(se)-1
        dx = se[k+1] - se[k]
        dx == 0 && continue
        slope = (val[k+1] - val[k]) / dx
        intercept = val[k] - slope * se[k]
        @constraint(model, tv <= slope * E_end + intercept)
    end
    return tv
end
