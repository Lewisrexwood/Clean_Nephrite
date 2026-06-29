struct HydroNetwork
    reservoirs::Vector{JadeReservoir}
    arcs::Vector{Arc}
    stations::Dict{String,HydroStation}
    station_hub::Dict{String,String}
    downstream::Dict{String,Vector{String}}
end

"Marginal MW/cumec per segment must be non-increasing (concave turbine curve)."
function _assert_concave(s::HydroStation)
    segs = s.turbine_segments
    length(segs) >= 2 || error("hydronet: station $(s.name) needs >= 2 turbine points")
    mc = Float64[]
    for i in 1:length(segs)-1
        dq = segs[i+1][1] - segs[i][1]
        dq > 0 || error("hydronet: station $(s.name) non-increasing flow breakpoints")
        push!(mc, (segs[i+1][2] - segs[i][2]) / dq)
    end
    all(mc[i] >= mc[i+1] - 1e-9 for i in 1:length(mc)-1) ||
        error("hydronet: station $(s.name) turbine curve is not concave")
end

"Evaluate the concave piecewise-linear turbine curve at `flow` (capped at capacity)."
function generation_mw(s::HydroStation, flow_cumecs::Real)
    segs = s.turbine_segments
    flow_cumecs <= segs[1][1] && return segs[1][2]
    for i in 1:length(segs)-1
        if flow_cumecs <= segs[i+1][1]
            t = (flow_cumecs - segs[i][1]) / (segs[i+1][1] - segs[i][1])
            return min(segs[i][2] + t * (segs[i+1][2] - segs[i][2]), s.capacity_mw)
        end
    end
    return min(segs[end][2], s.capacity_mw)
end

function build_hydronet(jd::JadeData, sm::StationMap)
    stations = Dict(s.name => s for s in jd.hydro_stations)
    for s in jd.hydro_stations
        _assert_concave(s)
    end
    nodes = Set(r.name for r in jd.reservoirs)
    downstream = Dict{String,Vector{String}}(r.name => String[] for r in jd.reservoirs)
    for a in jd.arcs
        a.station == "" || haskey(stations, a.station) ||
            error("hydronet: arc $(a.from)->$(a.to) references unknown station $(a.station)")
        if a.from in nodes
            push!(get!(downstream, a.from, String[]), a.to)
        end
    end
    station_hub = Dict(s.name => hub_for_station(sm, s.name) for s in jd.hydro_stations)
    return HydroNetwork(jd.reservoirs, jd.arcs, stations, station_hub, downstream)
end

station_hub_of(net::HydroNetwork, station::AbstractString) = net.station_hub[station]
