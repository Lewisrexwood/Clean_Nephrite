using Test, Nephrite, DataFrames
import SDDP

@testset "fcfsddp" begin
    @testset "_fcf_state_key builds the SDDP state symbol" begin
        @test Nephrite._fcf_state_key("Pukaki") == Symbol("s[Pukaki]")
        @test Nephrite._fcf_state_key("Lake_Taupo") == Symbol("s[Lake_Taupo]")
    end

    @testset "sddp_wv_sampler converts GWh->Mm3, fixes the joint state, reads the dual" begin
        captured = Ref{Any}(nothing)
        # stub: record the evaluation point, return (height, duals) with a known dual for Pukaki
        stub = (V, point) -> begin
            captured[] = point
            return (0.0, Dict(Nephrite._fcf_state_key("Pukaki") => -30.0,
                              Nephrite._fcf_state_key("Hawea")  => -10.0))
        end
        coeff = Dict("Pukaki" => 0.5, "Hawea" => 0.3)
        refvol = Dict("Pukaki" => 1000.0, "Hawea" => 500.0)        # Mm3
        s = Nephrite.sddp_wv_sampler(:dummyV, coeff, refvol; evaluate = stub)

        wv = s("Pukaki", 100.0)                                    # storage_gwh = 100
        expected_vol = 100.0 * 1000 / (0.5 * Nephrite.MWH_PER_MM3_PER_SP)
        @test isapprox(captured[][Nephrite._fcf_state_key("Pukaki")], expected_vol; rtol = 1e-9)
        @test captured[][Nephrite._fcf_state_key("Hawea")] == 500.0   # reference held
        # WV = -dual / (coeff * MWH_PER_MM3_PER_SP) = 30 / (0.5 * M)
        @test isapprox(wv, 30.0 / (0.5 * Nephrite.MWH_PER_MM3_PER_SP); rtol = 1e-9)
        @test refvol["Pukaki"] == 1000.0                           # reference_vol not mutated
    end

    @testset "sddp_wv_sampler returns 0 for a zero-coeff reservoir" begin
        s = Nephrite.sddp_wv_sampler(:dummyV, Dict("X" => 0.0), Dict("X" => 0.0);
                                     evaluate = (V, p) -> error("must not be called"))
        @test s("X", 100.0) == 0.0
    end

    @testset "mean_storage_trajectory: week1=initial, later weeks = mean of prev-week end" begin
        coeff = Dict("L" => 2.0)
        m = Nephrite.MWH_PER_MM3_PER_SP
        # two scenarios; end-of-week storage in Mm3
        traj = [Dict(("L", 1) => 100.0, ("L", 2) => 200.0),
                Dict(("L", 1) => 300.0, ("L", 2) => 400.0)]
        initial = Dict("L" => 50.0)                              # Mm3
        out = Nephrite.mean_storage_trajectory(traj, [1, 2, 3], initial, coeff)
        # week 1 = initial (50 Mm3) -> GWh
        @test isapprox(out[1]["L"], 50.0 * 2.0 * m / 1000; rtol = 1e-9)
        # week 2 = mean end-of-week-1 = mean(100,300)=200 Mm3 -> GWh
        @test isapprox(out[2]["L"], 200.0 * 2.0 * m / 1000; rtol = 1e-9)
        # week 3 = mean end-of-week-2 = mean(200,400)=300 Mm3 -> GWh
        @test isapprox(out[3]["L"], 300.0 * 2.0 * m / 1000; rtol = 1e-9)
    end

    @testset "build_grids: per-reservoir grid from (min,max) GWh" begin
        grids = Nephrite.build_grids(Dict("L" => (0.0, 80.0), "M" => (10.0, 20.0)), 5)
        @test grids["L"] == [0.0, 20.0, 40.0, 60.0, 80.0]
        @test length(grids["M"]) == 5
        @test grids["M"][1] == 10.0 && grids["M"][end] == 20.0
    end

    @testset "reservoir_energy_capacities: finite reservoirs only, in GWh" begin
        # toy net: one finite reservoir L (coeff 1.0 via station g), one ∞ reservoir R
        res  = [Nephrite.JadeReservoir("L", "SI", 0.0, 1000.0),
                Nephrite.JadeReservoir("R", "SI", 0.0, Inf)]
        stnL = Nephrite.HydroStation("g", 1e6, 1.0, [(0.0, 0.0), (1e6, 1e6)])
        arcs = [Nephrite.Arc("L", "SEA", "g", 1e6)]
        net  = Nephrite.HydroNetwork(res, arcs, Dict("g" => stnL),
                   Dict("g" => "BEN"), Dict("L" => ["SEA"], "R" => ["SEA"]))
        caps = Nephrite.reservoir_energy_capacities(net)
        @test haskey(caps, "L")
        @test !haskey(caps, "R")                                # infinite max_volume excluded
        m = Nephrite.MWH_PER_MM3_PER_SP
        @test isapprox(caps["L"][1], 0.0; atol = 1e-9)          # min 0 Mm3
        @test isapprox(caps["L"][2], 1000.0 * 1.0 * m / 1000; rtol = 1e-9)  # max GWh
    end

    @testset "write_run_fcf concatenates per-week curve blocks into one CSV" begin
        results = [
            (week = 1, curves = Dict("L" => Nephrite.Curve("L", [10.0, 20.0], [80.0, 60.0]))),
            (week = 2, curves = Dict("L" => Nephrite.Curve("L", [10.0, 20.0], [70.0, 50.0]))),
        ]
        mktempdir() do dir
            path = joinpath(dir, "fcf_curves.csv")
            Nephrite.write_run_fcf(results, path)
            @test isfile(path)
            back = Nephrite.read_fcf(path)                       # ignores the week column
            @test haskey(back, "L")
            @test length(back["L"].storage_gwh) == 4             # 2 weeks x 2 points
        end
    end

    @testset "run_model extract_fcf=true on :deterministic errors" begin
        @test_throws ErrorException Nephrite.run_model(
            Date(2026, 6, 10);
            root = mktempdir(), config_dir = joinpath(@__DIR__, "..", "config"),
            history_dir = "unused", nz_gwh = 4000.0, si_gwh = 2500.0,
            n_weeks = 2, min_history_days = 10,
            engine = :deterministic, extract_fcf = true)
    end

    @testset "run_model engine=:sddp extract_fcf=true writes fcf_curves.csv" begin
        mktempdir() do root
            d = Date(2026, 6, 10)
            build_test_snapshot!(root, d)
            hist = joinpath(root, "history", "demand"); write_inputs_test_history(hist)
            rr = Nephrite.run_model(d; root = root,
                config_dir = joinpath(@__DIR__, "..", "config"),
                history_dir = hist, nz_gwh = 4000.0, si_gwh = 2500.0,
                n_weeks = 2, seed = 1, min_history_days = 10,
                engine = :sddp, n_scenarios = 4, iteration_limit = 15,
                extract_fcf = true)
            path = joinpath(rr.run_dir, "fcf_curves.csv")
            @test isfile(path)
            back = Nephrite.read_fcf(path)
            @test !isempty(back)                                  # at least one reservoir curve
            cuts = joinpath(rr.run_dir, "fcf_cuts.json")
            @test isfile(cuts)
            @test filesize(cuts) > 0
        end
    end

    @testset "solve_sddp exposes the trained policy; extract_run_fcf produces curves" begin
        # tiny toy: 1 finite reservoir, 1 station, 1 hub, 1 thermal — 2 weeks.
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
        anch  = (values = Dict{String,Float64}(), weights = Nephrite.anchor_weights(13, 2), weight = 0.0)
        mi = Nephrite.ModelInputs(weeks, net, Dict("L" => 500.0), term, anch)
        scen = Dict(t => [Dict("L" => 0.0), Dict("L" => 200.0)] for t in 1:2)

        sr = Nephrite.solve_sddp(mi, scen; n_scenarios = 4, iteration_limit = 20, seed = 1)
        @test sr.policy isa SDDP.PolicyGraph

        cfg = Nephrite.FcfExtractConfig([1, 2, 3, 4], 4, 13, 0.0)   # weeks 3,4 clamp away (nW=2)
        offers = Dict{String,Float64}()                            # unanchored -> rides SDDP
        res_fcf = Nephrite.extract_run_fcf(sr.policy, mi.net, mi.initial_vol,
                                           sr.trajectories, offers, cfg)
        @test [r.week for r in res_fcf] == [1, 2]                  # clamped to n_weeks
        @test haskey(res_fcf[1].curves, "L")
        c = res_fcf[1].curves["L"]
        @test length(c.storage_gwh) == 4                           # grid_points
        @test all(isfinite, c.water_value)
    end

    @testset "extract_run_fcf: coeff==0 reservoir does not cause NaN or zero-division" begin
        # Two reservoirs: L (coeff>0, via station g) and Z (coeff==0, spill-only arc).
        # Z has a finite volume so SDDP allocates a storage state for it, but no
        # downstream station — downstream_energy_coeff returns 0 for Z.
        # The old code omitted Z from refvol (leaving it free in SDDP.evaluate) or
        # divided by coeff==0 (NaN). The fix builds refvol directly from trajectories
        # for ALL reservoirs including Z.
        res  = [Nephrite.JadeReservoir("L", "SI", 0.0, 1000.0),
                Nephrite.JadeReservoir("Z", "SI", 0.0, 500.0)]
        stn  = Nephrite.HydroStation("g", 1e6, 1.0, [(0.0, 0.0), (1e6, 1e6)])
        arcs = [Nephrite.Arc("L", "SEA", "g", 1e6),   # L → turbine → SEA
                Nephrite.Arc("Z", "SEA", "", Inf)]      # Z → spill-only, no station
        net  = Nephrite.HydroNetwork(res, arcs, Dict("g" => stn),
                   Dict("g" => "BEN"), Dict("L" => ["SEA"], "Z" => ["SEA"]))
        hubs = [Nephrite.Hub("BEN", "BEN2201", "Benmore", "SI")]
        topo = Nephrite.Topology(hubs, Nephrite.Corridor[])
        thermal = DataFrame(hub = ["BEN"], price = [200.0], mw = [1e6])
        mustrun = DataFrame(hub = String[], mw = Float64[])
        inp = Nephrite.DispatchInputs(topo, net, thermal, mustrun, NamedTuple[], 10000.0)
        per96  = [Nephrite.Period("p", 1.0, Dict("BEN" => 100.0))]
        per336 = [Nephrite.Period("t$i", 42.0, Dict("BEN" => 100.0)) for i in 1:4]
        wk = Nephrite.WeekInputs(per96, per336, inp, Dict("L" => 0.0, "Z" => 0.0))
        weeks = [wk, wk]
        term  = DataFrame(stored_energy = [0.0, 1e9], value = [0.0, 0.0])
        anch  = (values = Dict{String,Float64}(), weights = Nephrite.anchor_weights(13, 2), weight = 0.0)
        init_vol = Dict("L" => 500.0, "Z" => 300.0)
        mi = Nephrite.ModelInputs(weeks, net, init_vol, term, anch)
        scen = Dict(t => [Dict("L" => 0.0, "Z" => 0.0), Dict("L" => 200.0, "Z" => 0.0)]
                    for t in 1:2)

        sr = Nephrite.solve_sddp(mi, scen; n_scenarios = 4, iteration_limit = 20, seed = 1)
        cfg = Nephrite.FcfExtractConfig([1, 2], 4, 13, 0.0)
        offers = Dict{String,Float64}()
        # Must not error or produce NaN (old code: zero-division / free variable)
        res_fcf = Nephrite.extract_run_fcf(sr.policy, mi.net, mi.initial_vol,
                                           sr.trajectories, offers, cfg)
        @test [r.week for r in res_fcf] == [1, 2]
        @test haskey(res_fcf[1].curves, "L")           # L (coeff>0) gets a curve
        @test !haskey(res_fcf[1].curves, "Z")          # Z (coeff==0) excluded from grids
        @test all(isfinite, res_fcf[1].curves["L"].water_value)
        @test all(isfinite, res_fcf[2].curves["L"].water_value)
    end
end
