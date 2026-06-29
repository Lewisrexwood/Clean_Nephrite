using JuMP, HiGHS
import SDDP

# fcfsddp.jl — SDDP value-function sampler + run-level FCF extraction orchestrator.
# The water-value curve SHAPE is read from the trained policy's value function:
# WV_r = -∂V/∂s_r / (coeff_r · MWH_PER_MM3_PER_SP), matching master.jl's dual convention.

"SDDP state-variable symbol for reservoir `rname` (state is `@variable(sp, s[r], SDDP.State)`)."
_fcf_state_key(rname::AbstractString) = Symbol("s[$rname]")

"""
Water-value sampler over a trained SDDP value function `V` (one stage's
`SDDP.ValueFunction`).  Returns a closure `(reservoir, storage_gwh) -> WV (\$/MWh)`:
it fixes the full joint state at `reference_vol` (Mm³) with `reservoir` overridden
by `storage_gwh` (converted to Mm³), evaluates `V`, and reads the subgradient.
`evaluate` is injectable for testing (defaults to `SDDP.evaluate`).
"""
function sddp_wv_sampler(V, coeff::Dict{String,Float64}, reference_vol::Dict{String,Float64};
                         evaluate = SDDP.evaluate)
    return function (reservoir::AbstractString, storage_gwh::Real)
        r = String(reservoir)
        c = get(coeff, r, 0.0)
        c > 0 || return 0.0
        vol = Float64(storage_gwh) * 1000 / (c * MWH_PER_MM3_PER_SP)
        point = Dict{Symbol,Float64}()
        for (rr, v) in reference_vol
            point[_fcf_state_key(rr)] = v
        end
        point[_fcf_state_key(r)] = vol
        _, duals = evaluate(V, point)
        return -duals[_fcf_state_key(r)] / (c * MWH_PER_MM3_PER_SP)
    end
end

"Convert a reservoir VOLUME (Mm³) to its own stored ENERGY (GWh) via `coeff`."
_vol_to_gwh(vol::Real, c::Real) = Float64(vol) * c * MWH_PER_MM3_PER_SP / 1000

"""
Re-slice reference storage (GWh per reservoir, start-of-week) for each week in
`reslice_weeks`.  Week 1 starts at `initial_vol`; week w>1 starts at the mean
(across scenarios) end-of-(w−1) storage from `trajectories`.  Volumes are Mm³ in,
GWh out.
"""
function mean_storage_trajectory(trajectories::Vector{Dict{Tuple{String,Int},Float64}},
                                 reslice_weeks::Vector{Int}, initial_vol::Dict{String,Float64},
                                 coeff::Dict{String,Float64})
    rnames = collect(keys(initial_vol))
    n = length(trajectories)
    out = Dict{Int,Dict{String,Float64}}()
    for w in reslice_weeks
        joint = Dict{String,Float64}()
        for r in rnames
            c = get(coeff, r, 0.0)
            vol = if w == 1
                get(initial_vol, r, 0.0)
            else
                sum(traj[(r, w - 1)] for traj in trajectories) / n
            end
            joint[r] = _vol_to_gwh(vol, c)
        end
        out[w] = joint
    end
    return out
end

"Per-reservoir GWh grid of `grid_points` points spanning each `(min_gwh, max_gwh)`."
function build_grids(capacities::Dict{String,Tuple{Float64,Float64}}, grid_points::Int)
    out = Dict{String,Vector{Float64}}()
    for (r, (lo, hi)) in capacities
        out[r] = collect(range(lo, hi; length = grid_points))
    end
    return out
end

"""
Per-reservoir energy capacity `(min_gwh, max_gwh)` for reservoirs with a finite
`max_volume` and positive downstream coefficient.  Run-of-river / infinite-storage
reservoirs are excluded (no finite grid).
"""
function reservoir_energy_capacities(net::HydroNetwork)
    coeff = downstream_energy_coeff(net)
    out = Dict{String,Tuple{Float64,Float64}}()
    for r in net.reservoirs
        c = get(coeff, r.name, 0.0)
        (isfinite(r.max_volume) && c > 0) || continue
        lo = _vol_to_gwh(max(0.0, r.min_volume), c)
        hi = _vol_to_gwh(r.max_volume, c)
        out[r.name] = (lo, hi)
    end
    return out
end

"Write per-week curve blocks (`results` of `(week, curves)`) to one CSV via `_write_csv`."
function write_run_fcf(results::Vector, path::AbstractString)
    df = reduce(vcat, [fcf_dataframe(r.curves; week = r.week) for r in results])
    _write_csv(df, path)
    return path
end

"""
Run-level FCF extraction from a trained SDDP policy.  Clamps `cfg.reslice_weeks`
to the horizon, builds per-reservoir grids and the mean-storage re-slice
reference, and for each week constructs a value-function sampler at that week's
node.  Returns one `(week, curves)` per re-slice week (`forward_level = 0.0`).
"""
function extract_run_fcf(graph, net::HydroNetwork, initial_vol::Dict{String,Float64},
                         trajectories::Vector{Dict{Tuple{String,Int},Float64}},
                         offers::Dict{String,Float64}, cfg::FcfExtractConfig)
    coeff = downstream_energy_coeff(net)
    nW = maximum(t for (_, t) in keys(first(trajectories)))
    weeks = [w for w in cfg.reslice_weeks if 1 <= w <= nW]
    grids = build_grids(reservoir_energy_capacities(net), cfg.grid_points)
    traj  = mean_storage_trajectory(trajectories, weeks, initial_vol, coeff)

    # Complete Mm³ reference per week for the value-function evaluation point.
    # EVERY reservoir state must be fixed — including coeff==0 reservoirs, which
    # SDDP.evaluate would otherwise leave as free variables and perturb the duals.
    # Built directly from the trajectory (Mm³), so no coeff division is needed.
    rnames = collect(keys(initial_vol))
    n = length(trajectories)
    refvol = Dict{Int,Dict{String,Float64}}()
    for w in weeks
        refvol[w] = Dict(r => (w == 1 ? get(initial_vol, r, 0.0)
                               : sum(t[(r, w - 1)] for t in trajectories) / n)
                         for r in rnames)
    end

    make_sampler = function (w::Int, joint::Dict{String,Float64})
        V = SDDP.ValueFunction(graph[w])
        JuMP.set_optimizer(V, HiGHS.Optimizer)
        return sddp_wv_sampler(V, coeff, refvol[w])
    end

    cfg_w = FcfExtractConfig(weeks, cfg.grid_points, cfg.decay_weeks, cfg.forward_weight)
    return extract_fcf(make_sampler, traj, grids, offers, 0.0, cfg_w)
end
