using TOML

# fcfextract.jl — config + the re-slice driver orchestrating shape -> reconcile.

struct FcfExtractConfig
    reslice_weeks::Vector{Int}
    grid_points::Int
    decay_weeks::Int
    forward_weight::Float64
end

"Load the [fcf_extract] block from a TOML config file."
function load_fcf_config(path::AbstractString)
    cfg = TOML.parsefile(path)["fcf_extract"]
    return FcfExtractConfig(Int.(cfg["reslice_weeks"]), Int(cfg["grid_points"]),
                            Int(cfg["decay_weeks"]), Float64(cfg["forward_weight"]))
end

"""
Drive extraction across the re-slice schedule. At each `cfg.reslice_weeks` entry,
build a sampler at the realised joint storage, sample shapes over `grids`, and
reconcile to offers/SDDP/forward. Returns one `(week, curves)` per scheduled week.
"""
function extract_fcf(make_sampler, trajectory::Dict{Int,Dict{String,Float64}},
                     grids::Dict{String,Vector{Float64}}, offers::Dict{String,Float64},
                     forward_level::Float64, cfg::FcfExtractConfig)
    results = NamedTuple[]
    for w in cfg.reslice_weeks
        joint = trajectory[w]
        sampler = make_sampler(w, joint)
        shapes = extract_shapes(sampler, grids)
        curves = reconcile(shapes, offers, joint, forward_level, w;
                           decay_weeks = cfg.decay_weeks, forward_weight = cfg.forward_weight)
        push!(results, (week = w, curves = curves))
    end
    return results
end
