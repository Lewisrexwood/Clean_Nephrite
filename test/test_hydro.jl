using Dates, DataFrames

@testset "hydro" begin
    cfg = joinpath(@__DIR__, "..", "config", "reservoirs.toml")

    @testset "reservoir config loads and shares are sane" begin
        res = Nephrite.load_reservoirs(cfg)
        @test length(res.reservoirs) == 6
        @test all(r -> r.island in ("NI", "SI"), res.reservoirs)
        @test all(r -> r.hub in Nephrite.HUB_CODES, res.reservoirs)
        @test all(r -> length(r.monthly_share) == 12, res.reservoirs)
        for m in 1:12
            si = sum(r.monthly_share[m] for r in res.reservoirs if r.island == "SI")
            @test isapprox(si, 1.0; atol = 0.02)
            ni = sum(r.monthly_share[m] for r in res.reservoirs if r.island == "NI")
            @test isapprox(ni, 1.0; atol = 0.02)
        end
    end

    @testset "storage_state disaggregates operator-supplied aggregates" begin
        # Operator supplies NZ and SI aggregate storage (GWh).
        state = Nephrite.storage_state(cfg; nz_gwh = 4000.0, si_gwh = 2500.0,
                                       month = 6)
        @test names(state) == ["reservoir", "island", "hub", "gwh"]
        @test nrow(state) == 6
        @test all(state.gwh .>= 0)
        # SI lakes sum to the SI aggregate; NI (Taupo) = NZ - SI.
        @test isapprox(sum(state.gwh[state.island .== "SI"]), 2500.0; atol = 1.0)
        @test isapprox(sum(state.gwh[state.island .== "NI"]), 1500.0; atol = 1.0)
    end

    @testset "storage_state rejects SI exceeding NZ" begin
        @test_throws ErrorException Nephrite.storage_state(cfg; nz_gwh = 1000.0,
                                                           si_gwh = 2000.0, month = 6)
    end

    @testset "storage_state rejects negative storage" begin
        @test_throws ErrorException Nephrite.storage_state(cfg; nz_gwh = -100.0,
                                                           si_gwh = -200.0, month = 6)
    end

    @testset "weekly inflows load from the JADE static file" begin
        inflows = Nephrite.load_inflows(cfg)
        @test names(inflows) == ["reservoir", "woy", "inflow"]
        @test all(1 .<= inflows.woy .<= 52)
        @test all(inflows.inflow .>= 0)
        # 8 unique reservoirs: 6 storage-state lakes + Lake_Ohau + Lake_Waikaremoana
        # (the latter two are JADE network reservoirs with their own inflow columns,
        # added to [inflows.reservoir_columns] in FIX B so they get real inflow).
        @test length(unique(inflows.reservoir)) == 8
        # each reservoir has up to 52-53 weekly means
        @test nrow(inflows) >= 8 * 50
    end
end
