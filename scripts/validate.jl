# Attended success-criteria validation for the deterministic model.
#
#   julia --project=. scripts/validate.jl 2026-06-11 --nz-gwh <X> --si-gwh <Y>
#
# NOT a CI test.  Runs a REAL 104-week solve (minutes-to-tens-of-minutes) on a
# real snapshot and checks the spec's success criteria.  Storage figures
# (--nz-gwh / --si-gwh, the operator-supplied NZ/SI aggregate storage in GWh)
# are REQUIRED — the operator supplies the day's actual storage state.
#
# Hard gates (exit(1) on any failure so an attended operator sees it):
#   1. Halving storage RAISES mean OTA+BEN price.
#   2. Derating the HVDC (hvdc_derate=0.5) WIDENS the mean monthly |OTA-BEN| basis.
#   3. peak >= base on every OTA/BEN monthly point of the base run.
# Reported (not gated):
#   - Day-one (week-1) spot cross-check vs the snapshot's final_energy_prices.
#
# The three directional checks are PURE FUNCTIONS of forward_curves DataFrames
# (mean_price / mean_basis / peak_ge_base) so they can be unit-tested without a
# solve (see test/test_validate.jl).  `main(ARGS)` is guarded at the bottom so
# `include`ing this file is side-effect-free.
using Nephrite, Dates, DataFrames, Statistics

# ---------------------------------------------------------------------------
# Pure helpers on forward_curves DataFrames
#   forward_curves columns: month::Date, product::String ("base"/"peak"),
#   hub::String, distribution::String, price::Float64.  ASX hubs are OTA, BEN.
# ---------------------------------------------------------------------------

const _ASX_HUBS = ("OTA", "BEN")

"Rows of `fc` for one product at the two ASX hubs."
_base_rows(fc::DataFrame) =
    fc[(fc.product .== "base") .& in.(fc.hub, Ref(_ASX_HUBS)), :]

"""
    mean_price(fc) -> Float64

Mean base-product price across the two ASX hubs (OTA, BEN) over all months.
The directional gate: halving storage must raise this.
"""
mean_price(fc::DataFrame) = mean(_base_rows(fc).price)

"""
    mean_basis(fc) -> Float64

Mean over months of the absolute base-product OTA-BEN basis |OTA - BEN|.
The directional gate: derating the HVDC must widen this.
"""
function mean_basis(fc::DataFrame)
    rows = _base_rows(fc)
    bases = Float64[]
    for m in sort(unique(rows.month))
        sub = rows[rows.month .== m, :]
        ota = sub[sub.hub .== "OTA", :price]
        ben = sub[sub.hub .== "BEN", :price]
        (isempty(ota) || isempty(ben)) && continue
        push!(bases, abs(first(ota) - first(ben)))
    end
    return isempty(bases) ? 0.0 : mean(bases)
end

"""
    peak_ge_base(fc) -> Vector{NamedTuple}

Every (month, hub) ASX point where the peak price is strictly below the base
price (a sanity violation — peak should never be cheaper than the all-hours
base).  Empty when the run is clean.
"""
function peak_ge_base(fc::DataFrame)
    violations = NamedTuple[]
    asx = fc[in.(fc.hub, Ref(_ASX_HUBS)), :]
    for m in sort(unique(asx.month)), h in _ASX_HUBS
        sub = asx[(asx.month .== m) .& (asx.hub .== h), :]
        b = sub[sub.product .== "base", :price]
        p = sub[sub.product .== "peak", :price]
        (isempty(b) || isempty(p)) && continue
        if first(p) < first(b) - 1e-9
            push!(violations, (month = m, hub = h,
                               base = first(b), peak = first(p)))
        end
    end
    return violations
end

# ---------------------------------------------------------------------------
# CLI parsing (mirrors scripts/run.jl).
# ---------------------------------------------------------------------------

function _parse_opts(args)
    nz_gwh = nothing
    si_gwh = nothing
    min_history_days = nothing   # nothing -> run_model uses the demand.toml default
    i = 1
    while i <= length(args)
        flag = args[i]
        if flag == "--nz-gwh"
            i < length(args) || error("$flag requires a value")
            nz_gwh = parse(Float64, args[i + 1]); i += 2
        elseif flag == "--si-gwh"
            i < length(args) || error("$flag requires a value")
            si_gwh = parse(Float64, args[i + 1]); i += 2
        elseif flag == "--min-history-days"
            i < length(args) || error("$flag requires a value")
            min_history_days = parse(Int, args[i + 1]); i += 2
        else
            error("unknown flag: $flag")
        end
    end
    nz_gwh === nothing && error("--nz-gwh is required")
    si_gwh === nothing && error("--si-gwh is required")
    return (; nz_gwh = nz_gwh, si_gwh = si_gwh, min_history_days = min_history_days)
end

# ---------------------------------------------------------------------------
# Day-one spot cross-check (reported, not gated).
# ---------------------------------------------------------------------------

"""
    model_week1_hub_prices(rr) -> Dict{String,Float64}

Mean of the model's week-1 30-min nodal prices per hub.  These are the
deterministic run's day-one prices to compare against actual spot.
"""
function model_week1_hub_prices(rr)
    sums = Dict{String,Float64}()
    counts = Dict{String,Int}()
    for ((hub, week, _step), p) in rr.prices
        week == 1 || continue
        sums[hub] = get(sums, hub, 0.0) + p
        counts[hub] = get(counts, hub, 0) + 1
    end
    return Dict(h => sums[h] / counts[h] for h in keys(sums))
end

"""
    actual_spot_hub_prices(root, config_dir, date) -> Dict{String,Float64}

Mean actual spot price per hub from the snapshot's `final_energy_prices` table,
mapped POC->hub via the hubmap.

Schema assumption (from test/fixtures/final_energy_prices_sample.csv):
  columns TradingDate, TradingPeriod, PointOfConnection, DollarsPerMegawattHour.
We average DollarsPerMegawattHour over the snapshot's own TradingDate across all
trading periods, grouped by hub.  Defensive: if the table or columns are absent
this returns an empty Dict and the caller reports the spot check as N/A rather
than failing the (ungated) cross-check.
"""
function actual_spot_hub_prices(root::AbstractString, config_dir::AbstractString,
                                date::Date)
    ds = Nephrite.open_datastore(root, date)
    try
        hm = Nephrite.build_hubmap(ds, joinpath(config_dir, "hubmap.toml"))
        # Average per POC over the snapshot date's own trading day.
        df = Nephrite.query(ds,
            "SELECT PointOfConnection AS poc, " *
            "AVG(DollarsPerMegawattHour) AS price " *
            "FROM final_energy_prices " *
            "WHERE TradingDate = DATE '$(date)' " *
            "GROUP BY PointOfConnection")
        if isempty(df)
            # Snapshot may carry the previous day's finalised prices; fall back
            # to the whole table if the exact snapshot date has no rows.
            df = Nephrite.query(ds,
                "SELECT PointOfConnection AS poc, " *
                "AVG(DollarsPerMegawattHour) AS price " *
                "FROM final_energy_prices GROUP BY PointOfConnection")
        end
        sums = Dict{String,Float64}()
        counts = Dict{String,Int}()
        for row in eachrow(df)
            poc = String(row.poc)
            haskey(hm.poc_to_hub, poc) || continue
            hub = hm.poc_to_hub[poc]
            sums[hub] = get(sums, hub, 0.0) + Float64(row.price)
            counts[hub] = get(counts, hub, 0) + 1
        end
        return Dict(h => sums[h] / counts[h] for h in keys(sums))
    catch err
        @warn "spot cross-check: could not read final_energy_prices — reporting N/A" error=err
        return Dict{String,Float64}()
    finally
        close(ds)
    end
end

"Pearson correlation of two equal-length vectors; NaN if undefined."
function _pearson(x::Vector{Float64}, y::Vector{Float64})
    (length(x) < 2) && return NaN
    sx = std(x); sy = std(y)
    (sx == 0 || sy == 0) && return NaN
    return cor(x, y)
end

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

function main(args)
    date = length(args) >= 1 && !startswith(args[1], "--") ?
           Date(args[1]) : Date(2026, 6, 11)
    tail = (length(args) >= 1 && !startswith(args[1], "--")) ? args[2:end] : args
    opts = _parse_opts(tail)

    root = normpath(joinpath(@__DIR__, "..", "data"))
    config_dir = normpath(joinpath(@__DIR__, "..", "config"))
    history_dir = joinpath(root, "history", "demand")

    # min_history_days: pass through only when supplied (otherwise use the default).
    _mhd = opts.min_history_days
    run_one(; nz, si, ov = Dict{Symbol,Any}()) = _mhd === nothing ?
        Nephrite.run_model(date;
            root = root, config_dir = config_dir, history_dir = history_dir,
            nz_gwh = nz, si_gwh = si, n_weeks = 104, overrides = ov) :
        Nephrite.run_model(date;
            root = root, config_dir = config_dir, history_dir = history_dir,
            nz_gwh = nz, si_gwh = si, n_weeks = 104, overrides = ov,
            min_history_days = _mhd)

    println("=== Nephrite attended validation ===")
    println("snapshot date : $date")
    println("nz_gwh / si_gwh: $(opts.nz_gwh) / $(opts.si_gwh)")
    println("Running BASE 104-week solve ...")
    base = run_one(nz = opts.nz_gwh, si = opts.si_gwh)
    fc_base = Nephrite.forward_curves(base.prices, date; n_weeks = base.n_weeks)

    println("Running HALVED-storage solve ...")
    half = run_one(nz = opts.nz_gwh / 2, si = opts.si_gwh / 2)
    fc_half = Nephrite.forward_curves(half.prices, date; n_weeks = half.n_weeks)

    println("Running HVDC-derate (0.5) solve ...")
    derate = run_one(nz = opts.nz_gwh, si = opts.si_gwh,
                     ov = Dict{Symbol,Any}(:hvdc_derate => 0.5))
    fc_derate = Nephrite.forward_curves(derate.prices, date; n_weeks = derate.n_weeks)

    # --- Hard gates ---------------------------------------------------------
    base_mean   = mean_price(fc_base)
    half_mean   = mean_price(fc_half)
    gate1 = half_mean > base_mean

    base_basis   = mean_basis(fc_base)
    derate_basis = mean_basis(fc_derate)
    gate2 = derate_basis > base_basis

    violations = peak_ge_base(fc_base)
    gate3 = isempty(violations)

    println()
    println("--- Directional sanity (hard gates) ---")
    println("[$(gate1 ? "PASS" : "FAIL")] storage halved raises price: " *
            "base mean=$(round(base_mean, digits=2)) -> " *
            "halved mean=$(round(half_mean, digits=2))")
    println("[$(gate2 ? "PASS" : "FAIL")] HVDC derate widens basis: " *
            "base |OTA-BEN|=$(round(base_basis, digits=2)) -> " *
            "derate |OTA-BEN|=$(round(derate_basis, digits=2))")
    if gate3
        println("[PASS] peak >= base on all OTA/BEN monthly points")
    else
        println("[FAIL] peak < base at $(length(violations)) point(s):")
        for v in violations
            println("    $(v.month) $(v.hub): base=$(round(v.base, digits=2)) " *
                    "peak=$(round(v.peak, digits=2))")
        end
    end

    # --- Day-one spot cross-check (reported, NOT gated) ---------------------
    println()
    println("--- Day-one spot cross-check (reported, not gated) ---")
    model_hub = model_week1_hub_prices(base)
    actual_hub = actual_spot_hub_prices(root, config_dir, date)

    corr = NaN; bias = NaN
    spot_lines = String[]
    if isempty(actual_hub)
        println("spot table not found / empty — reported as N/A")
    else
        common = sort([h for h in keys(model_hub) if haskey(actual_hub, h)])
        mvec = Float64[model_hub[h] for h in common]
        avec = Float64[actual_hub[h] for h in common]
        corr = _pearson(mvec, avec)
        bias = isempty(mvec) ? NaN : mean(mvec .- avec)
        println("hubs compared : $(join(common, ", "))")
        println("Pearson corr  : $(round(corr, digits=4))")
        println("mean bias (model - actual): $(round(bias, digits=2))")
        println("(a deterministic model is expected to under-disperse — low bias / smoothing is normal)")
        for h in common
            gap = model_hub[h] - actual_hub[h]
            line = "    $h: model=$(round(model_hub[h], digits=2)) " *
                   "actual=$(round(actual_hub[h], digits=2)) " *
                   "gap=$(round(gap, digits=2))"
            println(line)
            push!(spot_lines, line)
        end
    end

    # --- Summary + notes file ----------------------------------------------
    all_pass = gate1 && gate2 && gate3
    println()
    println("=== SUMMARY: $(all_pass ? "ALL HARD GATES PASS" : "HARD GATE FAILURE") ===")

    notes = joinpath(base.run_dir, "validation_notes.txt")
    open(notes, "w") do io
        println(io, "Nephrite attended validation — $date")
        println(io, "nz_gwh/si_gwh: $(opts.nz_gwh)/$(opts.si_gwh)")
        println(io, "")
        println(io, "gate1 storage-halved-raises-price: $(gate1 ? "PASS" : "FAIL") " *
                    "base=$(base_mean) halved=$(half_mean)")
        println(io, "gate2 hvdc-derate-widens-basis: $(gate2 ? "PASS" : "FAIL") " *
                    "base=$(base_basis) derate=$(derate_basis)")
        println(io, "gate3 peak>=base: $(gate3 ? "PASS" : "FAIL") " *
                    "violations=$(length(violations))")
        for v in violations
            println(io, "  $(v.month) $(v.hub) base=$(v.base) peak=$(v.peak)")
        end
        println(io, "")
        println(io, "spot cross-check Pearson=$(corr) mean_bias=$(bias)")
        for l in spot_lines
            println(io, l)
        end
        println(io, "")
        println(io, "OVERALL: $(all_pass ? "PASS" : "FAIL")")
    end
    println("notes written -> $notes")

    all_pass || exit(1)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end
