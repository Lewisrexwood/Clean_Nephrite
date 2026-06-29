using Dates, DataFrames, Statistics

@testset "distributional outputs" begin
    @testset "forward_curves_dist emits mean + quantiles per month/product/hub" begin
        # One month of week-1 steps for OTA, 3 scenarios with a clear spread.
        # snapshot 2026-01-05 (a Monday); step 1 ⇒ 00:00, base only at this hour.
        snap = Date(2026, 1, 5)
        pd = Dict{Tuple{String,Int,Int},Vector{Float64}}(
            ("OTA", 1, 1) => [10.0, 20.0, 30.0],
            ("OTA", 1, 2) => [10.0, 20.0, 30.0])
        df = Nephrite.forward_curves_dist(pd, snap; n_weeks = 1)
        @test Set(names(df)) == Set(["month","product","hub","distribution","price"])
        @test Set(df.distribution) ⊇ Set(["mean","p10","p50","p90"])
        base_mean = only(df[(df.product .== "base") .& (df.hub .== "OTA") .&
                            (df.distribution .== "mean"), :price])
        @test isapprox(base_mean, 20.0; atol=1e-9)         # mean of pooled steps/scenarios
        base_p50 = only(df[(df.product .== "base") .& (df.hub .== "OTA") .&
                           (df.distribution .== "p50"), :price])
        @test isapprox(base_p50, 20.0; atol=1e-9)
        base_p90 = only(df[(df.product .== "base") .& (df.hub .== "OTA") .&
                           (df.distribution .== "p90"), :price])
        @test base_p90 > base_p50
    end

    @testset "period_price_fan emits half-hourly mean + quantiles per hub/step" begin
        # snapshot 2026-01-05 (a Monday). step 1 ⇒ 00:00, step 3 ⇒ +1 h = 01:00.
        snap = Date(2026, 1, 5)
        pd = Dict{Tuple{String,Int,Int},Vector{Float64}}(
            ("OTA", 1, 1) => [10.0, 20.0, 30.0],
            ("OTA", 1, 3) => [40.0, 50.0, 60.0],
            ("BEN", 1, 1) => [5.0, 15.0, 25.0],
            ("XYZ", 1, 1) => [99.0, 99.0, 99.0])   # non-ASX hub: must be dropped
        df = Nephrite.period_price_fan(pd, snap; n_weeks = 1)
        @test Set(names(df)) == Set(["datetime","hub","distribution","price"])
        @test Set(df.distribution) ⊇ Set(["mean","p10","p50","p90"])
        @test !("XYZ" in df.hub)                                   # non-ASX excluded
        # one entry per (hub, step) × 4 series: 2 OTA steps + 1 BEN step = 3 × 4 = 12 rows.
        @test nrow(df) == 12

        # OTA step 1 ⇒ 2026-01-05T00:00; mean of [10,20,30] = 20.
        m1 = only(df[(df.hub .== "OTA") .& (df.datetime .== DateTime(2026,1,5,0,0)) .&
                     (df.distribution .== "mean"), :price])
        @test isapprox(m1, 20.0; atol=1e-9)
        # OTA step 3 ⇒ 2026-01-05T01:00; p50 of [40,50,60] = 50.
        p3 = only(df[(df.hub .== "OTA") .& (df.datetime .== DateTime(2026,1,5,1,0)) .&
                     (df.distribution .== "p50"), :price])
        @test isapprox(p3, 50.0; atol=1e-9)
    end

    @testset "period_demand emits half-hourly demand per ASX hub" begin
        snap = Date(2026, 1, 5)
        # Minimal DispatchInputs (period_demand only reads weeks[w].periods336).
        hubs = [Nephrite.Hub("OTA","OTA2201","Otahuhu","NI"),
                Nephrite.Hub("BEN","BEN2201","Benmore","SI")]
        topo = Nephrite.Topology(hubs, Nephrite.Corridor[])
        net  = Nephrite.HydroNetwork(Nephrite.JadeReservoir[], Nephrite.Arc[],
                   Dict{String,Nephrite.HydroStation}(), Dict{String,String}(),
                   Dict{String,Vector{String}}())
        inp  = Nephrite.DispatchInputs(topo, net,
                   DataFrame(hub=String[],price=Float64[],mw=Float64[]),
                   DataFrame(hub=String[],mw=Float64[]), [], 1e4)
        # step 1 ⇒ 00:00, step 2 ⇒ 00:30.  XYZ is non-ASX → dropped.
        p1 = Nephrite.Period("s1", 0.5, Dict("OTA"=>500.0, "BEN"=>300.0, "XYZ"=>9.0))
        p2 = Nephrite.Period("s2", 0.5, Dict("OTA"=>600.0, "BEN"=>350.0))
        wk = Nephrite.WeekInputs(Nephrite.Period[], [p1, p2], inp, Dict{String,Float64}())

        df = Nephrite.period_demand([wk], snap; n_weeks = 1)
        @test Set(names(df)) == Set(["datetime","hub","demand_mw"])
        @test !("XYZ" in df.hub)                                   # non-ASX excluded
        @test nrow(df) == 4                                        # 2 steps × 2 hubs
        d = only(df[(df.hub .== "OTA") .& (df.datetime .== DateTime(2026,1,5,0,30)), :demand_mw])
        @test isapprox(d, 600.0; atol=1e-9)
        b = only(df[(df.hub .== "BEN") .& (df.datetime .== DateTime(2026,1,5,0,0)), :demand_mw])
        @test isapprox(b, 300.0; atol=1e-9)
    end

    @testset "write_distribution_outputs writes parquet + csv" begin
        mktempdir() do dir
            snap = Date(2026, 1, 5)
            pd = Dict{Tuple{String,Int,Int},Vector{Float64}}(
                ("OTA", 1, 1) => [10.0, 20.0, 30.0],
                ("BEN", 1, 1) => [5.0, 15.0, 25.0])
            Nephrite.write_distribution_outputs(dir, pd, snap; n_weeks = 1)
            @test isfile(joinpath(dir, "forward_curves_dist.parquet"))
            @test isfile(joinpath(dir, "forward_curves_dist.csv"))
        end
    end
end
