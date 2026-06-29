# Hermetic unit tests for scripts/validate.jl pure helpers.
#
# The script's `main(ARGS)` is guarded behind `if abspath(PROGRAM_FILE)==@__FILE__`,
# so this `include` is side-effect-free: no run_model, no solve, no network.  We
# only exercise the pure functions of forward_curves DataFrames.
include(joinpath(@__DIR__, "..", "scripts", "validate.jl"))

using DataFrames, Dates

"Build a minimal forward_curves-shaped DataFrame from (month,product,hub)=>price."
function _fc(rows)
    month = Date[]; product = String[]; hub = String[]
    distribution = String[]; price = Float64[]
    for ((m, p, h), v) in rows
        push!(month, m); push!(product, p); push!(hub, h)
        push!(distribution, "point"); push!(price, v)
    end
    return DataFrame(month = month, product = product, hub = hub,
                     distribution = distribution, price = price)
end

@testset "validate helpers" begin
    m1 = Date(2026, 7, 1)
    m2 = Date(2026, 8, 1)

    @testset "mean_price" begin
        # base OTA/BEN over two months: 100, 60, 120, 80 -> mean 90.
        fc = _fc([
            ((m1, "base", "OTA"), 100.0), ((m1, "base", "BEN"), 60.0),
            ((m2, "base", "OTA"), 120.0), ((m2, "base", "BEN"), 80.0),
            # peak rows must be ignored by mean_price (base only).
            ((m1, "peak", "OTA"), 999.0), ((m1, "peak", "BEN"), 999.0),
        ])
        @test mean_price(fc) ≈ 90.0
    end

    @testset "mean_basis" begin
        # OTA=100, BEN=60 -> basis 40 in the single month.
        fc = _fc([
            ((m1, "base", "OTA"), 100.0), ((m1, "base", "BEN"), 60.0),
        ])
        @test mean_basis(fc) ≈ 40.0

        # |OTA-BEN| uses absolute value: BEN above OTA still gives +40.
        fc_neg = _fc([
            ((m1, "base", "OTA"), 60.0), ((m1, "base", "BEN"), 100.0),
        ])
        @test mean_basis(fc_neg) ≈ 40.0

        # Widening detection: a wider-basis fc compares strictly greater.
        wide = _fc([
            ((m1, "base", "OTA"), 130.0), ((m1, "base", "BEN"), 60.0),
        ])
        @test mean_basis(wide) > mean_basis(fc)

        # Averaged over months: 40 and 20 -> 30.
        fc2 = _fc([
            ((m1, "base", "OTA"), 100.0), ((m1, "base", "BEN"), 60.0),
            ((m2, "base", "OTA"), 90.0),  ((m2, "base", "BEN"), 70.0),
        ])
        @test mean_basis(fc2) ≈ 30.0
    end

    @testset "peak_ge_base" begin
        # All peak >= base -> no violations.
        ok = _fc([
            ((m1, "base", "OTA"), 100.0), ((m1, "peak", "OTA"), 100.0),
            ((m1, "base", "BEN"), 60.0),  ((m1, "peak", "BEN"), 70.0),
        ])
        @test isempty(peak_ge_base(ok))

        # One point with peak < base -> exactly that violation reported.
        bad = _fc([
            ((m1, "base", "OTA"), 100.0), ((m1, "peak", "OTA"), 90.0),  # violation
            ((m1, "base", "BEN"), 60.0),  ((m1, "peak", "BEN"), 70.0),  # ok
        ])
        v = peak_ge_base(bad)
        @test length(v) == 1
        @test v[1].hub == "OTA"
        @test v[1].month == m1
        @test v[1].base ≈ 100.0
        @test v[1].peak ≈ 90.0
    end
end
