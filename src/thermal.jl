using DataFrames

"SRMC (\$/MWh) = heat_rate (GJ/MWh) x fuel price (\$/GJ) + carbon cost."
function srmc(unit::ThermalUnit, fuel_costs::Vector{FuelCost}, carbon_price::Real)
    fc = only(f for f in fuel_costs if f.fuel == unit.fuel)
    return unit.heat_rate * fc.price_per_gj +
           unit.heat_rate * fc.carbon_t_per_gj * carbon_price
end

"""
Hub-level thermal merit-order supply curves from JADE SRMC. One row per
(hub, unit) priced at SRMC, MW = capacity x available-fraction (derate),
sorted by price within hub. Period-independent in Phase 1 (SRMC doesn't vary
by trading period).
"""
function thermal_supply_curves(jd::JadeData, sm::StationMap; derate::Dict{String,Float64}=Dict{String,Float64}())
    rows = NamedTuple{(:hub,:price,:mw),Tuple{String,Float64,Float64}}[]
    for u in jd.thermal_units
        avail = get(derate, u.name, 1.0)
        mw = u.capacity_mw * avail
        mw > 0 || continue
        push!(rows, (hub = hub_for_station(sm, u.name),
                     price = srmc(u, jd.fuel_costs, jd.carbon_price_nzd_per_tonne),
                     mw = mw))
    end
    df = DataFrame(rows)
    sort!(df, [:hub, :price])
    return df
end

"""
    mustrun_generation(jd, sm, woy) -> DataFrame(hub, mw)

Sum fixed-station (geo/cogen/wind/run-of-river) must-run per hub for week-of-year
`woy`. Each station's per-week representative level `mustrun_mw(fs, woy)`
(= mean(PEAK, SHOULDER, OFFPEAK) for that week, averaged across years) is
attributed to the hub resolved via `hub_for_station`. Returns a DataFrame sorted
by hub with one row per hub that has must-run > 0. Pricing (~\$0) is the dispatch
builder's concern. Using the per-week scheduled level (not a max over all weeks)
is what keeps must-run at the true seasonal level rather than over-injecting.
"""
function mustrun_generation(jd::JadeData, sm::StationMap, woy::Integer)
    hub_mw = Dict{String,Float64}()
    for fs in jd.fixed_stations
        h = hub_for_station(sm, fs.name)
        hub_mw[h] = get(hub_mw, h, 0.0) + mustrun_mw(fs, woy)
    end
    rows = [(hub = h, mw = mw) for (h, mw) in hub_mw]
    df = DataFrame(rows)
    sort!(df, :hub)
    return df
end
