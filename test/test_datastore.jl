using Dates, DataFrames

@testset "datastore" begin
    @testset "opens a complete snapshot and exposes one view per dataset" begin
        mktempdir() do root
            d = Date(2026, 6, 10)
            build_test_snapshot!(root, d)
            ds = Nephrite.open_datastore(root, d)
            try
                offers = Nephrite.query(ds, "SELECT * FROM offers")
                @test nrow(offers) == 199
                prices = Nephrite.query(ds,
                    "SELECT count(*) AS n FROM final_energy_prices")
                @test prices.n[1] == 199
            finally
                close(ds)
            end
        end
    end

    @testset "re-ingested date opens the newest sibling" begin
        mktempdir() do root
            d = Date(2026, 6, 10)
            build_test_snapshot!(root, d)
            registry_path = write_test_registry(mktempdir())
            Nephrite.ingest!(d; root = root, registry_path = registry_path,
                             fetch = fake_fetch)   # creates sibling _2
            ds = Nephrite.open_datastore(root, d)
            try
                @test endswith(ds.dir, "_2")
            finally
                close(ds)
            end
        end
    end

    @testset "refuses to open a missing or incomplete snapshot" begin
        mktempdir() do root
            err = try
                Nephrite.open_datastore(root, Date(2026, 6, 10))
                nothing
            catch e
                e
            end
            @test err isa ErrorException
            @test occursin("ingest!", err.msg)
            dir = Nephrite.create_snapshot!(root, Date(2026, 6, 10))  # not finalized
            err = try
                Nephrite.open_datastore(root, Date(2026, 6, 10))
                nothing
            catch e
                e
            end
            @test err isa ErrorException
            @test occursin("ingest!", err.msg)
        end
    end
end
