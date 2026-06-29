@testset "jadedata" begin
    jdir = joinpath(@__DIR__, "fixtures", "jade")
    cfg = joinpath(@__DIR__, "..", "config", "jade.toml")
    jd = Nephrite.load_jade(jdir, cfg)

    @testset "thermal units load with SRMC inputs" begin
        @test !isempty(jd.thermal_units)
        u = first(jd.thermal_units)
        @test u.heat_rate > 0
        @test u.capacity_mw > 0
        @test u.fuel isa AbstractString
    end
    @testset "fuel costs load with carbon" begin
        @test !isempty(jd.fuel_costs)
        @test jd.carbon_price_nzd_per_tonne == 60.0
        @test all(fc.price_per_gj >= 0 for fc in jd.fuel_costs)
        @test all(fc.carbon_t_per_gj > 0 for fc in jd.fuel_costs)
    end
    @testset "hydro stations carry specific power and concave segments" begin
        @test !isempty(jd.hydro_stations)
        s = first(jd.hydro_stations)
        @test s.specific_power > 0
        # single linear segment: exactly two points (0,0) → (max_flow, capacity_mw)
        @test length(s.turbine_segments) == 2
        @test s.turbine_segments[1] == (0.0, 0.0)
        @test isapprox(s.turbine_segments[2][1], s.capacity_mw / s.specific_power; rtol=1e-9)
        @test isapprox(s.turbine_segments[2][2], s.capacity_mw; rtol=1e-9)
    end
    @testset "reservoirs and arcs load and reference known nodes" begin
        @test !isempty(jd.reservoirs)
        @test !isempty(jd.arcs)
        resnames  = Set(r.name for r in jd.reservoirs)
        statnames = Set(s.name for s in jd.hydro_stations)
        # Documented sink/junction tail-water nodes present in the toy fixture
        tail_nodes = Set(["ToyWhaka_tail", "ToyBenmore_tail"])
        known_nodes = resnames ∪ statnames ∪ tail_nodes
        for a in jd.arcs
            @test a.from in known_nodes
            @test a.to   in known_nodes
        end
    end
    @testset "each hydro station appears on exactly one arc (its own generation arc)" begin
        # Every station IS its own arc HEAD_WATER_FROM -> TAIL_WATER_TO.
        for s in jd.hydro_stations
            station_arcs = [a for a in jd.arcs if a.station == s.name]
            @test length(station_arcs) == 1
        end
    end
end

@testset "jadedata real-data hydro arcs (station-arc reconstruction)" begin
    jd = Nephrite.load_jade(joinpath(@__DIR__, "..", "data", "static", "jade"),
                            joinpath(@__DIR__, "..", "config", "jade.toml"))

    @testset "total arc count = stations + natural arcs" begin
        # 26 hydro stations (each its own arc) + 19 natural conveyance/spill arcs.
        @test length(jd.hydro_stations) == 26
        @test length(jd.arcs) == 45
    end

    @testset "every station is on exactly one arc with its own from/to nodes" begin
        for s in jd.hydro_stations
            station_arcs = [a for a in jd.arcs if a.station == s.name]
            @test length(station_arcs) == 1
        end
    end

    @testset "specific station arcs are present (chains reconnected)" begin
        bystation = Dict(a.station => a for a in jd.arcs if a.station != "")
        @test haskey(bystation, "Manapouri")
        @test bystation["Manapouri"].from == "Lakes_Manapouri_Te_Anau_head"
        @test bystation["Manapouri"].to   == "SEA"
        @test haskey(bystation, "Benmore")
        @test bystation["Benmore"].from == "Lake_Benmore"
        @test bystation["Benmore"].to   == "Lake_Aviemore"
        @test haskey(bystation, "Roxburgh")
        @test bystation["Roxburgh"].from == "Lake_Roxburgh"
        @test bystation["Roxburgh"].to   == "Roxburgh_tail"
    end

    @testset "station arc max_flow = capacity / specific_power" begin
        s = first(filter(s -> s.name == "Benmore", jd.hydro_stations))
        a = first(filter(a -> a.station == "Benmore", jd.arcs))
        @test isapprox(a.max_flow, s.capacity_mw / s.specific_power; rtol = 1e-9)
    end

    @testset "natural arcs carry no station (pure conveyance/spill)" begin
        natural = [a for a in jd.arcs if a.from == "Lake_Pukaki" && a.to == "Lake_Benmore"]
        @test length(natural) == 1
        @test natural[1].station == ""
        # The Pukaki->Benmore natural arc has a finite max flow (3820 cumecs).
        @test isapprox(natural[1].max_flow, 3820.0; rtol = 1e-9)
    end
end
