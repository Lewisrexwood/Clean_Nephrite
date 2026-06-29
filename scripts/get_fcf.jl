# scripts/get_fcf.jl — produce per-reservoir FCF water-value curves + the full FCF cuts.
#   julia --project=. scripts/get_fcf.jl          # quick example  (~minutes)
#   julia --project=. scripts/get_fcf.jl --full    # 2-year policy  (~hours)
using Nephrite, Dates, DataFrames
using DuckDB, DBInterface

const SNAPSHOT = Date(2026, 6, 11)
full = "--full" in ARGS

# Demand profile: prefer the shipped precomputed shape (clean repo); otherwise
# fall back to building it from the raw history cache (full dev repo).
shape_path = joinpath("data", "static", "demand_shape.csv")
forward_shape = if isfile(shape_path)
    con = DBInterface.connect(DuckDB.DB)
    df = try
        DataFrame(DBInterface.execute(con, """
            SELECT hub, CAST(woy AS INTEGER) AS woy, daytype,
                   CAST(tp AS INTEGER) AS tp, CAST(mw AS DOUBLE) AS mw
            FROM read_csv_auto('$(replace(abspath(shape_path), "\\\\" => "/"))')"""))
    finally
        DBInterface.close!(con); GC.gc()
    end
    println("using shipped demand shape: $shape_path")
    df
else
    println("no shipped shape — building demand profile from data/history/demand")
    nothing
end

nz, si = 2700.0, 2200.0
nw, iters, scen = full ? (104, 100, 50) : (8, 15, 4)
println(full ? ">>> FULL 2-year policy: n_weeks=$nw NZ=$nz/SI=$si iters=$iters scen=$scen (~hours)" :
               ">>> QUICK example: n_weeks=$nw iters=$iters scen=$scen (~minutes)")

rr = Nephrite.run_model(SNAPSHOT; root = "data", config_dir = "config",
        history_dir = joinpath("data", "history", "demand"),
        nz_gwh = nz, si_gwh = si, n_weeks = nw, engine = :sddp,
        n_scenarios = scen, iteration_limit = iters, extract_fcf = true,
        forward_shape = forward_shape, min_history_days = 10)

println("\nFCF artifacts written to: $(rr.run_dir)")
println("  fcf_curves.csv  — per-reservoir water-value offer curves (stack-model ready)")
println("  fcf_cuts.json   — the full FCF as SDDP cuts (for an LP/value-function engine)")
println("Optional plot:  python scripts/plot_fcf.py \"$(joinpath(rr.run_dir, "fcf_curves.csv"))\"")
println("How to consume these: see docs/FCF.md")
