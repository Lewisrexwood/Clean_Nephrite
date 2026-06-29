using Dates, DataFrames

@testset "supplycurves" begin
    mktempdir() do root
        d = Date(2026, 6, 10)
        build_test_snapshot!(root, d)
        ds = Nephrite.open_datastore(root, d)
        hm = Nephrite.build_hubmap(ds, joinpath(@__DIR__, "..", "config", "hubmap.toml"))
        plant = Nephrite.load_plant(joinpath(@__DIR__, "..", "config", "plant.toml"))
        try
            curves = Nephrite.hub_supply_curves(ds, hm, plant)

            @testset "structure" begin
                @test curves isa DataFrame
                @test names(curves) == ["hub", "tp", "price", "mw"]
                @test !isempty(curves)
            end

            @testset "curves are price-sorted within hub and period" begin
                for g in groupby(curves, [:hub, :tp])
                    @test issorted(g.price)
                end
            end

            @testset "no modelled-hydro POCs leak into the curves" begin
                all_plant = Nephrite.Plant(String[], Nephrite.Battery[])
                all_curves = Nephrite.hub_supply_curves(ds, hm, all_plant)
                @test sum(all_curves.mw) >= sum(curves.mw)
            end

            @testset "excluding a known offer POC removes exactly its MW" begin
                all_plant = Nephrite.Plant(String[], Nephrite.Battery[])
                all_curves = Nephrite.hub_supply_curves(ds, hm, all_plant)
                excl_plant = Nephrite.Plant(["COL0661"], Nephrite.Battery[])
                excl_curves = Nephrite.hub_supply_curves(ds, hm, excl_plant)
                # COL0661 contributes positive MW, so excluding it must strictly reduce total
                @test sum(excl_curves.mw) < sum(all_curves.mw)
                @test isapprox(sum(all_curves.mw) - sum(excl_curves.mw), 30.0; rtol = 1e-6)
            end

            @testset "only latest energy offers" begin
                raw = Nephrite.query(ds,
                    "SELECT sum(Megawatts) AS mw FROM offers " *
                    "WHERE ProductType = 'Energy' AND IsLatestYesNo = 'Y' AND Megawatts > 0")
                all_plant = Nephrite.Plant(String[], Nephrite.Battery[])
                all_curves = Nephrite.hub_supply_curves(ds, hm, all_plant)
                @test isapprox(sum(all_curves.mw), raw.mw[1]; rtol = 1e-6)
            end
        finally
            close(ds)
        end
    end
end
