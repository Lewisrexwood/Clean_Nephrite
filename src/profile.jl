using TOML, Dates, DataFrames, Statistics
using DuckDB, DBInterface

"""
Historical demand shape per hub: mean MW by (hub, week-of-year, daytype, tp)
over all backfilled history files. Tiwai POCs are excluded (it is a block,
not a shape). Errors if fewer than `min_days` distinct days are present.
"""
function demand_shape(history_dir::AbstractString, hm::HubMap,
                      config_path::AbstractString;
                      min_days::Int = TOML.parsefile(config_path)["forward"]["min_history_days"])
    isdir(history_dir) || error("demand history missing: $history_dir — run scripts/backfill_demand.jl")
    tiwai = tiwai_pocs(config_path)
    placeholders = sql_in_list(tiwai)
    glob = sql_path(joinpath(history_dir, "*_grid_demand.csv"))
    con = DBInterface.connect(DuckDB.DB)
    df = try
        DataFrame(DBInterface.execute(con, """
            WITH latest AS (
                SELECT *, row_number() OVER (
                    PARTITION BY PointOfConnectionCode, IntervalDateTime
                    ORDER BY CaseID DESC) AS rn
                FROM read_csv_auto('$glob', union_by_name = true))
            SELECT TradingDate AS date, TradingPeriodNumber AS tp,
                   PointOfConnectionCode AS poc, avg(LoadMegawatts) AS mw
            FROM latest
            WHERE rn = 1 AND LoadMegawatts > 0
              AND PointOfConnectionCode NOT IN ($placeholders)
            GROUP BY 1, 2, 3
        """))
    finally
        DBInterface.close!(con)
    end
    ndays = length(unique(df.date))
    ndays >= min_days ||
        error("demand shape needs >= $min_days days of history, found $ndays — " *
              "run scripts/backfill_demand.jl over a longer range")
    df.hub = [hub_for(hm, p) for p in df.poc]
    df.woy = [Dates.week(d) for d in df.date]
    df.daytype = [Dates.dayofweek(d) <= 5 ? "weekday" : "weekend" for d in df.date]
    hubmw = combine(groupby(df, [:date, :tp, :hub, :woy, :daytype]), :mw => sum => :mw)
    shape = combine(groupby(hubmw, [:hub, :woy, :daytype, :tp]), :mw => mean => :mw)
    sort!(shape, [:hub, :woy, :daytype, :tp])
    return shape[:, [:hub, :woy, :daytype, :tp, :mw]]
end

"""
Project the shape forward `years`×365 days from `start`: for each forward
date/tp/hub, take the shape value at (week-of-year, daytype, tp) scaled by
(1+growth)^(years elapsed). Missing (woy, daytype) cells fall back to the
nearest week-of-year with data for that daytype. Uses a flat 365-day year
(leap days are not added), so a 2-year horizon spans 730 calendar days.
"""
function forward_demand(shape::DataFrame, start::Date, years::Int;
                        growth::Float64)
    lookup = Dict{Tuple{String,Int,String,Int},Float64}(
        (r.hub, r.woy, r.daytype, r.tp) => r.mw for r in eachrow(shape))
    hubs = unique(shape.hub)
    tps = sort(unique(shape.tp))
    woys_by_daytype = Dict(dt => sort(unique(shape[shape.daytype .== dt, :woy]))
                           for dt in unique(shape.daytype))
    rows = NamedTuple{(:date, :tp, :hub, :mw),Tuple{Date,Int,String,Float64}}[]
    for offset in 0:(years * 365 - 1)
        d = start + Dates.Day(offset)
        woy = Dates.week(d)
        dt = Dates.dayofweek(d) <= 5 ? "weekday" : "weekend"
        haskey(woys_by_daytype, dt) || continue
        avail = woys_by_daytype[dt]
        w = avail[argmin([min(abs(a - woy), 53 - abs(a - woy)) for a in avail])]   # circular nearest week
        factor = (1.0 + growth)^(offset / 365)
        for hub in hubs, tp in tps
            mw = get(lookup, (hub, w, dt, tp), nothing)
            mw === nothing && continue
            push!(rows, (date = d, tp = tp, hub = hub, mw = mw * factor))
        end
    end
    return DataFrame(rows)
end
