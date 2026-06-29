using Test, Nephrite

@testset "fcfreconcile" begin
    @testset "weights: offer decays, forward held, sums to 1" begin
        a1, b1, g1 = Nephrite.reconcile_weights(1, 13, 0.0)
        @test (a1, b1, g1) == (1.0, 0.0, 0.0)                 # week 1, forward off -> pure offer
        a14, b14, g14 = Nephrite.reconcile_weights(14, 13, 0.0)
        @test (a14, b14, g14) == (0.0, 1.0, 0.0)              # past decay -> pure SDDP
        a, b, g = Nephrite.reconcile_weights(1, 13, 0.5)
        @test isapprox(a + b + g, 1.0; rtol = 1e-12)          # always normalised
        @test g > 0.0                                          # forward weight present
    end

    @testset "level: anchored uses theta near-term, SDDP far-term" begin
        # week 1, forward off, has offer -> level == theta
        @test isapprox(Nephrite.reconcile_level(1, 120.0, 95.0, 108.0, 13, 0.0), 120.0; rtol = 1e-9)
        # week 14 -> level == SDDP level
        @test isapprox(Nephrite.reconcile_level(14, 120.0, 95.0, 108.0, 13, 0.0), 95.0; rtol = 1e-9)
        # no offer (nothing): level rides SDDP even at week 1 (forward off)
        @test isapprox(Nephrite.reconcile_level(1, nothing, 95.0, 108.0, 13, 0.0), 95.0; rtol = 1e-9)
    end

    @testset "shift_to_level moves the whole curve so it passes through the level" begin
        c = Nephrite.Curve("Pukaki", [100.0, 200.0, 300.0], [80.0, 60.0, 40.0])
        s = Nephrite.shift_to_level(c, 200.0, 100.0)            # value at 200 was 60 -> +40
        @test isapprox(Nephrite.curve_value(s, 200.0), 100.0; rtol = 1e-9)
        @test isapprox(s.water_value, [120.0, 100.0, 80.0]; rtol = 1e-9)
        @test s.storage_gwh == c.storage_gwh
    end

    @testset "reconcile: anchored hits theta at week 1, unanchored rides SDDP" begin
        shapes = Dict(
            "Pukaki" => Nephrite.Curve("Pukaki", [100.0, 200.0], [80.0, 60.0]),
            "Tekapo" => Nephrite.Curve("Tekapo", [100.0, 200.0], [70.0, 50.0]),
        )
        offers = Dict("Pukaki" => 120.0)                       # Tekapo has no offer
        today  = Dict("Pukaki" => 150.0, "Tekapo" => 150.0)
        out = Nephrite.reconcile(shapes, offers, today, 108.0, 1; decay_weeks = 13, forward_weight = 0.0)
        @test isapprox(Nephrite.curve_value(out["Pukaki"], 150.0), 120.0; rtol = 1e-9)  # anchored -> theta
        # Tekapo unchanged in level: SDDP value at 150 was (70+50)/2 = 60
        @test isapprox(Nephrite.curve_value(out["Tekapo"], 150.0), 60.0; rtol = 1e-9)
    end
end
