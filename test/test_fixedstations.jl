using DataFrames

@testset "fixed stations / must-run" begin
    jdir = joinpath(@__DIR__, "fixtures", "jade")
    jd = Nephrite.load_jade(jdir, joinpath(@__DIR__, "..", "config", "jade.toml"))
    sm = Nephrite.build_stationmap(jd, joinpath(@__DIR__, "fixtures", "stationmap_test.toml"))

    # The toy fixture's fixed_stations.csv carries weeks 1 and 2; week 1 is present.
    woy = 1

    @testset "fixed stations load with a per-week schedule and node" begin
        @test !isempty(jd.fixed_stations)
        fs = first(jd.fixed_stations)
        @test fs.node isa AbstractString
        @test !isempty(fs.weekly_mw)
        @test all(v -> v > 0, values(fs.weekly_mw))
        @test Nephrite.mustrun_mw(fs, woy) > 0
    end
    @testset "mustrun_generation sums per-week must-run per hub" begin
        mr = Nephrite.mustrun_generation(jd, sm, woy)
        @test names(mr) == ["hub", "mw"]
        @test all(mr.mw .> 0)
        @test all(h in Nephrite.HUB_CODES for h in mr.hub)
        # total must-run equals total per-week must-run over the mapped stations
        @test isapprox(sum(mr.mw),
                       sum(Nephrite.mustrun_mw(f, woy) for f in jd.fixed_stations);
                       rtol = 1e-9)
    end
    @testset "real-data must-run magnitude is the per-week scheduled level" begin
        # Regression guard for the max-over-52-weeks bug: that bug injected a
        # constant ~3227 MW must-run.  The correct per-week mean(block) level
        # for a representative week (24) is ~1500 MW, well inside [1200, 1800].
        real_jdir = joinpath(@__DIR__, "..", "data", "static", "jade")
        if isdir(real_jdir)
            jd_real = Nephrite.load_jade(real_jdir,
                                         joinpath(@__DIR__, "..", "config", "jade.toml"))
            sm_real = Nephrite.build_stationmap(jd_real,
                                                joinpath(@__DIR__, "..", "config", "stationmap.toml"))
            total24 = sum(Nephrite.mustrun_generation(jd_real, sm_real, 24).mw)
            @test 1200.0 <= total24 <= 1800.0
        else
            @info "real JADE data absent; skipping must-run magnitude guard"
        end
    end
end
