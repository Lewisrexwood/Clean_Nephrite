using JuMP, HiGHS, DataFrames, Dates

# ---------------------------------------------------------------------------
# 1-reservoir / 1-station (sp=1) / 1-hub / 1-thermal ($50) toy.
#
#   coeff[L] = sp = 1.0  →  1 Mm³ of L = 1 × MWH_PER_MM3_PER_SP = 277.778 MWh.
#
# Demand is set high and water set scarce so that thermal ($50) runs at the
# margin every week and ALL water is used.  An extra Mm³ in week 1 then
# displaces $50/MWh thermal, so the week-1 storage-balance dual converts to a
# water value of exactly $50/MWh.
# ---------------------------------------------------------------------------
function master_toy(; init_vol, inflow, anchor)
    res  = [Nephrite.JadeReservoir("L", "SI", 0.0, 1e6)]
    stn  = Nephrite.HydroStation("g", 1e6, 1.0, [(0.0, 0.0), (1e6, 1e6)])
    arcs = [Nephrite.Arc("L", "SEA", "g", 1e6)]
    net  = Nephrite.HydroNetwork(res, arcs, Dict("g" => stn),
                Dict("g" => "BEN"), Dict("L" => ["SEA"]))
    hubs = [Nephrite.Hub("BEN", "BEN2201", "Benmore", "SI")]
    topo = Nephrite.Topology(hubs, Nephrite.Corridor[])
    thermal = DataFrame(hub = ["BEN"], price = [50.0], mw = [1000.0])
    mustrun = DataFrame(hub = String[], mw = Float64[])
    inp = Nephrite.DispatchInputs(topo, net, thermal, mustrun, NamedTuple[], 10000.0)

    # 1 period/week, 1 hour, demand 100 MW (=100 MWh/week).
    wk(i) = Nephrite.WeekInputs(
        [Nephrite.Period("w$i", 1.0, Dict("BEN" => 100.0))], inp,
        Dict("L" => Float64(inflow)))
    # Flat/zero terminal value → end storage worth nothing → no hoarding.
    term = DataFrame(stored_energy = [0.0, 1e9], value = [0.0, 0.0])
    init = Dict("L" => Float64(init_vol))
    return Nephrite.solve_master([wk(1), wk(2)], net, init, term, anchor), net
end

@testset "master" begin

    # -----------------------------------------------------------------------
    # Gate 1: water value == displaced SRMC.
    #
    # Demand = 100 MWh/week × 2 = 200 MWh.  Make water scarce: total water
    # energy < 200 MWh so thermal ($50) runs every week and all water is used.
    #   init 0.3 Mm³ → 0.3 × 277.778 = 83.3 MWh
    #   inflow 0 → no extra water.
    # Releasing 1 extra MWh of water in week 1 saves $50 thermal → wv = $50/MWh.
    # -----------------------------------------------------------------------
    @testset "water value equals displaced SRMC" begin
        anchor_off = (values = Dict{String,Float64}(),
                      weights = Nephrite.anchor_weights(13, 2), weight = 0.0)
        res_m, net = master_toy(init_vol = 0.3, inflow = 0.0, anchor = anchor_off)
        @test res_m.status == JuMP.MOI.OPTIMAL
        wv = res_m.water_value[("L", 1)]   # $/MWh
        @test isapprox(wv, 50.0; atol = 1e-3)
    end

    # -----------------------------------------------------------------------
    # Gate 2 (mechanism A): the anchor prices near-term hydro release at its
    # offer-implied value θ as an opportunity cost.  With ample water, hydro is
    # marginal: anchor OFF → costless hydro → near-term price 0; anchor ON at
    # θ=80 (below the $200 thermal backstop) → hydro bids 80 → price 80.
    # -----------------------------------------------------------------------
    @testset "anchor sets near-term price to the offer-implied value (mechanism A)" begin
        hubs = [Nephrite.Hub("BEN","BEN2201","Benmore","SI")]
        topo = Nephrite.Topology(hubs, Nephrite.Corridor[])
        res = [Nephrite.JadeReservoir("L","SI",0.0,1e6)]            # ample storage
        stn = Nephrite.HydroStation("g",1000.0,1.0,[(0.0,0.0),(1000.0,1000.0)])  # ample cap, sp=1
        arcs = [Nephrite.Arc("L","SEA","g",Inf)]
        net = Nephrite.HydroNetwork(res, arcs, Dict("g"=>stn), Dict("g"=>"BEN"), Dict("L"=>["SEA"]))
        thermal = DataFrame(hub=["BEN"], price=[200.0], mw=[1000.0])  # expensive backstop
        mustrun = DataFrame(hub=String[], mw=Float64[])
        inp = Nephrite.DispatchInputs(topo, net, thermal, mustrun, NamedTuple[], 10000.0)
        wk = Nephrite.WeekInputs([Nephrite.Period("p",1.0,Dict("BEN"=>10.0))], inp, Dict("L"=>0.0))
        term = DataFrame(stored_energy=[0.0,1e9], value=[0.0,0.0])   # no terminal value
        init = Dict("L"=>1000.0)   # ample initial water
        # anchor OFF: hydro costless -> near-term price 0
        off = (values=Dict{String,Float64}(), weights=Nephrite.anchor_weights(13,1), weight=0.0)
        r_off = Nephrite.solve_master([wk], net, init, term, off)
        @test isapprox(r_off.price[("BEN",1)], 0.0; atol=1e-6)
        # anchor ON at theta=80, full weight: hydro offered at 80 (<200 thermal) -> price 80
        on = (values=Dict("L"=>80.0), weights=Nephrite.anchor_weights(13,1), weight=1.0)
        r_on = Nephrite.solve_master([wk], net, init, term, on)
        @test isapprox(r_on.price[("BEN",1)], 80.0; atol=1e-6)
    end

    # -----------------------------------------------------------------------
    # Regression: master price units correct when periods have hours ≠ 1.
    #
    # 1 hub (BEN), ample hydro anchored at θ=80, two periods with DIFFERENT
    # hours (2.0 and 1.0) but the SAME demand per-hour (10 MW each).  The
    # marginal price should be 80 $/MWh in both periods.  The hours-weighted
    # mean of the per-period nodal prices is still 80.  Before the fix the
    # formula weighted raw duals (= price × hours) by hours again, giving
    # Σ(80·h²) / Σh = 80·(4+1)/(2+1) ≈ 133.3 ≠ 80.
    # -----------------------------------------------------------------------
    @testset "master price units correct for hours≠1 periods" begin
        hubs   = [Nephrite.Hub("BEN","BEN2201","Benmore","SI")]
        topo   = Nephrite.Topology(hubs, Nephrite.Corridor[])
        res    = [Nephrite.JadeReservoir("L","SI",0.0,1e6)]
        stn    = Nephrite.HydroStation("g",1000.0,1.0,[(0.0,0.0),(1000.0,1000.0)])
        arcs   = [Nephrite.Arc("L","SEA","g",Inf)]
        net    = Nephrite.HydroNetwork(res, arcs, Dict("g"=>stn), Dict("g"=>"BEN"), Dict("L"=>["SEA"]))
        thermal = DataFrame(hub=["BEN"], price=[200.0], mw=[1000.0])
        mustrun = DataFrame(hub=String[], mw=Float64[])
        inp    = Nephrite.DispatchInputs(topo, net, thermal, mustrun, NamedTuple[], 10000.0)
        # Two periods: 2-hour and 1-hour, both at 10 MW demand (same price signal).
        periods = [Nephrite.Period("p1", 2.0, Dict("BEN"=>10.0)),
                   Nephrite.Period("p2", 1.0, Dict("BEN"=>10.0))]
        wk     = Nephrite.WeekInputs(periods, inp, Dict("L"=>0.0))
        term   = DataFrame(stored_energy=[0.0,1e9], value=[0.0,0.0])
        init   = Dict("L"=>1000.0)
        # Anchor ON at θ=80 → hydro marginal at 80 in both periods.
        on = (values=Dict("L"=>80.0), weights=Nephrite.anchor_weights(13,1), weight=1.0)
        r  = Nephrite.solve_master([wk], net, init, term, on)
        @test isapprox(r.price[("BEN",1)], 80.0; atol=1e-4)
    end

    # -----------------------------------------------------------------------
    # FIX 1: battery within-week periodic-close (energy-neutral).
    #
    # 1 hub (BEN), no hydro, one thermal at $50, a battery (power 5, energy 10,
    # eff 1.0).  Two 1-hour periods, each demand 10 MW (=20 MWh total).  Without
    # the weekly close the battery could discharge free energy and crash the
    # price; with it, charge×eff == discharge over the week, so thermal must
    # cover ALL 20 MWh → objective = 20 MWh × $50 = $1000.
    # -----------------------------------------------------------------------
    @testset "battery periodic-close conserves weekly energy" begin
        hubs = [Nephrite.Hub("BEN","BEN2201","Benmore","SI")]
        topo = Nephrite.Topology(hubs, Nephrite.Corridor[])
        net  = Nephrite.HydroNetwork(Nephrite.JadeReservoir[], Nephrite.Arc[],
                   Dict{String,Nephrite.HydroStation}(), Dict{String,String}(),
                   Dict{String,Vector{String}}())
        thermal = DataFrame(hub=["BEN"], price=[50.0], mw=[1000.0])
        mustrun = DataFrame(hub=String[], mw=Float64[])
        batt = [(name="b", hub="BEN", power_mw=5.0, energy_mwh=10.0, eff=1.0)]
        inp = Nephrite.DispatchInputs(topo, net, thermal, mustrun, batt, 10000.0)
        periods = [Nephrite.Period("p1",1.0,Dict("BEN"=>10.0)),
                   Nephrite.Period("p2",1.0,Dict("BEN"=>10.0))]
        wk = Nephrite.WeekInputs(periods, inp, Dict{String,Float64}())
        term = DataFrame(stored_energy=[0.0,1e9], value=[0.0,0.0])
        anchor = (values=Dict{String,Float64}(), weights=Nephrite.anchor_weights(13,1), weight=0.0)
        r = Nephrite.solve_master([wk], net, Dict{String,Float64}(), term, anchor)
        # Battery nets to zero over the week → thermal covers all 20 MWh @ $50.
        @test isapprox(r.objective, 1000.0; atol=1e-6)
    end

end
