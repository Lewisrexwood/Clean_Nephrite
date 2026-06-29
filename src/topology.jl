using TOML

struct Hub
    code::String
    node::String
    name::String
    island::String
end

struct Corridor
    from::String
    to::String
    capacity_fwd_mw::Float64
    capacity_rev_mw::Float64
    loss_factor::Float64
    kind::String
end

struct Topology
    hubs::Vector{Hub}
    corridors::Vector{Corridor}
end

hub_codes(t::Topology) = [h.code for h in t.hubs]

function load_topology(path::AbstractString)
    raw = TOML.parsefile(path)
    hubs = [Hub(h["code"], h["node"], h["name"], h["island"]) for h in raw["hubs"]]
    corridors = [Corridor(c["from"], c["to"],
                          Float64(c["capacity_fwd_mw"]), Float64(c["capacity_rev_mw"]),
                          Float64(c["loss_factor"]), c["kind"])
                 for c in get(raw, "corridors", [])]
    topo = Topology(hubs, corridors)
    validate(topo)
    return topo
end

function validate(t::Topology)
    codes = hub_codes(t)
    length(unique(codes)) == length(codes) || error("duplicate hub codes")
    code_set = Set(codes)
    for h in t.hubs
        h.island in ("NI", "SI") || error("hub $(h.code): island must be NI or SI")
    end
    pairs = [(c.from, c.to) for c in t.corridors]
    length(unique(pairs)) == length(pairs) || error("duplicate corridor definition")
    for c in t.corridors
        c.from != c.to || error("corridor $(c.from)->$(c.to): self-loop")
        c.from in code_set || error("corridor references unknown hub: $(c.from)")
        c.to in code_set || error("corridor references unknown hub: $(c.to)")
        c.capacity_fwd_mw > 0 || error("corridor $(c.from)->$(c.to): non-positive forward capacity")
        c.capacity_rev_mw > 0 || error("corridor $(c.from)->$(c.to): non-positive reverse capacity")
        0.0 <= c.loss_factor < 0.2 || error("corridor $(c.from)->$(c.to): implausible loss factor")
        c.kind in ("AC", "HVDC") || error("corridor $(c.from)->$(c.to): kind must be AC or HVDC")
    end
    isconnected(t) || error("topology is not connected")
    return t
end

function isconnected(t::Topology)
    isempty(t.hubs) && return false
    adj = Dict(h.code => String[] for h in t.hubs)
    for c in t.corridors
        push!(adj[c.from], c.to)
        push!(adj[c.to], c.from)
    end
    seen = Set([t.hubs[1].code])
    queue = [t.hubs[1].code]
    while !isempty(queue)
        u = popfirst!(queue)
        for v in adj[u]
            if !(v in seen)
                push!(seen, v)
                push!(queue, v)
            end
        end
    end
    return length(seen) == length(t.hubs)
end
