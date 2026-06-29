using JuMP, HiGHS, DataFrames, Dates, Statistics
import SDDP

# A tiny 1-reservoir / 1-station / 1-hub / 1-thermal SDDP toy, parameterised by
# the inflow sample set so we can build "dry" vs "wet" variants.  Mirrors the
# master_toy in test_master.jl.
function sddp_toy_graph(; init_vol, inflow_samples, n_stages=3, thermal_price=50.0,
                          demand=100.0, anchor=nothing)
    res  = [Nephrite.JadeReservoir("L", "SI", 0.0, 1e6)]
    stn  = Nephrite.HydroStation("g", 1e6, 1.0, [(0.0, 0.0), (1e6, 1e6)])
    arcs = [Nephrite.Arc("L", "SEA", "g", 1e6)]
    net  = Nephrite.HydroNetwork(res, arcs, Dict("g" => stn),
                Dict("g" => "BEN"), Dict("L" => ["SEA"]))
    hubs = [Nephrite.Hub("BEN", "BEN2201", "Benmore", "SI")]
    topo = Nephrite.Topology(hubs, Nephrite.Corridor[])
    thermal = DataFrame(hub = ["BEN"], price = [thermal_price], mw = [1e6])
    mustrun = DataFrame(hub = String[], mw = Float64[])
    inp  = Nephrite.DispatchInputs(topo, net, thermal, mustrun, NamedTuple[], 10000.0)
    # 1 period/week, 1 hour, demand MW.
    wk = Nephrite.WeekInputs([Nephrite.Period("p", 1.0, Dict("BEN" => demand))],
                             inp, Dict("L" => 0.0))
    weeks = [wk for _ in 1:n_stages]
    term  = DataFrame(stored_energy = [0.0, 1e9], value = [0.0, 0.0])  # no terminal value
    init  = Dict("L" => Float64(init_vol))
    anch  = anchor === nothing ?
            (values = Dict{String,Float64}(),
             weights = Nephrite.anchor_weights(13, n_stages), weight = 0.0) : anchor
    # Same inflow sample set at every stage.
    scen = Dict(t => [Dict("L" => Float64(x)) for x in inflow_samples] for t in 1:n_stages)
    return Nephrite.build_policy_graph(weeks, net, init, term, anch, scen)
end

@testset "sddp engine" begin

    @testset "sddp_lower_bound is finite and non-positive" begin
        net = Nephrite.HydroNetwork(
            [Nephrite.JadeReservoir("L","SI",0.0,1e6)],
            [Nephrite.Arc("L","SEA","g",1e6)],
            Dict("g"=>Nephrite.HydroStation("g",1e6,1.0,[(0.0,0.0),(1e6,1e6)])),
            Dict("g"=>"BEN"), Dict("L"=>["SEA"]))
        term = DataFrame(stored_energy=[0.0, 1e3], value=[0.0, 100.0])
        lb = Nephrite.sddp_lower_bound(net, term)
        @test isfinite(lb)
        @test lb <= 0.0
    end

    @testset "policy graph builds and trains; bound is finite" begin
        g = sddp_toy_graph(init_vol=0.3, inflow_samples=[0.0, 0.0])  # dry, deterministic-ish
        Nephrite.train_policy!(g; iteration_limit=20, seed=1)
        @test isfinite(SDDP.calculate_bound(g))
    end

    @testset "drier inflows raise the trained cost (more thermal needed)" begin
        # Scarce water + low inflow → thermal runs more → higher expected cost than
        # an otherwise-identical water-rich system.
        g_dry = sddp_toy_graph(init_vol=0.1, inflow_samples=[0.0, 5.0])
        g_wet = sddp_toy_graph(init_vol=5.0, inflow_samples=[50.0, 100.0])
        Nephrite.train_policy!(g_dry; iteration_limit=40, seed=1)
        Nephrite.train_policy!(g_wet; iteration_limit=40, seed=1)
        @test SDDP.calculate_bound(g_dry) > SDDP.calculate_bound(g_wet)
    end

    @testset "simulate_policy returns trajectories + inflows of the right shape" begin
        g = sddp_toy_graph(init_vol=1.0, inflow_samples=[2.0, 8.0], n_stages=3)
        Nephrite.train_policy!(g; iteration_limit=30, seed=1)
        traj, infl = Nephrite.simulate_policy(g, 5; seed=1)
        @test length(traj) == 5
        @test length(infl) == 5
        # Each scenario covers 3 weeks for reservoir "L".
        @test all(haskey(traj[i], ("L", w)) for i in 1:5, w in 1:3)
        @test all(haskey(infl[i], ("L", w)) for i in 1:5, w in 1:3)
        # Storage stays within [0, max_volume] = [0, 1e6].
        @test all(0.0 - 1e-6 <= traj[i][("L", w)] <= 1e6 + 1e-6 for i in 1:5, w in 1:3)
        # Realized inflows come from the sample set {2.0, 8.0}.
        @test all(infl[i][("L", w)] in (2.0, 8.0) for i in 1:5, w in 1:3)
    end

    @testset "price_scenarios prices each trajectory at 336-step resolution" begin
        # Reuse the subproblem toy: 1 hub, 1 reservoir, thermal $50/∞, demand 100.
        res  = [Nephrite.JadeReservoir("L","SI",0.0,1e6)]
        stn  = Nephrite.HydroStation("g",1e6,1.0,[(0.0,0.0),(1e6,1e6)])
        arcs = [Nephrite.Arc("L","SEA","g",Inf)]
        net  = Nephrite.HydroNetwork(res, arcs, Dict("g"=>stn),
                   Dict("g"=>"BEN"), Dict("L"=>["SEA"]))
        hubs = [Nephrite.Hub("BEN","BEN2201","Benmore","SI")]
        topo = Nephrite.Topology(hubs, Nephrite.Corridor[])
        thermal = DataFrame(hub=["BEN"], price=[50.0], mw=[1e6])
        mustrun = DataFrame(hub=String[], mw=Float64[])
        inp = Nephrite.DispatchInputs(topo, net, thermal, mustrun, NamedTuple[], 10000.0)
        # 4-step weeks summing to 168 h (matching the SDDP 168-h water budget).
        periods336 = [Nephrite.Period("t$i", 42.0, Dict("BEN"=>100.0)) for i in 1:4]
        wk = Nephrite.WeekInputs(Nephrite.Period[], periods336, inp, Dict("L"=>0.0))
        weeks = [wk, wk]                           # 2 weeks
        init  = Dict("L"=>0.0)
        # 2 scenarios; storage stays 0 throughout, inflow 0 → all thermal.
        traj = [Dict(("L",1)=>0.0, ("L",2)=>0.0), Dict(("L",1)=>0.0, ("L",2)=>0.0)]
        infl = [Dict(("L",1)=>0.0, ("L",2)=>0.0), Dict(("L",1)=>0.0, ("L",2)=>0.0)]
        pd = Nephrite.price_scenarios(weeks, net, init, traj, infl)
        @test haskey(pd, ("BEN", 1, 1))
        @test length(pd[("BEN", 1, 1)]) == 2      # one entry per scenario
        @test all(isapprox(p, 50.0; atol=1e-4) for p in pd[("BEN", 1, 1)])
    end

    @testset "price_scenarios soft-pin fallback prices an otherwise-infeasible week" begin
        # Same toy. Scenario 2 pins week-1 end-storage to 0.5 from start 0 with zero
        # inflow — unreachable, so the hard `fix` is INFEASIBLE.  price_scenarios must
        # fall back to the soft terminal pin and still price every (hub,week,step)
        # for both scenarios rather than throwing.
        res  = [Nephrite.JadeReservoir("L","SI",0.0,1e6)]
        stn  = Nephrite.HydroStation("g",1e6,1.0,[(0.0,0.0),(1e6,1e6)])
        arcs = [Nephrite.Arc("L","SEA","g",Inf)]
        net  = Nephrite.HydroNetwork(res, arcs, Dict("g"=>stn),
                   Dict("g"=>"BEN"), Dict("L"=>["SEA"]))
        hubs = [Nephrite.Hub("BEN","BEN2201","Benmore","SI")]
        topo = Nephrite.Topology(hubs, Nephrite.Corridor[])
        thermal = DataFrame(hub=["BEN"], price=[50.0], mw=[1e6])
        mustrun = DataFrame(hub=String[], mw=Float64[])
        inp = Nephrite.DispatchInputs(topo, net, thermal, mustrun, NamedTuple[], 10000.0)
        periods336 = [Nephrite.Period("t$i", 42.0, Dict("BEN"=>100.0)) for i in 1:4]
        wk = Nephrite.WeekInputs(Nephrite.Period[], periods336, inp, Dict("L"=>0.0))
        weeks = [wk, wk]
        init  = Dict("L"=>0.0)
        traj = [Dict(("L",1)=>0.0, ("L",2)=>0.0),     # scenario 1: feasible (stays 0)
                Dict(("L",1)=>0.5, ("L",2)=>0.5)]      # scenario 2: week-1 pin unreachable
        infl = [Dict(("L",1)=>0.0, ("L",2)=>0.0),
                Dict(("L",1)=>0.0, ("L",2)=>0.0)]
        pd = Nephrite.price_scenarios(weeks, net, init, traj, infl)   # must NOT throw
        @test haskey(pd, ("BEN", 1, 1))
        @test length(pd[("BEN", 1, 1)]) == 2          # both scenarios priced (soft fallback for #2)
        @test length(pd[("BEN", 2, 1)]) == 2
    end

    @testset "solve_sddp produces a price distribution with spread" begin
        # Dry/wet inflow samples on the toy → priced scenarios should differ.
        res  = [Nephrite.JadeReservoir("L","SI",0.0,1e6)]
        stn  = Nephrite.HydroStation("g",1e6,1.0,[(0.0,0.0),(1e6,1e6)])
        arcs = [Nephrite.Arc("L","SEA","g",1e6)]
        net  = Nephrite.HydroNetwork(res, arcs, Dict("g"=>stn),
                   Dict("g"=>"BEN"), Dict("L"=>["SEA"]))
        hubs = [Nephrite.Hub("BEN","BEN2201","Benmore","SI")]
        topo = Nephrite.Topology(hubs, Nephrite.Corridor[])
        # Cheap hydro vs expensive thermal: scarcity (dry) forces $200 thermal.
        thermal = DataFrame(hub=["BEN"], price=[200.0], mw=[1e6])
        mustrun = DataFrame(hub=String[], mw=Float64[])
        inp = Nephrite.DispatchInputs(topo, net, thermal, mustrun, NamedTuple[], 10000.0)
        per96  = [Nephrite.Period("p", 1.0, Dict("BEN"=>100.0))]
        per336 = [Nephrite.Period("t$i", 42.0, Dict("BEN"=>100.0)) for i in 1:4]
        wk = Nephrite.WeekInputs(per96, per336, inp, Dict("L"=>0.0))
        weeks = [wk, wk]
        term  = DataFrame(stored_energy=[0.0,1e9], value=[0.0,0.0])
        anch  = (values=Dict{String,Float64}(), weights=Nephrite.anchor_weights(13,2), weight=0.0)
        mi = Nephrite.ModelInputs(weeks, net, Dict("L"=>0.5), term, anch)
        # Stagewise inflow samples: very dry (0) and wet (200) cumecs.
        scen = Dict(t => [Dict("L"=>0.0), Dict("L"=>200.0)] for t in 1:2)
        r = Nephrite.solve_sddp(mi, scen; n_scenarios=8, iteration_limit=40, seed=1)
        @test isfinite(r.lower_bound)
        @test length(r.trajectories) == 8
        prices_w1 = r.price_dist[("BEN", 1, 1)]
        @test length(prices_w1) == 8
        # Genuine spread: p90 strictly above p10 (the under-dispersion fix).
        @test Statistics.quantile(prices_w1, 0.9) > Statistics.quantile(prices_w1, 0.1)
    end

    @testset "run_model engine=:sddp runs end-to-end and writes a distribution" begin
        mktempdir() do root
            d = Date(2026, 6, 10)
            build_test_snapshot!(root, d)                      # from test/util.jl
            hist = joinpath(root, "history", "demand"); write_inputs_test_history(hist)
            rr = Nephrite.run_model(d; root = root,
                config_dir = joinpath(@__DIR__, "..", "config"),
                history_dir = hist, nz_gwh = 4000.0, si_gwh = 2500.0,
                n_weeks = 2, seed = 1, min_history_days = 10,
                engine = :sddp, n_scenarios = 4, iteration_limit = 15)
            @test rr.price_dist !== nothing
            @test !isempty(rr.price_dist)
            # Each distribution entry has one value per scenario.
            @test all(length(v) == 4 for v in values(rr.price_dist))
            @test isfile(joinpath(rr.run_dir, "forward_curves_dist.csv"))
            # Mean prices populate the point `prices` dict too.
            @test !isempty(rr.prices)
        end
    end

    @testset "checkpointed training resume == uninterrupted (bit-identity arbiter)" begin
        K = 4
        mktempdir() do tmp
            # Uninterrupted: train 4K straight.
            gA = sddp_toy_graph(init_vol=1.0, inflow_samples=[2.0, 8.0], n_stages=3)
            Nephrite.train_checkpointed!(gA, joinpath(tmp, "straight");
                                         iteration_limit=4K, chunk_iters=K, seed=7)
            bound_straight = SDDP.calculate_bound(gA)

            # Resume: train to 2K (checkpoint), then a FRESH graph continues to 4K.
            gB = sddp_toy_graph(init_vol=1.0, inflow_samples=[2.0, 8.0], n_stages=3)
            Nephrite.train_checkpointed!(gB, joinpath(tmp, "resume");
                                         iteration_limit=2K, chunk_iters=K, seed=7)
            gC = sddp_toy_graph(init_vol=1.0, inflow_samples=[2.0, 8.0], n_stages=3)
            Nephrite.train_checkpointed!(gC, joinpath(tmp, "resume");
                                         iteration_limit=4K, chunk_iters=K, seed=7)
            bound_resume = SDDP.calculate_bound(gC)

            # Bit-identity arbiter: resume must reproduce the uninterrupted bound.
            # If this fails, DO NOT loosen silently — record the residual
            # (bound_straight - bound_resume) and report it; the spec's claim
            # downgrades to "RNG-reproducible, near-identical (Δ=…)".
            @test isapprox(bound_straight, bound_resume; atol=1e-9)
        end
    end
end
