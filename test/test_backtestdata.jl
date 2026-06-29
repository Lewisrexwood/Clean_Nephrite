using Dates, DataFrames

@testset "backtestdata" begin
    @testset "backtest_dates is weekly by default" begin
        d = Nephrite.backtest_dates(Date(2024,1,1), Date(2024,1,22))
        @test d == [Date(2024,1,1), Date(2024,1,8), Date(2024,1,15), Date(2024,1,22)]
    end

    @testset "backtest_coverage flags per-date presence" begin
        mktempdir() do root
            # Two probe dates: an EMPTY date before any data exists (2023-06-01,
            # which precedes the HMD fixture series start of 2023-12-31), and a
            # FULL date (2024-01-08) with a real snapshot, storage, and a forward quote.
            empty_date = Date(2023,6,1)
            full_date  = Date(2024,1,8)
            build_test_snapshot!(root, full_date)         # snapshot only for the full date

            net = _hmd_toy_net()                          # defined in test_hmdstorage.jl
            lake_map = Dict("toy_upper.csv" => ["UpperLake"], "toy_lower.csv" => ["LowerLake"])
            storage = Nephrite.build_hmd_provider(joinpath(@__DIR__, "fixtures", "hmd"),
                                                  net; lake_map = lake_map)
            # forward frame: a single quote settled on 2024-01-06 (after empty_date,
            # on/before full_date).
            forward = DataFrame(settlement_date = [Date(2024,1,6)], location = ["Otahuhu"],
                hub = ["OTA"], duration = ["Monthly"], commodity = ["Base"],
                series = ["Jan 2025"], price = [150.0])

            cov = Nephrite.backtest_coverage([empty_date, full_date];
                root = root, storage = storage, forward = forward)
            @test names(cov) == ["date","has_snapshot","has_storage","has_forward"]
            pre  = cov[cov.date .== empty_date, :]
            full = cov[cov.date .== full_date, :]
            @test only(pre.has_snapshot)  == false
            @test only(full.has_snapshot) == true
            @test only(pre.has_storage)   == false    # before the HMD series starts (2023-12-31)
            @test only(full.has_storage)  == true
            @test only(pre.has_forward)   == false    # no quote on or before 2023-06-01
            @test only(full.has_forward)  == true
        end
    end
end
