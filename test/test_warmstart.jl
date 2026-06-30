using Test, Nephrite, DataFrames
import SDDP

@testset "warmstart" begin
    # --- Toy net: L has a downstream station (coeff>0); Z is spill-only (coeff==0). ---
    function _toy_net()
        res  = [Nephrite.JadeReservoir("L", "SI", 0.0, 1000.0),
                Nephrite.JadeReservoir("Z", "SI", 0.0, 500.0)]
        stn  = Nephrite.HydroStation("g", 1e6, 1.0, [(0.0, 0.0), (1e6, 1e6)])
        arcs = [Nephrite.Arc("L", "SEA", "g", 1e6),
                Nephrite.Arc("Z", "SEA", "", Inf)]
        return Nephrite.HydroNetwork(res, arcs, Dict("g" => stn),
                   Dict("g" => "BEN"), Dict("L" => ["SEA"], "Z" => ["SEA"]))
    end

    @testset "wv_warmstart_cuts builds point-slope cuts with the dual sign convention" begin
        net = _toy_net()
        m   = Nephrite.MWH_PER_MM3_PER_SP
        wv  = Dict("L" => 50.0, "Z" => 40.0)        # Z is coeff==0 → excluded
        avol = Dict("L" => 500.0, "Z" => 300.0)
        cuts = Nephrite.wv_warmstart_cuts(net, avol, wv, [1.0, 0.5], -10.0)

        @test length(cuts) == 2                      # one block per week
        @test cuts[1]["node"] == "1"
        @test cuts[2]["node"] == "2"

        sc1 = cuts[1]["single_cuts"][1]
        @test sc1["intercept"] == -10.0             # height == lb at the anchor
        @test isapprox(sc1["coefficients"]["s[L]"], 1.0 * (-50.0 * 1.0 * m); rtol = 1e-9)
        @test sc1["state"]["s[L]"] == 500.0
        @test !haskey(sc1["coefficients"], "s[Z]")  # coeff==0 reservoir excluded
        @test !haskey(sc1["state"], "s[Z]")
        @test keys(sc1["coefficients"]) == keys(sc1["state"])  # identical key sets

        sc2 = cuts[2]["single_cuts"][1]
        @test isapprox(sc2["coefficients"]["s[L]"], 0.5 * (-50.0 * 1.0 * m); rtol = 1e-9)

        @test cuts[1]["multi_cuts"] == Dict{String,Any}[]
        @test cuts[1]["risk_set_cuts"] == Vector{Float64}[]
    end

    @testset "wv_warmstart_cuts skips empty/zero priors" begin
        net = _toy_net()
        @test isempty(Nephrite.wv_warmstart_cuts(net, Dict("L" => 500.0),
                          Dict{String,Float64}(), [1.0, 0.5], -10.0))     # no WV at all
        @test isempty(Nephrite.wv_warmstart_cuts(net, Dict("L" => 500.0),
                          Dict("L" => 0.0), [1.0], -10.0))                # WV == 0 → skip
        @test isempty(Nephrite.wv_warmstart_cuts(net, Dict("Z" => 300.0),
                          Dict("Z" => 40.0), [1.0], -10.0))               # only coeff==0 → skip
    end

    # --- A 2-week toy policy graph used by injection + selector tests. ---
    function _toy_graph_inputs()
        res  = [Nephrite.JadeReservoir("L", "SI", 0.0, 1000.0)]
        stn  = Nephrite.HydroStation("g", 1e6, 1.0, [(0.0, 0.0), (1e6, 1e6)])
        arcs = [Nephrite.Arc("L", "SEA", "g", 1e6)]
        net  = Nephrite.HydroNetwork(res, arcs, Dict("g" => stn),
                   Dict("g" => "BEN"), Dict("L" => ["SEA"]))
        hubs = [Nephrite.Hub("BEN", "BEN2201", "Benmore", "SI")]
        topo = Nephrite.Topology(hubs, Nephrite.Corridor[])
        thermal = DataFrame(hub = ["BEN"], price = [200.0], mw = [1e6])
        mustrun = DataFrame(hub = String[], mw = Float64[])
        inp = Nephrite.DispatchInputs(topo, net, thermal, mustrun, NamedTuple[], 10000.0)
        per96  = [Nephrite.Period("p", 1.0, Dict("BEN" => 100.0))]
        per336 = [Nephrite.Period("t$i", 42.0, Dict("BEN" => 100.0)) for i in 1:4]
        wk = Nephrite.WeekInputs(per96, per336, inp, Dict("L" => 0.0))
        weeks = [wk, wk]
        term  = DataFrame(stored_energy = [0.0, 1e9], value = [0.0, 0.0])
        anch  = (values = Dict("L" => 30.0),
                 weights = Nephrite.anchor_weights(13, 2), weight = 1.0)
        mi   = Nephrite.ModelInputs(weeks, net, Dict("L" => 500.0), term, anch)
        scen = Dict(t => [Dict("L" => 0.0), Dict("L" => 200.0)] for t in 1:2)
        return mi, scen
    end

    @testset "apply_wv_warmstart! adds the cut into the node value function" begin
        mi, scen = _toy_graph_inputs()
        graph = Nephrite.build_policy_graph(mi.weeks, mi.net, mi.initial_vol,
                                            mi.terminal_wv, mi.anchor, scen)
        lb   = Nephrite.sddp_lower_bound(mi.net, mi.terminal_wv)
        cuts = Nephrite.wv_warmstart_cuts(mi.net, mi.initial_vol, mi.anchor.values,
                                          mi.anchor.weights, lb)
        @test !isempty(cuts)
        n_before = length(graph[1].bellman_function.global_theta.cuts)
        Nephrite.apply_wv_warmstart!(graph, cuts)
        n_after = length(graph[1].bellman_function.global_theta.cuts)
        @test n_after > n_before
        @test isfinite(SDDP.calculate_bound(graph))
    end

    @testset "apply_wv_warmstart! is a no-op on empty cuts" begin
        mi, scen = _toy_graph_inputs()
        graph = Nephrite.build_policy_graph(mi.weeks, mi.net, mi.initial_vol,
                                            mi.terminal_wv, mi.anchor, scen)
        n_before = length(graph[1].bellman_function.global_theta.cuts)
        g2 = Nephrite.apply_wv_warmstart!(graph, Dict{String,Any}[])
        @test g2 === graph
        @test length(graph[1].bellman_function.global_theta.cuts) == n_before
    end
end
