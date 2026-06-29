using Dates, DataFrames

# Write a synthetic demand history with enough distinct days to clear a low
# min_history_days threshold. POC codes are reused from the grid_demand fixture
# so build_hubmap resolves them against network_supply_points. Two day-types
# (weekday + weekend) per week across several weeks, constant load.
function write_inputs_test_history(dir::AbstractString)
    mkpath(dir)
    header = "TradingDate,TradingPeriodNumber,IntervalDateTime,RunDateTime,CaseTypeCode,CaseID,PointOfConnectionCode,UnitCode,PlantName,Island,LoadMegawatts,InitialMegawatts,GenerationMegawatts,LocationFactor,DollarsPerMegawattHour,IsDeadFlag,IsDisconnectedFlag"
    # Load-carrying POCs present in the fixture network_supply_points table.
    pocs = ["ALB0331", "ALB1101", "ISL0331", "ISL0661", "INV0331", "HAY0111"]
    # A run of consecutive days to span both weekdays and weekends.
    start = Date(2026, 3, 1)
    for k in 0:13
        date = start + Day(k)
        rows = String[header]
        for tp in 1:48, poc in pocs
            hh = lpad((tp - 1) ÷ 2, 2, '0')
            mm = lpad(((tp - 1) % 2) * 30, 2, '0')
            ts = "$(date)T$hh:$mm:00"
            push!(rows, "$date,$tp,$ts,$ts,RTD,1,$poc,N/A,N/A,NI,100.0,0,0,1.0,50.0,N,N")
        end
        write(joinpath(dir, "$(Dates.format(date, "yyyymmdd"))_grid_demand.csv"),
              join(rows, "\n"))
    end
end

@testset "assemble_inputs" begin
    mktempdir() do root
        d = Date(2026, 6, 10)
        build_test_snapshot!(root, d)
        ds = Nephrite.open_datastore(root, d)
        hist = joinpath(root, "history", "demand")
        write_inputs_test_history(hist)
        cfgdir = joinpath(@__DIR__, "..", "config")
        try
            mi = Nephrite.assemble_inputs(ds, d;
                config_dir = cfgdir, history_dir = hist,
                nz_gwh = 4000.0, si_gwh = 2500.0, n_weeks = 2,
                min_history_days = 10)

            @testset "structure" begin
                @test length(mi.weeks) == 2
                @test all(w -> !isempty(w.periods), mi.weeks)
                @test all(w -> w.inp isa Nephrite.DispatchInputs, mi.weeks)
                @test mi.net isa Nephrite.HydroNetwork
                @test !isempty(mi.initial_vol)
                @test names(mi.terminal_wv) == ["stored_energy", "value"]
                @test nrow(mi.terminal_wv) > 1
                # The terminal curve is read past its `%`-preamble: real numbers.
                @test all(isfinite, mi.terminal_wv.value)
                @test all(isfinite, mi.terminal_wv.stored_energy)
                # 96-period master representative day (48 tp × 2 day-types).
                @test maximum(length(w.periods) for w in mi.weeks) <= 96
                # 336 chronological 30-min subproblem steps (7 days × 48 tp).
                @test all(w -> length(w.periods336) == 336, mi.weeks)
                @test all(w -> all(p -> p.hours == 0.5, w.periods336), mi.weeks)
                # Thermal SRMC curves and a positive lost-load price are present.
                @test all(w -> nrow(w.inp.thermal) > 0, mi.weeks)
                @test all(w -> w.inp.lost_load_price > 0, mi.weeks)
            end

            @testset "per-week inflows present for every reservoir" begin
                for w in mi.weeks, r in mi.net.reservoirs
                    @test haskey(w.inflow_cumecs, r.name)
                end
                # At least one reservoir gets a real (positive) inflow — the
                # name translation against the inflow table actually resolved.
                @test any(v -> v > 0, values(mi.weeks[1].inflow_cumecs))
                # FIX B: Lake_Ohau and Lake_Waikaremoana are JADE network reservoirs
                # that were previously zeroed (not in [inflows.reservoir_columns]).
                # They now have real inflow from the JADE static file.
                ohau_names = [r.name for r in mi.net.reservoirs if r.name == "Lake_Ohau"]
                waik_names = [r.name for r in mi.net.reservoirs if r.name == "Lake_Waikaremoana"]
                if !isempty(ohau_names)
                    @test mi.weeks[1].inflow_cumecs["Lake_Ohau"] > 0
                end
                if !isempty(waik_names)
                    @test mi.weeks[1].inflow_cumecs["Lake_Waikaremoana"] > 0
                end
            end

            @testset "inflow_scale override scales every reservoir inflow" begin
                mi3 = Nephrite.assemble_inputs(ds, d; config_dir = cfgdir,
                    history_dir = hist, nz_gwh = 4000.0, si_gwh = 2500.0,
                    n_weeks = 1, min_history_days = 10,
                    overrides = Dict(:inflow_scale => 2.0))
                base = mi.weeks[1].inflow_cumecs
                scaled = mi3.weeks[1].inflow_cumecs
                for (k, v) in base
                    v > 0 && @test isapprox(scaled[k], 2.0 * v; rtol = 1e-9)
                end
            end

            @testset "hvdc_derate override shrinks the HVDC corridor cap" begin
                mi2 = Nephrite.assemble_inputs(ds, d; config_dir = cfgdir,
                    history_dir = hist, nz_gwh = 4000.0, si_gwh = 2500.0,
                    n_weeks = 1, min_history_days = 10,
                    overrides = Dict(:hvdc_derate => 0.5))
                hvdc1 = only(c for c in mi.weeks[1].inp.topology.corridors if c.kind == "HVDC")
                hvdc2 = only(c for c in mi2.weeks[1].inp.topology.corridors if c.kind == "HVDC")
                @test hvdc2.capacity_fwd_mw < hvdc1.capacity_fwd_mw
                @test isapprox(hvdc2.capacity_fwd_mw, 0.5 * hvdc1.capacity_fwd_mw; rtol = 1e-9)
                @test isapprox(hvdc2.capacity_rev_mw, 0.5 * hvdc1.capacity_rev_mw; rtol = 1e-9)
                # AC corridors are unchanged by the HVDC derate.
                ac1 = first(c for c in mi.weeks[1].inp.topology.corridors if c.kind == "AC")
                ac2 = first(c for c in mi2.weeks[1].inp.topology.corridors if c.kind == "AC")
                @test ac1.capacity_fwd_mw == ac2.capacity_fwd_mw
            end

            @testset "fuel_scale override scales thermal SRMC" begin
                mi4 = Nephrite.assemble_inputs(ds, d; config_dir = cfgdir,
                    history_dir = hist, nz_gwh = 4000.0, si_gwh = 2500.0,
                    n_weeks = 1, min_history_days = 10,
                    overrides = Dict(:fuel_scale => 2.0))
                p1 = sort(mi.weeks[1].inp.thermal.price)
                p4 = sort(mi4.weeks[1].inp.thermal.price)
                @test all(isapprox.(p4, 2.0 .* p1; rtol = 1e-9))
            end

            @testset "assemble_inputs forward_shape skips the history path" begin
                mktempdir() do root
                    d = Date(2026, 6, 10)
                    build_test_snapshot!(root, d)
                    hist = joinpath(root, "history", "demand"); write_inputs_test_history(hist)
                    ds = Nephrite.open_datastore(root, d)
                    cfgdir = joinpath(@__DIR__, "..", "config")
                    try
                        hm = Nephrite.build_hubmap(ds, joinpath(cfgdir, "hubmap.toml"))
                        shape = Nephrite.demand_shape(hist, hm, joinpath(cfgdir, "demand.toml"); min_days = 10)
                        # Pass the shape in AND point history at a non-existent dir: if the
                        # history path were taken, demand_shape would error on the bad dir.
                        mi = Nephrite.assemble_inputs(ds, d; config_dir = cfgdir,
                            history_dir = joinpath(root, "does_not_exist"),
                            nz_gwh = 4000.0, si_gwh = 2500.0, n_weeks = 2,
                            min_history_days = 10, forward_shape = shape)
                        @test length(mi.weeks) == 2
                    finally
                        close(ds)
                    end
                end
            end
        finally
            close(ds)
        end
    end
end
