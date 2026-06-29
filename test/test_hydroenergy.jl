using DataFrames

# Toy chain: UpperLake -> [stnA] -> LowerLake -> [stnB] -> SEA
function toy_net()
    res = [Nephrite.JadeReservoir("UpperLake","SI", 0.0, 100.0),
           Nephrite.JadeReservoir("LowerLake","SI", 0.0, 50.0)]
    stnA = Nephrite.HydroStation("stnA", 20.0, 2.0, [(0.0,0.0),(10.0,20.0)])  # sp=2 MW/cumec
    stnB = Nephrite.HydroStation("stnB", 30.0, 3.0, [(0.0,0.0),(10.0,30.0)])  # sp=3 MW/cumec
    arcs = [Nephrite.Arc("UpperLake","LowerLake","stnA",10.0),
            Nephrite.Arc("LowerLake","SEA","stnB",10.0)]
    stations = Dict("stnA"=>stnA, "stnB"=>stnB)
    station_hub = Dict("stnA"=>"BEN", "stnB"=>"BEN")
    downstream = Dict("UpperLake"=>["LowerLake"], "LowerLake"=>["SEA"])
    return Nephrite.HydroNetwork(res, arcs, stations, station_hub, downstream)
end

@testset "spill arc contributes 0 sp but still propagates downstream coeff" begin
    # TopLake --(spill, no station)--> MidLake --[gen sp=4]--> SEA
    res = [Nephrite.JadeReservoir("TopLake","SI",0.0,100.0),
           Nephrite.JadeReservoir("MidLake","SI",0.0,50.0)]
    gen = Nephrite.HydroStation("gen",40.0,4.0,[(0.0,0.0),(10.0,40.0)])
    arcs = [Nephrite.Arc("TopLake","MidLake","",10.0),     # spill arc, no station
            Nephrite.Arc("MidLake","SEA","gen",10.0)]
    net2 = Nephrite.HydroNetwork(res, arcs, Dict("gen"=>gen),
              Dict("gen"=>"BEN"), Dict("TopLake"=>["MidLake"],"MidLake"=>["SEA"]))
    c = Nephrite.downstream_energy_coeff(net2)
    @test isapprox(c["TopLake"], 4.0; atol=1e-9)   # 0 (spill) + 4 (downstream gen)
    @test isapprox(c["MidLake"], 4.0; atol=1e-9)
end

@testset "parallel turbine + spill arcs take the MAX route, not the SUM" begin
    # Reservoir with TWO outgoing arcs to the same downstream node:
    #   - a turbine arc (sp=5)
    #   - a parallel spill arc (sp=0, no station)
    # Physically a unit of water takes ONE route, so the energy-per-cumec is the
    # best route = 5 + coeff(down), NOT the SUM (which would double-count the
    # shared downstream coeff). This is the regression guard for SUM->MAX.
    res = [Nephrite.JadeReservoir("Head","SI",0.0,100.0),
           Nephrite.JadeReservoir("Down","SI",0.0,50.0)]
    turbine = Nephrite.HydroStation("turbine",50.0,5.0,[(0.0,0.0),(10.0,50.0)])  # sp=5
    downgen = Nephrite.HydroStation("downgen",30.0,3.0,[(0.0,0.0),(10.0,30.0)])  # sp=3
    arcs = [Nephrite.Arc("Head","Down","turbine",10.0),  # turbine route, sp=5
            Nephrite.Arc("Head","Down","",10.0),         # parallel spill, sp=0
            Nephrite.Arc("Down","SEA","downgen",10.0)]   # sp=3
    net3 = Nephrite.HydroNetwork(res, arcs, Dict("turbine"=>turbine,"downgen"=>downgen),
              Dict("turbine"=>"BEN","downgen"=>"BEN"),
              Dict("Head"=>["Down","Down"],"Down"=>["SEA"]))
    c = Nephrite.downstream_energy_coeff(net3)
    @test isapprox(c["Down"], 3.0; atol=1e-9)            # downgen(3)
    # MAX route: 5 + coeff(Down)=3 -> 8.  SUM would be (5+3)+(0+3)=11 -> wrong.
    @test isapprox(c["Head"], 8.0; atol=1e-9)
end

@testset "hydroenergy" begin
    net = toy_net()
    @testset "downstream energy coefficients sum specific power along the chain" begin
        c = Nephrite.downstream_energy_coeff(net)
        @test isapprox(c["UpperLake"], 5.0; atol=1e-9)   # stnA(2) + stnB(3)
        @test isapprox(c["LowerLake"], 3.0; atol=1e-9)   # stnB(3)
    end
    @testset "aggregate stored energy in GWh" begin
        vols = Dict("UpperLake"=>100.0, "LowerLake"=>50.0)
        # E = 100*5*277.778/1000 + 50*3*277.778/1000
        expected = (100*5 + 50*3) * (1e6/3600) / 1000
        @test isapprox(Nephrite.reservoir_energy_gwh(net, vols), expected; rtol=1e-9)
    end
    @testset "initial_volumes round-trips island energy" begin
        # both reservoirs SI; give SI=20 GWh, NI=0; expect reservoir_energy_gwh ≈ 20
        mktempdir() do d
            cfg = joinpath(d, "model.toml"); write(cfg, "[wvanchor]\nweight=0.0\ndecay_weeks=13\n")
            vols = Nephrite.initial_volumes(net, cfg; nz_gwh=20.0, si_gwh=20.0, month=6)
            @test isapprox(Nephrite.reservoir_energy_gwh(net, vols), 20.0; rtol=1e-6)
            @test all(v -> v >= -1e-9, values(vols))
        end
    end
    @testset "initial_volumes rejects SI exceeding NZ" begin
        mktempdir() do d
            cfg = joinpath(d, "model.toml"); write(cfg, "[wvanchor]\nweight=0.0\ndecay_weeks=13\n")
            @test_throws ErrorException Nephrite.initial_volumes(
                net, cfg; nz_gwh=1000.0, si_gwh=2000.0, month=6)
        end
    end
    @testset "initial_volumes rejects negative storage" begin
        mktempdir() do d
            cfg = joinpath(d, "model.toml"); write(cfg, "[wvanchor]\nweight=0.0\ndecay_weeks=13\n")
            @test_throws ErrorException Nephrite.initial_volumes(
                net, cfg; nz_gwh=-100.0, si_gwh=-200.0, month=6)
        end
    end
    @testset "initial_volumes clamps a target above island capacity to full" begin
        # SI energy capacity of toy_net = (100*5 + 50*3)*277.778/1000 ≈ 180.6 GWh.
        # Asking for far more must NOT push any reservoir past its max_volume; it
        # clamps every SI reservoir to full and warns.
        mktempdir() do d
            cfg = joinpath(d, "model.toml"); write(cfg, "[wvanchor]\nweight=0.0\ndecay_weeks=13\n")
            cap_gwh = (100*5 + 50*3) * (1e6/3600) / 1000
            vols = (@test_logs (:warn,) match_mode=:any Nephrite.initial_volumes(
                net, cfg; nz_gwh=10_000.0, si_gwh=10_000.0, month=6))
            @test vols["UpperLake"] <= 100.0 + 1e-6
            @test vols["LowerLake"] <= 50.0 + 1e-6
            @test isapprox(vols["UpperLake"], 100.0; atol=1e-6)   # clamped to full
            @test isapprox(vols["LowerLake"], 50.0;  atol=1e-6)
            @test isapprox(Nephrite.reservoir_energy_gwh(net, vols), cap_gwh; rtol=1e-6)
        end
    end
end

@testset "real-data downstream energy coefficients (chains reconnected)" begin
    jd = Nephrite.load_jade(joinpath(@__DIR__, "..", "data", "static", "jade"),
                            joinpath(@__DIR__, "..", "config", "jade.toml"))
    sm = Nephrite.build_stationmap(jd, joinpath(@__DIR__, "..", "config", "stationmap.toml"))
    net = Nephrite.build_hydronet(jd, sm)
    c = Nephrite.downstream_energy_coeff(net)

    @testset "every reservoir has a strictly positive coefficient" begin
        for r in jd.reservoirs
            @test c[r.name] > 0
        end
    end

    @testset "max-route coefficients match verified targets" begin
        @test isapprox(c["Lake_Tekapo"], 4.14; atol=0.05)
        @test isapprox(c["Lake_Taupo"],  2.47; atol=0.05)
    end
end
