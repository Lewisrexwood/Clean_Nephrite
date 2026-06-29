using Test, Nephrite, TOML

@testset "fcfextract" begin
    @testset "load_fcf_config parses the [fcf_extract] block" begin
        mktempdir() do dir
            path = joinpath(dir, "model.toml")
            open(path, "w") do io
                write(io, """
                [fcf_extract]
                reslice_weeks = [1, 2, 3, 4]
                grid_points = 9
                decay_weeks = 13
                forward_weight = 0.0
                """)
            end
            cfg = Nephrite.load_fcf_config(path)
            @test cfg.reslice_weeks == [1, 2, 3, 4]
            @test cfg.grid_points == 9
            @test cfg.decay_weeks == 13
            @test cfg.forward_weight == 0.0
        end
    end

    @testset "extract_fcf re-slices at scheduled weeks with the right joint storage" begin
        seen_weeks = Int[]
        # make_sampler returns a sampler whose level encodes the week it saw
        make_sampler = (week, joint) -> begin
            push!(seen_weeks, week)
            (r, s) -> 100.0 + week - 0.1 * s
        end
        trajectory = Dict(1 => Dict("Pukaki" => 150.0), 4 => Dict("Pukaki" => 120.0))
        grids = Dict("Pukaki" => [100.0, 200.0])
        offers = Dict{String,Float64}()                      # unanchored -> rides SDDP
        cfg = Nephrite.FcfExtractConfig([1, 4], 2, 13, 0.0)
        res = Nephrite.extract_fcf(make_sampler, trajectory, grids, offers, 0.0, cfg)
        @test [r.week for r in res] == [1, 4]
        @test sort(seen_weeks) == [1, 4]
        # week-1 sampler level at storage 150: 100 + 1 - 15 = 86
        @test isapprox(Nephrite.curve_value(res[1].curves["Pukaki"], 150.0), 86.0; rtol = 1e-9)
        # week-4 sampler level at storage 120: 100 + 4 - 12 = 92
        @test isapprox(Nephrite.curve_value(res[2].curves["Pukaki"], 120.0), 92.0; rtol = 1e-9)
    end

    @testset "end-to-end: real config -> extract -> write -> read round-trips" begin
        cfg = Nephrite.load_fcf_config(joinpath(@__DIR__, "..", "config", "model.toml"))
        @test cfg.reslice_weeks == [1, 2, 3, 4]
        @test cfg.forward_weight == 0.0

        make_sampler = (week, joint) -> ((r, s) -> 200.0 - 0.1 * s)   # deterministic
        traj = Dict(w => Dict("Pukaki" => 150.0, "Hawea" => 100.0) for w in cfg.reslice_weeks)
        grids = Dict("Pukaki" => collect(range(50.0, 300.0; length = cfg.grid_points)),
                     "Hawea"  => collect(range(50.0, 300.0; length = cfg.grid_points)))
        offers = Dict("Pukaki" => 120.0)
        res = Nephrite.extract_fcf(make_sampler, traj, grids, offers, 0.0, cfg)
        @test length(res) == 4
        # week-1 anchored Pukaki hits its offer at today's storage
        @test isapprox(Nephrite.curve_value(res[1].curves["Pukaki"], 150.0), 120.0; rtol = 1e-9)

        mktempdir() do dir
            path = joinpath(dir, "fcf_curves.csv")
            Nephrite.write_fcf(res[1].curves, path; week = res[1].week)
            back = Nephrite.read_fcf(path)
            @test isapprox(Nephrite.curve_value(back["Pukaki"], 150.0), 120.0; rtol = 1e-6)
        end
    end
end
