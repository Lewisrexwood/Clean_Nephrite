using Dates, DataFrames

# Reuses write_inputs_test_history from test_inputs.jl (included earlier in
# runtests.jl) and build_test_snapshot! from util.jl.

@testset "run_model end-to-end (toy horizon)" begin
    mktempdir() do root
        d = Date(2026, 6, 10)
        build_test_snapshot!(root, d)
        hist = joinpath(root, "history", "demand"); write_inputs_test_history(hist)
        rr = Nephrite.run_model(d; root=root, config_dir=joinpath(@__DIR__, "..", "config"),
            history_dir=hist, nz_gwh=4000.0, si_gwh=2500.0, n_weeks=2, seed=7,
            min_history_days=10)

        @testset "produces nodal prices for the horizon" begin
            @test rr.n_weeks == 2
            @test !isempty(rr.prices)
            # prices exist for every hub at week 1 step 1
            for h in Nephrite.HUB_CODES
                @test haskey(rr.prices, (h, 1, 1))
            end
            # the subproblem runs 336 chronological 30-min steps per week
            steps_w1 = sort(unique(s for (h, w, s) in keys(rr.prices) if w == 1))
            @test steps_w1 == collect(1:336)
        end

        @testset "manifest is reproducible and records the run" begin
            @test rr.manifest["seed"] == 7
            @test haskey(rr.manifest, "git_commit")
            @test rr.manifest["nz_gwh"] == 4000.0
            @test rr.manifest["si_gwh"] == 2500.0
            @test rr.manifest["n_weeks"] == 2
            @test isdir(rr.run_dir)
            @test isfile(joinpath(rr.run_dir, "manifest.json"))
        end

        @testset "manifest records auditable curtailment level" begin
            # The toy fixture WILL curtail (JADE must-run ≫ synthetic demand) —
            # we do NOT assert it's zero, only that it is recorded and sane.
            @test haskey(rr.manifest, "curtailment_mwh")
            @test haskey(rr.manifest, "curtailment_fraction")
            cf = rr.manifest["curtailment_fraction"]
            @test cf isa Float64
            @test isfinite(cf)
            @test cf >= 0.0
            @test rr.manifest["curtailment_mwh"] isa Float64
            @test isfinite(rr.manifest["curtailment_mwh"])
            @test rr.manifest["curtailment_mwh"] >= 0.0
        end
    end
end

@testset "_curtailment_audit tolerates 2-tuple soc0 keys (battery present)" begin
    # Regression: a battery makes the subproblem emit ("soc0", b) 2-tuple keys
    # in `generation`.  The audit must not try to destructure those as 3-tuples.
    hubs = [Nephrite.Hub("BEN","BEN2201","Benmore","SI")]
    topo = Nephrite.Topology(hubs, Nephrite.Corridor[])
    net  = Nephrite.HydroNetwork(Nephrite.JadeReservoir[], Nephrite.Arc[],
               Dict{String,Nephrite.HydroStation}(), Dict{String,String}(),
               Dict{String,Vector{String}}())
    thermal = DataFrame(hub=["BEN"], price=[50.0], mw=[1000.0])
    mustrun = DataFrame(hub=String[], mw=Float64[])
    batt = [(name="b", hub="BEN", power_mw=5.0, energy_mwh=10.0, eff=1.0)]
    inp = Nephrite.DispatchInputs(topo, net, thermal, mustrun, batt, 10000.0)
    steps = [Nephrite.Period("s1", 0.5, Dict("BEN"=>10.0)),
             Nephrite.Period("s2", 0.5, Dict("BEN"=>10.0))]
    wk = Nephrite.WeekInputs(Nephrite.Period[], steps, inp, Dict{String,Float64}())

    # generation dict mixing 3-tuple curtail keys with a 2-tuple soc0 key
    gen = Dict{Any,Float64}(
        ("curtail", "BEN", 1) => 4.0,
        ("curtail", "BEN", 2) => 0.0,
        ("gen", 1, 1)         => 6.0,
        ("soc0", 1)           => 2.5,   # <- 2-tuple; crashed the 3-tuple unpack
    )
    res = Nephrite.SubproblemResult(
        Dict{Tuple{String,Int},Float64}(), gen, Dict{Any,Float64}(),
        0.0, Nephrite.JuMP.MOI.OPTIMAL)

    curtail_mwh, demand_mwh, hot = Nephrite._curtailment_audit([res], [wk], 1)
    @test isfinite(curtail_mwh)
    @test isfinite(demand_mwh)
    @test curtail_mwh ≈ 4.0 * 0.5          # only the binding curtail step
    @test demand_mwh ≈ (10.0 + 10.0) * 0.5 # two steps × 10 MW × 0.5 h
    @test hot == ["week 1 hub BEN"]
end

@testset "run_dir is scenario-specific (no cross-scenario clobber)" begin
    # I1 regression: two runs on the same fixture+date+config but DIFFERENT
    # storage inputs must land in DIFFERENT run dirs (else they overwrite each
    # other's manifest/outputs); identical inputs must land in the SAME dir.
    cfgdir = joinpath(@__DIR__, "..", "config")
    run_dir(nz, si) = mktempdir() do root
        d = Date(2026, 6, 10)
        build_test_snapshot!(root, d)
        hist = joinpath(root, "history", "demand"); write_inputs_test_history(hist)
        basename(Nephrite.run_model(d; root=root, config_dir=cfgdir, history_dir=hist,
            nz_gwh=nz, si_gwh=si, n_weeks=2, seed=7, min_history_days=10).run_dir)
    end
    a = run_dir(4000.0, 2500.0)
    b = run_dir(3000.0, 1800.0)
    @test a != b
    # Same scenario inputs ⇒ same run-id (deterministic directory name).
    @test run_dir(4000.0, 2500.0) == a
end

@testset "run_model is deterministic on the same fixture + seed" begin
    cfgdir = joinpath(@__DIR__, "..", "config")
    run_once() = mktempdir() do root
        d = Date(2026, 6, 10)
        build_test_snapshot!(root, d)
        hist = joinpath(root, "history", "demand"); write_inputs_test_history(hist)
        Nephrite.run_model(d; root=root, config_dir=cfgdir, history_dir=hist,
            nz_gwh=4000.0, si_gwh=2500.0, n_weeks=2, seed=7, min_history_days=10).prices
    end
    p1 = run_once()
    p2 = run_once()
    # Value-identical price Dicts across two independent runs.
    @test keys(p1) == keys(p2)
    @test all(p1[k] == p2[k] for k in keys(p1))
end
