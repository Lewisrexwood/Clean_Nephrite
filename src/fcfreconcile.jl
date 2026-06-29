# fcfreconcile.jl — calibrate raw SDDP shapes to offer / SDDP / forward signals.

"""
Horizon weights (offer α, SDDP β, forward γ), normalised to sum to 1.
Offer trust α decays linearly to zero by `decay_weeks`; γ is seeded from
`forward_weight` and β = 1 − α − γ takes the remainder; all three are then
normalised. With the default `forward_weight = 0` (forward-curve anchoring is
deferred) γ stays 0 and the offer/SDDP split is exact. When `forward_weight > 0`
while the offer is still active, normalisation reduces the effective forward
share below `forward_weight` — the exact forward-blend rule is part of the
deferred forward-anchoring design.
"""
function reconcile_weights(week::Int, decay_weeks::Int, forward_weight::Float64)
    α = max(0.0, 1.0 - (week - 1) / decay_weeks)
    γ = forward_weight
    β = max(0.0, 1.0 - α - γ)
    s = α + β + γ
    return s > 0 ? (α / s, β / s, γ / s) : (0.0, 1.0, 0.0)
end

"""
Calibrated water-value LEVEL for one reservoir at `week`.
With an offer `θ`, blends offer/SDDP/forward by the horizon weights. With no
offer (`θ === nothing`), the offer weight folds onto SDDP, so the level rides
SDDP relativity (and forward when `forward_weight > 0`).
"""
function reconcile_level(week::Int, θ::Union{Real,Nothing}, sddp_level::Float64,
                         forward_level::Float64, decay_weeks::Int, forward_weight::Float64)
    α, β, γ = reconcile_weights(week, decay_weeks, forward_weight)
    if θ === nothing
        return (α + β) * sddp_level + γ * forward_level
    end
    return α * Float64(θ) + β * sddp_level + γ * forward_level
end

"Shift a shape curve uniformly so its value at `today_storage` equals `level`."
function shift_to_level(c::Curve, today_storage::Real, level::Real)
    Δ = Float64(level) - curve_value(c, today_storage)
    return Curve(c.reservoir, copy(c.storage_gwh), c.water_value .+ Δ)
end

"""
Calibrate every shape curve to its reconciled level at `week`.
`today` is the per-reservoir current storage (GWh); reservoirs absent from
`offers` ride SDDP relativity. Returns a new Dict of calibrated curves.
"""
function reconcile(shapes::Dict{String,Curve}, offers::Dict{String,Float64},
                   today::Dict{String,Float64}, forward_level::Float64, week::Int;
                   decay_weeks::Int, forward_weight::Float64)
    out = Dict{String,Curve}()
    for (r, shape) in shapes
        today_s = get(today, r, shape.storage_gwh[1])
        sddp_level = curve_value(shape, today_s)
        θ = haskey(offers, r) ? offers[r] : nothing
        level = reconcile_level(week, θ, sddp_level, forward_level, decay_weeks, forward_weight)
        out[r] = shift_to_level(shape, today_s, level)
    end
    return out
end
