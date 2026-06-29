using Dates, DataFrames, Statistics
using DuckDB, DBInterface

# ===========================================================================
# outputs.jl — turn a RunResult into ASX-shaped deliverables.
#
# The required deliverable is the monthly base/peak forward curve at the two
# ASX settlement nodes (OTA, BEN), written as Parquet + CSV into the run dir.
# Best-effort diagnostics (full 30-min hub prices, weekly water values vs the
# offer-implied anchor, master storage trajectories) are also written.
# ===========================================================================

# NZ ASX peak = 0700-2200 business days; confirm against current contract spec
# (flagged for Task 8 validation).  Encoded as a const so it is adjustable.
const ASX_PEAK_HOURS = (7, 22)

# ASX settlement nodes whose forward curves we publish.
const ASX_HUBS = ("OTA", "BEN")

"`true` if `ts` falls in the ASX peak window (weekday, hour ∈ [lo, hi))."
function _is_peak(ts::DateTime)
    lo, hi = ASX_PEAK_HOURS
    return dayofweek(ts) <= 5 && lo <= hour(ts) < hi
end

"Calendar timestamp of a (week, step): snapshot + 7-day weeks + 30-min steps."
_step_ts(snapshot_date::Date, week::Int, step::Int) =
    DateTime(snapshot_date) + Day(7 * (week - 1)) + Minute(30 * (step - 1))

"""
    forward_curves(prices, snapshot_date; n_weeks) -> DataFrame

Monthly base/peak forward curves at the ASX settlement nodes (OTA, BEN).

`prices` is the `RunResult.prices` dict `(hub, week, step) => \$/MWh`.  Each
(week, step) is mapped to a calendar timestamp and bucketed by first-of-month.
For each (month, hub):

- `base` = mean nodal price over ALL 30-min steps in the month;
- `peak` = mean over steps whose timestamp is a weekday with hour in the
           `ASX_PEAK_HOURS` window.

Returns a long DataFrame with columns `month, product, hub, distribution,
price` (`distribution = "point"` in Phase 1).  Iteration is over sorted keys
so the output is deterministic regardless of Dict order.
"""
function forward_curves(prices::Dict{Tuple{String,Int,Int},Float64},
                        snapshot_date::Date; n_weeks::Int)
    # Accumulate sums/counts per (month, hub) for base and peak windows.
    base_sum  = Dict{Tuple{Date,String},Float64}()
    base_n    = Dict{Tuple{Date,String},Int}()
    peak_sum  = Dict{Tuple{Date,String},Float64}()
    peak_n    = Dict{Tuple{Date,String},Int}()

    for key in sort(collect(keys(prices)))
        hub, week, step = key
        hub in ASX_HUBS || continue
        week <= n_weeks || continue
        ts = _step_ts(snapshot_date, week, step)
        m  = Date(year(ts), month(ts), 1)
        p  = prices[key]
        mk = (m, hub)
        base_sum[mk] = get(base_sum, mk, 0.0) + p
        base_n[mk]   = get(base_n, mk, 0) + 1
        if _is_peak(ts)
            peak_sum[mk] = get(peak_sum, mk, 0.0) + p
            peak_n[mk]   = get(peak_n, mk, 0) + 1
        end
    end

    months   = String[]
    products = String[]
    hubs     = String[]
    dists    = String[]
    pricecol = Float64[]
    months_d = Date[]

    for mk in sort(collect(keys(base_sum)))
        m, hub = mk
        # base: always defined where a month/hub bucket exists.
        push!(months_d, m); push!(products, "base"); push!(hubs, hub)
        push!(dists, "point"); push!(pricecol, base_sum[mk] / base_n[mk])
        # peak: only where the peak window had matching steps; otherwise fall
        # back to base so every (month, hub) has a complete base+peak pair.
        pn = get(peak_n, mk, 0)
        peak_price = pn > 0 ? peak_sum[mk] / pn : base_sum[mk] / base_n[mk]
        push!(months_d, m); push!(products, "peak"); push!(hubs, hub)
        push!(dists, "point"); push!(pricecol, peak_price)
    end

    return DataFrame(month = months_d, product = products, hub = hubs,
                     distribution = dists, price = pricecol)
end

# ---------------------------------------------------------------------------
# Output writing
# ---------------------------------------------------------------------------

"Write a DataFrame to Parquet via DuckDB COPY (registers the frame, copies it out)."
function _write_parquet(df::DataFrame, path::AbstractString)
    con = DBInterface.connect(DuckDB.DB)
    try
        DuckDB.register_data_frame(con, df, "out_tbl")
        DBInterface.execute(con,
            "COPY (SELECT * FROM out_tbl) TO '$(sql_path(path))' (FORMAT PARQUET)")
        DuckDB.unregister_data_frame(con, "out_tbl")
    finally
        DBInterface.close!(con)
        GC.gc()  # Windows: release DuckDB's file handle before any later overwrite
    end
    return path
end

"Write a DataFrame to a human-readable CSV via DuckDB COPY (FORMAT CSV, HEADER)."
function _write_csv(df::DataFrame, path::AbstractString)
    con = DBInterface.connect(DuckDB.DB)
    try
        DuckDB.register_data_frame(con, df, "out_tbl")
        DBInterface.execute(con,
            "COPY (SELECT * FROM out_tbl) TO '$(sql_path(path))' (FORMAT CSV, HEADER)")
        DuckDB.unregister_data_frame(con, "out_tbl")
    finally
        DBInterface.close!(con)
        GC.gc()
    end
    return path
end

"Long DataFrame of every 30-min nodal price: `hub, week, step, price` (sorted)."
function _prices_dataframe(prices::Dict{Tuple{String,Int,Int},Float64})
    keys_sorted = sort(collect(keys(prices)))
    hub  = [k[1] for k in keys_sorted]
    week = [k[2] for k in keys_sorted]
    step = [k[3] for k in keys_sorted]
    val  = [prices[k] for k in keys_sorted]
    return DataFrame(hub = hub, week = week, step = step, price = val)
end

"""
Weekly water values vs the offer-implied anchor.

`mr.water_value` is `(reservoir, week) => \$/MWh`.  The anchor bundle carries a
per-reservoir implied value (`anchor.values`) and a per-week decaying weight
(`anchor.weights` × `anchor.weight`); the anchored value applied in week `w` is
`implied × weight × weights[w]`.  Returns columns
`reservoir, week, water_value, anchor_implied, anchor_weight, anchor_applied`.
"""
function _water_value_dataframe(mr::MasterResult, anchor)
    keys_sorted = sort(collect(keys(mr.water_value)))
    reservoir = String[]; week = Int[]; wv = Float64[]
    implied = Float64[]; aweight = Float64[]; applied = Float64[]
    weights = anchor.weights
    for k in keys_sorted
        r, w = k
        push!(reservoir, r); push!(week, w); push!(wv, mr.water_value[k])
        imp = get(anchor.values, r, NaN)
        ww  = (1 <= w <= length(weights)) ? weights[w] : 0.0
        push!(implied, imp); push!(aweight, ww)
        push!(applied, imp * anchor.weight * ww)
    end
    return DataFrame(reservoir = reservoir, week = week, water_value = wv,
                     anchor_implied = implied, anchor_weight = aweight,
                     anchor_applied = applied)
end

"Master end-of-week storage trajectory: `reservoir, week, storage_mm3` (sorted)."
function _storage_dataframe(mr::MasterResult)
    keys_sorted = sort(collect(keys(mr.storage)))
    reservoir = [k[1] for k in keys_sorted]
    week      = [k[2] for k in keys_sorted]
    storage   = [mr.storage[k] for k in keys_sorted]
    return DataFrame(reservoir = reservoir, week = week, storage_mm3 = storage)
end

"""
    write_outputs(run_dir, rr, mi, snapshot_date)

Write the run's deliverables into `run_dir`:

- `forward_curves.parquet` + `forward_curves.csv` — the REQUIRED ASX monthly
  base/peak curves at OTA/BEN;
- `prices_30min.parquet` — every 30-min nodal price (diagnostic);
- `water_values.parquet` — weekly water values vs the offer-implied anchor;
- `storage.parquet` — master end-of-week storage trajectories.

Does NOT (re)write `manifest.json`: `run_model` already wrote it as the single
source.  HVDC flows and the full subproblem storage trajectories are NOT
threaded through `RunResult`, so they are deferred (see the Task 6 report).
"""
function write_outputs(run_dir::AbstractString, rr::RunResult, mi,
                       snapshot_date::Date)
    mkpath(run_dir)

    fc = forward_curves(rr.prices, snapshot_date; n_weeks = rr.n_weeks)
    _write_parquet(fc, joinpath(run_dir, "forward_curves.parquet"))
    _write_csv(fc, joinpath(run_dir, "forward_curves.csv"))

    # Best-effort diagnostics — reachable from RunResult + ModelInputs only.
    _write_parquet(_prices_dataframe(rr.prices),
                   joinpath(run_dir, "prices_30min.parquet"))
    _write_parquet(_water_value_dataframe(rr.master, mi.anchor),
                   joinpath(run_dir, "water_values.parquet"))
    _write_parquet(_storage_dataframe(rr.master),
                   joinpath(run_dir, "storage.parquet"))

    return run_dir
end

# ---------------------------------------------------------------------------
# Distributional outputs (Phase 2b SDDP path)
# ---------------------------------------------------------------------------

"""
    forward_curves_dist(price_dist, snapshot_date; n_weeks, quantiles=(0.1,0.5,0.9))
        -> DataFrame(month, product, hub, distribution, price)

Monthly base/peak ASX curves at OTA/BEN as a DISTRIBUTION.  `price_dist` is the
SDDP `(hub, week, step) => per-scenario Vector` dict.  For each (month, hub,
product) we pool every (step × scenario) nodal price that falls in the bucket
and summarise: `distribution = "mean"` plus one row per quantile
(`"p10","p50","p90"`).  Base pools all steps in the month; peak pools steps whose
timestamp is a weekday in `ASX_PEAK_HOURS`.  Iteration is over sorted keys so the
output is deterministic.
"""
function forward_curves_dist(price_dist::Dict{Tuple{String,Int,Int},Vector{Float64}},
                             snapshot_date::Date; n_weeks::Int,
                             quantiles = (0.1, 0.5, 0.9))
    base_pool = Dict{Tuple{Date,String},Vector{Float64}}()
    peak_pool = Dict{Tuple{Date,String},Vector{Float64}}()
    for key in sort(collect(keys(price_dist)))
        hub, week, step = key
        hub in ASX_HUBS || continue
        week <= n_weeks || continue
        ts = _step_ts(snapshot_date, week, step)
        m  = Date(year(ts), month(ts), 1)
        mk = (m, hub)
        vals = price_dist[key]
        append!(get!(base_pool, mk, Float64[]), vals)
        if _is_peak(ts)
            append!(get!(peak_pool, mk, Float64[]), vals)
        end
    end

    months = Date[]; products = String[]; hubs = String[]
    dists  = String[]; prices = Float64[]
    qlabels = ["p$(Int(round(q*100)))" for q in quantiles]

    function emit!(mk, product, pool)
        m, hub = mk
        push!(months, m); push!(products, product); push!(hubs, hub)
        push!(dists, "mean"); push!(prices, mean(pool))
        for (q, lab) in zip(quantiles, qlabels)
            push!(months, m); push!(products, product); push!(hubs, hub)
            push!(dists, lab); push!(prices, quantile(pool, q))
        end
    end

    for mk in sort(collect(keys(base_pool)))
        emit!(mk, "base", base_pool[mk])
        pk = get(peak_pool, mk, base_pool[mk])   # fall back to base if no peak steps
        emit!(mk, "peak", pk)
    end

    return DataFrame(month = months, product = products, hub = hubs,
                     distribution = dists, price = prices)
end

"""
    period_price_fan(price_dist, snapshot_date; n_weeks, quantiles=(0.1,0.5,0.9))
        -> DataFrame(datetime, hub, distribution, price)

Half-hourly nodal-price DISTRIBUTION at the ASX hubs (OTA, BEN) — the per-period
analogue of `forward_curves_dist` WITHOUT the monthly bucketing.  For each
(hub, week, step) the per-scenario price vector is summarised into
`distribution = "mean"` plus one row per quantile (`"p10","p50","p90"`), and the
(week, step) is mapped to its calendar timestamp via `_step_ts`.  Iteration is
over sorted keys, so rows come out ordered by (hub, datetime) — a deterministic,
plot-ready long table at full 30-minute resolution.
"""
function period_price_fan(price_dist::Dict{Tuple{String,Int,Int},Vector{Float64}},
                          snapshot_date::Date; n_weeks::Int,
                          quantiles = (0.1, 0.5, 0.9))
    qlabels = ["p$(Int(round(q*100)))" for q in quantiles]
    dts = DateTime[]; hubs = String[]; dists = String[]; prices = Float64[]
    for key in sort(collect(keys(price_dist)))
        hub, week, step = key
        hub in ASX_HUBS || continue
        week <= n_weeks || continue
        ts   = _step_ts(snapshot_date, week, step)
        vals = price_dist[key]
        push!(dts, ts); push!(hubs, hub); push!(dists, "mean"); push!(prices, mean(vals))
        for (q, lab) in zip(quantiles, qlabels)
            push!(dts, ts); push!(hubs, hub); push!(dists, lab); push!(prices, quantile(vals, q))
        end
    end
    return DataFrame(datetime = dts, hub = hubs, distribution = dists, price = prices)
end

"""
    period_demand(weeks, snapshot_date; n_weeks, hubs=ASX_HUBS)
        -> DataFrame(datetime, hub, demand_mw)

Half-hourly demand (MW) at the given `hubs` over the horizon — the deterministic
companion to `period_price_fan` (demand is the same across SDDP scenarios; only
inflows vary).  Reads `weeks[w].periods336[step].demand[hub]` and maps each
(week, step) to its timestamp via `_step_ts`.  Long table, ordered by
(week, step, hub) for a plot-ready overlay on the per-period price fan.
"""
function period_demand(weeks::Vector{WeekInputs}, snapshot_date::Date;
                       n_weeks::Int, hubs = ASX_HUBS)
    dts = DateTime[]; hs = String[]; dem = Float64[]
    for w in 1:min(n_weeks, length(weeks))
        p336 = weeks[w].periods336
        for (step, p) in enumerate(p336)
            ts = _step_ts(snapshot_date, w, step)
            for hub in hubs
                push!(dts, ts); push!(hs, hub); push!(dem, get(p.demand, hub, 0.0))
            end
        end
    end
    return DataFrame(datetime = dts, hub = hs, demand_mw = dem)
end

"""
    write_distribution_outputs(run_dir, price_dist, snapshot_date; n_weeks) -> run_dir

Write the SDDP distributional ASX curves to `forward_curves_dist.parquet` +
`forward_curves_dist.csv` in `run_dir`.
"""
function write_distribution_outputs(run_dir::AbstractString,
                                    price_dist::Dict{Tuple{String,Int,Int},Vector{Float64}},
                                    snapshot_date::Date; n_weeks::Int)
    mkpath(run_dir)
    fc = forward_curves_dist(price_dist, snapshot_date; n_weeks = n_weeks)
    _write_parquet(fc, joinpath(run_dir, "forward_curves_dist.parquet"))
    _write_csv(fc, joinpath(run_dir, "forward_curves_dist.csv"))
    return run_dir
end
