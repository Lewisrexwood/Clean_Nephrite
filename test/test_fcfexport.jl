using Test, Nephrite, DataFrames

@testset "fcfexport" begin
    @testset "dataframe has the right columns, sorted, optional week" begin
        curves = Dict(
            "Pukaki" => Nephrite.Curve("Pukaki", [100.0, 200.0], [80.0, 60.0]),
            "Hawea"  => Nephrite.Curve("Hawea",  [50.0, 150.0],  [90.0, 70.0]),
        )
        df = Nephrite.fcf_dataframe(curves)
        @test names(df) == ["reservoir", "storage_gwh", "water_value"]
        @test df.reservoir[1] == "Hawea"            # sorted by reservoir then storage
        @test nrow(df) == 4
        dfw = Nephrite.fcf_dataframe(curves; week = 3)
        @test "week" in names(dfw)
        @test all(dfw.week .== 3)
    end

    @testset "write_fcf then read_fcf round-trips" begin
        curves = Dict(
            "Pukaki" => Nephrite.Curve("Pukaki", [100.0, 200.0, 300.0], [80.0, 60.0, 40.0]),
            "Hawea"  => Nephrite.Curve("Hawea",  [50.0, 150.0],         [90.0, 70.0]),
        )
        mktempdir() do dir
            path = joinpath(dir, "fcf_curves.csv")
            Nephrite.write_fcf(curves, path)
            @test isfile(path)
            back = Nephrite.read_fcf(path)
            @test Set(keys(back)) == Set(["Pukaki", "Hawea"])
            @test isapprox(back["Pukaki"].storage_gwh, [100.0, 200.0, 300.0]; rtol = 1e-9)
            @test isapprox(back["Pukaki"].water_value, [80.0, 60.0, 40.0]; rtol = 1e-9)
            @test isapprox(back["Hawea"].storage_gwh, [50.0, 150.0]; rtol = 1e-9)
            @test isapprox(back["Hawea"].water_value, [90.0, 70.0]; rtol = 1e-9)
        end
    end
end
