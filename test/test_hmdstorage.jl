using Dates, DataFrames

# Toy chain: UpperLake(SI) -> [stnA sp=2] -> LowerLake(NI) -> [stnB sp=3] -> SEA
# coeff(UpperLake)=5, coeff(LowerLake)=3 (max-route). K = MWH_PER_MM3_PER_SP.
function _hmd_toy_net()
    res = [Nephrite.JadeReservoir("UpperLake","SI",0.0,200.0),
           Nephrite.JadeReservoir("LowerLake","NI",0.0,100.0)]   # one SI, one NI
    stnA = Nephrite.HydroStation("stnA",20.0,2.0,[(0.0,0.0),(10.0,20.0)])
    stnB = Nephrite.HydroStation("stnB",30.0,3.0,[(0.0,0.0),(10.0,30.0)])
    arcs = [Nephrite.Arc("UpperLake","LowerLake","stnA",10.0),
            Nephrite.Arc("LowerLake","SEA","stnB",10.0)]
    Nephrite.HydroNetwork(res, arcs, Dict("stnA"=>stnA,"stnB"=>stnB),
        Dict("stnA"=>"BEN","stnB"=>"OTA"),
        Dict("UpperLake"=>["LowerLake"],"LowerLake"=>["SEA"]))
end

@testset "hmdstorage" begin
    net = _hmd_toy_net()
    lake_map = Dict("toy_upper.csv" => ["UpperLake"], "toy_lower.csv" => ["LowerLake"])
    p = Nephrite.build_hmd_provider(joinpath(@__DIR__, "fixtures", "hmd"), net;
                                    lake_map = lake_map)
    K = Nephrite.MWH_PER_MM3_PER_SP

    @testset "aggregate GWh on a date with readings" begin
        nz, si = Nephrite.historical_storage(p, Date(2024,1,1))   # uses 2023-12-31 row
        # UpperLake 100 Mm3 * coeff 5 ; LowerLake 50 Mm3 * coeff 3
        exp_nz = (100*5 + 50*3) * K / 1000
        exp_si = (100*5) * K / 1000          # only UpperLake is SI
        @test isapprox(nz, exp_nz; rtol=1e-9)
        @test isapprox(si, exp_si; rtol=1e-9)
        @test nz >= si > 0
    end

    @testset "uses the nearest reading on or before the date" begin
        nz_jun, _ = Nephrite.historical_storage(p, Date(2024,7,1))  # uses 2024-06-15 row
        exp = (80*5 + 40*3) * K / 1000
        @test isapprox(nz_jun, exp; rtol=1e-9)
    end

    @testset "errors before the series starts" begin
        @test_throws ErrorException Nephrite.historical_storage(p, Date(2020,1,1))
    end
end
