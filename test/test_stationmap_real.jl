@testset "stationmap real coverage" begin
    jd = Nephrite.load_jade(joinpath(@__DIR__, "..", "data", "static", "jade"),
                            joinpath(@__DIR__, "..", "config", "jade.toml"))
    @testset "every real JADE station maps to a hub (loud-fail covered)" begin
        sm = Nephrite.build_stationmap(jd, joinpath(@__DIR__, "..", "config", "stationmap.toml"))
        station_names = vcat([u.name for u in jd.thermal_units], [s.name for s in jd.hydro_stations])
        @test length(station_names) == 36   # dataset canary: update if JADE static data changes
        for n in station_names
            @test Nephrite.hub_for_station(sm, n) in Nephrite.HUB_CODES
        end
    end
    @testset "every real fixed station resolves via hub_for_station" begin
        sm = Nephrite.build_stationmap(jd, joinpath(@__DIR__, "..", "config", "stationmap.toml"))
        # build_stationmap now validates fixed_stations in the unmapped-stations check
        # (thermal ∪ hydro ∪ fixed_stations), so reaching here already proves all are
        # mapped.  We also call hub_for_station on each one to be non-vacuous.
        @test !isempty(jd.fixed_stations)
        for fs in jd.fixed_stations
            @test Nephrite.hub_for_station(sm, fs.name) in Nephrite.HUB_CODES
        end
    end
    @testset "build_stationmap loud-fails when a fixed station is missing from config" begin
        # stationmap_missing_fixed.toml maps all thermal and hydro fixture stations
        # but deliberately omits ToyCogen_NI (a fixed station).  After the FIX A
        # change, build_stationmap includes fixed_stations in the coverage check,
        # so this must error rather than silently accepting the incomplete config.
        jd_fixture = Nephrite.load_jade(joinpath(@__DIR__, "fixtures", "jade"),
                                        joinpath(@__DIR__, "..", "config", "jade.toml"))
        @test !isempty(jd_fixture.fixed_stations)
        @test_throws ErrorException Nephrite.build_stationmap(
            jd_fixture, joinpath(@__DIR__, "fixtures", "stationmap_missing_fixed.toml"))
    end
    @testset "mapped POCs resolve to known reservoirs; run-of-river POCs are intentionally unmapped" begin
        # Run-of-river hydro POCs with no JADE-tracked controlled reservoir
        # (e.g. Mangahao MHO0331) are legitimately absent from poc_to_reservoir
        # and do NOT need to resolve to a reservoir.  This testset validates only
        # the entries that ARE in the map.
        sm = Nephrite.build_stationmap(jd, joinpath(@__DIR__, "..", "config", "stationmap.toml"))
        resnames = Set(r.name for r in jd.reservoirs)
        mapped_pocs = collect(keys(sm.poc_to_reservoir))
        @test length(mapped_pocs) == 24   # 25 modelled-hydro POCs minus 1 run-of-river (MHO0331)
        for poc in mapped_pocs
            @test Nephrite.reservoir_for_poc(sm, poc) in resnames
        end
    end
end
