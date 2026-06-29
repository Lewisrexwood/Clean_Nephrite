using Dates

@testset "snapshots" begin
    @testset "create + finalize writes hashed snapshot.json" begin
        mktempdir() do root
            d = Date(2026, 6, 10)
            dir = Nephrite.create_snapshot!(root, d)
            @test isdir(dir)
            @test endswith(dir, joinpath("snapshots", "2026-06-10"))
            @test !Nephrite.is_complete(dir)

            write(joinpath(dir, "offers.parquet"), "fake-bytes")
            manifest = Nephrite.finalize_snapshot!(dir;
                sources = Dict("offers.parquet" => "https://example.test/offers"))
            @test Nephrite.is_complete(dir)
            @test length(manifest["files"]) == 1
            entry = manifest["files"][1]
            @test entry["name"] == "offers.parquet"
            @test entry["source"] == "https://example.test/offers"
            @test length(entry["sha256"]) == 64
            @test entry["sha256"] == Nephrite.file_sha256(joinpath(dir, "offers.parquet"))
            @test entry["downloaded_utc"] == "unknown"
        end
    end

    @testset "finalized snapshots are immutable; same-date recreate makes a sibling" begin
        mktempdir() do root
            d = Date(2026, 6, 10)
            dir1 = Nephrite.create_snapshot!(root, d)
            write(joinpath(dir1, "offers.parquet"), "v1")
            Nephrite.finalize_snapshot!(dir1; sources = Dict{String,String}())

            dir2 = Nephrite.create_snapshot!(root, d)
            @test dir2 != dir1
            @test endswith(dir2, "2026-06-10_2")
        end
    end

    @testset "refuses to finalize an empty snapshot" begin
        mktempdir() do root
            dir = Nephrite.create_snapshot!(root, Date(2026, 6, 10))
            @test_throws ErrorException Nephrite.finalize_snapshot!(dir;
                sources = Dict{String,String}())
        end
    end

    @testset "subdirectories are ignored when finalizing" begin
        mktempdir() do root
            dir = Nephrite.create_snapshot!(root, Date(2026, 6, 10))
            write(joinpath(dir, "offers.parquet"), "bytes")
            mkpath(joinpath(dir, "stray_subdir"))
            manifest = Nephrite.finalize_snapshot!(dir;
                sources = Dict{String,String}())
            @test [e["name"] for e in manifest["files"]] == ["offers.parquet"]
        end
    end

    @testset "latest_snapshot_dir resolves the newest finalized sibling" begin
        mktempdir() do root
            d = Date(2026, 6, 10)
            @test_throws ErrorException Nephrite.latest_snapshot_dir(root, d)

            dir1 = Nephrite.create_snapshot!(root, d)
            write(joinpath(dir1, "offers.parquet"), "v1")
            Nephrite.finalize_snapshot!(dir1; sources = Dict{String,String}())
            @test Nephrite.latest_snapshot_dir(root, d) == dir1

            dir2 = Nephrite.create_snapshot!(root, d)
            write(joinpath(dir2, "offers.parquet"), "v2")
            Nephrite.finalize_snapshot!(dir2; sources = Dict{String,String}())
            @test Nephrite.latest_snapshot_dir(root, d) == dir2
        end
    end
end
