using Dates, DataFrames, DuckDB, DBInterface

# Reuses build_test_snapshot! (test/util.jl) and write_inputs_test_history
# (test/test_inputs.jl), both included earlier in runtests.jl, so the golden
# run is byte-for-byte the same setup as the runner test.

# Local CSV helpers via DuckDB (no CSV.jl dependency), mirroring src/outputs.jl.
_golden_write_csv(df::DataFrame, path::AbstractString) =
    Nephrite._write_csv(df, path)

function _golden_read_csv(path::AbstractString)
    con = DBInterface.connect(DuckDB.DB)
    try
        df = DataFrame(DBInterface.execute(con,
            "SELECT * FROM read_csv_auto('$(Nephrite.sql_path(path))', header=true)"))
        return df
    finally
        DBInterface.close!(con)
        GC.gc()  # Windows: release DuckDB's file handle
    end
end

@testset "golden run (deterministic, within tolerance)" begin
    mktempdir() do root
        d = Date(2026, 6, 10)
        build_test_snapshot!(root, d)
        hist = joinpath(root, "history", "demand"); write_inputs_test_history(hist)
        rr = Nephrite.run_model(d; root = root,
            config_dir = joinpath(@__DIR__, "..", "config"),
            history_dir = hist, nz_gwh = 4000.0, si_gwh = 2500.0,
            n_weeks = 2, seed = 1, min_history_days = 10)
        fc = Nephrite.forward_curves(rr.prices, d; n_weeks = 2)
        sort!(fc, [:hub, :product, :month])

        # The expected fixture is a tracked regression gate.  To REGENERATE it
        # (a deliberate, reviewed action): delete the file, temporarily restore
        # a first-run branch that writes `_golden_write_csv(fc, expected_path)`,
        # inspect the values for determinism + finiteness, then re-commit.
        expected_path = joinpath(@__DIR__, "fixtures", "golden", "forward_curves.csv")
        @test isfile(expected_path)  # committed; see regeneration note above
        exp = _golden_read_csv(expected_path)
        @test nrow(fc) == nrow(exp)
        # Determinism/regression gate ONLY — the toy fixture's JADE must-run
        # (~3227 MW) ≫ toy demand, so over-supply curtailment binds and pins
        # affected nodal prices to ≈ −CURTAIL_PENALTY.  We therefore assert
        # equality-to-stored + finiteness, NOT realism (peak≥base, price≥0);
        # real-demand validation is Task 8.
        @test all(isfinite, fc.price)
        @test all(isapprox.(fc.price, exp.price; atol = 1e-6))
    end
end

# --- scripts/run.jl option-parsing smoke test ------------------------------
include(joinpath(@__DIR__, "..", "scripts", "run.jl"))

@testset "run.jl _parse_opts" begin
    @testset "maps every override flag with the run_model keys" begin
        opts = _parse_opts(["--nz-gwh", "4200", "--si-gwh", "2600",
            "--hvdc-derate", "0.8", "--fuel-scale", "1.5",
            "--inflow-scale", "0.9", "--demand-growth", "0.02", "--tiwai-off"])
        @test opts.nz_gwh == 4200.0
        @test opts.si_gwh == 2600.0
        @test opts.overrides[:hvdc_derate]   == 0.8
        @test opts.overrides[:fuel_scale]    == 1.5
        @test opts.overrides[:inflow_scale]  == 0.9
        @test opts.overrides[:demand_growth] == 0.02
        @test opts.overrides[:tiwai_off]     === true
    end

    @testset "no overrides when only required flags given" begin
        opts = _parse_opts(["--nz-gwh", "4000", "--si-gwh", "2500"])
        @test opts.nz_gwh == 4000.0
        @test opts.si_gwh == 2500.0
        @test isempty(opts.overrides)
    end

    @testset "required flags are enforced" begin
        @test_throws ErrorException _parse_opts(["--si-gwh", "2500"])  # missing nz
        @test_throws ErrorException _parse_opts(["--nz-gwh", "4000"])  # missing si
        @test_throws ErrorException _parse_opts(String[])              # both missing
    end

    @testset "unknown flag and missing value error" begin
        @test_throws ErrorException _parse_opts(["--nz-gwh", "4000", "--si-gwh", "2500", "--bogus"])
        @test_throws ErrorException _parse_opts(["--nz-gwh"])  # value missing
    end
end
