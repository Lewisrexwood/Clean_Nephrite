using Dates, DataFrames, Statistics, Random

@testset "jadecompare" begin
    # Two reservoirs whose net names map to config names.
    res = [Nephrite.JadeReservoir("Lake_Taupo", "NI", 0.0, 1e6),
           Nephrite.JadeReservoir("Lake_Pukaki", "SI", 0.0, 1e6)]
    net = Nephrite.HydroNetwork(res, Nephrite.Arc[],
        Dict{String,Nephrite.HydroStation}(), Dict{String,String}(),
        Dict{String,Vector{String}}())
    jade_to_cfg = Dict("Lake_Taupo" => "Taupo", "Lake_Pukaki" => "Pukaki")

    @testset "historical_inflow_sequences traces one coherent year chronologically" begin
        # Encode inflow as year*1000 + woy so each (year,woy) value is identifiable.
        # Cover config reservoirs Taupo & Pukaki, years 1990 & 1991, weeks 1..52.
        rows = NamedTuple[]
        for cfg in ("Taupo","Pukaki"), y in (1990,1991), w in 1:52
            push!(rows, (reservoir=cfg, year=y, woy=w, inflow=Float64(y*1000 + w)))
        end
        by_year = DataFrame(rows)
        # Snapshot 2022-12-19 (Monday). Stage woys via Dates.week: 51,52,1,2.
        # Calendar-year offset 0,0,1,1 → start-year 1990 uses years 1990,1990,1991,1991.
        snap = Date(2022, 12, 19); nW = 4
        seqs = Nephrite.historical_inflow_sequences(by_year, net, jade_to_cfg, snap, nW)

        # start-year 1990 is usable (last stage needs year 1991, present).
        @test haskey(seqs, 1990)
        s = seqs[1990]
        @test length(s) == 4
        # Each stage keyed by NET reservoir name, carrying both reservoirs.
        @test Set(keys(s[1])) == Set(["Lake_Taupo", "Lake_Pukaki"])
        # Expected (year,woy) per stage from the same Dates mapping:
        expected = [(Dates.week(snap + Day(7*(t-1))),
                     1990 + (year(snap + Day(7*(t-1))) - year(snap))) for t in 1:nW]
        for t in 1:nW
            woy, yr = expected[t]
            @test isapprox(s[t]["Lake_Taupo"],  yr*1000 + woy; atol=1e-9)
            @test isapprox(s[t]["Lake_Pukaki"], yr*1000 + woy; atol=1e-9)
        end

        # start-year 1991 needs year 1992 at the rolled-over stages → absent → dropped.
        @test !haskey(seqs, 1991)
    end

    @testset "missing reservoir in a year samples 0 cumecs" begin
        # Taupo present for 1990 all weeks; Pukaki absent entirely.
        rows = NamedTuple[]
        for w in 1:52
            push!(rows, (reservoir="Taupo", year=1990, woy=w, inflow=100.0))
        end
        by_year = DataFrame(rows)
        snap = Date(2022, 6, 6); nW = 2   # mid-year, no rollover → only year 1990 needed
        seqs = Nephrite.historical_inflow_sequences(by_year, net, jade_to_cfg, snap, nW)
        @test haskey(seqs, 1990)
        @test all(st["Lake_Pukaki"] == 0.0 for st in seqs[1990])
        @test all(st["Lake_Taupo"] == 100.0 for st in seqs[1990])
    end

    @testset "replay_historical replays each sequence's coherent inflow + storage" begin
        # Reuse the SDDP toy graph builder from test_sddp.jl (included earlier in
        # runtests.jl): 1 reservoir "L", 1 hub, thermal, sampled inflows {2.0, 8.0}.
        g = sddp_toy_graph(init_vol = 1.0, inflow_samples = [2.0, 8.0], n_stages = 3)
        Nephrite.train_policy!(g; iteration_limit = 20, seed = 1)
        # Two coherent sequences over the toy's 3 stages, using in-support values.
        sequences = Dict(
            1990 => [Dict("L" => 2.0), Dict("L" => 2.0), Dict("L" => 2.0)],   # all-dry
            1991 => [Dict("L" => 8.0), Dict("L" => 8.0), Dict("L" => 8.0)])    # all-wet
        storage_by_seq, inflow_by_seq = Nephrite.replay_historical(g, sequences)
        @test Set(keys(storage_by_seq)) == Set([1990, 1991])
        @test Set(keys(inflow_by_seq))  == Set([1990, 1991])
        # Each sequence has storage for ("L", 1:3) within [0, 1e6], and the recorded
        # inflow equals the supplied coherent trace.
        for Y in (1990, 1991)
            @test all(haskey(storage_by_seq[Y], ("L", w)) for w in 1:3)
            @test all(0.0 - 1e-6 <= storage_by_seq[Y][("L", w)] <= 1e6 + 1e-6 for w in 1:3)
        end
        @test all(inflow_by_seq[1990][("L", w)] == 2.0 for w in 1:3)
        @test all(inflow_by_seq[1991][("L", w)] == 8.0 for w in 1:3)
    end

    @testset "storage_fan aggregates per (start_year, week) to GWh" begin
        # 1-reservoir net with coeff 1.0 (station sp=1 on L→SEA).
        res2 = [Nephrite.JadeReservoir("L", "SI", 0.0, 1e6)]
        stn  = Nephrite.HydroStation("g", 1e6, 1.0, [(0.0,0.0),(1e6,1e6)])
        net2 = Nephrite.HydroNetwork(res2, [Nephrite.Arc("L","SEA","g",1e6)],
            Dict("g"=>stn), Dict("g"=>"BEN"), Dict("L"=>["SEA"]))
        storage_by_seq = Dict(
            1990 => Dict(("L",1)=>10.0, ("L",2)=>20.0),
            1991 => Dict(("L",1)=>30.0, ("L",2)=>40.0))
        fan = Nephrite.storage_fan(storage_by_seq, net2, 2)
        @test Set(names(fan)) == Set(["start_year","week","agg_gwh"])
        @test nrow(fan) == 4                                  # 2 years × 2 weeks
        # agg_gwh = reservoir_energy_gwh(net, Dict("L"=>vol)); monotone in storage.
        row = only(fan[(fan.start_year .== 1990) .& (fan.week .== 1), :])
        @test isapprox(row.agg_gwh,
            Nephrite.reservoir_energy_gwh(net2, Dict("L"=>10.0)); atol=1e-9)
        @test row.agg_gwh > 0
    end

    @testset "select_price_sequences picks a dry→wet spread / stride / all" begin
        # Total inflow per start-year: 1990 driest, 1993 wettest.
        sequences = Dict(
            1990 => [Dict("L"=>1.0)], 1991 => [Dict("L"=>2.0)],
            1992 => [Dict("L"=>3.0)], 1993 => [Dict("L"=>4.0)])
        # all=true → every start-year, sorted.
        @test Nephrite.select_price_sequences(sequences; all=true) == [1990,1991,1992,1993]
        # n=2 → spread endpoints present (driest + wettest), length 2, sorted.
        sel = Nephrite.select_price_sequences(sequences; n=2)
        @test length(sel) == 2
        @test 1990 in sel && 1993 in sel
        @test issorted(sel)
        # stride=2 → every 2nd by start-year.
        @test Nephrite.select_price_sequences(sequences; stride=2) == [1990, 1992]
    end

    @testset "cal_year_annual_base means a calendar year's base price per sequence" begin
        # snapshot 2022-12-19; week 1 step 1 = 2022-12-19 00:00 (year 2022),
        # week 3 lands in 2023. Build two scenarios (start_years 1990, 1991).
        snap = Date(2022, 12, 19)
        pd = Dict{Tuple{String,Int,Int},Vector{Float64}}(
            ("OTA", 1, 1) => [10.0, 100.0],   # 2022 → excluded from 2023 mean
            ("OTA", 3, 1) => [20.0, 200.0],   # 2023
            ("OTA", 3, 2) => [40.0, 400.0])   # 2023
        # Confirm week 3 step 1 is in 2023 for this snapshot (sanity within test):
        @test year(Nephrite._step_ts(snap, 3, 1)) == 2023
        df = Nephrite.cal_year_annual_base(pd, snap, 3, 2023, [1990, 1991])
        @test Set(names(df)) == Set(["start_year","hub","annual_base"])
        # Sequence 1 (start_year 1990): mean of 2023 OTA steps = (20+40)/2 = 30.
        v1 = only(df[(df.start_year .== 1990) .& (df.hub .== "OTA"), :annual_base])
        @test isapprox(v1, 30.0; atol=1e-9)
        # Sequence 2 (start_year 1991): (200+400)/2 = 300.
        v2 = only(df[(df.start_year .== 1991) .& (df.hub .== "OTA"), :annual_base])
        @test isapprox(v2, 300.0; atol=1e-9)
    end

    @testset "trajectories parquet round-trip" begin
        storage = Dict(1990 => Dict(("L",1)=>10.0, ("L",2)=>20.0, ("M",1)=>5.0),
                       1991 => Dict(("L",1)=>30.0, ("L",2)=>40.0, ("M",1)=>7.0))
        inflow  = Dict(1990 => Dict(("L",1)=>2.0,  ("L",2)=>3.0,  ("M",1)=>1.0),
                       1991 => Dict(("L",1)=>8.0,  ("L",2)=>9.0,  ("M",1)=>4.0))
        mktempdir() do dir
            p = joinpath(dir, "trajectories.parquet")
            Nephrite.save_trajectories(p, storage, inflow)
            @test isfile(p)
            s2, i2 = Nephrite.load_trajectories(p)
            @test s2 == storage
            @test i2 == inflow
        end
    end

    @testset "det-overlay / progress / rng-state round-trips" begin
        mktempdir() do dir
            # det overlay
            det = Dict("OTA"=>137.9, "BEN"=>113.5)
            dp = joinpath(dir, "det_overlay.csv")
            Nephrite.save_det_overlay(dp, det)
            @test Nephrite.load_det_overlay(dp) == det

            # progress
            prog = Dict("snapshot"=>"2022-01-05", "iters_target"=>100,
                        "train_samples"=>10, "n_weeks"=>104,
                        "master_done"=>true, "train_iters_done"=>50, "replay_done"=>false)
            pp = joinpath(dir, "progress.json")
            Nephrite.save_progress(pp, prog)
            got = Nephrite.load_progress(pp)
            @test got["snapshot"] == "2022-01-05"
            @test got["train_iters_done"] == 50
            @test got["master_done"] == true
            @test got["replay_done"] == false

            # rng state: save → advance → restore → identical draws
            rp = joinpath(dir, "rng_state.json")
            Random.seed!(123)
            Nephrite.save_rng_state(rp)
            a = [rand() for _ in 1:5]
            Random.seed!(999)                 # perturb
            Nephrite.restore_rng_state!(rp)
            b = [rand() for _ in 1:5]
            @test a == b
        end
    end
end
