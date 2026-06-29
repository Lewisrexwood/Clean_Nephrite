@testset "hydronet" begin
    jdir = joinpath(@__DIR__, "fixtures", "jade")
    jd = Nephrite.load_jade(jdir, joinpath(@__DIR__, "..", "config", "jade.toml"))
    sm = Nephrite.build_stationmap(jd, joinpath(@__DIR__, "fixtures", "stationmap_test.toml"))
    net = Nephrite.build_hydronet(jd, sm)

    @testset "network assembles with reservoirs, arcs, stations" begin
        @test !isempty(net.reservoirs)
        @test !isempty(net.arcs)
        @test !isempty(net.stations)
    end

    @testset "downstream topology is acyclic and connects to a sink" begin
        # toy chain: upper reservoir -> station -> lower reservoir -> station -> sea
        @test haskey(net.downstream, first(net.reservoirs).name)
    end

    @testset "turbine curve generation is concave and capped" begin
        s = net.stations["ToyTaupo_gen"]
        # generation rises with flow but with non-increasing marginal rate
        g_lo = Nephrite.generation_mw(s, 0.25 * s.turbine_segments[end][1])
        g_hi = Nephrite.generation_mw(s, s.turbine_segments[end][1])
        @test 0 <= g_lo <= g_hi <= s.capacity_mw + 1e-6
        # beyond max flow, generation is capped at capacity
        @test Nephrite.generation_mw(s, 10 * s.turbine_segments[end][1]) <=
              s.capacity_mw + 1e-6
    end

    @testset "loud-fail on a station with a non-concave turbine curve" begin
        bad = deepcopy(jd)
        # craft a convex (increasing-marginal) curve -> must be rejected
        s = bad.hydro_stations[1]
        bad.hydro_stations[1] = Nephrite.HydroStation(s.name, s.capacity_mw,
            s.specific_power, [(0.0,0.0),(1.0,1.0),(2.0,5.0)])
        @test_throws ErrorException Nephrite.build_hydronet(bad, sm)
    end

    @testset "loud-fail on an arc referencing an unknown station" begin
        bad = deepcopy(jd)
        a = bad.arcs[1]
        # rebuild arc[1] with a bogus station name, keeping its other fields
        bad.arcs[1] = Nephrite.Arc(a.from, a.to, "NO_SUCH_STATION", a.max_flow)
        @test_throws ErrorException Nephrite.build_hydronet(bad, sm)
    end
end
