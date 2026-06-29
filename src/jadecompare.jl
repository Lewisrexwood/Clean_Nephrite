using DataFrames, Dates, Statistics
using JSON3, Random, DuckDB, DBInterface

# ===========================================================================
# jadecompare.jl — attended-analysis helpers: replay the trained SDDP policy on
# coherent historical inflow year-sequences ("the JADE scenarios") and summarise
# storage / price fans.  Library only; the heavy real-data orchestration lives in
# scripts/compare_jade.jl.
# ===========================================================================

"""
    historical_inflow_sequences(by_year, net, jade_to_cfg, snapshot_date, n_weeks)
        -> Dict{Int, Vector{Dict{String,Float64}}}

Build the COHERENT historical inflow sequences keyed by start-year.  For start-year
`Y`, stage `t` (1-based) uses the real historical inflow at calendar position
`(year = Y + calendar-year-offset(t), week-of-year = Dates.week(snapshot + 7·(t-1)))`,
where the offset is `year(snapshot + 7·(t-1)) - year(snapshot)` — so the trace rolls
`Y → Y+1 → …` exactly as the calendar advances over the horizon.  Each stage entry
is `net-reservoir-name => cumecs`; a reservoir absent from the table for a given
(year,woy) contributes 0.0.  Start-years whose horizon needs a year beyond the data
are dropped.  (Week-of-year uses `Dates.week`, matching `empirical_inflow_scenarios`;
ISO-week boundaries can shift a week's year assignment by one in rare cases — a
negligible approximation for this exploratory comparison.)
"""
function historical_inflow_sequences(by_year::DataFrame, net::HydroNetwork,
                                     jade_to_cfg::Dict{String,String},
                                     snapshot_date::Date, n_weeks::Integer)
    cfg_names = Dict(r.name => get(jade_to_cfg, r.name, r.name) for r in net.reservoirs)
    # O(1) lookup: (config-reservoir, year, woy) -> cumecs
    bykey = Dict{Tuple{String,Int,Int},Float64}()
    for row in eachrow(by_year)
        bykey[(String(row.reservoir), Int(row.year), Int(row.woy))] = Float64(row.inflow)
    end
    data_max_year = isempty(by_year.year) ? typemin(Int) : maximum(by_year.year)
    data_min_year = isempty(by_year.year) ? typemax(Int) : minimum(by_year.year)

    # Per-stage (calendar-year-offset, week-of-year), independent of start-year.
    offsets = Int[]; woys = Int[]
    for t in 1:n_weeks
        d = snapshot_date + Day(7 * (t - 1))
        push!(offsets, year(d) - year(snapshot_date))
        push!(woys, Dates.week(d))
    end
    max_offset = isempty(offsets) ? 0 : maximum(offsets)

    out = Dict{Int,Vector{Dict{String,Float64}}}()
    for Y in data_min_year:data_max_year
        Y + max_offset <= data_max_year || continue        # horizon runs past data → drop
        seq = Vector{Dict{String,Float64}}(undef, n_weeks)
        for t in 1:n_weeks
            yr = Y + offsets[t]; woy = woys[t]
            real = Dict{String,Float64}()
            for r in net.reservoirs
                real[r.name] = get(bykey, (cfg_names[r.name], yr, woy), 0.0)
            end
            seq[t] = real
        end
        out[Y] = seq
    end
    return out
end

"""
    replay_historical(graph, sequences) -> (storage_by_seq, inflow_by_seq)

For each start-year sequence, forward-simulate the TRAINED policy on that exact
coherent inflow trace via `SDDP.Historical`, recording end-of-week storage (Mm³)
and the realized inflow (cumecs).  Both returned dicts are keyed by start-year →
`(reservoir-name, week) => value`.

`sequences` maps start-year → `Vector{Dict{String,Float64}}` (noise term per stage).
SDDP.Historical in v1.13.2 requires `Vector{Tuple{node_index, noise_term}}`, so each
sequence is converted from `[Dict(...), ...]` to `[(1, Dict(...)), (2, Dict(...)), ...]`
before being passed to `SDDP.Historical`.
"""
function replay_historical(graph::SDDP.PolicyGraph,
                           sequences::Dict{Int,Vector{Dict{String,Float64}}})
    storage_by_seq = Dict{Int,Dict{Tuple{String,Int},Float64}}()
    inflow_by_seq  = Dict{Int,Dict{Tuple{String,Int},Float64}}()
    for (Y, seq) in sequences
        # SDDP.Historical(scenario::Vector{Tuple{T,S}}) where T=node index, S=noise term.
        # For a LinearPolicyGraph the node indices are Ints (1..n_stages).
        hist_seq = [(t, seq[t]) for t in 1:length(seq)]
        sim = SDDP.simulate(graph, 1, [:s];
                            sampling_scheme = SDDP.Historical(hist_seq))
        rec = sim[1]
        traj = Dict{Tuple{String,Int},Float64}()
        infl = Dict{Tuple{String,Int},Float64}()
        for t in 1:length(rec)
            sval = rec[t][:s]
            for r in axes(sval, 1)
                traj[(String(r), t)] = sval[r].out
            end
            for (rname, cumecs) in rec[t][:noise_term]
                infl[(String(rname), t)] = Float64(cumecs)
            end
        end
        storage_by_seq[Y] = traj
        inflow_by_seq[Y]  = infl
    end
    return storage_by_seq, inflow_by_seq
end

"""
    storage_fan(storage_by_seq, net, n_weeks) -> DataFrame(start_year, week, agg_gwh)

Aggregate end-of-week stored energy (GWh) per (start-year, week) across all replayed
sequences, via `reservoir_energy_gwh`.  Long form, sorted by (start_year, week).
"""
function storage_fan(storage_by_seq::Dict{Int,Dict{Tuple{String,Int},Float64}},
                     net::HydroNetwork, n_weeks::Integer)
    rnames = [r.name for r in net.reservoirs]
    years = Int[]; weeks = Int[]; gwh = Float64[]
    for Y in sort(collect(keys(storage_by_seq)))
        traj = storage_by_seq[Y]
        for w in 1:n_weeks
            vols = Dict(r => get(traj, (r, w), 0.0) for r in rnames)
            push!(years, Y); push!(weeks, w)
            push!(gwh, reservoir_energy_gwh(net, vols))
        end
    end
    return DataFrame(start_year = years, week = weeks, agg_gwh = gwh)
end

"""
    select_price_sequences(sequences; n=20, stride=0, all=false) -> Vector{Int}

Choose which start-years to price (the expensive 336-step pass).  `all` → every
start-year.  `stride>0` → every `stride`-th start-year by ascending year.  Else → a
representative `n`-point spread across the dry→wet ranking (by total inflow summed
over the sequence and reservoirs), always including the driest and wettest.  Returns
a sorted vector of start-years.
"""
function select_price_sequences(sequences::Dict{Int,Vector{Dict{String,Float64}}};
                                n::Int = 20, stride::Int = 0, all::Bool = false)
    yrs = sort(collect(keys(sequences)))
    isempty(yrs) && return Int[]
    all && return yrs
    stride > 0 && return yrs[1:stride:end]
    n >= length(yrs) && return yrs
    # Rank by total inflow (dry→wet), pick n evenly-spaced ranks incl. both ends.
    total(Y) = sum(sum(values(st)) for st in sequences[Y]; init = 0.0)
    by_wet = sort(yrs; by = total)
    idx = unique(round.(Int, range(1, length(by_wet); length = n)))
    return sort(by_wet[idx])
end

# ---------------------------------------------------------------------------
# Checkpoint helpers (crash-safe / resumable compare_jade run)
# ---------------------------------------------------------------------------

"""
    save_trajectories(path, storage_by_seq, inflow_by_seq) -> path

Write the replayed per-(start_year, reservoir, week) storage (Mm³) and realized
inflow (cumecs) to a parquet long table. The two dicts share keys.
"""
function save_trajectories(path::AbstractString,
                           storage_by_seq::Dict{Int,Dict{Tuple{String,Int},Float64}},
                           inflow_by_seq::Dict{Int,Dict{Tuple{String,Int},Float64}})
    yrs = Int[]; res = String[]; wks = Int[]; sto = Float64[]; inf = Float64[]
    for Y in sort(collect(keys(storage_by_seq)))
        st = storage_by_seq[Y]; it = inflow_by_seq[Y]
        for k in sort(collect(keys(st)))
            rname, w = k
            push!(yrs, Y); push!(res, rname); push!(wks, w)
            push!(sto, st[k]); push!(inf, get(it, k, 0.0))
        end
    end
    df = DataFrame(start_year = yrs, reservoir = res, week = wks,
                   storage_mm3 = sto, inflow_cumecs = inf)
    _bt_write_parquet(df, path)
    return path
end

"Reload `save_trajectories` output into (storage_by_seq, inflow_by_seq)."
function load_trajectories(path::AbstractString)
    df = _bt_read_parquet(path)
    storage_by_seq = Dict{Int,Dict{Tuple{String,Int},Float64}}()
    inflow_by_seq  = Dict{Int,Dict{Tuple{String,Int},Float64}}()
    for row in eachrow(df)
        Y = Int(row.start_year); rname = String(row.reservoir); w = Int(row.week)
        get!(storage_by_seq, Y, Dict{Tuple{String,Int},Float64}())[(rname, w)] = Float64(row.storage_mm3)
        get!(inflow_by_seq,  Y, Dict{Tuple{String,Int},Float64}())[(rname, w)] = Float64(row.inflow_cumecs)
    end
    return storage_by_seq, inflow_by_seq
end

"""
    cal_year_annual_base(price_dist, snapshot_date, n_weeks, year, start_years)
        -> DataFrame(start_year, hub, annual_base)

Per priced sequence and ASX hub, the BASE (all-steps) mean nodal price over the
30-min steps whose timestamp falls in calendar `year`.  Scenario index `i` in each
`price_dist` vector maps to `start_years[i]`.  Only OTA/BEN.
"""
function cal_year_annual_base(price_dist::Dict{Tuple{String,Int,Int},Vector{Float64}},
                              snapshot_date::Date, n_weeks::Int, year::Int,
                              start_years::Vector{Int})
    N = length(start_years)
    sums = Dict{Tuple{Int,String},Float64}(); counts = Dict{Tuple{Int,String},Int}()
    for key in sort(collect(keys(price_dist)))
        hub, week, step = key
        hub in ASX_HUBS || continue
        week <= n_weeks || continue
        Dates.year(_step_ts(snapshot_date, week, step)) == year || continue
        vals = price_dist[key]
        for i in 1:N
            mk = (i, hub)
            sums[mk] = get(sums, mk, 0.0) + vals[i]
            counts[mk] = get(counts, mk, 0) + 1
        end
    end
    sy = Int[]; hubs = String[]; ann = Float64[]
    for mk in sort(collect(keys(sums)))
        i, hub = mk
        push!(sy, start_years[i]); push!(hubs, hub); push!(ann, sums[mk] / counts[mk])
    end
    return DataFrame(start_year = sy, hub = hubs, annual_base = ann)
end

# ---------------------------------------------------------------------------
# det-overlay / progress / rng-state checkpoint helpers
# ---------------------------------------------------------------------------

# Small DuckDB CSV reader (mirrors the golden-test pattern) -> DataFrame.
function _read_csv_df(path::AbstractString)
    con = DBInterface.connect(DuckDB.DB)
    try
        return DataFrame(DBInterface.execute(con,
            "SELECT * FROM read_csv_auto('$(sql_path(path))', header=true)"))
    finally
        DBInterface.close!(con); GC.gc()
    end
end

"Write the deterministic-point overlay (hub => annual base \$/MWh) to CSV."
function save_det_overlay(path::AbstractString, det::Dict{String,Float64})
    hubs = sort(collect(keys(det)))
    _write_csv(DataFrame(hub = hubs, det_annual_base = [det[h] for h in hubs]), path)
    return path
end

"Reload `save_det_overlay` output into a Dict(hub => annual base)."
function load_det_overlay(path::AbstractString)
    df = _read_csv_df(path)
    return Dict(String(r.hub) => Float64(r.det_annual_base) for r in eachrow(df))
end

"Write the stage-progress manifest as JSON."
function save_progress(path::AbstractString, prog::AbstractDict)
    open(path, "w") do io
        JSON3.write(io, prog)
    end
    return path
end

"Read the stage-progress manifest. Returns a Dict{String,Any}."
function load_progress(path::AbstractString)
    return copy(JSON3.read(read(path, String), Dict{String,Any}))
end

"Snapshot the global RNG (Xoshiro) state to JSON (UInt64 words as strings)."
function save_rng_state(path::AbstractString)
    r = copy(Random.default_rng())   # Xoshiro snapshot with fields s0..s4
    open(path, "w") do io
        JSON3.write(io, Dict("s0"=>string(r.s0), "s1"=>string(r.s1),
                             "s2"=>string(r.s2), "s3"=>string(r.s3), "s4"=>string(r.s4)))
    end
    return path
end

"Restore the global RNG state saved by `save_rng_state`."
function restore_rng_state!(path::AbstractString)
    d = JSON3.read(read(path, String))
    x = Random.Xoshiro(0)
    x.s0 = parse(UInt64, String(d["s0"])); x.s1 = parse(UInt64, String(d["s1"]))
    x.s2 = parse(UInt64, String(d["s2"])); x.s3 = parse(UInt64, String(d["s3"]))
    x.s4 = parse(UInt64, String(d["s4"]))
    copy!(Random.default_rng(), x)
    return nothing
end

"""
    train_checkpointed!(graph, ckpt_dir; iteration_limit, chunk_iters=25, seed=1) -> graph

Train `graph` to `iteration_limit` in chunks of `chunk_iters`, writing the SDDP
cuts (`cuts.json`) and the RNG state (`rng_state.json`) after each chunk, plus a
`train_progress.json` recording `train_iters_done`.  If `cuts.json` already exists
in `ckpt_dir`, RESUME: reload the cuts (`cut_selection=true`, kept in the oracle
pool), restore the RNG state, and continue from `train_iters_done`.  A fresh start
seeds the RNG with `seed`.

Resuming reproduces an uninterrupted run when the RNG + cuts fully determine
training (verified by the bit-identity arbiter test).
"""
function train_checkpointed!(graph::SDDP.PolicyGraph, ckpt_dir::AbstractString;
                             iteration_limit::Int, chunk_iters::Int = 25, seed::Int = 1)
    mkpath(ckpt_dir)
    cuts_path = joinpath(ckpt_dir, "cuts.json")
    rng_path  = joinpath(ckpt_dir, "rng_state.json")
    prog_path = joinpath(ckpt_dir, "train_progress.json")

    done = 0
    if isfile(cuts_path) && isfile(rng_path) && isfile(prog_path)
        SDDP.read_cuts_from_file(graph, cuts_path; cut_selection = true)
        restore_rng_state!(rng_path)
        done = Int(load_progress(prog_path)["train_iters_done"])
    else
        Random.seed!(seed)
    end

    while done < iteration_limit
        n = min(chunk_iters, iteration_limit - done)
        SDDP.train(graph; iteration_limit = n, add_to_existing_cuts = true,
                   risk_measure = SDDP.Expectation(), print_level = 0)
        done += n
        SDDP.write_cuts_to_file(graph, cuts_path)
        save_rng_state(rng_path)
        save_progress(prog_path, Dict("train_iters_done" => done))
    end
    return graph
end
