using TOML

struct StationMap
    station_to_hub::Dict{String,String}
    poc_to_reservoir::Dict{String,String}
end

function build_stationmap(jd::JadeData, config_path::AbstractString)
    cfg = TOML.parsefile(config_path)
    s2h = Dict{String,String}(get(cfg, "station_to_hub", Dict()))
    p2r = Dict{String,String}(get(cfg, "poc_to_reservoir", Dict()))

    # Validate hub targets
    for (k, v) in s2h
        v in HUB_CODES || error("stationmap: station $k maps to unknown hub $v")
    end

    # Validate reservoir targets
    resnames = Set(r.name for r in jd.reservoirs)
    for (k, v) in p2r
        v in resnames || error("stationmap: POC $k maps to unknown reservoir $v")
    end

    # Every JADE station (thermal, hydro, and fixed/must-run) must appear in station_to_hub.
    # fixed_stations are checked here because mustrun_generation calls hub_for_station on
    # every jd.fixed_stations entry — a missing mapping would fail deep inside that function
    # rather than loudly here at construction time.
    stations = vcat([u.name for u in jd.thermal_units],
                    [s.name for s in jd.hydro_stations],
                    [f.name for f in jd.fixed_stations])
    unmapped = [s for s in stations if !haskey(s2h, s)]
    isempty(unmapped) ||
        error("stationmap: unmapped JADE stations — add to $config_path:\n" *
              join(first(unmapped, 30), "\n"))

    return StationMap(s2h, p2r)
end

hub_for_station(sm::StationMap, name::AbstractString) =
    get(sm.station_to_hub, name) do
        error("stationmap: station $name not mapped to a hub")
    end

reservoir_for_poc(sm::StationMap, poc::AbstractString) =
    get(sm.poc_to_reservoir, poc) do
        error("stationmap: POC $poc not mapped to a reservoir")
    end
