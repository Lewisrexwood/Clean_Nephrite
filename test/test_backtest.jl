using Dates, DataFrames, Statistics

@testset "backtest helpers" begin
    @testset "model_week1_hubs averages week-1 prices per hub" begin
        prices = Dict{Tuple{String,Int,Int},Float64}(
            ("OTA",1,1)=>100.0, ("OTA",1,2)=>120.0,   # week 1 OTA mean 110
            ("BEN",1,1)=>50.0,                          # week 1 BEN
            ("OTA",2,1)=>999.0)                         # week 2 ignored
        m = Nephrite.model_week1_hubs(prices)
        @test isapprox(m["OTA"], 110.0; atol=1e-9)
        @test isapprox(m["BEN"], 50.0; atol=1e-9)
        @test !haskey(m, "WKM")
    end

    @testset "fully_covered_years returns calendar years entirely inside the horizon" begin
        # 104 weeks = 728 days, which can never span two FULL calendar years
        # (that needs >=730 days), so a 104-week horizon yields exactly one year.
        # From 2022-06-15 → to 2024-06-12: 2023 is fully inside; 2022/2024 partial.
        @test Nephrite.fully_covered_years(Date(2022,6,15), 104) == [2023]
        # From 2022-12-20 → to 2024-12-17: 2023 fully inside; 2024 loses Dec 18-31.
        @test Nephrite.fully_covered_years(Date(2022,12,20), 104) == [2023]
        # A longer horizon (105 weeks from 2023-01-01 → 2025-01-05) covers two
        # full years, exercising the multi-year branch.
        @test Nephrite.fully_covered_years(Date(2023,1,1), 105) == [2023, 2024]
    end

    @testset "realised_annual_spot means the daily spot series over a year" begin
        fdf = DataFrame(settlement_date=[Date(2023,1,1),Date(2023,7,1),Date(2024,1,1)],
            location=["Otahuhu","Otahuhu","Otahuhu"], hub=["OTA","OTA","OTA"],
            duration=["N/A","N/A","N/A"], commodity=["N/A","N/A","N/A"],
            series=fill("Simple daily average spot price",3), price=[100.0,200.0,500.0])
        @test isapprox(Nephrite.realised_annual_spot(fdf, 2023, "OTA"), 150.0; atol=1e-9)  # (100+200)/2
        @test isapprox(Nephrite.realised_annual_spot(fdf, 2024, "OTA"), 500.0; atol=1e-9)
    end

    @testset "bt_pearson" begin
        @test isapprox(Nephrite.bt_pearson([1.0,2.0,3.0],[2.0,4.0,6.0]), 1.0; atol=1e-9)
        @test isapprox(Nephrite.bt_pearson([1.0,2.0,3.0],[3.0,2.0,1.0]), -1.0; atol=1e-9)
    end

    @testset "score_near_term" begin
        # Two dates, 3 hubs. Date 1: model exactly +10 over realised at every hub
        # AND model ranks hubs the same as realised (corr +1). Date 2: model inverts
        # the ranking (corr -1) with bias 0.
        near = DataFrame(
            date = [Date(2023,1,1),Date(2023,1,1),Date(2023,1,1),
                    Date(2023,2,1),Date(2023,2,1),Date(2023,2,1)],
            hub  = ["OTA","BEN","WKM","OTA","BEN","WKM"],
            model    = [110.0,60.0,210.0, 50.0,100.0,150.0],
            realised = [100.0,50.0,200.0, 150.0,100.0,50.0])
        rows, summary = Nephrite.score_near_term(near)
        @test "bias" in names(rows)
        @test isapprox(summary["mean_bias_by_hub"]["OTA"], (10.0 + (-100.0))/2; atol=1e-9)
        cbd = summary["corr_by_date"]
        @test isapprox(only(cbd[cbd.date .== Date(2023,1,1), :corr]),  1.0; atol=1e-9)
        @test isapprox(only(cbd[cbd.date .== Date(2023,2,1), :corr]), -1.0; atol=1e-9)
        @test isapprox(summary["mean_corr"], 0.0; atol=1e-9)
    end

    @testset "score_forward three-way (BASE)" begin
        # forward_df: a BASE calendar-year quote and a spot series for OTA, year 2023.
        fdf = DataFrame(
            settlement_date = [Date(2022,6,1), Date(2022,6,10),          # market quotes (use nearest ≤ date)
                               Date(2023,1,1), Date(2023,7,1)],          # spot series for realised
            location = fill("Otahuhu",4), hub = fill("OTA",4),
            duration = ["Quarterly","Quarterly","N/A","N/A"],
            commodity = ["Base","Base","N/A","N/A"],
            series = ["2023 Calendar year","2023 Calendar year",
                      "Simple daily average spot price","Simple daily average spot price"],
            price = [150.0, 160.0, 200.0, 220.0])      # market nearest ≤ 2022-06-15 = 160; realised 2023 = 210
        # model says 2023 will be 180 (below market 160? no, above). Set up a clean edge case:
        #   market_fwd=160, model_fwd=140 (model says market RICH), realised=210.
        #   realised_dev = market−realised = 160−210 = −50 (market was CHEAP, not rich).
        #   model_signal = market−model = 160−140 = +20 (model says rich). signs differ → WRONG.
        fm = DataFrame(date=[Date(2022,6,15)], year=[2023], hub=["OTA"],
                       product=["base"], model_fwd=[140.0])
        @test isapprox(Nephrite.market_annual_base(fdf, Date(2022,6,15), 2023, "OTA"), 160.0; atol=1e-9)
        rows, summary = Nephrite.score_forward(fm, fdf)
        r = only(eachrow(rows))
        @test isapprox(r.market_fwd, 160.0; atol=1e-9)
        @test isapprox(r.realised,   210.0; atol=1e-9)
        @test isapprox(r.model_err,  140.0-210.0; atol=1e-9)   # −70
        @test isapprox(r.market_err, 160.0-210.0; atol=1e-9)   # −50
        @test r.hit == false                                    # signs of signal vs dev differ
        @test isapprox(summary["hit_rate"], 0.0; atol=1e-9)
        @test isapprox(summary["pnl"], sign(160.0-140.0)*(160.0-210.0); atol=1e-9)   # +1*(−50) = −50
        @test summary["n_points"] == 1
        @test isapprox(summary["rmse_model"], 70.0; atol=1e-9)
        @test isapprox(summary["rmse_market"], 50.0; atol=1e-9)
    end

    @testset "score_forward counts a correct-side call as a hit" begin
        # market_fwd=160, model_fwd=140 (model says market RICH), realised=120
        # (market WAS rich: realised below market). signal +20, dev +40 → same sign → HIT.
        # pnl = sign(+20)·(160−120) = +40 (short the rich future, settles lower → profit).
        fdf = DataFrame(
            settlement_date = [Date(2022,6,10), Date(2023,1,1), Date(2023,7,1)],
            location = fill("Otahuhu",3), hub = fill("OTA",3),
            duration = ["Quarterly","N/A","N/A"], commodity = ["Base","N/A","N/A"],
            series = ["2023 Calendar year",
                      "Simple daily average spot price","Simple daily average spot price"],
            price = [160.0, 100.0, 140.0])      # realised 2023 = (100+140)/2 = 120
        fm = DataFrame(date=[Date(2022,6,15)], year=[2023], hub=["OTA"],
                       product=["base"], model_fwd=[140.0])
        rows, summary = Nephrite.score_forward(fm, fdf)
        r = only(eachrow(rows))
        @test isapprox(r.realised, 120.0; atol=1e-9)
        @test r.hit == true
        @test isapprox(summary["hit_rate"], 1.0; atol=1e-9)
        @test isapprox(summary["pnl"], 40.0; atol=1e-9)
    end
end

@testset "score_backtest combines both layers" begin
    bt = Nephrite.BacktestResult(
        DataFrame(date=[Date(2023,1,1),Date(2023,1,1)], hub=["OTA","BEN"],
                  model=[110.0,60.0], realised=[100.0,50.0]),
        DataFrame(date=[Date(2022,6,15)], year=[2023], hub=["OTA"],
                  product=["base"], model_fwd=[140.0]),
        [Date(2022,6,15)])
    fdf = DataFrame(
        settlement_date=[Date(2022,6,10),Date(2023,1,1),Date(2023,7,1)],
        location=fill("Otahuhu",3), hub=fill("OTA",3),
        duration=["Quarterly","N/A","N/A"], commodity=["Base","N/A","N/A"],
        series=["2023 Calendar year","Simple daily average spot price","Simple daily average spot price"],
        price=[160.0,200.0,220.0])
    near_term, forward, summary = Nephrite.score_backtest(bt, fdf)
    @test "bias" in names(near_term)
    @test summary["near_term"]["mean_bias_by_hub"]["OTA"] == 10.0
    @test summary["forward"]["n_points"] == 1
    @test haskey(summary["forward"], "hit_rate")
end

@testset "run_backtest end-to-end + resumable (toy horizon)" begin
    mktempdir() do root
        d = Date(2026, 6, 10)
        build_test_snapshot!(root, d)
        hist = joinpath(root, "history", "demand"); write_inputs_test_history(hist)
        cache = joinpath(root, "btcache")
        storage_at(_d) = (4000.0, 2500.0)
        bt = Nephrite.run_backtest([d]; root=root,
            config_dir=joinpath(@__DIR__, "..", "config"), history_dir=hist,
            storage_at=storage_at, n_weeks=2, min_history_days=10, cache_dir=cache)
        @test names(bt.near_term) == ["date","hub","model","realised"]
        @test nrow(bt.near_term) >= 1                 # at least one hub scored
        @test all(bt.near_term.date .== d)
        @test isdir(cache) && !isempty(readdir(cache))   # per-date cache written
        # n_weeks=2 covers no full calendar year → forward_model may be empty; shape still correct
        @test names(bt.forward_model) == ["date","year","hub","product","model_fwd"]

        # Resumable: re-run must NOT re-solve (cache hit). Prove by deleting the
        # snapshot so a real solve would error; the cached run still succeeds.
        rm(Nephrite.snapshot_dir(root, d); recursive=true, force=true)
        bt2 = Nephrite.run_backtest([d]; root=root,
            config_dir=joinpath(@__DIR__, "..", "config"), history_dir=hist,
            storage_at=storage_at, n_weeks=2, min_history_days=10, cache_dir=cache)
        @test nrow(bt2.near_term) == nrow(bt.near_term)
        @test names(bt2.near_term) == ["date","hub","model","realised"]
        @test names(bt2.forward_model) == ["date","year","hub","product","model_fwd"]  # sentinel reload keeps schema
    end
end
