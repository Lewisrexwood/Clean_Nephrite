using TOML, DataFrames
using DuckDB, DBInterface

struct Reservoir
    name::String
    island::String
    hub::String
    monthly_share::Vector{Float64}
end

struct ReservoirSet
    reservoirs::Vector{Reservoir}
    inflow_file::String
    inflow_skip::Int
    inflow_comment::String
    inflow_year_col::String
    inflow_week_col::String
    reservoir_columns::Dict{String,String}
end

function load_reservoirs(path::AbstractString)
    cfg = TOML.parsefile(path)
    reservoirs = [Reservoir(r["name"], r["island"], r["hub"], Float64.(r["monthly_share"]))
                  for r in cfg["reservoirs"]]
    for r in reservoirs
        r.island in ("NI", "SI") || error("reservoir $(r.name): bad island $(r.island)")
        r.hub in HUB_CODES     || error("reservoir $(r.name): unknown hub $(r.hub)")
        length(r.monthly_share) == 12 ||
            error("reservoir $(r.name): monthly_share must have 12 entries")
    end
    inf = cfg["inflows"]
    return ReservoirSet(
        reservoirs,
        inf["file"],
        Int(inf["skip_rows"]),
        inf["comment_char"],
        inf["year_column"],
        inf["week_column"],
        Dict{String,String}(inf["reservoir_columns"]),
    )
end

"""
Per-reservoir storage (GWh) for calendar `month`, disaggregating the
operator-supplied NZ and SI aggregate storage with monthly shares.
NI storage = nz_gwh - si_gwh. Storage is a manual input because no free
daily storage feed is automatable (see config/reservoirs.toml).
"""
function storage_state(config_path::AbstractString; nz_gwh::Real, si_gwh::Real,
                       month::Integer)
    (nz_gwh >= 0 && si_gwh >= 0) ||
        error("storage_state: storage must be non-negative (nz=$nz_gwh, si=$si_gwh GWh)")
    si_gwh <= nz_gwh || error("storage_state: SI storage ($si_gwh GWh) exceeds NZ total ($nz_gwh GWh)")
    1 <= month <= 12 || error("storage_state: month must be 1–12, got $month")
    res = load_reservoirs(config_path)
    ni_gwh = nz_gwh - si_gwh
    rows = [(reservoir = r.name, island = r.island, hub = r.hub,
             gwh = (r.island == "SI" ? si_gwh : ni_gwh) * r.monthly_share[month])
            for r in res.reservoirs]
    return DataFrame(rows)
end

"""
Mean weekly inflows (cumecs) by week-of-year per reservoir, from the JADE
wide-format static file. The file has a leading `%` comment, a blank line,
then a CATCHMENT header row that provides lake column names, followed by two
metadata rows (INFLOW_REGION, YEAR/WEEK labels) and then the weekly data
(1932–2025, weeks 1–52). Returns a DataFrame with columns (reservoir, woy,
inflow) where inflow is the mean over all years for that week.

TeAnau and Manapouri both map to the combined Lakes_Manapouri_Te_Anau JADE
catchment — they receive the same mean inflow (monthly shares in storage_state
handle the within-lake split).
"""
function load_inflows(config_path::AbstractString)
    res = load_reservoirs(config_path)
    # @__DIR__ is src/; its parent is the project root, where data/static/ lives.
    project_root = normpath(dirname(@__DIR__))
    file = normpath(joinpath(project_root, res.inflow_file))
    isfile(file) || error("inflows file missing: $file — see data/static/README.md")
    fpath = sql_path(file)

    con = DBInterface.connect(DuckDB.DB)
    frames = DataFrame[]
    try
        for (reservoir, col) in res.reservoir_columns
            df = DataFrame(DBInterface.execute(con, """
                SELECT CAST("$(res.inflow_week_col)" AS INTEGER) AS woy,
                       avg(CAST("$col" AS DOUBLE)) AS inflow
                FROM read_csv('$(fpath)',
                              comment='$(res.inflow_comment)',
                              skip=$(res.inflow_skip),
                              header=true,
                              delim=',',
                              all_varchar=true,
                              null_padding=true)
                WHERE TRY_CAST("$(res.inflow_year_col)" AS INTEGER) IS NOT NULL
                  AND TRY_CAST("$col" AS DOUBLE) IS NOT NULL
                GROUP BY 1
                ORDER BY 1
            """))
            df[!, :reservoir] .= reservoir
            push!(frames, df)
        end
    finally
        DBInterface.close!(con)
    end
    out = vcat(frames...)
    out.woy    = Int.(out.woy)
    out.inflow = Float64.(out.inflow)
    sort!(out, [:reservoir, :woy])
    return out[:, [:reservoir, :woy, :inflow]]
end
