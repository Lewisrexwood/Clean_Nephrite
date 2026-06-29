using JuMP, HiGHS, DataFrames

@testset "subproblem spill" begin
    @testset "spill lets the subproblem reach a low end_vol that release alone cannot" begin
        hubs = [Nephrite.Hub("BEN","BEN2201","Benmore","SI")]
        topo = Nephrite.Topology(hubs, Nephrite.Corridor[])
        res = [Nephrite.JadeReservoir("L","SI",0.0,1e6)]
        # tiny station capacity so release alone can't draw the lake down enough
        stn = Nephrite.HydroStation("g", 1.0, 1.0, [(0.0,0.0),(1.0,1.0)])  # 1 MW cap
        arcs = [Nephrite.Arc("L","SEA","g", 1.0)]   # max 1 cumec
        net = Nephrite.HydroNetwork(res, arcs, Dict("g"=>stn), Dict("g"=>"BEN"), Dict("L"=>["SEA"]))
        thermal = DataFrame(hub=["BEN"], price=[50.0], mw=[1000.0])
        mustrun = DataFrame(hub=String[], mw=Float64[])
        inp = Nephrite.DispatchInputs(topo, net, thermal, mustrun, NamedTuple[], 10000.0)
        # 4 steps, demand 10; start 100 Mm3, end 0 — release alone (≤1 cumec) sheds
        # only ~1×0.0036×0.5×4 ≈ 0.0072 Mm3 over the week, far short of 100 → spill needed.
        periods = [Nephrite.Period("s$t", 0.5, Dict("BEN"=>10.0)) for t in 1:4]
        res_sp = Nephrite.solve_subproblem(periods, inp, Dict("L"=>100.0), Dict("L"=>0.0),
                                           Dict("L"=>0.0))
        @test res_sp.objective < Inf                         # feasible (would be Inf without spill)
        @test res_sp.status == JuMP.MOI.OPTIMAL              # solver confirmed OPTIMAL
        # Spill must be positive: released only ~0.0072 Mm³ via arc, spilled ~99.99 Mm³
        total_spill = sum(res_sp.flows[("spill", "L", t)] for t in 1:4)
        @test total_spill > 90.0
    end
end
