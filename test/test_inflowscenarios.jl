using Dates, DataFrames, Statistics

@testset "inflow scenarios" begin
    # A toy net with two reservoirs whose names match JADE catchment columns.
    # Use the test-suite's lightweight constructors (JadeReservoir(name, island, min, max)).
    res = [Nephrite.JadeReservoir("Lake_Taupo", "NI", 0.0, 1e6),
           Nephrite.JadeReservoir("Lake_Pukaki", "SI", 0.0, 1e6)]
    net = Nephrite.HydroNetwork(res, Nephrite.Arc[],
        Dict{String,Nephrite.HydroStation}(), Dict{String,String}(),
        Dict{String,Vector{String}}())
    # jade_to_cfg maps JADE/net name -> config reservoir-table name.
    jade_to_cfg = Dict("Lake_Taupo" => "Taupo", "Lake_Pukaki" => "Pukaki")

    @testset "inflow_scenarios_from_frame builds one realization per year, keyed by net name" begin
        # Two years (1990, 1991), one week-of-year (woy=10), two config reservoirs.
        by_year = DataFrame(
            reservoir = ["Taupo","Taupo","Pukaki","Pukaki"],
            year      = [1990, 1991, 1990, 1991],
            woy       = [10, 10, 10, 10],
            inflow    = [100.0, 200.0, 50.0, 70.0])
        # Ask for two stages, both mapping to woy=10.
        sc = Nephrite.inflow_scenarios_from_frame(by_year, net, jade_to_cfg, [10, 10])
        @test sort(collect(keys(sc))) == [1, 2]
        # Stage 1: two equiprobable realizations (one per year).
        @test length(sc[1]) == 2
        # Each realization is keyed by NET reservoir name and carries both reservoirs.
        taupo_vals = sort([r["Lake_Taupo"] for r in sc[1]])
        pukaki_vals = sort([r["Lake_Pukaki"] for r in sc[1]])
        @test taupo_vals == [100.0, 200.0]
        @test pukaki_vals == [50.0, 70.0]
    end

    @testset "reservoir absent from the table samples as 0 cumecs" begin
        res3 = [Nephrite.JadeReservoir("Lake_Taupo","NI",0.0,1e6),
                Nephrite.JadeReservoir("Lake_Missing","SI",0.0,1e6)]
        net3 = Nephrite.HydroNetwork(res3, Nephrite.Arc[],
            Dict{String,Nephrite.HydroStation}(), Dict{String,String}(),
            Dict{String,Vector{String}}())
        by_year = DataFrame(reservoir=["Taupo","Taupo"], year=[1990,1991],
                            woy=[10,10], inflow=[100.0,200.0])
        sc = Nephrite.inflow_scenarios_from_frame(by_year, net3,
                Dict("Lake_Taupo"=>"Taupo"), [10])
        @test all(r["Lake_Missing"] == 0.0 for r in sc[1])
        @test sort([r["Lake_Taupo"] for r in sc[1]]) == [100.0, 200.0]
    end

    @testset "load_inflows_by_year averages back to load_inflows" begin
        cfg = joinpath(@__DIR__, "..", "config", "reservoirs.toml")
        by_year = Nephrite.load_inflows_by_year(cfg)
        @test names(by_year) == ["reservoir", "year", "woy", "inflow"]
        @test all(1 .<= by_year.woy .<= 53)
        # Averaging over years per (reservoir, woy) reproduces load_inflows.
        avg = combine(groupby(by_year, [:reservoir, :woy]), :inflow => mean => :inflow)
        ref = Nephrite.load_inflows(cfg)
        m_avg = Dict((r.reservoir, r.woy) => r.inflow for r in eachrow(avg))
        m_ref = Dict((r.reservoir, r.woy) => r.inflow for r in eachrow(ref))
        @test keys(m_avg) == keys(m_ref)
        @test all(isapprox(m_avg[k], m_ref[k]; atol=1e-6) for k in keys(m_ref))
    end
end
