using Dates, DataFrames, DuckDB, DBInterface

@testset "ingest" begin
    @testset "registry loads and renders URLs" begin
        specs = Nephrite.load_registry(joinpath(@__DIR__, "..", "config", "datasets.toml"))
        @test length(specs) >= 3
        offers = only(s for s in specs if s.name == "offers")
        @test offers.required
        url = Nephrite.url_for(offers, Date(2026, 6, 10))
        @test url == "https://www.emi.ea.govt.nz/Wholesale/Datasets/BidsAndOffers/Offers/2026/20260610_Offers.csv"
    end

    @testset "ingest! lands all datasets as parquet and finalizes" begin
        mktempdir() do root
            d = Date(2026, 6, 10)
            registry_path = write_test_registry(mktempdir())
            manifest = Nephrite.ingest!(d; root = root, registry_path = registry_path,
                                        fetch = fake_fetch)
            dir = Nephrite.snapshot_dir(root, d)
            @test Nephrite.is_complete(dir)
            names = sort([e["name"] for e in manifest["files"]])
            @test names == ["final_energy_prices.parquet", "final_reserve_prices.parquet",
                            "grid_demand.parquet", "network_supply_points.parquet",
                            "offers.parquet"]
            @test all(e["source"] != "unknown" for e in manifest["files"])
            @test all(e["downloaded_utc"] != "unknown" for e in manifest["files"])

            con = DBInterface.connect(DuckDB.DB)
            try
                p = replace(joinpath(dir, "offers.parquet"), "\\" => "/")
                n = DataFrame(DBInterface.execute(con, "SELECT count(*) AS n FROM read_parquet('$p')")).n[1]
                @test n == 199
            finally
                DBInterface.close!(con)
            end
        end
    end

    @testset "ingest! is all-or-nothing on failure" begin
        mktempdir() do root
            d = Date(2026, 6, 10)
            registry_path = write_test_registry(mktempdir())
            failing_fetch(url, dest) = occursin("FinalReservePrices", url) ?
                error("simulated 404") : fake_fetch(url, dest)
            @test_throws ErrorException Nephrite.ingest!(d; root = root,
                registry_path = registry_path, fetch = failing_fetch)
            dir = Nephrite.snapshot_dir(root, d)
            @test !Nephrite.is_complete(dir)
            @test !isdir(dir)
        end
    end

    @testset "registry carries the ByMonth template and url_bymonth substitutes" begin
        specs = Nephrite.load_registry(joinpath(@__DIR__, "..", "config", "datasets.toml"))
        fep = only(s for s in specs if s.name == "final_energy_prices")
        @test occursin("ByMonth", fep.bymonth_url_template)
        u = Nephrite.url_bymonth(fep, Date(2022, 1, 5))
        @test occursin("202201_FinalEnergyPrices.csv", u)
        @test !occursin("{yyyymm}", u)
        # a dataset without a bymonth template defaults to empty string
        offers = only(s for s in specs if s.name == "offers")
        @test offers.bymonth_url_template == ""
    end

    @testset "historical ingest! slices ByMonth final prices and uses static NSP" begin
        mktempdir() do root
            d = Date(2022, 1, 5)
            # Pin a static network_supply_points table for the historical path.
            mkpath(joinpath(root, "static"))
            cp(joinpath(@__DIR__, "fixtures", "network_supply_points_sample.csv"),
               joinpath(root, "static", "network_supply_points.csv"))
            registry_path = write_test_registry(mktempdir())

            manifest = Nephrite.ingest!(d; root = root, registry_path = registry_path,
                                        fetch = fake_fetch, historical = true)
            dir = Nephrite.snapshot_dir(root, d)
            @test Nephrite.is_complete(dir)

            names = sort([e["name"] for e in manifest["files"]])
            # reserves skipped; the other four present
            @test names == ["final_energy_prices.parquet", "grid_demand.parquet",
                            "network_supply_points.parquet", "offers.parquet"]
            @test !("final_reserve_prices.parquet" in names)

            # final_energy_prices was sliced to the snapshot day only.
            con = DBInterface.connect(DuckDB.DB)
            try
                p = replace(joinpath(dir, "final_energy_prices.parquet"), "\\" => "/")
                df = DataFrame(DBInterface.execute(con,
                    "SELECT DISTINCT TradingDate FROM read_parquet('$p')"))
                @test nrow(df) == 1
                @test df.TradingDate[1] == d            # only 2022-01-05 rows survive
            finally
                DBInterface.close!(con)
            end
        end
    end

    @testset "backfill_snapshots! threads historical and is idempotent" begin
        mktempdir() do root
            mkpath(joinpath(root, "static"))
            cp(joinpath(@__DIR__, "fixtures", "network_supply_points_sample.csv"),
               joinpath(root, "static", "network_supply_points.csv"))
            registry_path = write_test_registry(mktempdir())
            r1 = Nephrite.backfill_snapshots!(Date(2022,1,5), Date(2022,1,5);
                root = root, registry_path = registry_path, stride = 7,
                fetch = fake_fetch, historical = true)
            @test r1.downloaded == 1
            @test Nephrite.is_complete(Nephrite.snapshot_dir(root, Date(2022,1,5)))
            r2 = Nephrite.backfill_snapshots!(Date(2022,1,5), Date(2022,1,5);
                root = root, registry_path = registry_path, stride = 7,
                fetch = fake_fetch, historical = true)
            @test r2.skipped == 1
        end
    end

    @testset "backfill date range generation" begin
        dates = Nephrite.backfill_dates(Date(2026, 1, 1), Date(2026, 1, 10), 3)
        @test dates == [Date(2026, 1, 1), Date(2026, 1, 4), Date(2026, 1, 7), Date(2026, 1, 10)]
        @test_throws ErrorException Nephrite.backfill_dates(Date(2026, 2, 1), Date(2026, 1, 1), 1)

        mktempdir() do root
            registry_path = write_test_registry(mktempdir())
            calls = Ref(0)
            counting_fetch(url, dest) = (calls[] += 1; fake_fetch(url, dest))
            r1 = Nephrite.backfill_demand!(Date(2026, 6, 9), Date(2026, 6, 10);
                root = root, registry_path = registry_path, stride = 1,
                fetch = counting_fetch)
            @test r1.downloaded == 2
            @test isfile(joinpath(root, "history", "demand", "20260609_grid_demand.csv"))
            @test isfile(joinpath(root, "history", "demand", "20260610_grid_demand.csv"))
            r2 = Nephrite.backfill_demand!(Date(2026, 6, 9), Date(2026, 6, 10);
                root = root, registry_path = registry_path, stride = 1,
                fetch = counting_fetch)
            @test r2.skipped == 2
            @test calls[] == 2
        end
    end
end
