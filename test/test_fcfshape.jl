using Test, Nephrite, DataFrames

@testset "fcfshape" begin
    @testset "Curve construction validates inputs" begin
        c = Nephrite.Curve("Pukaki", [100.0, 200.0, 300.0], [80.0, 60.0, 40.0])
        @test c.reservoir == "Pukaki"
        @test c.storage_gwh == [100.0, 200.0, 300.0]
        @test_throws ErrorException Nephrite.Curve("X", [1.0, 2.0], [3.0])       # length mismatch
        @test_throws ErrorException Nephrite.Curve("X", [2.0, 1.0], [3.0, 4.0])  # unsorted
    end

    @testset "curve_value interpolates and clamps" begin
        c = Nephrite.Curve("Pukaki", [100.0, 200.0, 300.0], [80.0, 60.0, 40.0])
        @test isapprox(Nephrite.curve_value(c, 150.0), 70.0; rtol = 1e-9)   # midpoint
        @test isapprox(Nephrite.curve_value(c, 250.0), 50.0; rtol = 1e-9)
        @test Nephrite.curve_value(c, 50.0)  == 80.0   # clamp low
        @test Nephrite.curve_value(c, 999.0) == 40.0   # clamp high
        @test Nephrite.curve_value(c, 100.0) == 80.0   # exact endpoint
    end

    @testset "sample_curve and extract_shapes use the sampler over the grid" begin
        # mock sampler: water value falls linearly with storage
        sampler(r, s) = r == "Pukaki" ? 200.0 - 0.1 * s : 150.0 - 0.05 * s
        c = Nephrite.sample_curve(sampler, "Pukaki", [300.0, 100.0, 200.0])  # unsorted input
        @test c.storage_gwh == [100.0, 200.0, 300.0]                          # sorted on build
        @test isapprox(c.water_value, [190.0, 180.0, 170.0]; rtol = 1e-9)
        @test issorted(c.water_value; rev = true)                            # monotone decreasing

        grids = Dict("Pukaki" => [100.0, 200.0], "Hawea" => [100.0, 200.0])
        shapes = Nephrite.extract_shapes(sampler, grids)
        @test Set(keys(shapes)) == Set(["Pukaki", "Hawea"])
        @test isapprox(Nephrite.curve_value(shapes["Hawea"], 100.0), 145.0; rtol = 1e-9)
    end

    @testset "master_wv_sampler perturbs one reservoir's volume and reads the week-1 dual" begin
        captured = Ref{Any}(nothing)
        # stub solve: record the initial_vol it received, return a known week-1 water value
        stub = (w, n, v, t, a) -> begin
            captured[] = v
            return (water_value = Dict(("Pukaki", 1) => 7.5),)
        end
        base = Dict("Pukaki" => 100.0, "Hawea" => 50.0)
        coeff = Dict("Pukaki" => 0.5, "Hawea" => 0.3)
        s = Nephrite.master_wv_sampler(nothing, nothing, base, nothing, nothing, coeff; solve = stub)

        val = s("Pukaki", 1000.0)
        @test val == 7.5
        # volume = gwh * 1000 / (coeff * MWH_PER_MM3_PER_SP)
        expected_vol = 1000.0 * 1000 / (0.5 * Nephrite.MWH_PER_MM3_PER_SP)
        @test isapprox(captured[]["Pukaki"], expected_vol; rtol = 1e-9)
        @test captured[]["Hawea"] == 50.0          # other reservoirs untouched
        @test base["Pukaki"] == 100.0              # base_vol not mutated
    end
end
