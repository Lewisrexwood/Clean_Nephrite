using Dates, DataFrames

@testset "hubmap" begin
    mktempdir() do root
        d = Date(2026, 6, 10)
        build_test_snapshot!(root, d)
        ds = Nephrite.open_datastore(root, d)
        cfg = joinpath(@__DIR__, "..", "config", "hubmap.toml")
        try
            hm = Nephrite.build_hubmap(ds, cfg)

            @testset "every fixture POC resolves to a known hub" begin
                hubs = Set(["OTA", "WKM", "RDF", "HAY", "KIK", "ISL", "BEN", "INV"])
                @test !isempty(hm.poc_to_hub)
                @test all(h in hubs for h in values(hm.poc_to_hub))
            end

            @testset "lookup and miss behaviour" begin
                poc = first(keys(hm.poc_to_hub))
                @test Nephrite.hub_for(hm, poc) in
                      ["OTA", "WKM", "RDF", "HAY", "KIK", "ISL", "BEN", "INV"]
                @test_throws ErrorException Nephrite.hub_for(hm, "ZZZ9999")
            end

            @testset "multi-region POC resolves via override, not alphabetical default" begin
                @test Nephrite.hub_for(hm, "OKN0111") == "WKM"
            end

            @testset "null-region-only POC resolves via override" begin
                # KAW2201 has only null-region rows; its override must win over unmapped.
                @test Nephrite.hub_for(hm, "KAW2201") == "WKM"
            end
        finally
            close(ds)
        end
    end

    @testset "unmapped region fails loudly" begin
        mktempdir() do d
            bad = joinpath(d, "hubmap_bad.toml")
            good = read(joinpath(@__DIR__, "..", "config", "hubmap.toml"), String)
            # Remove all region/override assignments: loader must refuse to default.
            # `\r?` tolerates CRLF working-tree line endings (git autocrlf on Windows);
            # without it the strip is a no-op and the loader wrongly resolves everything.
            stripped = replace(good, r"(?m)^\"[^\"]+\" = \"[A-Z]{3}\"\r?$" => "")
            write(bad, stripped)
            mktempdir() do root
                build_test_snapshot!(root, Date(2026, 6, 10))
                ds = Nephrite.open_datastore(root, Date(2026, 6, 10))
                try
                    @test_throws ErrorException Nephrite.build_hubmap(ds, bad)
                finally
                    close(ds)
                end
            end
        end
    end

    @testset "unresolved multi-hub POC fails loudly" begin
        mktempdir() do dtmp
            # Build a config whose region map sends two regions of one POC to different hubs,
            # with that POC's override removed.
            good = read(joinpath(@__DIR__, "..", "config", "hubmap.toml"), String)
            # Depends on fixture network_supply_points_sample.csv containing OKN0111 with both its King Country and Whanganui rows (the reproducible conflict).
            # Remove the OKN0111 override line so the conflict is exposed.
            stripped = replace(good, r"(?m)^\"OKN0111\".*$" => "")
            bad = joinpath(dtmp, "hubmap_conflict.toml")
            write(bad, stripped)
            mktempdir() do root
                build_test_snapshot!(root, Date(2026, 6, 10))
                ds = Nephrite.open_datastore(root, Date(2026, 6, 10))
                try
                    @test_throws "span multiple hubs" Nephrite.build_hubmap(ds, bad)
                finally
                    close(ds)
                end
            end
        end
    end
end
