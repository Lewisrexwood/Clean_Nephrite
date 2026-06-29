using DataFrames, Dates, Statistics, DuckDB, DBInterface

# --- Model + realised extraction -------------------------------------------

"Mean of the model's week-1 30-min nodal prices per hub."
function model_week1_hubs(prices::Dict{Tuple{String,Int,Int},Float64})
    sums = Dict{String,Float64}(); counts = Dict{String,Int}()
    for ((hub, week, _step), p) in prices
        week == 1 || continue
        sums[hub] = get(sums, hub, 0.0) + p
        counts[hub] = get(counts, hub, 0) + 1
    end
    return Dict(h => sums[h] / counts[h] for h in keys(sums))
end

"""
Realised annual spot at `hub` for calendar `year`: mean of the KOP4VM
"Simple daily average spot price" series over that year. (The spot series is
identical across the BASE/PEAK files, so duplicates do not bias the mean.)
"""
function realised_annual_spot(forward_df::DataFrame, year::Integer, hub::AbstractString)
    sub = forward_df[(forward_df.hub .== hub) .&
                     (forward_df.series .== "Simple daily average spot price") .&
                     (Dates.year.(forward_df.settlement_date) .== year), :]
    isempty(sub) && return NaN
    return mean(sub.price)
end

"Calendar years entirely inside the horizon [date, date + 7*n_weeks days]."
function fully_covered_years(date::Date, n_weeks::Integer)
    horizon_end = date + Day(7 * n_weeks)
    years = Int[]
    for y in year(date):year(horizon_end)
        # Strictly inside: the year both starts on/after the run date and ends
        # (Dec 31) on/before the horizon end. A year missing even its final weeks
        # is NOT fully covered, so its annual model average is never compared.
        (Date(y,1,1) >= date && Date(y,12,31) <= horizon_end) && push!(years, y)
    end
    return years
end

"Mean actual spot per hub from a snapshot's final_energy_prices (POC→hub via hubmap)."
function realised_spot_hubs(root::AbstractString, config_dir::AbstractString, date::Date)
    ds = open_datastore(root, date)
    try
        hm = build_hubmap(ds, joinpath(config_dir, "hubmap.toml"))
        df = query(ds, "SELECT PointOfConnection AS poc, AVG(DollarsPerMegawattHour) AS price " *
                       "FROM final_energy_prices WHERE TradingDate = DATE '$(date)' " *
                       "GROUP BY PointOfConnection")
        isempty(df) && (df = query(ds, "SELECT PointOfConnection AS poc, " *
                       "AVG(DollarsPerMegawattHour) AS price FROM final_energy_prices " *
                       "GROUP BY PointOfConnection"))
        sums = Dict{String,Float64}(); counts = Dict{String,Int}()
        for row in eachrow(df)
            poc = String(row.poc)
            haskey(hm.poc_to_hub, poc) || continue
            hub = hm.poc_to_hub[poc]
            sums[hub] = get(sums, hub, 0.0) + Float64(row.price)
            counts[hub] = get(counts, hub, 0) + 1
        end
        return Dict(h => sums[h] / counts[h] for h in keys(sums))
    finally
        close(ds)
    end
end

"Pearson correlation; NaN if undefined (n<2 or zero variance)."
function bt_pearson(x::Vector{Float64}, y::Vector{Float64})
    (length(x) < 2) && return NaN
    (std(x) == 0 || std(y) == 0) && return NaN
    return cor(x, y)
end

# --- Near-term scoring ------------------------------------------------------

"""
    score_near_term(near) -> (rows, summary)

`near` is `DataFrame(date, hub, model, realised)`. Adds a `bias = model − realised`
column; `summary` carries the per-hub mean bias, the per-date cross-hub Pearson
correlation, and the mean of those correlations.
"""
function score_near_term(near::DataFrame)
    rows = copy(near)
    rows.bias = rows.model .- rows.realised
    # Per-hub mean bias.
    mean_bias = Dict{String,Float64}()
    for h in unique(rows.hub)
        mean_bias[h] = mean(rows[rows.hub .== h, :bias])
    end
    # Per-date cross-hub correlation.
    dts = Date[]; corrs = Float64[]
    for d in sort(unique(rows.date))
        sub = rows[rows.date .== d, :]
        push!(dts, d)
        push!(corrs, bt_pearson(Float64.(sub.model), Float64.(sub.realised)))
    end
    corr_by_date = DataFrame(date = dts, corr = corrs)
    summary = Dict("mean_bias_by_hub" => mean_bias,
                   "corr_by_date"     => corr_by_date,
                   "mean_corr"        => mean(filter(!isnan, corrs)))
    return rows, summary
end

# --- Forward three-way scoring (BASE product only) --------------------------

"KOP4VM '<year> Calendar year' BASE quote at `hub`, nearest settlement on/before `date`. NaN if none."
function market_annual_base(forward_df::DataFrame, date::Date, year::Integer, hub::AbstractString)
    tag = "$year Calendar year"
    sub = forward_df[(forward_df.hub .== hub) .&
                     (lowercase.(forward_df.commodity) .== "base") .&
                     (forward_df.series .== tag) .&
                     (forward_df.settlement_date .<= date), :]
    isempty(sub) && return NaN
    return sub[argmax(sub.settlement_date), :price]
end

"""
    score_forward(forward_model, forward_df) -> (rows, summary)

For each BASE-product row of `forward_model` (date, year, hub, model_fwd), join the
nearest market calendar-year quote and realised annual spot. Skips points with no
market quote or no realised (logged count in summary["skipped"]).

Accuracy: model_err/market_err vs realised; summary rmse_model/rmse_market, bias_*.
Edge: hit = sign(market−model) == sign(market−realised); summary hit_rate, pnl.
"""
function score_forward(forward_model::DataFrame, forward_df::DataFrame)
    base = forward_model[forward_model.product .== "base", :]
    cols = (date=Date[], year=Int[], hub=String[], model_fwd=Float64[],
            market_fwd=Float64[], realised=Float64[], model_err=Float64[],
            market_err=Float64[], hit=Bool[])
    skipped = 0
    for r in eachrow(base)
        mkt = market_annual_base(forward_df, r.date, r.year, r.hub)
        rea = realised_annual_spot(forward_df, r.year, r.hub)
        (isnan(mkt) || isnan(rea)) && (skipped += 1; continue)
        signal = mkt - r.model_fwd          # >0: model says market rich
        dev    = mkt - rea                  # >0: market WAS rich (realised below market)
        push!(cols.date, r.date); push!(cols.year, r.year); push!(cols.hub, r.hub)
        push!(cols.model_fwd, r.model_fwd); push!(cols.market_fwd, mkt); push!(cols.realised, rea)
        push!(cols.model_err, r.model_fwd - rea); push!(cols.market_err, mkt - rea)
        push!(cols.hit, sign(signal) == sign(dev))
    end
    rows = DataFrame(cols)
    n = nrow(rows)
    summary = Dict{String,Any}("n_points" => n, "skipped" => skipped)
    if n > 0
        summary["rmse_model"]  = sqrt(mean(rows.model_err .^ 2))
        summary["rmse_market"] = sqrt(mean(rows.market_err .^ 2))
        summary["bias_model"]  = mean(rows.model_err)
        summary["bias_market"] = mean(rows.market_err)
        summary["hit_rate"]    = mean(rows.hit)
        summary["pnl"]         = sum(sign.(rows.market_fwd .- rows.model_fwd) .*
                                     (rows.market_fwd .- rows.realised))
    end
    return rows, summary
end

# ===========================================================================
# Task 4: resumable run_backtest orchestrator
# ===========================================================================

struct BacktestResult
    near_term::DataFrame
    forward_model::DataFrame
    dates::Vector{Date}
end

# Parquet round-trip helpers for the per-date cache (mirrors outputs.jl).
function _bt_write_parquet(df::DataFrame, path::AbstractString)
    con = DBInterface.connect(DuckDB.DB)
    try
        DuckDB.register_data_frame(con, df, "t")
        DBInterface.execute(con, "COPY t TO '$(sql_path(path))' (FORMAT PARQUET)")
    finally
        DuckDB.unregister_data_frame(con, "t")
        DBInterface.close!(con); GC.gc()
    end
end
function _bt_read_parquet(path::AbstractString)
    con = DBInterface.connect(DuckDB.DB)
    try
        return DataFrame(DBInterface.execute(con, "SELECT * FROM read_parquet('$(sql_path(path))')"))
    finally
        DBInterface.close!(con); GC.gc()
    end
end

# Aggregate the model's monthly forward_curves to annual means per fully-covered year.
function _annualise_model(fc::DataFrame, date::Date, n_weeks::Integer)
    years = fully_covered_years(date, n_weeks)
    out = DataFrame(date=Date[], year=Int[], hub=String[], product=String[], model_fwd=Float64[])
    for y in years, hub in unique(fc.hub), product in unique(fc.product)
        sub = fc[(Dates.year.(fc.month) .== y) .& (fc.hub .== hub) .& (fc.product .== product), :]
        isempty(sub) && continue
        push!(out, (date, y, hub, product, mean(sub.price)))
    end
    return out
end

"""
    run_backtest(dates; root, config_dir, history_dir, storage_at, n_weeks=104,
                 min_history_days, cache_dir) -> BacktestResult

For each date: `storage_at(date)` → `run_model` (base run) → model week-1 hub means
+ realised week-1 spot (near-term) and the annualised model forward curve. Caches
each date's two frames under `cache_dir`; a re-run loads the cache and skips solving.
"""
function run_backtest(dates::Vector{Date}; root::AbstractString,
                      config_dir::AbstractString, history_dir::AbstractString,
                      storage_at::Function, n_weeks::Int = 104,
                      min_history_days::Union{Int,Nothing} = nothing,
                      cache_dir::AbstractString)
    mkpath(cache_dir)
    near_parts = DataFrame[]; fwd_parts = DataFrame[]
    for d in dates
        np = joinpath(cache_dir, "$(d)_nearterm.parquet")
        fp = joinpath(cache_dir, "$(d)_forward.parquet")
        if isfile(np) && isfile(fp)
            near_df = _bt_read_parquet(np)
            # Sentinel file (written when forward_model is empty): exactly the 5
            # bytes "EMPTY". Gate on filesize so a real (larger) parquet is never
            # read in full just to test the sentinel.
            fwd_df = (filesize(fp) == 5 && read(fp, String) == "EMPTY") ?
                DataFrame(date=Date[], year=Int[], hub=String[], product=String[], model_fwd=Float64[]) :
                _bt_read_parquet(fp)
            push!(near_parts, near_df); push!(fwd_parts, fwd_df)
            continue
        end
        # A single date's solve/data failure must not abort the whole run:
        # log it loudly and skip (spec: "skipped loudly, never silently dropped").
        local near, fwd
        try
            nz, si = storage_at(d)
            # Pass min_history_days only when given; otherwise run_model uses its
            # own demand.toml default (so the kwarg is optional through the CLI).
            mkw = min_history_days === nothing ? (;) : (; min_history_days = min_history_days)
            rr = run_model(d; root=root, config_dir=config_dir, history_dir=history_dir,
                           nz_gwh=nz, si_gwh=si, n_weeks=n_weeks, mkw...)
            model = model_week1_hubs(rr.prices)
            realised = realised_spot_hubs(root, config_dir, d)
            hubs = sort(collect(intersect(keys(model), keys(realised))))
            near = DataFrame(date=fill(d, length(hubs)), hub=hubs,
                             model=[model[h] for h in hubs], realised=[realised[h] for h in hubs])
            fc = forward_curves(rr.prices, d; n_weeks=n_weeks)
            fwd = _annualise_model(fc, d, n_weeks)
        catch err
            @warn "run_backtest: skipping date $d (solve/data failed)" error=err
            continue
        end
        _bt_write_parquet(near, np)
        # Empty forward_model: skip parquet write (DuckDB drops columns on empty frames);
        # write a sentinel file so the cache hit check still fires on re-run.
        if isempty(fwd)
            open(fp, "w") do io; write(io, "EMPTY"); end
        else
            _bt_write_parquet(fwd, fp)
        end
        push!(near_parts, near); push!(fwd_parts, fwd)
    end
    near_all = isempty(near_parts) ? DataFrame(date=Date[],hub=String[],model=Float64[],realised=Float64[]) :
               vcat(near_parts...)
    fwd_all  = isempty(fwd_parts) ? DataFrame(date=Date[],year=Int[],hub=String[],product=String[],model_fwd=Float64[]) :
               vcat(fwd_parts...)
    return BacktestResult(near_all, fwd_all, dates)
end

"""
    score_backtest(bt, forward_df) -> (near_term, forward, summary)

Runs both scoring layers over a BacktestResult and the loaded KOP4VM forward frame.
`summary` nests `summary["near_term"]` and `summary["forward"]`.
"""
function score_backtest(bt::BacktestResult, forward_df::DataFrame)
    near_term, near_sum = score_near_term(bt.near_term)
    forward, fwd_sum    = score_forward(bt.forward_model, forward_df)
    return near_term, forward, Dict("near_term" => near_sum, "forward" => fwd_sum)
end
