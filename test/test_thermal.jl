using DataFrames

@testset "thermal" begin
    jdir = joinpath(@__DIR__, "fixtures", "jade")
    jd = Nephrite.load_jade(jdir, joinpath(@__DIR__, "..", "config", "jade.toml"))
    sm = Nephrite.build_stationmap(jd, joinpath(@__DIR__, "fixtures", "stationmap_test.toml"))

    @testset "SRMC = heat rate x fuel + carbon" begin
        u = first(jd.thermal_units)
        fc = only(f for f in jd.fuel_costs if f.fuel == u.fuel)
        expected = u.heat_rate * fc.price_per_gj +
                   u.heat_rate * fc.carbon_t_per_gj * jd.carbon_price_nzd_per_tonne
        @test isapprox(Nephrite.srmc(u, jd.fuel_costs, jd.carbon_price_nzd_per_tonne),
                       expected; rtol=1e-9)
    end

    @testset "supply curves are per-hub and price-sorted" begin
        curves = Nephrite.thermal_supply_curves(jd, sm)
        @test names(curves) == ["hub", "price", "mw"]
        @test all(h in Nephrite.HUB_CODES for h in curves.hub)
        for g in groupby(curves, :hub)
            @test issorted(g.price)
        end
        @test all(curves.mw .> 0)
    end

    @testset "outage derate reduces available MW" begin
        u = first(jd.thermal_units)
        curves = Nephrite.thermal_supply_curves(jd, sm)
        full = sum(curves.mw)
        der = sum(Nephrite.thermal_supply_curves(jd, sm; derate=Dict(u.name=>0.5)).mw)
        @test der < full
        der0 = Nephrite.thermal_supply_curves(jd, sm; derate=Dict(u.name=>0.0))
        @test nrow(der0) == nrow(curves) - 1
    end
end
