@testset "topology" begin
    path = joinpath(@__DIR__, "..", "config", "topology.toml")
    topo = Nephrite.load_topology(path)

    @testset "loads 8 FTR hubs" begin
        @test length(topo.hubs) == 8
        @test sort(Nephrite.hub_codes(topo)) ==
              ["BEN", "HAY", "INV", "ISL", "KIK", "OTA", "RDF", "WKM"]
    end

    @testset "islands are sane" begin
        ni = [h.code for h in topo.hubs if h.island == "NI"]
        @test sort(ni) == ["HAY", "OTA", "RDF", "WKM"]
    end

    @testset "corridors reference known hubs and the network is connected" begin
        codes = Nephrite.hub_codes(topo)
        @test all(c.from in codes && c.to in codes for c in topo.corridors)
        @test Nephrite.isconnected(topo)
    end

    @testset "exactly one HVDC corridor, between HAY and BEN" begin
        hvdc = [c for c in topo.corridors if c.kind == "HVDC"]
        @test length(hvdc) == 1
        @test Set([hvdc[1].from, hvdc[1].to]) == Set(["HAY", "BEN"])
    end

    @testset "validation rejects bad input" begin
        mktempdir() do d
            bad = joinpath(d, "bad.toml")
            write(bad, """
            [[hubs]]
            code = "OTA"
            node = "OTA2201"
            name = "Otahuhu"
            island = "NI"

            [[corridors]]
            from = "OTA"
            to = "NOPE"
            capacity_fwd_mw = 100.0
            capacity_rev_mw = 100.0
            loss_factor = 0.03
            kind = "AC"
            """)
            @test_throws ErrorException Nephrite.load_topology(bad)
        end

        mktempdir() do d
            bad = joinpath(d, "bad_island.toml")
            write(bad, """
            [[hubs]]
            code = "OTA"
            node = "OTA2201"
            name = "Otahuhu"
            island = "XX"
            """)
            @test_throws ErrorException Nephrite.load_topology(bad)
        end

        mktempdir() do d
            bad = joinpath(d, "bad_cap.toml")
            write(bad, """
            [[hubs]]
            code = "OTA"
            node = "OTA2201"
            name = "Otahuhu"
            island = "NI"

            [[hubs]]
            code = "BEN"
            node = "BEN2201"
            name = "Benmore"
            island = "SI"

            [[corridors]]
            from = "OTA"
            to = "BEN"
            capacity_fwd_mw = 0.0
            capacity_rev_mw = 100.0
            loss_factor = 0.03
            kind = "AC"
            """)
            @test_throws ErrorException Nephrite.load_topology(bad)
        end
    end
end
