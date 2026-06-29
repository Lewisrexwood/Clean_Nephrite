using JuMP, HiGHS, DataFrames, Dates, Statistics

# ---------------------------------------------------------------------------
# Helper: build a 2-hub topology with a single BEN→OTA corridor
# ---------------------------------------------------------------------------
function two_hub_inputs(cap)
    hubs = [Nephrite.Hub("OTA", "OTA2201", "Otahuhu", "NI"),
            Nephrite.Hub("BEN", "BEN2201", "Benmore", "SI")]
    corr = [Nephrite.Corridor("BEN", "OTA", cap, cap, 0.0, "AC")]
    topo = Nephrite.Topology(hubs, corr)
    net  = Nephrite.HydroNetwork(
        Nephrite.JadeReservoir[],
        Nephrite.Arc[],
        Dict{String,Nephrite.HydroStation}(),
        Dict{String,String}(),
        Dict{String,Vector{String}}(),
    )
    thermal = DataFrame(hub=["BEN","OTA"], price=[10.0,100.0], mw=[1000.0,1000.0])
    mustrun = DataFrame(hub=String[], mw=Float64[])
    return Nephrite.DispatchInputs(topo, net, thermal, mustrun, NamedTuple[], 10000.0)
end

@testset "dispatch" begin

    # -----------------------------------------------------------------------
    # 2-hub price separation with a binding transmission cap
    # Cheap gen at BEN ($10), dear gen at OTA ($100).
    # Demand: OTA=120, BEN=0. BEN→OTA cap = 50 MW (binding).
    # BEN exports 50 → OTA self-supplies 70 at $100.
    # Expected: price(BEN)=$10, price(OTA)=$100.
    # -----------------------------------------------------------------------
    @testset "2-hub price separation with binding transmission" begin
        inp = two_hub_inputs(50.0)
        p   = Nephrite.Period("p", 1.0, Dict("OTA"=>120.0, "BEN"=>0.0))
        m   = Model(HiGHS.Optimizer)
        set_silent(m)
        v = Nephrite.build_dispatch!(m, [p], inp)
        @objective(m, Min, Nephrite.dispatch_cost(m, [p], inp, v))
        optimize!(m)
        @test termination_status(m) == MOI.OPTIMAL
        @test isapprox(dual(v.balance["BEN", 1]), 10.0;  atol=1e-6)
        @test isapprox(dual(v.balance["OTA", 1]), 100.0; atol=1e-6)
    end

    # -----------------------------------------------------------------------
    # Unbinding transmission: cap 1000 MW — all cheap BEN gen flows, prices equalise.
    # Expected: price(BEN)=price(OTA)=$10.
    # -----------------------------------------------------------------------
    @testset "unbinding transmission equalises price" begin
        inp = two_hub_inputs(1000.0)
        p   = Nephrite.Period("p", 1.0, Dict("OTA"=>120.0, "BEN"=>0.0))
        m   = Model(HiGHS.Optimizer)
        set_silent(m)
        v = Nephrite.build_dispatch!(m, [p], inp)
        @objective(m, Min, Nephrite.dispatch_cost(m, [p], inp, v))
        optimize!(m)
        @test termination_status(m) == MOI.OPTIMAL
        @test isapprox(dual(v.balance["OTA", 1]), 10.0; atol=1e-6)
        @test isapprox(dual(v.balance["BEN", 1]), 10.0; atol=1e-6)
    end

    # -----------------------------------------------------------------------
    # bucket_demand: synthetic week, constant 100 MW weekday / 50 MW weekend at OTA.
    # 2026-06-15 is a Monday → weekdays: Mon–Fri (5 days), weekend: Sat–Sun (2 days).
    # Expect: 96 periods (2 day-types × 48 TPs).
    # Weekday hours sum = 5 × 0.5 × 48 = 120.
    # Weekend hours sum = 2 × 0.5 × 48 = 48.
    # Total hours = 168.
    # -----------------------------------------------------------------------
    @testset "bucket_demand period counts and hour weights" begin
        week_start = Date(2026, 6, 15)   # Monday
        days = [week_start + Day(k) for k in 0:6]
        # 48 TPs per day, 7 days, hubs = ["OTA"]
        rows = []
        for d in days
            mw = dayofweek(d) <= 5 ? 100.0 : 50.0
            for tp in 1:48
                push!(rows, (date=d, tp=tp, hub="OTA", mw=mw))
            end
        end
        fd = DataFrame(rows)

        periods = Nephrite.bucket_demand(fd, week_start)

        @test length(periods) == 96   # 2 day-types × 48 TPs

        weekday_hrs = sum(p.hours for p in periods if startswith(p.label, "weekday"))
        weekend_hrs = sum(p.hours for p in periods if startswith(p.label, "weekend"))
        @test isapprox(weekday_hrs, 120.0; atol=1e-10)   # 5 × 0.5 × 48
        @test isapprox(weekend_hrs,  48.0; atol=1e-10)   # 2 × 0.5 × 48
        @test isapprox(weekday_hrs + weekend_hrs, 168.0;  atol=1e-10)

        # Demand values are correctly averaged
        wd_p = first(p for p in periods if startswith(p.label, "weekday"))
        we_p = first(p for p in periods if startswith(p.label, "weekend"))
        @test isapprox(wd_p.demand["OTA"], 100.0; atol=1e-10)
        @test isapprox(we_p.demand["OTA"],  50.0; atol=1e-10)
    end

    # -----------------------------------------------------------------------
    # Hydro capacity cap: station with Inf-flow arc, cap 30 MW, demand 50 MW.
    # Without C1 fix hydro supplies all 50 (price=0). With fix, hydro is capped
    # at 30 MW and dear thermal ($100) supplies the remaining 20 → price=100.
    # -----------------------------------------------------------------------
    @testset "hydro generation capped at station capacity_mw even with Inf-flow arc" begin
        hubs = [Nephrite.Hub("BEN", "BEN2201", "Benmore", "SI")]
        topo = Nephrite.Topology(hubs, Nephrite.Corridor[])
        res  = [Nephrite.JadeReservoir("L", "SI", 0.0, 1e6)]
        stn  = Nephrite.HydroStation("g", 30.0, 1.0, [(0.0, 0.0), (30.0, 30.0)])  # cap 30 MW
        arcs = [Nephrite.Arc("L", "SEA", "g", Inf)]   # Inf hydraulic limit
        net  = Nephrite.HydroNetwork(
            res,
            arcs,
            Dict("g" => stn),
            Dict("g" => "BEN"),
            Dict("L" => ["SEA"]),
        )
        thermal = DataFrame(hub=["BEN"], price=[100.0], mw=[1000.0])  # dear backup
        mustrun = DataFrame(hub=String[], mw=Float64[])
        inp = Nephrite.DispatchInputs(topo, net, thermal, mustrun, NamedTuple[], 10000.0)
        p = Nephrite.Period("p", 1.0, Dict("BEN" => 50.0))   # demand 50 > hydro cap 30
        m = Model(HiGHS.Optimizer); set_silent(m)
        v = Nephrite.build_dispatch!(m, [p], inp)
        @objective(m, Min, Nephrite.dispatch_cost(m, [p], inp, v))
        optimize!(m)
        @test termination_status(m) == MOI.OPTIMAL
        # hydro generation = arcflow × specific_power must be ≤ 30 (capped)
        ai = 1
        @test value(v.arcflow[ai, 1]) * 1.0 <= 30.0 + 1e-6
        # dear thermal sets price at margin
        @test isapprox(dual(v.balance["BEN", 1]), 100.0; atol=1e-6)
    end

end
