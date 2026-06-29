using Dates

fixture_path(name::AbstractString) = joinpath(@__DIR__, "fixtures", name)

"""
A fetch stand-in matching the Downloads.download(url, dest) signature.
Maps dataset URLs to fixtures by substring, so no test touches the network.
"""
function fake_fetch(url::AbstractString, dest::AbstractString)
    fixture = if occursin("ByMonth", url) && occursin("FinalEnergyPrices", url)
        fixture_path("final_energy_prices_bymonth_sample.csv")
    elseif occursin("_Offers.csv", url)
        fixture_path("offers_sample.csv")
    elseif occursin("FinalEnergyPrices", url)
        fixture_path("final_energy_prices_sample.csv")
    elseif occursin("FinalReservePrices", url)
        fixture_path("final_reserve_prices_sample.csv")
    elseif occursin("NodalPricesAndVolumes", url)
        fixture_path("grid_demand_sample.csv")
    elseif occursin("NetworkSupplyPointsTable", url)
        fixture_path("network_supply_points_sample.csv")
    else
        error("fake_fetch: no fixture for $url")
    end
    cp(fixture, dest; force = true)
    return dest
end

"Registry file (production datasets.toml) copied into a temp dir."
function write_test_registry(dir::AbstractString)
    path = joinpath(dir, "datasets.toml")
    cp(joinpath(@__DIR__, "..", "config", "datasets.toml"), path)
    return path
end

"Build a complete snapshot from fixtures; returns the snapshot dir."
function build_test_snapshot!(root::AbstractString, date::Date)
    registry_path = write_test_registry(mktempdir())
    Nephrite.ingest!(date; root = root, registry_path = registry_path,
                     fetch = fake_fetch)
    return Nephrite.snapshot_dir(root, date)
end
