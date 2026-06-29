@testset "stationmap" begin
    jdir = joinpath(@__DIR__, "fixtures", "jade")
    jd = Nephrite.load_jade(jdir, joinpath(@__DIR__, "..", "config", "jade.toml"))
    cfg = joinpath(@__DIR__, "fixtures", "stationmap_test.toml")

    @testset "maps every station to a valid hub" begin
        sm = Nephrite.build_stationmap(jd, cfg)
        names = vcat([u.name for u in jd.thermal_units], [s.name for s in jd.hydro_stations])
        @test length(names) == 7
        for n in names
            @test Nephrite.hub_for_station(sm, n) in Nephrite.HUB_CODES
        end
    end
    @testset "loud-fail on an unmapped station" begin
        # a config missing one station entry must error listing it
        @test_throws ErrorException Nephrite.build_stationmap(jd,
            joinpath(@__DIR__, "fixtures", "stationmap_missing.toml"))
    end
    @testset "poc->reservoir lookups" begin
        sm = Nephrite.build_stationmap(jd, cfg)
        @test Nephrite.reservoir_for_poc(sm, "TST2201") == "Lake_ToyTaupo"
        @test_throws ErrorException Nephrite.reservoir_for_poc(sm, "ZZZ9999")
    end
end
