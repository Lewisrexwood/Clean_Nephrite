using Dates, DataFrames

@testset "outputs" begin
    # synthetic prices: 2 weeks, 336 steps, OTA flat 100, BEN flat 50, all hubs present
    d = Date(2026, 6, 1)   # a Monday-anchored month for clean bucketing
    prices = Dict{Tuple{String,Int,Int},Float64}()
    for h in Nephrite.HUB_CODES, w in 1:2, t in 1:336
        prices[(h,w,t)] = h=="OTA" ? 100.0 : (h=="BEN" ? 50.0 : 70.0)
    end
    @testset "monthly base/peak at OTA and BEN" begin
        fc = Nephrite.forward_curves(prices, d; n_weeks=2)
        @test names(fc) == ["month","product","hub","distribution","price"]
        @test Set(fc.hub) == Set(["OTA","BEN"])
        @test Set(fc.product) == Set(["base","peak"])
        @test all(fc.distribution .== "point")
        ota_base = only(fc[(fc.hub.=="OTA").&(fc.product.=="base"), :price])
        @test isapprox(ota_base, 100.0; atol=1e-9)   # flat price -> base == 100
        ben_base = only(fc[(fc.hub.=="BEN").&(fc.product.=="base"), :price])
        @test isapprox(ben_base, 50.0; atol=1e-9)
    end
    @testset "peak >= base never violated for flat prices (equal); peak window applied" begin
        fc = Nephrite.forward_curves(prices, d; n_weeks=2)
        for g in groupby(fc, [:hub])
            b = only(g[g.product.=="base", :price]); p = only(g[g.product.=="peak", :price])
            @test p >= b - 1e-9   # flat prices -> equal
        end
    end
end
