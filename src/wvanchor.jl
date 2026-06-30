using DataFrames, Statistics, TOML

"""
Aggregate per-POC offer-implied WV to per-reservoir: mean over periods per POC,
drop POCs not in the map, mean over POCs per reservoir.
"""
function _aggregate_reservoir_wv(iwv::DataFrame, poc_to_reservoir::Dict)
    isempty(iwv) && return DataFrame(reservoir = String[], implied_wv = Float64[])
    perpoc = combine(groupby(iwv, :poc), :implied_wv => mean => :implied_wv)
    keep = [haskey(poc_to_reservoir, p) for p in perpoc.poc]
    perpoc = perpoc[keep, :]
    isempty(perpoc) && return DataFrame(reservoir = String[], implied_wv = Float64[])
    # rebuild as a fresh frame (avoid mutating a filtered copy)
    mapped = DataFrame(reservoir = [poc_to_reservoir[p] for p in perpoc.poc],
                       implied_wv = perpoc.implied_wv)
    out = combine(groupby(mapped, :reservoir), :implied_wv => mean => :implied_wv)
    sort!(out, :reservoir)
    return out[:, [:reservoir, :implied_wv]]
end

"Per-reservoir offer-implied water value: per-POC values averaged over periods, mapped POC->reservoir, averaged per reservoir."
function reservoir_implied_wv(ds::DataStore, plant::Plant, sm::StationMap)
    iwv = implied_water_values(ds, plant)          # (poc, tp, implied_wv)
    return _aggregate_reservoir_wv(iwv, sm.poc_to_reservoir)
end

"""
Linear decay weights of length `n_weeks`.
Weight is 1.0 at week 1, decays linearly to 1/decay_weeks at week=decay_weeks,
and is exactly 0.0 for all weeks strictly past decay_weeks.
"""
function anchor_weights(decay_weeks::Integer, n_weeks::Integer)
    [w <= decay_weeks ? max(0.0, 1.0 - (w - 1) / decay_weeks) : 0.0 for w in 1:n_weeks]
end

"Bundle the per-reservoir anchor values, per-week decay weights, and global weight (0 disables)."
function wvanchor(ds::DataStore, plant::Plant, sm::StationMap, config_path::AbstractString;
                  n_weeks::Integer)
    cfg = TOML.parsefile(config_path)["wvanchor"]
    weight = Float64(cfg["weight"])
    decay = Int(cfg["decay_weeks"])
    rv = reservoir_implied_wv(ds, plant, sm)
    values = Dict{String,Float64}(r.reservoir => r.implied_wv for r in eachrow(rv))
    return (values = values, weights = anchor_weights(decay, n_weeks), weight = weight)
end
