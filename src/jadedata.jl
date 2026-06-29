using TOML, DataFrames
using DuckDB, DBInterface

# ---------------------------------------------------------------------------
# Typed structs
# ---------------------------------------------------------------------------

struct ThermalUnit
    name::String
    fuel::String
    heat_rate::Float64        # GJ/MWh
    capacity_mw::Float64
    hub_ref::String           # JADE node/region — resolved to a hub by stationmap
end

struct FuelCost
    fuel::String
    price_per_gj::Float64
    carbon_t_per_gj::Float64  # tCO2/GJ — from config scalars, not in data rows
end

struct HydroStation
    name::String
    capacity_mw::Float64
    specific_power::Float64                          # MW per cumec
    turbine_segments::Vector{Tuple{Float64,Float64}} # cumulative (flow_cumecs, mw), concave
end

struct JadeReservoir
    name::String
    island::String            # inflow region (NI / SI)
    min_volume::Float64       # Mm³ (lake storage volume; JADE reservoir_limits MIN_1_LEVEL; min may be negative = contingent storage; 0.0 if no limit)
    max_volume::Float64       # Mm³ (lake storage volume; JADE reservoir_limits MAX_LEVEL; Inf if no limit). Energy content is derived downstream via specific_power (see hydroenergy.jl).
end

struct Arc
    from::String
    to::String
    station::String           # "" if no station on this arc (spill / river)
    max_flow::Float64         # cumecs (Inf if unconstrained)
end

struct FixedStation
    name::String
    node::String              # JADE node (NI / SI / HAY)
    # week-of-year (1..52) -> representative must-run MW for that week.
    # The representative level is the equal-weight mean(PEAK, SHOULDER, OFFPEAK):
    # JADE does not define the within-day block windows and the blocks are nearly
    # flat for almost all stations, so the mean of the three blocks is the
    # representative daily level applied to every period of that week.
    weekly_mw::Dict{Int,Float64}
end

"""
    mustrun_mw(fs::FixedStation, woy::Integer) -> Float64

Representative must-run MW for `fs` in week-of-year `woy` (falls back to the mean
over all weeks if that week is absent).
"""
function mustrun_mw(fs::FixedStation, woy::Integer)
    haskey(fs.weekly_mw, woy) && return fs.weekly_mw[woy]
    isempty(fs.weekly_mw) ? 0.0 : sum(values(fs.weekly_mw)) / length(fs.weekly_mw)
end

struct JadeData
    thermal_units::Vector{ThermalUnit}
    fuel_costs::Vector{FuelCost}
    hydro_stations::Vector{HydroStation}
    reservoirs::Vector{JadeReservoir}
    arcs::Vector{Arc}
    carbon_price_nzd_per_tonne::Float64
    fixed_stations::Vector{FixedStation}
end

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# Forward-slash escape for DuckDB SQL string literals.
_jade_sql_path(p::AbstractString) = replace(replace(p, "\\" => "/"), "'" => "''")

function _read_csv(path::AbstractString)
    con = DBInterface.connect(DuckDB.DB)
    try
        DataFrame(DBInterface.execute(con,
            "SELECT * FROM read_csv_auto('$(_jade_sql_path(path))', all_varchar=false)"))
    finally
        DBInterface.close!(con)
    end
end

# Column name lookup: config[columns.<file>.<logical>] or fallback to default.
_col(cfg, file, logical, default) =
    get(get(get(cfg, "columns", Dict()), file, Dict()), logical, default)

# ---------------------------------------------------------------------------
# Single-segment turbine curve (linear) per station.
# Real JADE hydro_stations.csv has one SPECIFIC_POWER scalar per station —
# no multi-segment curve rows.  A single linear segment (0→max_flow) is
# trivially concave and satisfies Task 5's concavity validator.
# ---------------------------------------------------------------------------
function _turbine_segments(capacity_mw::Float64, specific_power::Float64, station_name::String="")
    specific_power > 0 || error("jadedata: station $(isempty(station_name) ? "<unknown>" : station_name) has non-positive specific_power $specific_power")
    max_flow = capacity_mw / specific_power   # cumecs at full load
    return [(0.0, 0.0), (max_flow, capacity_mw)]
end

# ---------------------------------------------------------------------------
# Join reservoirs.csv to reservoir_limits.csv to extract min/max volumes.
# reservoir_limits is a wide-format time-series; we take the column-wise max
# of MAX_LEVEL over all rows as the max volume, and the column-wise max of
# MIN_1_LEVEL as the binding minimum (most permissive lower bound).
# Reservoirs that have no limit columns default to min=0, max=Inf.
# ---------------------------------------------------------------------------
function _build_reservoirs(rdf::DataFrame, ldf::DataFrame,
                           cfg::Dict)
    res_col  = _col(cfg, "reservoirs", "name",          "RESERVOIR")
    reg_col  = _col(cfg, "reservoirs", "inflow_region", "INFLOW_REGION")

    # Collect spaced column names from reservoir_limits that are present.
    limit_cols = names(ldf)  # includes YEAR, WEEK + lake columns

    reservoirs = JadeReservoir[]
    for row in eachrow(rdf)
        rname  = String(row[res_col])
        island = String(row[reg_col])

        max_col_name = "$rname MAX_LEVEL"
        min_col_name = "$rname MIN_1_LEVEL"

        max_vol = if max_col_name in limit_cols
            maximum(Float64.(ldf[!, max_col_name]))
        else
            Inf
        end

        min_vol = if min_col_name in limit_cols
            maximum(Float64.(ldf[!, min_col_name]))  # least-binding lower bound
        else
            0.0
        end

        push!(reservoirs, JadeReservoir(rname, island, min_vol, max_vol))
    end
    return reservoirs
end

# ---------------------------------------------------------------------------
# Fuel costs: thermal_fuel_costs.csv has a 3-row non-comment preamble.
# Load with DuckDB skip=3/header=false; CO2 intensities come from config
# scalars (they live in the skipped preamble row 2).
# We take the last data row as the "current" price for each fuel.
# ---------------------------------------------------------------------------
function _load_fuel_costs(path::AbstractString, cfg::Dict)
    col_section = get(get(cfg, "columns", Dict()), "thermal_fuel_costs", Dict())
    year_col    = get(col_section, "year",   "YEAR")
    week_col    = get(col_section, "week",   "WEEK")
    coal_col    = get(col_section, "coal",   "coal")
    diesel_col  = get(col_section, "diesel", "diesel")
    gas_col     = get(col_section, "gas",    "gas")

    # CO2 intensities (tCO2/GJ) from config scalars derived from preamble row 2
    co2_coal   = Float64(get(col_section, "co2_intensity_coal",   0.09218))
    co2_diesel = Float64(get(col_section, "co2_intensity_diesel", 0.06939))
    co2_gas    = Float64(get(col_section, "co2_intensity_gas",    0.05397))

    sp = _jade_sql_path(path)
    con = DBInterface.connect(DuckDB.DB)
    df = try
        DataFrame(DBInterface.execute(con,
            "SELECT * FROM read_csv('$sp', skip=3, header=false, " *
            "columns={'$year_col':'INTEGER','$week_col':'INTEGER'," *
            " '$coal_col':'DOUBLE','$diesel_col':'DOUBLE'," *
            " '$gas_col':'DOUBLE','CO2':'DOUBLE'})"))
    finally
        DBInterface.close!(con)
    end

    isempty(df) && return FuelCost[]

    # Use last row (most recent week) as the current fuel price
    last_row = last(df)
    return [
        FuelCost("coal",   Float64(last_row[coal_col]),   co2_coal),
        FuelCost("diesel", Float64(last_row[diesel_col]), co2_diesel),
        FuelCost("gas",    Float64(last_row[gas_col]),    co2_gas),
    ]
end

# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

"""
    load_jade(jade_dir, config_path) -> JadeData

Load the JADE input dataset from `jade_dir` CSV files, guided by column-name
overrides in `config_path` (config/jade.toml).  Returns a `JadeData` bundle
of typed structs ready for use in the dispatch model.

Column reconciliation: all names are read from config/jade.toml `[columns.*]`
sections, with hardcoded defaults matching the real JADE schema.
"""
function load_jade(jade_dir::AbstractString, config_path::AbstractString)
    cfg = TOML.parsefile(config_path)
    rd(f) = _read_csv(joinpath(jade_dir, f))

    # --- Thermal stations ---------------------------------------------------
    tdf = rd("thermal_stations.csv")
    name_c  = _col(cfg, "thermal_stations", "name",      "GENERATOR")
    fuel_c  = _col(cfg, "thermal_stations", "fuel",      "FUEL")
    hr_c    = _col(cfg, "thermal_stations", "heat_rate", "HEAT_RATE")
    cap_c   = _col(cfg, "thermal_stations", "capacity",  "CAPACITY")
    node_c  = _col(cfg, "thermal_stations", "node",      "NODE")
    thermal = [ThermalUnit(String(r[name_c]),
                           String(r[fuel_c]),
                           Float64(r[hr_c]),
                           Float64(r[cap_c]),
                           String(r[node_c]))
               for r in eachrow(tdf)]

    # --- Fuel costs (special preamble handling) ------------------------------
    fuels = _load_fuel_costs(joinpath(jade_dir, "thermal_fuel_costs.csv"), cfg)

    # --- Hydro stations ------------------------------------------------------
    hdf    = rd("hydro_stations.csv")
    hname_c = _col(cfg, "hydro_stations", "name",           "GENERATOR")
    hcap_c  = _col(cfg, "hydro_stations", "capacity",       "CAPACITY")
    hsp_c   = _col(cfg, "hydro_stations", "specific_power", "SPECIFIC_POWER")
    hydro = [HydroStation(String(r[hname_c]),
                          Float64(r[hcap_c]),
                          Float64(r[hsp_c]),
                          _turbine_segments(Float64(r[hcap_c]), Float64(r[hsp_c]), String(r[hname_c])))
             for r in eachrow(hdf)]

    # --- Reservoirs (joined to limits) --------------------------------------
    rdf  = rd("reservoirs.csv")
    ldf  = rd("reservoir_limits.csv")
    reservoirs = _build_reservoirs(rdf, ldf, cfg)

    # --- Arcs ----------------------------------------------------------------
    # In JADE each hydro station IS its own arc: water flows HEAD_WATER_FROM →
    # TAIL_WATER_TO through the turbine.  Build one such station arc per station,
    # then add the natural conveyance/spill arcs from hydro_arcs.csv (station "").
    hhw_col = _col(cfg, "hydro_stations", "head_water_from", "HEAD_WATER_FROM")
    htw_col = _col(cfg, "hydro_stations", "tail_water_to",   "TAIL_WATER_TO")

    arcs = Arc[]
    for r in eachrow(hdf)
        name     = String(r[hname_c])
        from_node = String(r[hhw_col])
        to_node   = String(r[htw_col])
        # turbine hydraulic max in cumecs (matches _turbine_segments); keeps
        # arcflow*specific_power ≤ capacity consistent with the electrical cap.
        max_flow = Float64(r[hcap_c]) / Float64(r[hsp_c])
        push!(arcs, Arc(from_node, to_node, name, max_flow))
    end

    adf   = rd("hydro_arcs.csv")
    orig_c    = _col(cfg, "hydro_arcs", "orig",     "ORIG")
    dest_c    = _col(cfg, "hydro_arcs", "dest",     "DEST")
    mflow_c   = _col(cfg, "hydro_arcs", "max_flow", "MAX_FLOW")
    for r in eachrow(adf)
        from_node = String(r[orig_c])
        to_node   = String(r[dest_c])
        raw_max   = r[mflow_c]
        max_flow  = (ismissing(raw_max) || string(raw_max) == "na") ? Inf : parse(Float64, string(raw_max))
        push!(arcs, Arc(from_node, to_node, "", max_flow))
    end

    # --- Fixed stations (geo / cogen must-run) ----------------------------------
    fdf = rd("fixed_stations.csv")
    fname_c   = _col(cfg, "fixed_stations", "station", "STATION")
    fnode_c   = _col(cfg, "fixed_stations", "node",    "NODE")
    fweek_c   = _col(cfg, "fixed_stations", "week",    "WEEK")
    fpeak_c   = _col(cfg, "fixed_stations", "peak",    "PEAK")
    fshoul_c  = _col(cfg, "fixed_stations", "shoulder", "SHOULDER")
    foffpeak_c = _col(cfg, "fixed_stations", "offpeak",  "OFFPEAK")

    # One FixedStation per unique (station, node).  For each row the representative
    # level is rep = mean(PEAK, SHOULDER, OFFPEAK) (equal-weight: JADE block windows
    # are undefined and blocks are nearly flat).  The file spans many years per
    # week-of-year, so weekly_mw[WEEK] = mean of rep across all rows (years) with
    # that WEEK — the per-week scheduled must-run level applied to every period of
    # that week.
    fixed = FixedStation[]
    for gdf in groupby(fdf, [fname_c, fnode_c])
        name = String(first(gdf[!, fname_c]))
        node = String(first(gdf[!, fnode_c]))
        sums  = Dict{Int,Float64}()
        counts = Dict{Int,Int}()
        for r in eachrow(gdf)
            week = Int(r[fweek_c])
            rep  = (Float64(r[fpeak_c]) + Float64(r[fshoul_c]) + Float64(r[foffpeak_c])) / 3
            sums[week]   = get(sums, week, 0.0) + rep
            counts[week] = get(counts, week, 0) + 1
        end
        weekly = Dict(w => sums[w] / counts[w] for w in keys(sums))
        push!(fixed, FixedStation(name, node, weekly))
    end

    return JadeData(thermal, fuels, hydro, reservoirs, arcs,
                    Float64(cfg["carbon_price_nzd_per_tonne"]),
                    fixed)
end
