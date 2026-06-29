using DataFrames, Dates
using DuckDB, DBInterface

# ===========================================================================
# inflowscenarios.jl — empirical, stagewise-independent inflow scenarios for the
# SDDP engine (Phase 2b).  Each stage week gets a vector of equiprobable inflow
# realizations (one per historical year for that week-of-year), keyed by the net
# reservoir name.  This is the SWAP-POINT for sub-project 2a (persistence /
# spatial coherence / exogenous conditioning replace the internals; the return
# type is stable).
# ===========================================================================

"""
    load_inflows_by_year(config_path) -> DataFrame(reservoir, year, woy, inflow)

Per-(reservoir, year, week-of-year) weekly inflow (cumecs) from the JADE wide
static file — the SAME file `load_inflows` reads, but retaining the year rather
than averaging over years.  `reservoir` is the CONFIG name (the key of
`[inflows.reservoir_columns]`), matching `load_inflows`'s convention.
"""
function load_inflows_by_year(config_path::AbstractString)
    res = load_reservoirs(config_path)
    project_root = normpath(dirname(@__DIR__))
    file = normpath(joinpath(project_root, res.inflow_file))
    isfile(file) || error("inflows file missing: $file — see data/static/README.md")
    fpath = sql_path(file)

    con = DBInterface.connect(DuckDB.DB)
    frames = DataFrame[]
    try
        for (reservoir, col) in res.reservoir_columns
            df = DataFrame(DBInterface.execute(con, """
                SELECT CAST("$(res.inflow_year_col)" AS INTEGER) AS year,
                       CAST("$(res.inflow_week_col)" AS INTEGER) AS woy,
                       CAST("$col" AS DOUBLE) AS inflow
                FROM read_csv('$(fpath)',
                              comment='$(res.inflow_comment)',
                              skip=$(res.inflow_skip),
                              header=true, delim=',',
                              all_varchar=true, null_padding=true)
                WHERE TRY_CAST("$(res.inflow_year_col)" AS INTEGER) IS NOT NULL
                  AND TRY_CAST("$col" AS DOUBLE) IS NOT NULL
            """))
            df[!, :reservoir] .= reservoir
            push!(frames, df)
        end
    finally
        DBInterface.close!(con)
    end
    out = vcat(frames...)
    out.year   = Int.(out.year)
    out.woy    = Int.(out.woy)
    out.inflow = Float64.(out.inflow)
    sort!(out, [:reservoir, :year, :woy])
    return out[:, [:reservoir, :year, :woy, :inflow]]
end

"""
    inflow_scenarios_from_frame(by_year, net, jade_to_cfg, woys)
        -> Dict{Int, Vector{Dict{String,Float64}}}

Pure transform: for each stage index `t` (1-based, matching `woys[t]`), collect
one equiprobable realization per historical year present for that week-of-year.
Each realization is `net-reservoir-name => cumecs`.  A net reservoir with no
table entry (or missing in a given year) contributes 0.0 for that year.
"""
function inflow_scenarios_from_frame(by_year::DataFrame, net::HydroNetwork,
                                     jade_to_cfg::Dict{String,String}, woys::Vector{Int})
    cfg_names = Dict(r.name => get(jade_to_cfg, r.name, r.name) for r in net.reservoirs)
    out = Dict{Int,Vector{Dict{String,Float64}}}()
    for (t, woy) in enumerate(woys)
        sub = by_year[by_year.woy .== woy, :]
        years = sort(unique(sub.year))
        # value lookup: (config-reservoir, year) -> inflow
        bykey = Dict{Tuple{String,Int},Float64}()
        for row in eachrow(sub)
            bykey[(String(row.reservoir), Int(row.year))] = Float64(row.inflow)
        end
        realizations = Vector{Dict{String,Float64}}()
        for y in years
            real = Dict{String,Float64}()
            for r in net.reservoirs
                real[r.name] = get(bykey, (cfg_names[r.name], y), 0.0)
            end
            push!(realizations, real)
        end
        # If a week-of-year has no rows at all, fall back to a single zero sample
        # so the stage still has support (logged so it cannot pass silently).
        if isempty(realizations)
            @info "inflow_scenarios: no inflow rows for week-of-year $woy — using a single zero sample"
            push!(realizations, Dict(r.name => 0.0 for r in net.reservoirs))
        end
        out[t] = realizations
    end
    return out
end

"""
    empirical_inflow_scenarios(config_path, net, snapshot_date, n_weeks)
        -> Dict{Int, Vector{Dict{String,Float64}}}

Compose `load_inflows_by_year` with `inflow_scenarios_from_frame`, mapping each
stage week to its week-of-year exactly as `_week_inflows` does
(`Dates.week(snapshot_date + 7*(t-1))`).
"""
function empirical_inflow_scenarios(config_path::AbstractString, net::HydroNetwork,
                                    snapshot_date::Date, n_weeks::Integer)
    by_year = load_inflows_by_year(config_path)
    jade_to_cfg = _jade_to_config_reservoir(config_path)
    woys = [Dates.week(snapshot_date + Day(7 * (t - 1))) for t in 1:n_weeks]
    return inflow_scenarios_from_frame(by_year, net, jade_to_cfg, woys)
end
