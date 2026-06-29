using Dates, DataFrames

@testset "fleet" begin
    cfg = joinpath(@__DIR__, "..", "config", "committed_projects.toml")

    @testset "loads and validates" begin
        fleet = Nephrite.load_fleet(cfg)
        @test all(p -> p.hub in Nephrite.HUB_CODES, fleet.projects)
        @test all(p -> p.technology in
                       ("wind", "solar", "geothermal", "battery", "thermal", "hydro"),
                  fleet.projects)
        @test all(p -> p.capacity_mw > 0, fleet.projects)
    end

    @testset "active capacity respects dates" begin
        fleet = Nephrite.load_fleet(cfg)
        adds_before = Nephrite.fleet_changes(fleet, Date(2026, 6, 13))
        adds_after = Nephrite.fleet_changes(fleet, Date(2027, 6, 13))
        @test sum(adds_after.capacity_mw) >= sum(adds_before.capacity_mw)
        @test all(adds_after.effective .<= Date(2027, 6, 13))
    end

    @testset "rejects bad config" begin
        mktempdir() do d
            bad = joinpath(d, "bad.toml")
            write(bad, """
            [[projects]]
            name = "X"
            hub = "ZZZ"
            technology = "wind"
            capacity_mw = 10.0
            energy_mwh = 0.0
            commissioning = 2026-12-01
            source_note = "n"
            """)
            @test_throws ErrorException Nephrite.load_fleet(bad)
        end
    end
end
