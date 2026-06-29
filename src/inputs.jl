using Dates, DataFrames, TOML
using DuckDB, DBInterface

# ===========================================================================
# inputs.jl — assemble the dispatch model's real WeekInputs from the Plan 1/2/3a
# transforms.  Builds, per week, the 96-period representative-day MASTER inputs
# plus the shared net / initial volumes / terminal water-value curve / anchor.
# The 336-step subproblem period lists are the runner's concern (Task 5).
# ===========================================================================

"""
Assembled model inputs:
- `weeks`        : one `WeekInputs` per modelled week (96-period master rep day).
- `net`          : the shared hydro network.
- `initial_vol`  : reservoir → initial storage VOLUME (Mm³) at the snapshot.
- `terminal_wv`  : JADE terminal water-value curve (stored_energy GWh, value \$/MWh).
- `anchor`       : offer-implied water-value anchor bundle (from `wvanchor`).
"""
struct ModelInputs
    weeks::Vector{WeekInputs}
    net::HydroNetwork
    initial_vol::Dict{String,Float64}
    terminal_wv::DataFrame
    anchor
end

"""
    assemble_inputs(ds, snapshot_date; config_dir, history_dir, nz_gwh, si_gwh,
                    n_weeks=104, overrides=Dict(), min_history_days=<demand.toml>)
        -> ModelInputs

Build the master model inputs for `n_weeks` weeks starting at `snapshot_date`.

What-if `overrides` (all hashed into the run manifest by the runner):
- `:demand_growth` (Float64)  — replaces the demand-growth rate.
- `:hvdc_derate`   (Float64)  — 0..1 multiplier on HVDC corridor caps.
- `:inflow_scale`  (Float64)  — multiplier on every reservoir's weekly inflow.
- `:fuel_scale`    (Float64)  — multiplier on thermal SRMC.
- `:tiwai_off`     (Bool)     — drop the Tiwai demand block when true.

`min_history_days` is threaded to `demand_shape` (defaults to demand.toml's
`min_history_days`).  It exists so tests/golden runs can use a short synthetic
history; production runs leave it at the config default.
"""
function assemble_inputs(ds::DataStore, snapshot_date::Date; config_dir::AbstractString,
                         history_dir::AbstractString, nz_gwh::Real, si_gwh::Real,
                         n_weeks::Int = 104, overrides::Dict = Dict(),
                         min_history_days::Int =
                             TOML.parsefile(joinpath(config_dir, "demand.toml"))["forward"]["min_history_days"],
                         forward_shape::Union{Nothing,DataFrame} = nothing)
    cfg(p) = joinpath(config_dir, p)
    project_root = normpath(dirname(config_dir))
    jade_dir = joinpath(project_root, "data", "static", "jade")

    # --- fundamentals -------------------------------------------------------
    jd    = load_jade(jade_dir, cfg("jade.toml"))
    sm    = build_stationmap(jd, cfg("stationmap.toml"))
    net   = build_hydronet(jd, sm)
    hm    = build_hubmap(ds, cfg("hubmap.toml"))
    plant = load_plant(cfg("plant.toml"))
    topo  = load_topology(cfg("topology.toml"))
    fleet = load_fleet(cfg("committed_projects.toml"))

    # --- thermal SRMC (+ fuel-scale override) -------------------------------
    fuel_scale = Float64(get(overrides, :fuel_scale, 1.0))
    thermal = thermal_supply_curves(jd, sm)            # hub, price, mw
    if fuel_scale != 1.0
        thermal = copy(thermal)
        thermal.price = thermal.price .* fuel_scale
    end
    lost_load_price = _lost_load_price(jd_lost_load(jade_dir, cfg("jade.toml")))
    batteries = _batteries(plant, fleet, snapshot_date)

    # --- demand: shape -> forward (+ growth + tiwai_off overrides) ----------
    growth = Float64(get(overrides, :demand_growth, _growth(cfg("demand.toml"))))
    shape  = forward_shape === nothing ?
             demand_shape(history_dir, hm, cfg("demand.toml"); min_days = min_history_days) :
             forward_shape
    years  = max(ceil(Int, n_weeks * 7 / 365), 1)
    fwd    = forward_demand(shape, snapshot_date, years; growth = growth)
    tiwai  = get(overrides, :tiwai_off, false) ? nothing : tiwai_block(hm, cfg("demand.toml"))

    # --- inflows by week-of-year (+ inflow_scale) ---------------------------
    infl_scale = Float64(get(overrides, :inflow_scale, 1.0))
    inflows    = load_inflows(cfg("reservoirs.toml"))  # reservoir, woy, inflow
    # net.reservoirs use JADE catchment names (Lake_Taupo, ...); the inflow
    # table is keyed by the reservoirs.toml names (Taupo, ...).  Bridge via the
    # config's reservoir_columns (config name -> JADE column == net name).
    jade_to_cfg = _jade_to_config_reservoir(cfg("reservoirs.toml"))

    # --- transmission with hvdc_derate override -----------------------------
    hvdc_derate = Float64(get(overrides, :hvdc_derate, 1.0))
    topo = _apply_hvdc_derate(topo, hvdc_derate)

    # --- assemble per-week --------------------------------------------------
    weeks = WeekInputs[]
    for w in 1:n_weeks
        ws = snapshot_date + Day(7 * (w - 1))
        periods = bucket_demand(fwd, ws)               # 96 reps (master)
        tiwai !== nothing && _add_tiwai!(periods, tiwai)
        periods336 = _build_periods336(fwd, ws, tiwai) # 336 chronological steps (subproblem)
        woy  = Dates.week(ws)                           # mirror _week_inflows
        mustrun = mustrun_generation(jd, sm, woy)       # hub, mw — per-week scheduled level
        inp  = DispatchInputs(topo, net, thermal, mustrun, batteries, lost_load_price)
        infl = _week_inflows(inflows, net, jade_to_cfg, ws; scale = infl_scale)
        push!(weeks, WeekInputs(periods, periods336, inp, infl))
    end

    month       = Dates.month(snapshot_date)
    initial_vol = initial_volumes(net, cfg("reservoirs.toml"); nz_gwh = nz_gwh,
                                  si_gwh = si_gwh, month = month)
    terminal_wv = _load_terminal_wv(joinpath(jade_dir, "terminal_water_value.csv"),
                                    cfg("jade.toml"))
    anchor      = wvanchor(ds, plant, sm, cfg("model.toml"); n_weeks = n_weeks)

    return ModelInputs(weeks, net, initial_vol, terminal_wv, anchor)
end

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

"Demand growth rate from demand.toml ([forward].annual_growth)."
_growth(demand_path::AbstractString) =
    Float64(TOML.parsefile(demand_path)["forward"]["annual_growth"])

# Path to the JADE lost_load.csv (handles the same project-root layout as the
# main loader); `_lost_load_price` reads it.
jd_lost_load(jade_dir::AbstractString, jade_cfg_path::AbstractString) =
    (jade_dir, jade_cfg_path)

"""
Representative lost-load price (\$/MWh) for the unserved-energy slack.  JADE's
lost_load.csv is a multi-segment value-of-lost-load schedule; we take the MAX
COST across all segments so shedding is the last resort in the dispatch (a
single scalar VOLL is all the LP slack needs).  The file carries a two-line
`%` comment preamble before the header.
"""
function _lost_load_price(loc::Tuple{<:AbstractString,<:AbstractString})
    jade_dir, jade_cfg_path = loc
    cfg = TOML.parsefile(jade_cfg_path)
    cost_col = _col(cfg, "lost_load", "cost", "COST")
    path = joinpath(jade_dir, "lost_load.csv")
    sp = sql_path(path)
    con = DBInterface.connect(DuckDB.DB)
    df = try
        DataFrame(DBInterface.execute(con,
            "SELECT * FROM read_csv('$sp', comment='%', header=true, all_varchar=false)"))
    finally
        DBInterface.close!(con)
    end
    isempty(df) && error("lost_load.csv has no rows: $path")
    return maximum(Float64.(df[!, cost_col]))
end

"""
Batteries for dispatch as NamedTuples (name, hub, power_mw, energy_mwh, eff),
combining plant.toml batteries with committed-fleet BESS additions effective by
`as_of`.  Zero-power batteries (placeholders) are skipped.  May be empty.

Plant batteries carry a POC, not a hub; they are mapped to a hub via the
fleet's hub if a same-name fleet entry exists, else dropped with a log line
(plant.toml batteries have no hub and 0 power in the current config).
"""
function _batteries(plant::Plant, fleet::Fleet, as_of::Date)
    out = NamedTuple{(:name,:hub,:power_mw,:energy_mwh,:eff),
                     Tuple{String,String,Float64,Float64,Float64}}[]
    fc = fleet_changes(fleet, as_of)
    for row in eachrow(fc)
        (row.kind == "addition" && row.technology == "battery") || continue
        row.capacity_mw > 0 || continue
        push!(out, (name = row.name, hub = row.hub, power_mw = row.capacity_mw,
                    energy_mwh = row.energy_mwh, eff = 0.85))
    end
    for b in plant.batteries
        b.power_mw > 0 || continue   # placeholders have 0 power — skip silently
        @info "inputs: plant.toml battery $(b.name) has no hub mapping; skipped (provide it via committed_projects.toml)"
    end
    return out
end

"""
Return a NEW Topology with HVDC corridor caps scaled by `derate` (0..1);
AC corridors are left unchanged.  `derate == 1.0` returns the topology as-is.
"""
function _apply_hvdc_derate(topo::Topology, derate::Float64)
    derate == 1.0 && return topo
    (0.0 <= derate <= 1.0) || error("hvdc_derate must be in 0..1, got $derate")
    corridors = Corridor[]
    for c in topo.corridors
        if c.kind == "HVDC"
            push!(corridors, Corridor(c.from, c.to,
                                      c.capacity_fwd_mw * derate,
                                      c.capacity_rev_mw * derate,
                                      c.loss_factor, c.kind))
        else
            push!(corridors, c)
        end
    end
    return Topology(topo.hubs, corridors)
end

"""
Build the 336-step CHRONOLOGICAL subproblem period list for the week starting
`week_start`: 7 days × 48 trading periods, each a 30-min `Period` (hours = 0.5)
whose demand is the forward-demand MW at that (date, tp) per hub.  Tiwai's
baseline MW is added to its hub when `tiwai !== nothing` (matching the master's
treatment).  Days/tps absent from `fwd` simply contribute zero demand for that
hub.  The order is strictly chronological (day-major, then tp) so the subproblem
sees a real week, not a representative day.
"""
function _build_periods336(fd::DataFrame, week_start::Date, tiwai;
                           periods_per_day::Int = 48)
    days = [week_start + Day(k) for k in 0:6]
    sub  = fd[in.(fd.date, Ref(Set(days))), :]
    isempty(sub) && error("_build_periods336: no demand rows for week of $week_start")
    # (date, tp) -> Dict(hub => mw)
    lookup = Dict{Tuple{Date,Int},Dict{String,Float64}}()
    for r in eachrow(sub)
        d = get!(lookup, (r.date, r.tp), Dict{String,Float64}())
        d[r.hub] = get(d, r.hub, 0.0) + Float64(r.mw)
    end
    periods = Period[]
    for day in days, tp in 1:periods_per_day
        dem = copy(get(lookup, (day, tp), Dict{String,Float64}()))
        tiwai !== nothing && (dem[tiwai.hub] = get(dem, tiwai.hub, 0.0) + tiwai.baseline_mw)
        push!(periods, Period("$(day)_tp$(tp)", 0.5, dem))
    end
    return periods
end

"Add the Tiwai block MW to its hub's demand in every period (in place)."
function _add_tiwai!(periods::Vector{Period}, tiwai)
    for p in periods
        p.demand[tiwai.hub] = get(p.demand, tiwai.hub, 0.0) + tiwai.baseline_mw
    end
    return periods
end

"""
Invert reservoirs.toml's `[inflows.reservoir_columns]` (config name -> JADE
column name) to a map JADE-column-name -> config reservoir name.  The JADE
column name equals the `net.reservoirs` name (both are JADE catchment names).
"""
function _jade_to_config_reservoir(reservoirs_config_path::AbstractString)
    res = load_reservoirs(reservoirs_config_path)
    out = Dict{String,String}()
    for (cfg_name, jade_col) in res.reservoir_columns
        out[jade_col] = cfg_name
    end
    return out
end

"""
Per-reservoir mean inflow (cumecs) for the week-of-year of `week_start`, keyed
by JADE reservoir name (matching `net.reservoirs`), scaled by `scale`.
Reservoirs absent from the inflow table get 0.0 — and are LOGGED so silent
zeroing of the whole hydro budget is impossible to miss.
"""
function _week_inflows(inflows::DataFrame, net::HydroNetwork,
                       jade_to_cfg::Dict{String,String}, week_start::Date;
                       scale::Float64 = 1.0)
    woy = Dates.week(week_start)
    sub = inflows[inflows.woy .== woy, :]
    by_cfg = Dict(r.reservoir => r.inflow for r in eachrow(sub))
    out  = Dict{String,Float64}()
    zeroed = String[]
    for r in net.reservoirs
        cfg_name = get(jade_to_cfg, r.name, r.name)
        v = get(by_cfg, cfg_name, nothing)
        if v === nothing
            out[r.name] = 0.0
            push!(zeroed, r.name)
        else
            out[r.name] = Float64(v) * scale
        end
    end
    isempty(zeroed) ||
        @info "inputs: no inflow-table entry for reservoir(s) $(join(zeroed, ", ")) (week-of-year $woy) — set to 0 cumecs"
    return out
end

"""
Read the JADE terminal water-value curve, handling its leading `%` comment
preamble.  Returns a DataFrame with columns `stored_energy` (GWh) and `value`
(\$/MWh), sorted by stored_energy.  Column names are taken from jade.toml's
`[columns.terminal_water_value]`.
"""
function _load_terminal_wv(path::AbstractString, jade_cfg_path::AbstractString)
    isfile(path) || error("terminal water-value file missing: $path")
    cfg = TOML.parsefile(jade_cfg_path)
    se_col  = _col(cfg, "terminal_water_value", "stored_energy", "STORED_ENERGY")
    val_col = _col(cfg, "terminal_water_value", "value",         "VALUE")
    sp = sql_path(path)
    con = DBInterface.connect(DuckDB.DB)
    df = try
        DataFrame(DBInterface.execute(con,
            "SELECT CAST(\"$se_col\" AS DOUBLE) AS stored_energy, " *
            "CAST(\"$val_col\" AS DOUBLE) AS value " *
            "FROM read_csv('$sp', comment='%', header=true, all_varchar=true)"))
    finally
        DBInterface.close!(con)
    end
    isempty(df) && error("terminal water-value curve has no rows: $path")
    sort!(df, :stored_energy)
    return df[:, [:stored_energy, :value]]
end
