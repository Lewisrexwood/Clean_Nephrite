using Dates, DataFrames

"Write a tiny synthetic history: two Mondays + two Saturdays, constant load."
function write_test_history(dir::AbstractString)
    mkpath(dir)
    header = "TradingDate,TradingPeriodNumber,IntervalDateTime,RunDateTime,CaseTypeCode,CaseID,PointOfConnectionCode,UnitCode,PlantName,Island,LoadMegawatts,InitialMegawatts,GenerationMegawatts,LocationFactor,DollarsPerMegawattHour,IsDeadFlag,IsDisconnectedFlag"
    for (date, mw) in [(Date(2026, 1, 5), 100.0), (Date(2026, 1, 12), 100.0),
                       (Date(2026, 1, 10), 50.0), (Date(2026, 1, 17), 50.0)]
        rows = String[header]
        for tp in 1:2, m in 0:5:25
            ts = "$(date)T$(lpad((tp - 1) ÷ 2, 2, '0')):$(lpad(((tp - 1) % 2) * 30 + m, 2, '0')):00"
            push!(rows, "$date,$tp,$ts,$ts,RTD,1,TST0001,,Test,NI,$mw,0,0,1.0,50.0,false,false")
        end
        write(joinpath(dir, "$(Dates.format(date, "yyyymmdd"))_grid_demand.csv"),
              join(rows, "\n"))
    end
end

@testset "profile" begin
    mktempdir() do tmp
        hist = joinpath(tmp, "history", "demand")
        write_test_history(hist)
        poc_to_hub = Dict("TST0001" => "OTA")
        hm = Nephrite.HubMap(poc_to_hub)
        cfg = joinpath(@__DIR__, "..", "config", "demand.toml")

        shape = Nephrite.demand_shape(hist, hm, cfg; min_days = 2)

        @testset "shape distinguishes day types" begin
            @test names(shape) == ["hub", "woy", "daytype", "tp", "mw"]
            wk = shape[(shape.daytype .== "weekday") .& (shape.tp .== 1), :mw]
            we = shape[(shape.daytype .== "weekend") .& (shape.tp .== 1), :mw]
            @test all(isapprox.(wk, 100.0; rtol = 1e-6))
            @test all(isapprox.(we, 50.0; rtol = 1e-6))
        end

        @testset "forward projection applies growth" begin
            fwd = Nephrite.forward_demand(shape, Date(2026, 6, 15), 2; growth = 0.10)
            @test names(fwd) == ["date", "tp", "hub", "mw"]
            d1 = Date(2026, 6, 15)            # Monday
            d2 = d1 + Dates.Week(52)          # Monday, ~same week-of-year
            m1 = fwd[(fwd.date .== d1) .& (fwd.tp .== 1), :mw]
            m2 = fwd[(fwd.date .== d2) .& (fwd.tp .== 1), :mw]
            @test !isempty(m1)
            @test !isempty(m2)
            @test isapprox(m2[1] / m1[1], 1.10; rtol = 0.02)
            @test minimum(fwd.date) == Date(2026, 6, 15)
            @test maximum(fwd.date) == Date(2026, 6, 15) + Dates.Day(2 * 365 - 1)
        end

        @testset "insufficient history fails loudly" begin
            @test_throws ErrorException Nephrite.demand_shape(hist, hm, cfg;
                                                              min_days = 99)
        end

        @testset "forward_demand picks circularly-nearest week-of-year" begin
            # Shape has weekday data only at woy 2 (mw 100) and woy 40 (mw 200), hub OTA, tp 1.
            shp = DataFrame(hub = ["OTA", "OTA"], woy = [2, 40],
                            daytype = ["weekday", "weekday"], tp = [1, 1],
                            mw = [100.0, 200.0])
            # A late-December weekday is ~woy 52; circular-nearest is woy 2 (dist 3),
            # NOT woy 40 (dist 12). Linear distance would wrongly pick woy 40.
            fwd = Nephrite.forward_demand(shp, Date(2026, 12, 21), 1; growth = 0.0)
            wk = fwd[(fwd.date .== Date(2026, 12, 21)) .& (fwd.tp .== 1), :mw]
            # 2026-12-21 is a Monday (weekday); confirm it resolved to woy 2's value.
            if Dates.dayofweek(Date(2026, 12, 21)) <= 5
                @test !isempty(wk)
                @test isapprox(wk[1], 100.0; rtol = 1e-9)
            end
        end
    end
end
