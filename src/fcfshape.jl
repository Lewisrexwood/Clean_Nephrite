# fcfshape.jl — per-reservoir water-value curves (the "diagonal").
# A Curve is a piecewise-linear water-value-vs-own-storage relationship.

struct Curve
    reservoir::String
    storage_gwh::Vector{Float64}
    water_value::Vector{Float64}
    function Curve(reservoir, storage_gwh, water_value)
        length(storage_gwh) == length(water_value) ||
            error("Curve: storage_gwh and water_value length mismatch")
        length(storage_gwh) >= 1 || error("Curve: need at least one point")
        issorted(storage_gwh) || error("Curve: storage_gwh must be sorted ascending")
        new(String(reservoir), Float64.(storage_gwh), Float64.(water_value))
    end
end

"Water value at `storage` by linear interpolation, clamped to the curve's range."
function curve_value(c::Curve, storage::Real)
    s = Float64(storage)
    x = c.storage_gwh
    y = c.water_value
    s <= x[1]   && return y[1]
    s >= x[end] && return y[end]
    i = searchsortedlast(x, s)         # x[i] <= s < x[i+1]
    t = (s - x[i]) / (x[i+1] - x[i])
    return y[i] + t * (y[i+1] - y[i])
end

"Build a Curve for `reservoir` by calling `sampler(reservoir, storage)` over a sorted grid."
function sample_curve(sampler, reservoir::AbstractString, grid::AbstractVector{<:Real})
    g = sort(collect(Float64.(grid)))
    wv = Float64[Float64(sampler(reservoir, s)) for s in g]
    return Curve(String(reservoir), g, wv)
end

"Sample a Curve per reservoir from `grids` (reservoir => storage grid)."
function extract_shapes(sampler, grids::Dict{String,Vector{Float64}})
    out = Dict{String,Curve}()
    for (r, grid) in grids
        out[r] = sample_curve(sampler, r, grid)
    end
    return out
end

"""
Water-value sampler over the deterministic master LP.

Returns a closure `(reservoir, storage_gwh) -> water_value`: it converts the
reservoir's storage (GWh) to volume (Mm³) via `coeff`, sets only that
reservoir's initial volume, re-solves, and reads the week-1 storage-balance
DUAL (the exact marginal water value at that storage — not a finite difference).
`solve` is injectable (defaults to `solve_master`) so the wiring is unit-testable.
"""
function master_wv_sampler(weeks, net, base_vol::Dict{String,Float64},
                           terminal_wv, anchor, coeff::Dict{String,Float64};
                           solve = solve_master)
    return function (reservoir::AbstractString, storage_gwh::Real)
        r = String(reservoir)
        c = get(coeff, r, 0.0)
        vol = c > 0 ? Float64(storage_gwh) * 1000 / (c * MWH_PER_MM3_PER_SP) : 0.0
        v = copy(base_vol)
        v[r] = vol
        result = solve(weeks, net, v, terminal_wv, anchor)
        return Float64(result.water_value[(r, 1)])
    end
end
