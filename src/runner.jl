using Dates, DataFrames, SHA
using JuMP: MOI

# Curtailment above this fraction of served demand means the per-hub over-supply
# slack is binding enough to pin nodal prices to ≈ −CURTAIL_PENALTY rather than a
# real marginal generator.  Above this threshold we @warn so distorted prices
# cannot silently propagate into the ASX outputs; we never error (the toy fixture
# legitimately curtails because JADE must-run exceeds synthetic demand).
const CURTAIL_WARN_FRACTION = 1e-3

# ===========================================================================
# runner.jl — end-to-end orchestration of a single deterministic model run.
#
#   pre-flight POC/station coverage checks
#     → assemble_inputs
#     → solve_master (104-week water budget)
#     → threaded 336-step weekly subproblems (independent given the master)
#     → manifest written into runs/<run-id>/
#
# The master uses each week's 96-period representative day (`WeekInputs.periods`);
# the subproblem uses the 336 chronological 30-min steps (`WeekInputs.periods336`,
# built in `assemble_inputs`).  Subproblem prices ARE the run's nodal prices.
# ===========================================================================

"""
Result of one end-to-end run:
- `prices`     : `(hub, week, step) => \$/MWh` — subproblem 30-min nodal prices
                 across the whole horizon (week ∈ 1..n_weeks, step ∈ 1..336).
                 On the SDDP path this is the per-(hub,week,step) mean across
                 scenarios.
- `master`     : the `MasterResult` (storage, water values, coarse prices).
                 On the SDDP path this is a sentinel with empty Dicts and
                 `objective = sddp_lower_bound`.
- `manifest`   : reproducibility manifest (commit, config/snapshot hashes, run
                 inputs, per-stage wall-clock).
- `run_dir`    : `runs/<run-id>/` where the manifest (and outputs) live.
- `n_weeks`    : modelled horizon length.
- `price_dist` : `(hub, week, step) => per-scenario Vector` — full SDDP price
                 distribution, or `nothing` on the deterministic path.
"""
struct RunResult
    prices::Dict{Tuple{String,Int,Int},Float64}
    master::MasterResult
    manifest::Dict
    run_dir::String
    n_weeks::Int
    price_dist::Union{Nothing,Dict{Tuple{String,Int,Int},Vector{Float64}}}
end

"""
    run_model(snapshot_date; root, config_dir, history_dir, nz_gwh, si_gwh,
              n_weeks=104, seed=1, overrides=Dict(), min_history_days=<demand.toml>)
        -> RunResult

Solve the deterministic model for `snapshot_date` and write the run manifest to
`runs/<run-id>/`.  See `RunResult` for the return shape.  `overrides` are the
what-if knobs documented on `assemble_inputs` (demand_growth, hvdc_derate,
inflow_scale, fuel_scale, tiwai_off); they are stringified into the manifest.
"""
function run_model(snapshot_date::Date; root::AbstractString,
                   config_dir::AbstractString, history_dir::AbstractString,
                   nz_gwh::Real, si_gwh::Real, n_weeks::Int = 104, seed::Int = 1,
                   overrides::Dict = Dict(),
                   engine::Symbol = :deterministic,
                   n_scenarios::Int = 100, iteration_limit::Int = 200,
                   warm_start::Symbol = :anchor,
                   extract_fcf::Bool = false,
                   min_history_days::Int =
                       TOML.parsefile(joinpath(config_dir, "demand.toml"))["forward"]["min_history_days"],
                   forward_shape::Union{Nothing,DataFrame} = nothing)
    extract_fcf && engine != :sddp &&
        error("run_model: extract_fcf=true requires engine=:sddp " *
              "(the value-function sampler needs a trained policy graph)")
    t0 = time()
    ds = open_datastore(root, snapshot_date)
    try
        cfg(p) = joinpath(config_dir, p)
        project_root = normpath(dirname(config_dir))
        jade_dir = joinpath(project_root, "data", "static", "jade")

        # --- 1. Pre-flight coverage checks ----------------------------------
        # build_stationmap loud-fails on any JADE station missing a hub.
        jd = load_jade(jade_dir, cfg("jade.toml"))
        build_stationmap(jd, cfg("stationmap.toml"))
        hm = build_hubmap(ds, cfg("hubmap.toml"))
        _preflight_pocs(ds, hm)
        t_preflight = time()

        # --- 2. Assemble inputs ---------------------------------------------
        mi = assemble_inputs(ds, snapshot_date; config_dir = config_dir,
                             history_dir = history_dir, nz_gwh = nz_gwh,
                             si_gwh = si_gwh, n_weeks = n_weeks,
                             overrides = overrides, min_history_days = min_history_days,
                             forward_shape = forward_shape)
        t_assemble = time()

        # --- SDDP engine (Phase 2b) -----------------------------------------
        # Stochastic path: train a policy, simulate, price each scenario, and
        # write the distributional ASX curves.  The deterministic path below is
        # untouched (engine == :deterministic).
        if engine == :sddp
            scen = empirical_inflow_scenarios(joinpath(config_dir, "reservoirs.toml"),
                                              mi.net, snapshot_date, n_weeks)
            sr = solve_sddp(mi, scen; n_scenarios = n_scenarios,
                            iteration_limit = iteration_limit, seed = seed,
                            warm_start = warm_start)

            # Point `prices` = per-(hub,week,step) mean across scenarios.
            prices = Dict{Tuple{String,Int,Int},Float64}()
            for (k, v) in sr.price_dist
                prices[k] = sum(v) / length(v)
            end

            config_paths = [cfg(p) for p in sort(readdir(config_dir)) if endswith(p, ".toml")]
            manifest = build_manifest(; snapshot_dir = ds.dir,
                                      config_paths = config_paths, seed = seed)
            manifest["nz_gwh"]       = Float64(nz_gwh)
            manifest["si_gwh"]       = Float64(si_gwh)
            manifest["n_weeks"]      = n_weeks
            manifest["engine"]       = "sddp"
            manifest["n_scenarios"]  = n_scenarios
            manifest["sddp_lower_bound"] = sr.lower_bound
            manifest["overrides"]    = Dict(string(k) => string(v) for (k, v) in overrides)

            run_id  = "$(snapshot_date)_$(_config_hash(config_paths))_sddp_" *
                      _scenario_hash(nz_gwh, si_gwh, seed, overrides)
            run_dir = joinpath(project_root, "runs", run_id)
            mkpath(run_dir)
            write_manifest(joinpath(run_dir, "manifest.json"), manifest)
            write_distribution_outputs(run_dir, sr.price_dist, snapshot_date; n_weeks = n_weeks)

            if extract_fcf
                sm    = build_stationmap(jd, cfg("stationmap.toml"))
                plant = load_plant(cfg("plant.toml"))
                rv    = reservoir_implied_wv(ds, plant, sm)
                offers = Dict{String,Float64}(String(row.reservoir) => Float64(row.implied_wv)
                              for row in eachrow(rv))
                fcfg = load_fcf_config(cfg("model.toml"))
                fcf  = extract_run_fcf(sr.policy, mi.net, mi.initial_vol,
                                       sr.trajectories, offers, fcfg)
                write_run_fcf(fcf, joinpath(run_dir, "fcf_curves.csv"))
                SDDP.write_cuts_to_file(sr.policy, joinpath(run_dir, "fcf_cuts.json"))
            end

            # A point MasterResult sentinel (SDDP has no master); diagnostics that
            # need a master are not written on the SDDP path.
            sentinel = MasterResult(Dict{Tuple{String,Int},Float64}(),
                                    Dict{Tuple{String,Int},Float64}(),
                                    Dict{Tuple{String,Int},Float64}(),
                                    sr.lower_bound, MOI.OPTIMAL)
            return RunResult(prices, sentinel, manifest, run_dir, n_weeks, sr.price_dist)
        end

        # --- 3. Master water-budget LP --------------------------------------
        # Gate on the master's solver status BEFORE touching any subproblem: an
        # infeasible/unbounded master returns meaningless storage targets that
        # would silently pin every subproblem's end_vol.
        mr = solve_master(mi.weeks, mi.net, mi.initial_vol, mi.terminal_wv, mi.anchor)
        mr.status == MOI.OPTIMAL ||
            error("run_model: master LP did not solve (status $(mr.status)) — " *
                  "storage targets are meaningless; aborting before subproblems")
        t_master = time()

        # --- 4. Threaded weekly subproblems (336 chronological steps) -------
        # Independent given the master's storage targets.  Each thread writes a
        # disjoint index of a pre-sized vector — no shared-Dict race; the merge
        # into `prices` happens after the loop, so the result is order-independent.
        results = Vector{SubproblemResult}(undef, n_weeks)
        reservoir_names = [r.name for r in mi.net.reservoirs]
        Threads.@threads for i in 1:n_weeks
            start_vol = i == 1 ? mi.initial_vol :
                        Dict(r => mr.storage[(r, i - 1)] for r in reservoir_names)
            end_vol = Dict(r => mr.storage[(r, i)] for r in reservoir_names)
            results[i] = solve_subproblem(mi.weeks[i].periods336, mi.weeks[i].inp,
                                          start_vol, end_vol,
                                          mi.weeks[i].inflow_cumecs)
        end

        prices = Dict{Tuple{String,Int,Int},Float64}()
        for i in 1:n_weeks
            sp = results[i]
            sp.status == MOI.OPTIMAL ||
                error("run_model: subproblem week $i did not solve (status $(sp.status))")
            for ((hub, step), p) in sp.prices
                prices[(hub, i, step)] = p
            end
        end
        t_subproblems = time()

        # --- Curtailment audit ----------------------------------------------
        # When the per-hub over-supply slack `curtail` binds, that hub/step's
        # balance dual (the nodal price) is pinned to ≈ −CURTAIL_PENALTY rather
        # than a real marginal generator.  Aggregate total curtailed energy and
        # total served demand (order-independently — fixed iteration over weeks
        # then sorted keys) so a binding slack can be both warned about and
        # audited from the manifest, never silently distorting ASX outputs.
        curtail_mwh, demand_mwh, hot_weeks =
            _curtailment_audit(results, mi.weeks, n_weeks)
        curtail_fraction = demand_mwh > 0 ? curtail_mwh / demand_mwh : 0.0
        if curtail_fraction > CURTAIL_WARN_FRACTION
            @warn "run_model: over-supply curtailment is binding — nodal prices " *
                  "at affected hubs/steps are pinned to ≈ −CURTAIL_PENALTY and " *
                  "are NOT meaningful marginal prices" curtailed_fraction=curtail_fraction curtailed_mwh=curtail_mwh weeks_hubs=hot_weeks
        end

        # --- 5. Manifest + run directory ------------------------------------
        config_paths = [cfg(p) for p in sort(readdir(config_dir)) if endswith(p, ".toml")]
        manifest = build_manifest(; snapshot_dir = ds.dir,
                                  config_paths = config_paths, seed = seed)
        manifest["nz_gwh"]      = Float64(nz_gwh)
        manifest["si_gwh"]      = Float64(si_gwh)
        manifest["n_weeks"]     = n_weeks
        manifest["overrides"]   = Dict(string(k) => string(v) for (k, v) in overrides)
        manifest["curtailment_mwh"]      = curtail_mwh
        manifest["curtailment_fraction"] = curtail_fraction
        manifest["wall_clock_s"] = Dict(
            "preflight"    => t_preflight - t0,
            "assemble"     => t_assemble - t_preflight,
            "master"       => t_master - t_assemble,
            "subproblems"  => t_subproblems - t_master,
        )

        run_id  = "$(snapshot_date)_$(_config_hash(config_paths))_" *
                  _scenario_hash(nz_gwh, si_gwh, seed, overrides)
        run_dir = joinpath(project_root, "runs", run_id)
        mkpath(run_dir)
        write_manifest(joinpath(run_dir, "manifest.json"), manifest)

        rr = RunResult(prices, mr, manifest, run_dir, n_weeks, nothing)
        write_outputs(run_dir, rr, mi, snapshot_date)
        return rr
    finally
        close(ds)
    end
end

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

"""
Assert that every latest-energy offer POC and every demand POC in the snapshot
resolves through the hubmap.  Errors listing all gaps — no silent dropping of
generation or load.
"""
function _preflight_pocs(ds::DataStore, hm::HubMap)
    offer_pocs = query(ds,
        "SELECT DISTINCT PointOfConnection AS poc FROM offers " *
        "WHERE ProductType='Energy' AND IsLatestYesNo='Y'").poc
    demand_pocs = query(ds,
        "SELECT DISTINCT PointOfConnectionCode AS poc FROM grid_demand").poc

    missing_offer  = [String(p) for p in offer_pocs  if !haskey(hm.poc_to_hub, String(p))]
    missing_demand = [String(p) for p in demand_pocs if !haskey(hm.poc_to_hub, String(p))]

    if !isempty(missing_offer) || !isempty(missing_demand)
        msg = "run_model pre-flight: POCs missing from hubmap (add regions/overrides to hubmap.toml):"
        isempty(missing_offer)  || (msg *= "\n  offer POCs: "  * join(sort(unique(missing_offer)), ", "))
        isempty(missing_demand) || (msg *= "\n  demand POCs: " * join(sort(unique(missing_demand)), ", "))
        error(msg)
    end
    return nothing
end

"""
Aggregate total curtailed energy (MWh) and total served demand (MWh) across all
weeks/hubs/steps, plus a sorted list of \"week W hub H\" labels where curtailment
binds.  Energy = MW × step-hours; the subproblem ran `weeks[i].periods336`, so we
read each step's `hours` from there.  Iteration order is fixed (weeks 1..n_weeks,
then sorted generation keys), so the result is order-independent.
"""
function _curtailment_audit(results::Vector{SubproblemResult},
                            weeks::Vector{WeekInputs}, n_weeks::Int)
    curtail_mwh = 0.0
    demand_mwh  = 0.0
    hot = Set{Tuple{Int,String}}()
    for i in 1:n_weeks
        steps = weeks[i].periods336
        gen   = results[i].generation
        for (key, val) in gen
            # `generation` mixes 3-tuple ("curtail",hub,step) keys with
            # other arities (e.g. 2-tuple ("soc0",b) when a battery is
            # present) — only destructure the curtail keys we expect.
            (key isa Tuple && length(key) == 3 && key[1] == "curtail") || continue
            _, hub, step = key
            step = step::Int
            hours = step <= length(steps) ? steps[step].hours : 0.5
            mwh = val * hours
            if mwh > 0
                curtail_mwh += mwh
                push!(hot, (i, String(hub)))
            end
        end
        # Served demand denominator: sum of each step's demand across hubs × hours.
        for p in steps
            for (_, mw) in p.demand
                demand_mwh += mw * p.hours
            end
        end
    end
    hot_labels = ["week $w hub $h" for (w, h) in sort(collect(hot))]
    return curtail_mwh, demand_mwh, hot_labels
end

"Stable short hash of the config set (path + content), for the run-id."
function _config_hash(config_paths::Vector{String})
    ctx = SHA.SHA256_CTX()
    for p in sort(config_paths)
        SHA.update!(ctx, codeunits(basename(p)))
        SHA.update!(ctx, read(p))
    end
    return bytes2hex(SHA.digest!(ctx))[1:12]
end

"""
Stable short hash of the per-run SCENARIO inputs (storage targets, seed,
what-if overrides), so distinct scenarios on the same date+config get distinct
`runs/<id>/` directories instead of clobbering each other.  Overrides keys are
sorted for determinism; identical inputs ⇒ identical hash.
"""
function _scenario_hash(nz_gwh::Real, si_gwh::Real, seed::Int, overrides::Dict)
    ov = join(["$(string(k))=$(string(overrides[k]))" for k in sort(collect(keys(overrides)), by=string)], ";")
    canonical = "nz=$(Float64(nz_gwh));si=$(Float64(si_gwh));seed=$(seed);overrides=$(ov)"
    return bytes2hex(SHA.sha256(codeunits(canonical)))[1:12]
end
