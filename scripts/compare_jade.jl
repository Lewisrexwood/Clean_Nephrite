# Attended JADE scenario comparison: replay the trained SDDP policy on coherent
# historical inflow year-sequences and write storage + price fans vs the
# deterministic point, ASX forward, and realized spot.
#   julia --project=. --threads=auto scripts/compare_jade.jl 2022-01-05 \
#       [--price-seqs 20] [--price-stride K] [--price-all] [--iters N] \
#       [--train-samples K] [--replay-stride K] [--no-det] [--min-history-days N] \
#       [--resume] [--price-only]
# Heavy: SDDP train + 336-step pricing over the priced sequences. Not CI.
# --threads=auto is important: the price pass threads over the 104 weeks.
# --resume: auto-detect furthest completed stage and continue from there.
# --price-only: skip training/replay; load checkpointed trajectories and re-price.
# Default --iters is 100; training checkpoints every 25 iterations.
# Demand shape: prefers the shipped data/static/demand_shape.csv (byte-identical
# to the full-history build); falls back to data/history/demand if absent.
using Nephrite, Dates, DataFrames, Printf, Statistics
using DuckDB, DBInterface
import SDDP, Random

function parse_opts(args)
    length(args) >= 1 || (println("usage: compare_jade.jl DATE [--price-seqs N|--price-stride K|--price-all] [--iters N] [--train-samples K] [--replay-stride K] [--no-det] [--min-history-days N] [--resume] [--price-only]"); exit(1))
    date = Date(args[1])
    o = Dict{Symbol,Any}(:n => 20, :stride => 0, :all => false, :iters => 100,
                         :mhd => nothing, :tsamp => 0, :det => true, :rstride => 1,
                         :resume => false, :price_only => false)
    i = 2
    while i <= length(args)
        a = args[i]
        if     a == "--price-seqs";   o[:n] = parse(Int, args[i+1]); i += 2
        elseif a == "--price-stride"; o[:stride] = parse(Int, args[i+1]); i += 2
        elseif a == "--price-all";    o[:all] = true; i += 1
        elseif a == "--iters";        o[:iters] = parse(Int, args[i+1]); i += 2
        elseif a == "--train-samples"; o[:tsamp] = parse(Int, args[i+1]); i += 2
        elseif a == "--replay-stride"; o[:rstride] = parse(Int, args[i+1]); i += 2
        elseif a == "--no-det";       o[:det] = false; i += 1
        elseif a == "--min-history-days"; o[:mhd] = parse(Int, args[i+1]); i += 2
        elseif a == "--resume";       o[:resume] = true; i += 1
        elseif a == "--price-only";   o[:price_only] = true; i += 1
        else error("unknown arg $a")
        end
    end
    return date, o
end

function main(args)
    date, o = parse_opts(args)
    root = normpath(joinpath(@__DIR__, "..", "data"))
    cfg  = normpath(joinpath(@__DIR__, "..", "config"))
    hist = joinpath(root, "history", "demand")
    n_weeks = 104

    # --- stage timing (flushes so background output is live) -----------------
    t_start = time(); t_prev = Ref(t_start)
    function lap(label)
        t = time()
        @printf("[%7.1fs total | +%6.1fs] %s\n", t - t_start, t - t_prev[], label)
        t_prev[] = t; flush(stdout)
    end
    @printf("=== compare_jade %s | n=%s stride=%s all=%s iters=%s resume=%s price_only=%s ===\n",
            args[1], o[:n], o[:stride], o[:all], o[:iters], o[:resume], o[:price_only]); flush(stdout)

    # Demand shape: prefer the shipped precomputed shape (clean repo); otherwise
    # assemble_inputs builds it from the raw history cache (full dev repo).
    shape_path = joinpath(root, "static", "demand_shape.csv")
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
        println("using shipped demand shape: $shape_path"); flush(stdout)
        df
    else
        println("no shipped shape — building demand profile from $hist"); flush(stdout)
        nothing
    end

    # HMD day-one storage for the snapshot date.
    jd  = Nephrite.load_jade(joinpath(root,"static","jade"), joinpath(cfg,"jade.toml"))
    sm  = Nephrite.build_stationmap(jd, joinpath(cfg,"stationmap.toml"))
    net = Nephrite.build_hydronet(jd, sm)
    prov = Nephrite.build_hmd_provider(joinpath(root,"static","hmd"), net)
    stor = Nephrite.historical_storage(prov, date)
    @printf("Day-one storage @ %s: nz=%.0f GWh  si=%.0f GWh\n", date, stor.nz_gwh, stor.si_gwh)
    lap("load pkg + JADE + HMD storage")

    ds = Nephrite.open_datastore(root, date)
    try
        mhd_kw = o[:mhd] === nothing ? (;) : (; min_history_days = o[:mhd])
        mi = Nephrite.assemble_inputs(ds, date; config_dir=cfg, history_dir=hist,
                 nz_gwh=stor.nz_gwh, si_gwh=stor.si_gwh, n_weeks=n_weeks,
                 forward_shape=forward_shape, mhd_kw...)
        lap("assemble_inputs")

        ckpt = joinpath(@__DIR__, "..", "runs", "jade_compare", string(date), "ckpt")
        mkpath(ckpt)
        prog_path = joinpath(ckpt, "progress.json")
        progress = isfile(prog_path) && (o[:resume] || o[:price_only]) ?
                   Nephrite.load_progress(prog_path) :
                   Dict{String,Any}("snapshot"=>string(date), "iters_target"=>o[:iters],
                       "train_samples"=>o[:tsamp], "n_weeks"=>n_weeks,
                       "master_done"=>false, "train_iters_done"=>0, "replay_done"=>false)
        # Config guard on resume: a checkpoint must match this invocation on the
        # fields that define the problem and the saved artifacts. `train_samples`
        # is guarded because the saved cuts were trained on that inflow support —
        # resuming with a different support would silently mix incompatible policies.
        # `iters_target` is deliberately NOT guarded: resuming with a higher --iters
        # to train further is a legitimate use of train_checkpointed!.
        if (o[:resume] || o[:price_only]) && isfile(prog_path)
            for (k, v) in (("snapshot", string(date)), ("n_weeks", n_weeks), ("train_samples", o[:tsamp]))
                progress[k] == v || error("compare_jade --resume: checkpoint $k=$(progress[k]) != $v; refusing to resume an incompatible run")
            end
        end
        det_path  = joinpath(ckpt, "det_overlay.csv")
        traj_path = joinpath(ckpt, "trajectories.parquet")

        # --- Deterministic overlay (skip on --no-det; reload if checkpointed) ---
        det_by_hub = Dict{String,Float64}("OTA"=>NaN, "BEN"=>NaN)
        if o[:det]
            if isfile(det_path) && (o[:resume] || o[:price_only])
                det_by_hub = Nephrite.load_det_overlay(det_path)
                println("Loaded deterministic overlay from checkpoint"); flush(stdout)
            else
                mr = Nephrite.solve_master(mi.weeks, mi.net, mi.initial_vol, mi.terminal_wv, mi.anchor)
                lap("solve_master (deterministic baseline)")
                det_traj = Dict((r, w) => mr.storage[(r, w)] for r in [x.name for x in mi.net.reservoirs], w in 1:n_weeks)
                det_infl = Dict((r, w) => mi.weeks[w].inflow_cumecs[r] for r in [x.name for x in mi.net.reservoirs], w in 1:n_weeks)
                det_pd = Nephrite.price_scenarios(mi.weeks, mi.net, mi.initial_vol, [det_traj], [det_infl])
                det_ann = Nephrite.cal_year_annual_base(det_pd, date, n_weeks, 2023, [0])
                for hub in ("OTA","BEN")
                    sub = det_ann[det_ann.hub .== hub, :annual_base]
                    det_by_hub[hub] = isempty(sub) ? NaN : only(sub)
                end
                Nephrite.save_det_overlay(det_path, det_by_hub)
                progress["master_done"] = true; Nephrite.save_progress(prog_path, progress)
            end
        end

        # --- Replay + pricing inputs: trained policy (skip both on --price-only) ---
        # `price_years` (the dry→wet-selected subset to price) is computed on a fresh
        # run from the real inflow sequences and PERSISTED in progress.json, so
        # --resume/--price-only price the IDENTICAL subset.
        local storage_by_seq, inflow_by_seq, sfan, price_years
        if o[:price_only] || (isfile(traj_path) && o[:resume])
            isfile(traj_path) || error("compare_jade: $traj_path is missing; the replay stage never " *
                "completed, so there is nothing to price. Re-run without --price-only to train + replay first.")
            haskey(progress, "price_years") || error("compare_jade: checkpoint has no persisted priced-year " *
                "selection (replay stage did not finish). Re-run without --price-only to complete replay first.")
            storage_by_seq, inflow_by_seq = Nephrite.load_trajectories(traj_path)
            sfan = Nephrite.storage_fan(storage_by_seq, mi.net, n_weeks)
            price_years = Int.(progress["price_years"])
            println("Loaded $(length(storage_by_seq)) replayed trajectories + $(length(price_years)) priced-year selection from checkpoint"); flush(stdout)
        else
            scen = Nephrite.empirical_inflow_scenarios(joinpath(cfg,"reservoirs.toml"), mi.net, date, n_weeks)
            if o[:tsamp] > 0
                scen = Dict(t => (length(v) <= o[:tsamp] ? v :
                                  v[unique(round.(Int, range(1, length(v); length=o[:tsamp])))])
                            for (t, v) in scen)
                @printf("Training support subsampled to <= %d inflow samples/stage\n", o[:tsamp]); flush(stdout)
            end
            graph = Nephrite.build_policy_graph(mi.weeks, mi.net, mi.initial_vol, mi.terminal_wv, mi.anchor, scen)
            lap("build_policy_graph")
            Nephrite.train_checkpointed!(graph, ckpt; iteration_limit=o[:iters], chunk_iters=25, seed=1)
            lap("train_checkpointed! ($(o[:iters]) iters, $(o[:tsamp]==0 ? "full" : string(o[:tsamp])) samples)")

            by_year = Nephrite.load_inflows_by_year(joinpath(cfg,"reservoirs.toml"))
            jade_to_cfg = Nephrite._jade_to_config_reservoir(joinpath(cfg,"reservoirs.toml"))
            sequences = Nephrite.historical_inflow_sequences(by_year, mi.net, jade_to_cfg, date, n_weeks)
            if o[:rstride] > 1
                yrs = sort(collect(keys(sequences)))[1:o[:rstride]:end]
                sequences = Dict(Y => sequences[Y] for Y in yrs)
                @printf("Replay thinned to every %d-th start-year\n", o[:rstride]); flush(stdout)
            end
            @printf("Historical sequences: %d start-years\n", length(sequences)); flush(stdout)
            storage_by_seq, inflow_by_seq = Nephrite.replay_historical(graph, sequences)
            sfan = Nephrite.storage_fan(storage_by_seq, mi.net, n_weeks)
            # Select the priced subset from the REAL inflow sequences (dry→wet) and
            # persist it so a later --price-only/--resume prices the same years.
            price_years = Nephrite.select_price_sequences(sequences; n=o[:n], stride=o[:stride], all=o[:all])
            Nephrite.save_trajectories(traj_path, storage_by_seq, inflow_by_seq)
            progress["replay_done"] = true; progress["price_years"] = price_years
            Nephrite.save_progress(prog_path, progress)
            lap("replay_historical ($(length(sequences)) seqs) + storage_fan + checkpoint")
        end

        # --- Price the subsample (batched, threaded; per-sequence fallback) -----
        @printf("Threads available: %d ; pricing %d sequences\n", Threads.nthreads(), length(price_years)); flush(stdout)
        local price_dist, priced
        try
            price_dist = Nephrite.price_scenarios(mi.weeks, mi.net, mi.initial_vol,
                             [storage_by_seq[Y] for Y in price_years],
                             [inflow_by_seq[Y] for Y in price_years])
            priced = collect(price_years)
            @printf("Priced all %d sequences (batched)\n", length(priced)); flush(stdout)
        catch err
            @warn "batched pricing hit an infeasible sequence — falling back to per-sequence" exception=err
            price_dist = Dict{Tuple{String,Int,Int},Vector{Float64}}(); priced = Int[]
            for (k, Y) in enumerate(price_years)
                try
                    pd1 = Nephrite.price_scenarios(mi.weeks, mi.net, mi.initial_vol,
                              [storage_by_seq[Y]], [inflow_by_seq[Y]])
                    for (key, v) in pd1; push!(get!(price_dist, key, Float64[]), v[1]); end
                    push!(priced, Y)
                    @printf("    priced %2d/%d  start-year %d\n", k, length(price_years), Y); flush(stdout)
                catch e2
                    @warn "pricing failed for start-year $Y — dropping" exception=e2
                end
                k % 5 == 0 && GC.gc()
            end
        end
        length(priced) >= 1 || error("compare_jade: no sequences priced successfully")
        lap("price subsample ($(length(priced)) priced)")

        monthly = Nephrite.forward_curves_dist(price_dist, date; n_weeks = n_weeks)
        period  = Nephrite.period_price_fan(price_dist, date; n_weeks = n_weeks)
        cal2023 = Nephrite.cal_year_annual_base(price_dist, date, n_weeks, 2023, priced)

        # Overlays: deterministic point (mean-inflow path, skipped with --no-det), ASX, realized.
        fdir = joinpath(root, "static", "forward_prices")
        csvs = isdir(fdir) ? filter(f -> endswith(f, ".csv"), readdir(fdir)) : String[]
        forward_df = isempty(csvs) ? DataFrame() :
            reduce(vcat, [Nephrite.load_forward_prices(joinpath(fdir, f)) for f in csvs])

        overlay_rows = NamedTuple[]
        for hub in ("OTA","BEN")
            det = det_by_hub[hub]
            asx = isempty(forward_df) ? NaN : Nephrite.market_annual_base(forward_df, date, 2023, hub)
            rea = isempty(forward_df) ? NaN : Nephrite.realised_annual_spot(forward_df, 2023, hub)
            push!(overlay_rows, (hub=hub, deterministic=det, asx_forward=asx, realized=rea))
        end
        overlays = DataFrame(overlay_rows)
        lap("deterministic point + overlays")

        # Write outputs.
        outdir = normpath(joinpath(@__DIR__, "..", "runs", "jade_compare", string(date))); mkpath(outdir)
        Nephrite._write_csv(sfan,    joinpath(outdir, "storage_fan.csv"))
        Nephrite._write_csv(monthly, joinpath(outdir, "price_fan_monthly.csv"))
        Nephrite._write_csv(period,  joinpath(outdir, "period_price_fan.csv"))
        Nephrite._write_csv(Nephrite.period_demand(mi.weeks, date; n_weeks = n_weeks),
                            joinpath(outdir, "period_demand.csv"))
        Nephrite._write_csv(cal2023, joinpath(outdir, "cal2023_annual.csv"))
        Nephrite._write_csv(overlays, joinpath(outdir, "overlays.csv"))

        # Notes summary.
        open(joinpath(outdir, "compare_notes.txt"), "w") do io
            println(io, "JADE scenario comparison — snapshot $date")
            println(io, "Storage sequences: $(length(storage_by_seq)); priced: $(length(priced)) / $(length(price_years))")
            println(io, "Storage envelope (agg GWh): min=$(round(minimum(sfan.agg_gwh),digits=1)) max=$(round(maximum(sfan.agg_gwh),digits=1))")
            println(io, "NOTE: det = deterministic point priced on the MEAN-CLIMATOLOGY inflow path (not a historical")
            println(io, "      year); it is a central-estimate reference, not strictly comparable to the fan quantiles.")
            for hub in ("OTA","BEN")
                ann = cal2023[cal2023.hub .== hub, :annual_base]
                isempty(ann) && continue
                p10, p50, p90 = quantile(ann, 0.1), quantile(ann, 0.5), quantile(ann, 0.9)
                ov = only(overlays[overlays.hub .== hub, :])
                bracket = (!isnan(ov.realized) && p10 <= ov.realized <= p90) ? "YES" : "NO"
                @printf(io, "%s cal-2023 base: fan p10=%.1f p50=%.1f p90=%.1f | det=%.1f asx=%.1f realized=%.1f | realized in [p10,p90]? %s | dispersion(p90-p10)=%.1f\n",
                        hub, p10, p50, p90, ov.deterministic, ov.asx_forward, ov.realized, bracket, p90-p10)
            end
        end
        lap("write CSVs + notes")
        @printf("=== TOTAL %.1fs ===\n", time() - t_start); flush(stdout)
        println("\nWrote storage_fan.csv, price_fan_monthly.csv, period_price_fan.csv, period_demand.csv, cal2023_annual.csv, overlays.csv, compare_notes.txt -> $outdir")
        println(read(joinpath(outdir, "compare_notes.txt"), String))
    finally
        close(ds)
    end
end

main(ARGS)
