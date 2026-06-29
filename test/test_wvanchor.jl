using Dates, DataFrames

@testset "wvanchor" begin
    @testset "aggregation: per-POC mean then per-reservoir mean, unmapped dropped" begin
        iwv = DataFrame(poc = ["A","A","B","C"], tp = [1,2,1,1],
                        implied_wv = [100.0, 200.0, 60.0, 999.0])
        # A,B -> ResX ; C unmapped (dropped)
        map = Dict("A" => "ResX", "B" => "ResX")
        out = Nephrite._aggregate_reservoir_wv(iwv, map)
        @test names(out) == ["reservoir", "implied_wv"]
        @test nrow(out) == 1
        @test out.reservoir[1] == "ResX"
        # A mean over tp = 150; B = 60; reservoir mean over POCs = (150+60)/2 = 105
        @test isapprox(out.implied_wv[1], 105.0; rtol = 1e-9)
        # empty input -> typed empty
        @test isempty(Nephrite._aggregate_reservoir_wv(DataFrame(poc=String[],tp=Int[],implied_wv=Float64[]), map))
    end

    @testset "decay weights: full at week 1, zero past horizon" begin
        w = Nephrite.anchor_weights(13, 104)
        @test length(w) == 104
        @test w[1] == 1.0
        @test w[13] <= w[1]
        @test all(w[14:end] .== 0.0)
        @test issorted(w[1:13]; rev=true)
    end

    @testset "per-reservoir aggregation maps POC->reservoir" begin
        mktempdir() do root
            d = Date(2026, 6, 10)
            build_test_snapshot!(root, d)
            ds = Nephrite.open_datastore(root, d)
            jd = Nephrite.load_jade(joinpath(@__DIR__,"fixtures","jade"),
                                    joinpath(@__DIR__,"..","config","jade.toml"))
            sm = Nephrite.build_stationmap(jd, joinpath(@__DIR__,"fixtures","stationmap_test.toml"))
            plant = Nephrite.load_plant(joinpath(@__DIR__,"..","config","plant.toml"))
            try
                rv = Nephrite.reservoir_implied_wv(ds, plant, sm)
                @test names(rv) == ["reservoir", "implied_wv"]
                @test all(rv.implied_wv .>= 0)
            finally
                close(ds)
            end
        end
    end

    @testset "weight 0 disables the anchor" begin
        mktempdir() do root
            d = Date(2026, 6, 10)
            build_test_snapshot!(root, d)
            ds = Nephrite.open_datastore(root, d)
            jd = Nephrite.load_jade(joinpath(@__DIR__,"fixtures","jade"),
                                    joinpath(@__DIR__,"..","config","jade.toml"))
            sm = Nephrite.build_stationmap(jd, joinpath(@__DIR__,"fixtures","stationmap_test.toml"))
            plant = Nephrite.load_plant(joinpath(@__DIR__,"..","config","plant.toml"))
            cfg = joinpath(@__DIR__,"fixtures","model_zero_anchor.toml")
            try
                a = Nephrite.wvanchor(ds, plant, sm, cfg; n_weeks=104)
                @test a.weight == 0.0
                @test length(a.weights) == 104
            finally
                close(ds)
            end
        end
    end
end
