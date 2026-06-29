using Dates, JSON3

@testset "manifest" begin
    mktempdir() do root
        d = Date(2026, 6, 10)
        dir = build_test_snapshot!(root, d)
        config = joinpath(@__DIR__, "..", "config", "topology.toml")

        m = Nephrite.build_manifest(snapshot_dir = dir,
                                    config_paths = [config], seed = 42)

        @testset "captures git state" begin
            @test occursin(r"^[0-9a-f]{40}$", m["git_commit"]) || m["git_commit"] == "unknown"
            @test m["git_dirty"] isa Bool
        end

        @testset "captures environment and inputs" begin
            @test m["julia_version"] == string(VERSION)
            @test length(m["pkg_manifest_sha256"]) == 64
            @test m["seed"] == 42
            @test length(m["snapshot_files"]) == 5
            @test length(m["config_hashes"][config]) == 64
            @test DateTime(m["created_utc"]) isa DateTime
        end

        @testset "round-trips through JSON" begin
            path = joinpath(root, "manifest.json")
            Nephrite.write_manifest(path, m)
            back = JSON3.read(read(path, String))
            @test back["seed"] == 42
            @test back["git_commit"] == m["git_commit"]
            required = ["created_utc", "git_commit", "git_dirty", "julia_version",
                        "pkg_manifest_sha256", "snapshot_dir", "snapshot_files",
                        "config_hashes", "seed"]
            @test all(haskey(back, k) for k in required)
            @test back["git_dirty"] isa Bool
            @test length(back["snapshot_files"]) == 5
            @test all(length(f["sha256"]) == 64 for f in back["snapshot_files"])
        end
    end
end
