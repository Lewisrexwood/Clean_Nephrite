using Dates, DataFrames

@testset "watervalues" begin
    @testset "weighted median" begin
        @test Nephrite.weighted_median([10.0, 20.0, 30.0], [1.0, 1.0, 1.0]) == 20.0
        @test Nephrite.weighted_median([10.0, 999.0], [9.0, 1.0]) == 10.0
    end

    mktempdir() do root
        d = Date(2026, 6, 10)
        build_test_snapshot!(root, d)
        ds = Nephrite.open_datastore(root, d)
        plantfile = joinpath(@__DIR__, "..", "config", "plant.toml")
        plant = Nephrite.load_plant(plantfile)
        try
            wv = Nephrite.implied_water_values(ds, plant)
            @testset "structure" begin
                @test names(wv) == ["poc", "tp", "implied_wv"]
                @test all(wv.implied_wv .>= 0)
            end
            if isempty(plant.modelled_hydro_pocs)
                @test isempty(wv)
            else
                @test all(p in plant.modelled_hydro_pocs for p in unique(wv.poc))
            end
        finally
            close(ds)
        end
    end
end
