# scripts/warmstart_demo.jl — compare SDDP warm-start options on the quick example.
# Runs :none (cold), :anchor (Option C), :cuts (Option A) over ONE assembled set of
# inputs and shows how each affects policy (storage trajectory, weekly price) and
# water values (per-reservoir FCF curves).
#   julia --project=. scripts/warmstart_demo.jl
using Nephrite, Dates, DataFrames, Statistics
using DuckDB, DBInterface

const SNAPSHOT = Date(2026, 6, 11)
const MODES    = [:none, :anchor, :cuts]
nz, si = 2700.0, 2200.0
n_weeks, iters, scen_n = 8, 15, 4

# Optional shipped demand shape (clean repo); else build from history.
shape_path = joinpath("data", "static", "demand_shape.csv")
forward_shape = if isfile(shape_path)
    con = DBInterface.connect(DuckDB.DB)
    df = try
        DataFrame(DBInterface.execute(con, """
            SELECT hub, CAST(woy AS INTEGER) AS woy, daytype,
                   CAST(tp AS INTEGER) AS tp, CAST(mw AS DOUBLE) AS mw
            FROM read_csv_auto('$(replace(abspath(shape_path), "\\" => "/"))')"""))
    finally
        DBInterface.close!(con); GC.gc()
    end
    df
else
    nothing
end

ds = Nephrite.open_datastore("data", SNAPSHOT)
try
    cfg(p) = joinpath("config", p)
    jade_dir = joinpath("data", "static", "jade")
    jd = Nephrite.load_jade(jade_dir, cfg("jade.toml"))
    sm = Nephrite.build_stationmap(jd, cfg("stationmap.toml"))
    hm = Nephrite.build_hubmap(ds, cfg("hubmap.toml"))
    Nephrite._preflight_pocs(ds, hm)

    mi = Nephrite.assemble_inputs(ds, SNAPSHOT; config_dir = "config",
            history_dir = joinpath("data", "history", "demand"),
            nz_gwh = nz, si_gwh = si, n_weeks = n_weeks,
            min_history_days = 10, forward_shape = forward_shape)
    scen = Nephrite.empirical_inflow_scenarios(cfg("reservoirs.toml"), mi.net,
                                               SNAPSHOT, n_weeks)

    # FCF extraction inputs (shared across modes).
    plant  = Nephrite.load_plant(cfg("plant.toml"))
    rv     = Nephrite.reservoir_implied_wv(ds, plant, sm)
    offers = Dict{String,Float64}(String(r.reservoir) => Float64(r.implied_wv)
                                  for r in eachrow(rv))
    fcfg   = Nephrite.load_fcf_config(cfg("model.toml"))
    rnames = [r.name for r in mi.net.reservoirs]

    wv_rows  = DataFrame(mode = String[], reservoir = String[],
                         storage_gwh = Float64[], water_value = Float64[], week = Int[])
    pol_rows = DataFrame(mode = String[], reservoir = String[], week = Int[],
                         mean_storage_mm3 = Float64[])
    prc_rows = DataFrame(mode = String[], hub = String[], week = Int[], mean_price = Float64[])

    println(rpad("mode", 8), " | ", rpad("lower_bound", 16), " | week-1 water values")
    println("-"^60)
    for mode in MODES
        sr = Nephrite.solve_sddp(mi, scen; n_scenarios = scen_n,
                                 iteration_limit = iters, seed = 1, warm_start = mode)

        # Water values: per-reservoir FCF curves (week-1 reslice block).
        fcf = Nephrite.extract_run_fcf(sr.policy, mi.net, mi.initial_vol,
                                       sr.trajectories, offers, fcfg)
        wk1 = first(fcf)                     # the earliest re-slice week
        for (r, c) in wk1.curves
            for (s, w) in zip(c.storage_gwh, c.water_value)
                push!(wv_rows, (string(mode), r, s, w, wk1.week))
            end
        end

        # Policy: mean end-of-week storage (Mm³) across scenarios.
        N = length(sr.trajectories)
        for r in rnames, w in 1:n_weeks
            ms = mean(sr.trajectories[i][(r, w)] for i in 1:N)
            push!(pol_rows, (string(mode), r, w, ms))
        end
        # Policy: mean weekly price ($/MWh) across scenarios and steps.
        byhubweek = Dict{Tuple{String,Int},Vector{Float64}}()
        for ((hub, w, _step), v) in sr.price_dist
            push!(get!(byhubweek, (hub, w), Float64[]), mean(v))
        end
        for ((hub, w), vals) in byhubweek
            push!(prc_rows, (string(mode), hub, w, mean(vals)))
        end

        coeff = Nephrite.downstream_energy_coeff(mi.net)
        wk1_summary = join(["$(r)=$(round(Nephrite.curve_value(wk1.curves[r], Nephrite._vol_to_gwh(get(mi.initial_vol, r, 0.0), get(coeff, r, 0.0))); digits=1))"
                            for r in sort(collect(keys(wk1.curves)))], ", ")
        println(rpad(string(mode), 8), " | ", rpad(string(round(sr.lower_bound; digits = 2)), 16),
                " | ", wk1_summary)
    end

    out = joinpath("runs", "warmstart_demo_$(SNAPSHOT)")
    mkpath(out)
    Nephrite._write_csv(wv_rows, joinpath(out, "warmstart_compare_wv.csv"))
    Nephrite._write_csv(vcat(pol_rows,
        rename(prc_rows, :hub => :reservoir, :mean_price => :mean_storage_mm3);
        cols = :union), joinpath(out, "warmstart_compare_policy.csv"))
    println("\nComparison CSVs written to: $out")
    println("  warmstart_compare_wv.csv      — per-mode, per-reservoir water-value curves")
    println("  warmstart_compare_policy.csv  — per-mode mean storage trajectory + weekly price")
    println("See docs/WARMSTART.md for how to read these.")
finally
    close(ds)
end
