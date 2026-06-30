using Test, Nephrite, DataFrames
import SDDP

@testset "warmstart" begin
    # --- Toy net: L has a downstream station (coeff>0); Z is spill-only (coeff==0). ---
    function _toy_net()
        res  = [Nephrite.JadeReservoir("L", "SI", 0.0, 1000.0),
                Nephrite.JadeReservoir("Z", "SI", 0.0, 500.0)]
        stn  = Nephrite.HydroStation("g", 1e6, 1.0, [(0.0, 0.0), (1e6, 1e6)])
        arcs = [Nephrite.Arc("L", "SEA", "g", 1e6),
                Nephrite.Arc("Z", "SEA", "", Inf)]
        return Nephrite.HydroNetwork(res, arcs, Dict("g" => stn),
                   Dict("g" => "BEN"), Dict("L" => ["SEA"], "Z" => ["SEA"]))
    end

    @testset "wv_warmstart_cuts builds point-slope cuts with the dual sign convention" begin
        net = _toy_net()
        m   = Nephrite.MWH_PER_MM3_PER_SP
        wv  = Dict("L" => 50.0, "Z" => 40.0)        # Z is coeff==0 → excluded
        avol = Dict("L" => 500.0, "Z" => 300.0)
        cuts = Nephrite.wv_warmstart_cuts(net, avol, wv, [1.0, 0.5], -10.0)

        @test length(cuts) == 2                      # one block per week
        @test cuts[1]["node"] == "1"
        @test cuts[2]["node"] == "2"

        sc1 = cuts[1]["single_cuts"][1]
        @test sc1["intercept"] == -10.0             # height == lb at the anchor
        @test isapprox(sc1["coefficients"]["s[L]"], 1.0 * (-50.0 * 1.0 * m); rtol = 1e-9)
        @test sc1["state"]["s[L]"] == 500.0
        @test !haskey(sc1["coefficients"], "s[Z]")  # coeff==0 reservoir excluded
        @test !haskey(sc1["state"], "s[Z]")
        @test keys(sc1["coefficients"]) == keys(sc1["state"])  # identical key sets

        sc2 = cuts[2]["single_cuts"][1]
        @test isapprox(sc2["coefficients"]["s[L]"], 0.5 * (-50.0 * 1.0 * m); rtol = 1e-9)

        @test cuts[1]["multi_cuts"] == Dict{String,Any}[]
        @test cuts[1]["risk_set_cuts"] == Vector{Float64}[]
    end

    @testset "wv_warmstart_cuts skips empty/zero priors" begin
        net = _toy_net()
        @test isempty(Nephrite.wv_warmstart_cuts(net, Dict("L" => 500.0),
                          Dict{String,Float64}(), [1.0, 0.5], -10.0))     # no WV at all
        @test isempty(Nephrite.wv_warmstart_cuts(net, Dict("L" => 500.0),
                          Dict("L" => 0.0), [1.0], -10.0))                # WV == 0 → skip
        @test isempty(Nephrite.wv_warmstart_cuts(net, Dict("Z" => 300.0),
                          Dict("Z" => 40.0), [1.0], -10.0))               # only coeff==0 → skip
    end
end
