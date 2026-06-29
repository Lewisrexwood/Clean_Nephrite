const MM3_PER_CUMEC_HOUR = 0.0036          # 3600 s / 1e6 m3
const MWH_PER_MM3_PER_SP = 1e6 / 3600      # MWh per Mm3 per (MW/cumec) ≈ 277.7778

"""
Energy generated per cumec of water leaving `node`, taken as the MAXIMUM over
downstream routes (MW/cumec).  A unit of water takes ONE route, so with parallel
arcs present (turbine + bypass spill) we must NOT sum across them — the
physically correct value is the best generating path.  0.0 if no outgoing arcs.
"""
function downstream_energy_coeff(net::HydroNetwork)
    # adjacency: node -> outgoing arcs
    out = Dict{String,Vector{Arc}}()
    for a in net.arcs
        push!(get!(out, a.from, Arc[]), a)
    end
    memo = Dict{String,Float64}()
    function coeff(node)
        haskey(memo, node) && return memo[node]
        memo[node] = 0.0   # guard against cycles during recursion
        best = 0.0
        for a in get(out, node, Arc[])
            sp = a.station == "" ? 0.0 : net.stations[a.station].specific_power
            best = max(best, sp + coeff(a.to))
        end
        memo[node] = best
        return best
    end
    return Dict(r.name => coeff(r.name) for r in net.reservoirs)
end

"Aggregate stored energy (GWh) from per-reservoir volumes (Mm3)."
function reservoir_energy_gwh(net::HydroNetwork, volumes::Dict{String,Float64})
    coeff = downstream_energy_coeff(net)
    mwh = sum(get(volumes, r.name, 0.0) * get(coeff, r.name, 0.0) * MWH_PER_MM3_PER_SP
              for r in net.reservoirs)
    return mwh / 1000
end

"""
Distribute the operator NZ/SI aggregate storage energy onto JADE reservoirs and
return per-reservoir initial VOLUME (Mm3). Energy is split within each island by
each reservoir's energy capacity (max_volume × coeff), then converted back to
volume via the reservoir's coeff. Run-of-river reservoirs (max_volume==Inf) get 0.
"""
function initial_volumes(net::HydroNetwork, config_path::AbstractString;
                         nz_gwh::Real, si_gwh::Real, month::Integer)
    (nz_gwh >= 0 && si_gwh >= 0) ||
        error("initial_volumes: storage must be non-negative (nz=$nz_gwh, si=$si_gwh GWh)")
    si_gwh <= nz_gwh || error("initial_volumes: SI storage ($si_gwh GWh) exceeds NZ total ($nz_gwh GWh)")
    coeff = downstream_energy_coeff(net)
    ni_gwh = nz_gwh - si_gwh
    island_target = Dict("SI" => Float64(si_gwh), "NI" => Float64(ni_gwh))
    # energy capacity per reservoir (GWh); skip storage-less (Inf max) reservoirs
    ecap = Dict{String,Float64}()
    for r in net.reservoirs
        ecap[r.name] = isfinite(r.max_volume) ?
            r.max_volume * get(coeff, r.name, 0.0) * MWH_PER_MM3_PER_SP / 1000 : 0.0
    end
    vols = Dict{String,Float64}()
    for island in ("NI", "SI")
        members = [r for r in net.reservoirs if r.island == island && ecap[r.name] > 0]
        tot = sum(ecap[r.name] for r in members; init=0.0)
        # Operator-supplied storage can exceed the modelled energy capacity (e.g.
        # the NI aggregate vs Taupo-dominated NI capacity).  Clamp to full so no
        # reservoir is initialised above its max_volume, and warn — the excess
        # energy is not representable on this topology.
        target = island_target[island]
        if target > tot + 1e-6
            @warn "initial_volumes: $island storage target ($(round(target, digits=1)) GWh) " *
                  "exceeds modelled capacity ($(round(tot, digits=1)) GWh); clamping to full"
            target = tot
        end
        for r in members
            share = tot > 0 ? ecap[r.name] / tot : 0.0
            energy_gwh = target * share
            c = coeff[r.name]
            vols[r.name] = c > 0 ? energy_gwh * 1000 / (c * MWH_PER_MM3_PER_SP) : 0.0
        end
    end
    for r in net.reservoirs
        haskey(vols, r.name) || (vols[r.name] = 0.0)
    end
    return vols
end
