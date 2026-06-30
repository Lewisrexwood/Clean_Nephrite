using JSON3
import SDDP

# warmstart.jl — Option A warm start: convert prior per-reservoir water values into
# SDDP value-function cuts and inject them into a policy graph before training.
# Companion to the objective anchor (Option C, in sddp.jl/master.jl); both share the
# offer-implied WV source and the decay_weeks taper. See
# docs/superpowers/specs/2026-06-30-sddp-warm-start-water-values-design.md.

"""
    wv_warmstart_cuts(net, anchor_vol, wv_values, decay_weights, lb) -> Vector{Dict{String,Any}}

Build one SDDP single-cut per reservoir per weekly node from prior water values,
in `SDDP.write_cuts_to_file` schema (ready for `apply_wv_warmstart!`).

For node `t` and reservoir `r` with downstream energy coeff `c_r > 0` and `wv_r != 0`:

    slope  π_{r,t} = decay_weights[t] · (−wv_r · c_r · MWH_PER_MM3_PER_SP)      [\$/Mm³]
    cut_t:  V(s) ≥ lb + Σ_r π_{r,t} · (s_r − anchor_vol_r)

i.e. point-slope anchored at `anchor_vol` (Mm³) with height `lb`. Reservoirs with
`c_r == 0` or zero/missing `wv` are skipped; a node whose cut would be empty is
omitted. Node names are `string(t)` for `t in 1:length(decay_weights)`; state keys
are `s[<reservoir>]` (matching `_fcf_state_key`).
"""
function wv_warmstart_cuts(net::HydroNetwork, anchor_vol::Dict{String,Float64},
                           wv_values::Dict{String,Float64},
                           decay_weights::Vector{Float64}, lb::Float64)
    coeff = downstream_energy_coeff(net)
    cuts = Dict{String,Any}[]
    for t in 1:length(decay_weights)
        coeffs = Dict{String,Float64}()
        state  = Dict{String,Float64}()
        for r in net.reservoirs
            c  = get(coeff, r.name, 0.0)
            wv = get(wv_values, r.name, 0.0)
            (c > 0 && wv != 0.0) || continue
            key = "s[$(r.name)]"
            coeffs[key] = decay_weights[t] * (-wv * c * MWH_PER_MM3_PER_SP)
            state[key]  = get(anchor_vol, r.name, 0.0)
        end
        isempty(coeffs) && continue
        push!(cuts, Dict{String,Any}(
            "node" => string(t),
            "single_cuts" => Any[Dict{String,Any}(
                "intercept"    => lb,
                "coefficients" => coeffs,
                "state"        => state)],
            "multi_cuts" => Dict{String,Any}[],
            "risk_set_cuts" => Vector{Float64}[]))
    end
    return cuts
end

"""
    apply_wv_warmstart!(graph, cuts) -> graph

Inject `cuts` (from `wv_warmstart_cuts`) into `graph` by writing them to a temp file
in SDDP.jl's cut schema and loading via the public `SDDP.read_cuts_from_file`. Each
cut becomes `V(s) ≥ intercept + Σ coefficients·(s − state)` on its node's cost-to-go.
No-op when `cuts` is empty. Returns `graph`.
"""
function apply_wv_warmstart!(graph::SDDP.PolicyGraph, cuts::Vector{Dict{String,Any}})
    isempty(cuts) && return graph
    mktempdir() do dir
        path = joinpath(dir, "warmstart_cuts.json")
        open(io -> JSON3.write(io, cuts), path, "w")
        SDDP.read_cuts_from_file(graph, path)
    end
    return graph
end
