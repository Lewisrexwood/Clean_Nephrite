using DataFrames

"""
Offer-implied marginal water values: for each modelled-hydro POC and trading
period, the volume-weighted median price of its latest energy offers with
price > 1 \$/MWh (near-zero tranches are must-run flow, not marginal water).
A calibration diagnostic — compared against the model's own water values
(master storage duals) in Plan 3, and a candidate SDDP warm-start later.
"""
function implied_water_values(ds::DataStore, plant::Plant)
    isempty(plant.modelled_hydro_pocs) &&
        return DataFrame(poc = String[], tp = Int[], implied_wv = Float64[])
    placeholders = sql_in_list(plant.modelled_hydro_pocs)
    offers = query(ds,
        "SELECT PointOfConnection AS poc, TradingPeriod AS tp, " *
        "       DollarsPerMegawattHour AS price, Megawatts AS mw " *
        "FROM offers " *
        "WHERE ProductType = 'Energy' AND IsLatestYesNo = 'Y' " *
        "  AND Megawatts > 0 AND DollarsPerMegawattHour > 1.0 " *
        "  AND PointOfConnection IN ($placeholders)")
    isempty(offers) && return DataFrame(poc = String[], tp = Int[], implied_wv = Float64[])
    out = combine(groupby(offers, [:poc, :tp])) do g
        (implied_wv = weighted_median(g.price, g.mw),)
    end
    sort!(out, [:poc, :tp])
    return out[:, [:poc, :tp, :implied_wv]]
end

"Volume-weighted median: smallest x whose cumulative weight reaches half the total."
function weighted_median(x::AbstractVector, w::AbstractVector)
    order = sortperm(x)
    cum = 0.0
    half = sum(w) / 2
    for i in order
        cum += w[i]
        cum >= half && return Float64(x[i])
    end
    return Float64(x[order[end]])
end
