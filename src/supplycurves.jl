using TOML, DataFrames

struct Battery
    name::String
    poc::String
    power_mw::Float64
    energy_mwh::Float64
    round_trip_efficiency::Float64
end

struct Plant
    modelled_hydro_pocs::Vector{String}
    batteries::Vector{Battery}
end

"""
Load plant classification (modelled hydro POCs + batteries) from config.
Batteries with zero power/energy are placeholders: kept here so their POC is
excluded from offer supply curves, but Plan 3 dispatch must skip zero-capacity
batteries. Negative capacities are rejected.
"""
function load_plant(path::AbstractString)
    cfg = TOML.parsefile(path)
    hydro = String[String(p) for p in get(get(cfg, "modelled_hydro", Dict()), "pocs", [])]
    bats = [Battery(b["name"], b["poc"], Float64(b["power_mw"]),
                    Float64(b["energy_mwh"]), Float64(b["round_trip_efficiency"]))
            for b in get(cfg, "batteries", [])]
    for b in bats
        b.power_mw >= 0.0 || error("plant: battery $(b.name) has negative power_mw")
        b.energy_mwh >= 0.0 || error("plant: battery $(b.name) has negative energy_mwh")
        0.0 < b.round_trip_efficiency <= 1.0 ||
            error("plant: battery $(b.name) has implausible round-trip efficiency")
    end
    return Plant(hydro, bats)
end

"""
Hub-level supply curves from the snapshot's offers: latest energy offers,
excluding modelled plant (hydro + batteries — they are dispatched by the
model, not offer-taken). Returns a DataFrame (hub, tp, price, mw) sorted by
price within each (hub, tp) — i.e. the merit-order curve in long form.
"""
function hub_supply_curves(ds::DataStore, hm::HubMap, plant::Plant)
    offers = query(ds,
        "SELECT TradingPeriod AS tp, PointOfConnection AS poc, " *
        "       DollarsPerMegawattHour AS price, Megawatts AS mw " *
        "FROM offers " *
        "WHERE ProductType = 'Energy' AND IsLatestYesNo = 'Y' AND Megawatts > 0 " *
        "AND DollarsPerMegawattHour IS NOT NULL")
    excluded = Set(vcat(plant.modelled_hydro_pocs, [b.poc for b in plant.batteries]))
    offers = offers[[!(p in excluded) for p in offers.poc], :]
    offers.hub = [hub_for(hm, p) for p in offers.poc]
    curves = combine(groupby(offers, [:hub, :tp, :price]), :mw => sum => :mw)
    sort!(curves, [:hub, :tp, :price])
    return curves[:, [:hub, :tp, :price, :mw]]
end
