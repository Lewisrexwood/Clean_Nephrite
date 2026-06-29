# Run the deterministic model for one snapshot:
#   julia --project=. scripts/run.jl 2026-06-11 --nz-gwh 4200 --si-gwh 2600 [--hvdc-derate 0.8 ...]
#
# Required flags: --nz-gwh, --si-gwh (Float64, the operator-supplied NZ/SI
# aggregate storage in GWh).  Optional what-if knobs map to `run_model`
# overrides: --hvdc-derate, --fuel-scale, --inflow-scale, --demand-growth
# (Float64) and --tiwai-off (Bool flag, no value).
#
# `main`/`_parse_opts` are defined as plain functions so they are unit-testable
# (a test can `include` this file and call `_parse_opts` directly); the
# `main(ARGS)` invocation is guarded so the include is side-effect-free.
using Nephrite, Dates

# Optional flags taking a Float64 value → override key.
const _FLOAT_OVERRIDES = Dict(
    "--hvdc-derate"   => :hvdc_derate,
    "--fuel-scale"    => :fuel_scale,
    "--inflow-scale"  => :inflow_scale,
    "--demand-growth" => :demand_growth,
)

"""
    _parse_opts(args) -> (; nz_gwh, si_gwh, overrides)

Parse the option tail (everything after the date).  `--nz-gwh`/`--si-gwh` are
required Float64s; the float what-if flags map into `overrides::Dict{Symbol,Any}`
using the SAME keys `assemble_inputs`/`run_model` accept; `--tiwai-off` is a
valueless flag setting `overrides[:tiwai_off] = true`.  Errors loudly on an
unknown flag, a missing value, or a missing required flag.
"""
function _parse_opts(args)
    nz_gwh = nothing
    si_gwh = nothing
    overrides = Dict{Symbol,Any}()
    i = 1
    while i <= length(args)
        flag = args[i]
        if flag == "--tiwai-off"
            overrides[:tiwai_off] = true
            i += 1
        elseif flag == "--nz-gwh"
            i < length(args) || error("$flag requires a value")
            nz_gwh = parse(Float64, args[i + 1]); i += 2
        elseif flag == "--si-gwh"
            i < length(args) || error("$flag requires a value")
            si_gwh = parse(Float64, args[i + 1]); i += 2
        elseif haskey(_FLOAT_OVERRIDES, flag)
            i < length(args) || error("$flag requires a value")
            overrides[_FLOAT_OVERRIDES[flag]] = parse(Float64, args[i + 1]); i += 2
        else
            error("unknown flag: $flag")
        end
    end
    nz_gwh === nothing && error("--nz-gwh is required")
    si_gwh === nothing && error("--si-gwh is required")
    return (; nz_gwh = nz_gwh, si_gwh = si_gwh, overrides = overrides)
end

function main(args)
    if length(args) < 1
        println("usage: julia --project=. scripts/run.jl YYYY-MM-DD --nz-gwh X --si-gwh Y " *
                "[--hvdc-derate D --fuel-scale F --inflow-scale I --demand-growth G --tiwai-off]")
        exit(1)
    end
    date = Date(args[1])
    opts = _parse_opts(args[2:end])
    root = normpath(joinpath(@__DIR__, "..", "data"))
    rr = Nephrite.run_model(date; root = root,
        config_dir = normpath(joinpath(@__DIR__, "..", "config")),
        history_dir = joinpath(root, "history", "demand"),
        nz_gwh = opts.nz_gwh, si_gwh = opts.si_gwh, overrides = opts.overrides)
    println("Run complete -> $(rr.run_dir)")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end
