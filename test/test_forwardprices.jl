using Dates, DataFrames

@testset "forwardprices" begin
    @testset "forward_url builds the KOP4VM CSV endpoint" begin
        u = Nephrite.forward_url(location="OTA", commodity="BASE", duration="MTH",
                                 from=Date(2021,1,1), to=Date(2024,12,31))
        @test occursin("Download/DataReport/CSV/KOP4VM", u)
        @test occursin("CommodityType=BASE", u)
        @test occursin("Location=OTA", u)
        @test occursin("Duration=MTH", u)
        @test occursin("Instrument=FUTURE", u)
        @test occursin("DateFrom=20210101", u)
        @test occursin("DateTo=20241231", u)
        @test occursin("Forward%20markets", u)   # space percent-encoded for the live GET
        @test !occursin(" ", u)                  # no raw space anywhere in the URL
    end

    @testset "load_forward_prices parses the CSV into a tidy frame" begin
        df = Nephrite.load_forward_prices(joinpath(@__DIR__, "fixtures",
                                                   "forward_prices_sample.csv"))
        @test names(df) == ["settlement_date","location","hub","duration",
                            "commodity","series","price"]
        @test Set(df.hub) == Set(["OTA","BEN"])
        ota = df[(df.hub .== "OTA") .& (df.commodity .== "Base"), :]
        @test only(ota.settlement_date) == Date(2024,1,3)
        @test isapprox(only(ota.price), 157.6250; atol=1e-6)
        @test any(df.series .== "Simple daily average spot price")   # spot row kept
    end

    @testset "fetch_forward_prices! writes one CSV per location x commodity" begin
        mktempdir() do root
            written = String[]
            stub(url, dest) = (push!(written, dest); write(dest, "stub"); dest)
            dir = Nephrite.fetch_forward_prices!(; root = root, from = Date(2024,1,1),
                to = Date(2024,3,31), fetch = stub)   # default duration = QTR
            @test isdir(dir)
            @test length(written) == 4        # OTA/BEN x BASE/PEAK
            @test all(isfile, written)
            @test all(p -> occursin("QTR", p), written)   # filenames carry the QTR default
        end
    end
end
