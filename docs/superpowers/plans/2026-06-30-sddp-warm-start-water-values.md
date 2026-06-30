# SDDP Warm-Start with Prior Water Values — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Inject offer-implied water values into SDDP at training start as two client-facing options — value-function cuts (A) and the existing objective anchor (C) — and provide a harness showing how each affects policy and water values.

**Architecture:** A `warm_start::Symbol` selector on the SDDP path (`:none`/`:anchor`/`:cuts`/`:both`). Option A is a new `src/warmstart.jl` that converts per-reservoir water values into SDDP-format linear cuts (point-slope, anchored at snapshot storage, height = model lower bound) and injects them via the public `SDDP.read_cuts_from_file`. Option C reuses the existing anchor (objective opportunity-cost). Both share `mi.anchor.values` (WV source) and `mi.anchor.weights` (13-week linear decay).

**Tech Stack:** Julia 1.12, JuMP, HiGHS, SDDP.jl 1.13.2, JSON3, DataFrames.

## Global Constraints

- Cut slope convention (must match `src/fcfsddp.jl:31`): `π_r = −WV_r · coeff_r · MWH_PER_MM3_PER_SP` ($/Mm³), where `coeff = downstream_energy_coeff(net)`.
- Cut file schema is SDDP.jl's `write_cuts_to_file` format: per node `{"node": string(t), "single_cuts": [{"intercept", "coefficients", "state"}], "multi_cuts": [], "risk_set_cuts": []}`. `"intercept"` is the cut height at `"state"`; `"coefficients"`/`"state"` are keyed `s[<reservoir>]` and MUST share identical key sets (SDDP's `_add_cut` indexes coefficients by every state key).
- Reservoirs with `coeff_r == 0` (run-of-river / no downstream station) get no cut.
- Default `warm_start = :anchor` everywhere — preserves current behaviour; existing golden tests must stay green.
- Use JSON3 for serialization (`open(io -> JSON3.write(io, x), path, "w")`), matching `src/manifest.jl`.
- Follow repo conventions: fail loud with `error(...)` on invalid input; one responsibility per file.

---

### Task 1: Pure cut construction — `wv_warmstart_cuts`

**Files:**
- Create: `src/warmstart.jl`
- Modify: `src/Nephrite.jl` (add `include("warmstart.jl")` after `include("sddp.jl")`)
- Create: `test/test_warmstart.jl`
- Modify: `test/runtests.jl` (add `include("test_warmstart.jl")` after `include("test_fcfsddp.jl")`)

**Interfaces:**
- Consumes: `downstream_energy_coeff(net)::Dict` and `MWH_PER_MM3_PER_SP` (from `src/hydroenergy.jl`); `HydroNetwork` with field `reservoirs` (each `r.name::String`).
- Produces: `wv_warmstart_cuts(net::HydroNetwork, anchor_vol::Dict{String,Float64}, wv_values::Dict{String,Float64}, decay_weights::Vector{Float64}, lb::Float64) -> Vector{Dict{String,Any}}`.

- [ ] **Step 1: Create the test file with failing tests for cut construction**

Create `test/test_warmstart.jl`:

```julia
using Test, Nephrite, DataFrames
import SDDP

@testset "warmstart" begin
    # --- Toy net: L has a downstream station (coeff>0); Z is spill-only (coeff==0). ---
    function _toy_net()
        res  = [Nephrite.JadeReservoir("L", "SI", 0.0, 1000.0),
                Nephrite.JadeReservoir("Z", "SI", 0.0, 500.0)]
        stn  = Nephrite.HydroStation("g", 1e6, 1.0, [(0.0, 0.0), (1e6, 1e6)])
        arcs = [Nephrite.Arc("L", "SEA", "g", 1e6),
                Nephrite.Arc("Z", "SEA", "", Inf)]
        return Nephrite.HydroNetwork(res, arcs, Dict("g" => stn),
                   Dict("g" => "BEN"), Dict("L" => ["SEA"], "Z" => ["SEA"]))
    end

    @testset "wv_warmstart_cuts builds point-slope cuts with the dual sign convention" begin
        net = _toy_net()
        m   = Nephrite.MWH_PER_MM3_PER_SP
        wv  = Dict("L" => 50.0, "Z" => 40.0)        # Z is coeff==0 → excluded
        avol = Dict("L" => 500.0, "Z" => 300.0)
        cuts = Nephrite.wv_warmstart_cuts(net, avol, wv, [1.0, 0.5], -10.0)

        @test length(cuts) == 2                      # one block per week
        @test cuts[1]["node"] == "1"
        @test cuts[2]["node"] == "2"

        sc1 = cuts[1]["single_cuts"][1]
        @test sc1["intercept"] == -10.0             # height == lb at the anchor
        @test isapprox(sc1["coefficients"]["s[L]"], 1.0 * (-50.0 * 1.0 * m); rtol = 1e-9)
        @test sc1["state"]["s[L]"] == 500.0
        @test !haskey(sc1["coefficients"], "s[Z]")  # coeff==0 reservoir excluded
        @test !haskey(sc1["state"], "s[Z]")
        @test keys(sc1["coefficients"]) == keys(sc1["state"])  # identical key sets

        sc2 = cuts[2]["single_cuts"][1]
        @test isapprox(sc2["coefficients"]["s[L]"], 0.5 * (-50.0 * 1.0 * m); rtol = 1e-9)

        @test cuts[1]["multi_cuts"] == Dict{String,Any}[]
        @test cuts[1]["risk_set_cuts"] == Vector{Float64}[]
    end

    @testset "wv_warmstart_cuts skips empty/zero priors" begin
        net = _toy_net()
        @test isempty(Nephrite.wv_warmstart_cuts(net, Dict("L" => 500.0),
                          Dict{String,Float64}(), [1.0, 0.5], -10.0))     # no WV at all
        @test isempty(Nephrite.wv_warmstart_cuts(net, Dict("L" => 500.0),
                          Dict("L" => 0.0), [1.0], -10.0))                # WV == 0 → skip
        @test isempty(Nephrite.wv_warmstart_cuts(net, Dict("Z" => 300.0),
                          Dict("Z" => 40.0), [1.0], -10.0))               # only coeff==0 → skip
    end
end
```

- [ ] **Step 2: Wire the new file into the package and test suite**

In `src/Nephrite.jl`, add after line `include("sddp.jl")`:

```julia
include("warmstart.jl")
```

In `test/runtests.jl`, add after `include("test_fcfsddp.jl")`:

```julia
    include("test_warmstart.jl")
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `julia --project=. -e 'using Pkg; Pkg.test()' ` (or, faster, run just the file after the suite loads)
Expected: FAIL — `UndefVarError: wv_warmstart_cuts not defined` (file `src/warmstart.jl` does not exist yet).

- [ ] **Step 4: Create `src/warmstart.jl` with the cut builder**

Create `src/warmstart.jl`:

```julia
using JSON3
import SDDP

# warmstart.jl — Option A warm start: convert prior per-reservoir water values into
# SDDP value-function cuts and inject them into a policy graph before training.
# Companion to the objective anchor (Option C, in sddp.jl/master.jl); both share the
# offer-implied WV source and the decay_weeks taper. See
# docs/superpowers/specs/2026-06-30-sddp-warm-start-water-values-design.md.

"""
    wv_warmstart_cuts(net, anchor_vol, wv_values, decay_weights, lb) -> Vector{Dict{String,Any}}

Build one SDDP single-cut per reservoir per weekly node from prior water values,
in `SDDP.write_cuts_to_file` schema (ready for `apply_wv_warmstart!`).

For node `t` and reservoir `r` with downstream energy coeff `c_r > 0` and `wv_r != 0`:

    slope  π_{r,t} = decay_weights[t] · (−wv_r · c_r · MWH_PER_MM3_PER_SP)      [\$/Mm³]
    cut_t:  V(s) ≥ lb + Σ_r π_{r,t} · (s_r − anchor_vol_r)

i.e. point-slope anchored at `anchor_vol` (Mm³) with height `lb`. Reservoirs with
`c_r == 0` or zero/missing `wv` are skipped; a node whose cut would be empty is
omitted. Node names are `string(t)` for `t in 1:length(decay_weights)`; state keys
are `s[<reservoir>]` (matching `_fcf_state_key`).
"""
function wv_warmstart_cuts(net::HydroNetwork, anchor_vol::Dict{String,Float64},
                           wv_values::Dict{String,Float64},
                           decay_weights::Vector{Float64}, lb::Float64)
    coeff = downstream_energy_coeff(net)
    cuts = Dict{String,Any}[]
    for t in 1:length(decay_weights)
        coeffs = Dict{String,Float64}()
        state  = Dict{String,Float64}()
        for r in net.reservoirs
            c  = get(coeff, r.name, 0.0)
            wv = get(wv_values, r.name, 0.0)
            (c > 0 && wv != 0.0) || continue
            key = "s[$(r.name)]"
            coeffs[key] = decay_weights[t] * (-wv * c * MWH_PER_MM3_PER_SP)
            state[key]  = get(anchor_vol, r.name, 0.0)
        end
        isempty(coeffs) && continue
        push!(cuts, Dict{String,Any}(
            "node" => string(t),
            "single_cuts" => Any[Dict{String,Any}(
                "intercept"    => lb,
                "coefficients" => coeffs,
                "state"        => state)],
            "multi_cuts" => Dict{String,Any}[],
            "risk_set_cuts" => Vector{Float64}[]))
    end
    return cuts
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: PASS for the `warmstart` testset (the two `@testset`s above).

- [ ] **Step 6: Commit**

```bash
git add src/warmstart.jl src/Nephrite.jl test/test_warmstart.jl test/runtests.jl
git commit -m "feat(warmstart): build SDDP value-function cuts from prior water values"
```

---

### Task 2: Cut injection — `apply_wv_warmstart!`

**Files:**
- Modify: `src/warmstart.jl` (append the injection function)
- Modify: `test/test_warmstart.jl` (add an injection testset)

**Interfaces:**
- Consumes: `wv_warmstart_cuts` (Task 1); `build_policy_graph` and `sddp_lower_bound` (from `src/sddp.jl`); `SDDP.read_cuts_from_file`, `SDDP.calculate_bound`.
- Produces: `apply_wv_warmstart!(graph::SDDP.PolicyGraph, cuts::Vector{Dict{String,Any}}) -> SDDP.PolicyGraph`.

- [ ] **Step 1: Add the failing injection test**

In `test/test_warmstart.jl`, add inside the `@testset "warmstart"` block (before its closing `end`):

```julia
    # --- A 2-week toy policy graph used by injection + selector tests. ---
    function _toy_graph_inputs()
        res  = [Nephrite.JadeReservoir("L", "SI", 0.0, 1000.0)]
        stn  = Nephrite.HydroStation("g", 1e6, 1.0, [(0.0, 0.0), (1e6, 1e6)])
        arcs = [Nephrite.Arc("L", "SEA", "g", 1e6)]
        net  = Nephrite.HydroNetwork(res, arcs, Dict("g" => stn),
                   Dict("g" => "BEN"), Dict("L" => ["SEA"]))
        hubs = [Nephrite.Hub("BEN", "BEN2201", "Benmore", "SI")]
        topo = Nephrite.Topology(hubs, Nephrite.Corridor[])
        thermal = DataFrame(hub = ["BEN"], price = [200.0], mw = [1e6])
        mustrun = DataFrame(hub = String[], mw = Float64[])
        inp = Nephrite.DispatchInputs(topo, net, thermal, mustrun, NamedTuple[], 10000.0)
        per96  = [Nephrite.Period("p", 1.0, Dict("BEN" => 100.0))]
        per336 = [Nephrite.Period("t$i", 42.0, Dict("BEN" => 100.0)) for i in 1:4]
        wk = Nephrite.WeekInputs(per96, per336, inp, Dict("L" => 0.0))
        weeks = [wk, wk]
        term  = DataFrame(stored_energy = [0.0, 1e9], value = [0.0, 0.0])
        anch  = (values = Dict("L" => 30.0),
                 weights = Nephrite.anchor_weights(13, 2), weight = 1.0)
        mi   = Nephrite.ModelInputs(weeks, net, Dict("L" => 500.0), term, anch)
        scen = Dict(t => [Dict("L" => 0.0), Dict("L" => 200.0)] for t in 1:2)
        return mi, scen
    end

    @testset "apply_wv_warmstart! adds the cut into the node value function" begin
        mi, scen = _toy_graph_inputs()
        graph = Nephrite.build_policy_graph(mi.weeks, mi.net, mi.initial_vol,
                                            mi.terminal_wv, mi.anchor, scen)
        lb   = Nephrite.sddp_lower_bound(mi.net, mi.terminal_wv)
        cuts = Nephrite.wv_warmstart_cuts(mi.net, mi.initial_vol, mi.anchor.values,
                                          mi.anchor.weights, lb)
        @test !isempty(cuts)
        n_before = length(graph[1].bellman_function.global_theta.cuts)
        Nephrite.apply_wv_warmstart!(graph, cuts)
        n_after = length(graph[1].bellman_function.global_theta.cuts)
        @test n_after > n_before
        @test isfinite(SDDP.calculate_bound(graph))
    end

    @testset "apply_wv_warmstart! is a no-op on empty cuts" begin
        mi, scen = _toy_graph_inputs()
        graph = Nephrite.build_policy_graph(mi.weeks, mi.net, mi.initial_vol,
                                            mi.terminal_wv, mi.anchor, scen)
        n_before = length(graph[1].bellman_function.global_theta.cuts)
        g2 = Nephrite.apply_wv_warmstart!(graph, Dict{String,Any}[])
        @test g2 === graph
        @test length(graph[1].bellman_function.global_theta.cuts) == n_before
    end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: FAIL — `UndefVarError: apply_wv_warmstart! not defined`.

- [ ] **Step 3: Implement `apply_wv_warmstart!`**

Append to `src/warmstart.jl`:

```julia
"""
    apply_wv_warmstart!(graph, cuts) -> graph

Inject `cuts` (from `wv_warmstart_cuts`) into `graph` by writing them to a temp file
in SDDP.jl's cut schema and loading via the public `SDDP.read_cuts_from_file`. Each
cut becomes `V(s) ≥ intercept + Σ coefficients·(s − state)` on its node's cost-to-go.
No-op when `cuts` is empty. Returns `graph`.
"""
function apply_wv_warmstart!(graph::SDDP.PolicyGraph, cuts::Vector{Dict{String,Any}})
    isempty(cuts) && return graph
    mktempdir() do dir
        path = joinpath(dir, "warmstart_cuts.json")
        open(io -> JSON3.write(io, cuts), path, "w")
        SDDP.read_cuts_from_file(graph, path)
    end
    return graph
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: PASS — cut count on node 1 increases by 1; bound is finite; empty-cuts path is a no-op.

- [ ] **Step 5: Commit**

```bash
git add src/warmstart.jl test/test_warmstart.jl
git commit -m "feat(warmstart): inject WV cuts into a policy graph via read_cuts_from_file"
```

---

### Task 3: Warm-start selector + `solve_sddp` wiring

**Files:**
- Modify: `src/warmstart.jl` (add `_zero_weight_anchor`, `_warmstart_plan`)
- Modify: `src/sddp.jl` (`solve_sddp` gains `warm_start::Symbol = :anchor`)
- Modify: `test/test_warmstart.jl` (selector unit tests + 4-mode smoke)

**Interfaces:**
- Consumes: `mi.anchor` (NamedTuple `(values, weights, weight)`), `build_policy_graph`, `train_policy!`, `simulate_policy`, `price_scenarios`, `SddpResult`, `sddp_lower_bound`, `SDDP.calculate_bound`; `wv_warmstart_cuts` + `apply_wv_warmstart!` (Tasks 1–2).
- Produces:
  - `_zero_weight_anchor(anchor) -> NamedTuple` (same `values`/`weights`, `weight = 0.0`).
  - `_warmstart_plan(warm_start::Symbol, anchor) -> (effective_anchor, inject_cuts::Bool)`.
  - `solve_sddp(mi, inflow_scenarios; n_scenarios=100, iteration_limit=200, seed=1, warm_start::Symbol=:anchor) -> SddpResult` (added keyword; return type unchanged).

- [ ] **Step 1: Add failing selector unit tests + smoke test**

In `test/test_warmstart.jl`, add inside the `@testset "warmstart"` block:

```julia
    @testset "_warmstart_plan / _zero_weight_anchor select mechanism correctly" begin
        anch = (values = Dict("L" => 50.0), weights = [1.0, 0.5], weight = 1.0)

        @test Nephrite._zero_weight_anchor(anch).weight == 0.0
        @test Nephrite._zero_weight_anchor(anch).values === anch.values   # preserved
        @test Nephrite._zero_weight_anchor(anch).weights == anch.weights

        @test Nephrite._warmstart_plan(:none,   anch) == (Nephrite._zero_weight_anchor(anch), false)
        @test Nephrite._warmstart_plan(:anchor, anch)[1].weight == 1.0
        @test Nephrite._warmstart_plan(:anchor, anch)[2] == false
        @test Nephrite._warmstart_plan(:cuts,   anch)[1].weight == 0.0
        @test Nephrite._warmstart_plan(:cuts,   anch)[2] == true
        @test Nephrite._warmstart_plan(:both,   anch)[1].weight == 1.0
        @test Nephrite._warmstart_plan(:both,   anch)[2] == true
        @test_throws ErrorException Nephrite._warmstart_plan(:bogus, anch)
    end

    @testset "solve_sddp runs all four warm_start modes and still yields finite FCF" begin
        mi, scen = _toy_graph_inputs()
        for mode in (:none, :anchor, :cuts, :both)
            sr = Nephrite.solve_sddp(mi, scen; n_scenarios = 4, iteration_limit = 15,
                                     seed = 1, warm_start = mode)
            @test sr.policy isa SDDP.PolicyGraph
            cfg = Nephrite.FcfExtractConfig([1, 2], 4, 13, 0.0)
            fcf = Nephrite.extract_run_fcf(sr.policy, mi.net, mi.initial_vol,
                                           sr.trajectories, Dict{String,Float64}(), cfg)
            @test all(isfinite, fcf[1].curves["L"].water_value)
        end
    end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: FAIL — `UndefVarError: _warmstart_plan not defined` (and `solve_sddp` does not accept `warm_start`).

- [ ] **Step 3: Add the selector helpers**

Append to `src/warmstart.jl`:

```julia
"Copy of an anchor bundle with `weight = 0.0` (objective anchor off; values/weights kept)."
_zero_weight_anchor(anchor) = merge(anchor, (weight = 0.0,))

"""
    _warmstart_plan(warm_start, anchor) -> (effective_anchor, inject_cuts::Bool)

Resolve a warm-start selector into (a) the anchor bundle to build the graph with —
the original (objective anchor ON) for `:anchor`/`:both`, else a zero-weight copy —
and (b) whether to inject value-function cuts (`:cuts`/`:both`). Errors on any other
symbol.
"""
function _warmstart_plan(warm_start::Symbol, anchor)
    warm_start in (:none, :anchor, :cuts, :both) ||
        error("solve_sddp: warm_start must be :none, :anchor, :cuts, or :both (got :$warm_start)")
    use_anchor  = warm_start in (:anchor, :both)
    inject_cuts = warm_start in (:cuts, :both)
    eff = use_anchor ? anchor : _zero_weight_anchor(anchor)
    return (eff, inject_cuts)
end
```

- [ ] **Step 4: Wire the selector into `solve_sddp`**

In `src/sddp.jl`, replace the `solve_sddp` function (currently the block starting `function solve_sddp(mi::ModelInputs, ...)` through its `end`) with:

```julia
function solve_sddp(mi::ModelInputs, inflow_scenarios::Dict{Int,Vector{Dict{String,Float64}}};
                    n_scenarios::Int = 100, iteration_limit::Int = 200, seed::Int = 1,
                    warm_start::Symbol = :anchor)
    eff_anchor, inject_cuts = _warmstart_plan(warm_start, mi.anchor)
    graph = build_policy_graph(mi.weeks, mi.net, mi.initial_vol, mi.terminal_wv,
                               eff_anchor, inflow_scenarios)
    if inject_cuts
        lb = sddp_lower_bound(mi.net, mi.terminal_wv)
        cuts = wv_warmstart_cuts(mi.net, mi.initial_vol, mi.anchor.values,
                                 mi.anchor.weights, lb)
        apply_wv_warmstart!(graph, cuts)
    end
    train_policy!(graph; iteration_limit = iteration_limit, seed = seed)
    lb_bound = SDDP.calculate_bound(graph)
    traj, infl = simulate_policy(graph, n_scenarios; seed = seed)
    price_dist = price_scenarios(mi.weeks, mi.net, mi.initial_vol, traj, infl)
    return SddpResult(lb_bound, traj, price_dist, graph)
end
```

Also update the `solve_sddp` docstring's signature line (immediately above the function) to include `, warm_start=:anchor)` and add a sentence: "`warm_start` selects the prior-WV injection: `:none` (cold), `:anchor` (objective anchor, default), `:cuts` (value-function cuts), `:both`."

- [ ] **Step 5: Run the test to verify it passes**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: PASS — selector unit tests pass; all four modes return a `PolicyGraph` and finite FCF water values.

- [ ] **Step 6: Commit**

```bash
git add src/warmstart.jl src/sddp.jl test/test_warmstart.jl
git commit -m "feat(warmstart): add warm_start selector to solve_sddp (:none/:anchor/:cuts/:both)"
```

---

### Task 4: Thread `warm_start` through `run_model`

**Files:**
- Modify: `src/runner.jl` (`run_model` signature + the `solve_sddp` call)
- Modify: `test/test_warmstart.jl` (snapshot integration test)

**Interfaces:**
- Consumes: `solve_sddp(...; warm_start)` (Task 3); test helpers `build_test_snapshot!`, `write_inputs_test_history` (from `test/util.jl`, already loaded by `runtests.jl`).
- Produces: `run_model(...; warm_start::Symbol = :anchor)` — passes `warm_start` to `solve_sddp` on the `:sddp` path. Default keeps current behaviour.

- [ ] **Step 1: Add the failing integration test**

In `test/test_warmstart.jl`, add inside the `@testset "warmstart"` block:

```julia
    @testset "run_model engine=:sddp warm_start=:cuts produces FCF curves" begin
        mktempdir() do root
            d = Date(2026, 6, 10)
            build_test_snapshot!(root, d)
            hist = joinpath(root, "history", "demand"); write_inputs_test_history(hist)
            rr = Nephrite.run_model(d; root = root,
                config_dir = joinpath(@__DIR__, "..", "config"),
                history_dir = hist, nz_gwh = 4000.0, si_gwh = 2500.0,
                n_weeks = 2, seed = 1, min_history_days = 10,
                engine = :sddp, n_scenarios = 4, iteration_limit = 15,
                extract_fcf = true, warm_start = :cuts)
            @test isfile(joinpath(rr.run_dir, "fcf_curves.csv"))
        end
    end
```

Add `using Dates` to the top of `test/test_warmstart.jl` (the test references `Date`):

```julia
using Test, Nephrite, DataFrames, Dates
import SDDP
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: FAIL — `MethodError`/`got unsupported keyword argument "warm_start"` from `run_model`.

- [ ] **Step 3: Add `warm_start` to `run_model` and pass it through**

In `src/runner.jl`, in the `run_model` keyword list, add after `n_scenarios::Int = 100, iteration_limit::Int = 200,`:

```julia
                   warm_start::Symbol = :anchor,
```

Then, in the `if engine == :sddp` block, change the `solve_sddp` call from:

```julia
            sr = solve_sddp(mi, scen; n_scenarios = n_scenarios,
                            iteration_limit = iteration_limit, seed = seed)
```

to:

```julia
            sr = solve_sddp(mi, scen; n_scenarios = n_scenarios,
                            iteration_limit = iteration_limit, seed = seed,
                            warm_start = warm_start)
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `julia --project=. -e 'using Pkg; Pkg.test()'`
Expected: PASS — the SDDP run with `warm_start=:cuts` completes and writes `fcf_curves.csv`. Existing `test_fcfsddp.jl` / golden tests remain green (default `:anchor` unchanged).

- [ ] **Step 5: Commit**

```bash
git add src/runner.jl test/test_warmstart.jl
git commit -m "feat(warmstart): thread warm_start through run_model (default :anchor)"
```

---

### Task 5: Comparison harness + client docs

**Files:**
- Create: `scripts/warmstart_demo.jl`
- Create: `docs/WARMSTART.md`

**Interfaces:**
- Consumes: `open_datastore`, `load_jade`, `build_stationmap`, `build_hubmap`, `_preflight_pocs`, `assemble_inputs`, `empirical_inflow_scenarios`, `solve_sddp(...; warm_start)`, `reservoir_implied_wv`, `load_plant`, `load_fcf_config`, `extract_run_fcf`, `fcf_dataframe`, `_write_csv` (all in `Nephrite`).
- Produces: a script writing `warmstart_compare_wv.csv` and `warmstart_compare_policy.csv` plus a console summary; documentation describing the two options for the client.

> This task's deliverable is a runnable script + doc, verified by running it once and inspecting outputs (no unit test — it depends on the real snapshot).

- [ ] **Step 1: Write the comparison harness**

Create `scripts/warmstart_demo.jl`:

```julia
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
            FROM read_csv_auto('$(replace(abspath(shape_path), "\\\\" => "/"))')"""))
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

        wk1_summary = join(["$(r)=$(round(Nephrite.curve_value(wk1.curves[r], Nephrite._vol_to_gwh(get(mi.initial_vol, r, 0.0), get(Nephrite.downstream_energy_coeff(mi.net), r, 0.0))); digits=1))"
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
```

> Note on the policy CSV: storage rows (`reservoir`, `mean_storage_mm3`) and price rows (`hub`→`reservoir`, `mean_price`→`mean_storage_mm3`) are stacked with `cols=:union` so a single file carries both; the `mode`/`week` columns disambiguate. If you prefer two separate files, split the final `vcat` into two `_write_csv` calls — adjust only this step.

- [ ] **Step 2: Verify the harness exports it needs are accessible**

Run a load + name check (fast, no solve):

```bash
julia --project=. -e 'using Nephrite; for f in (:open_datastore,:load_jade,:build_stationmap,:build_hubmap,:assemble_inputs,:empirical_inflow_scenarios,:reservoir_implied_wv,:load_plant,:load_fcf_config,:extract_run_fcf,:curve_value,:_vol_to_gwh,:_write_csv,:downstream_energy_coeff); isdefined(Nephrite,f) || error("missing $f"); end; println("all harness symbols present")'
```

Expected: `all harness symbols present`. (If any symbol is missing, it lives under `Nephrite.` already — the script qualifies everything; this step only guards against a typo.)

- [ ] **Step 3: Run the harness on the quick example**

Run: `julia --project=. scripts/warmstart_demo.jl`
Expected: a printed 3-row table (`:none`/`:anchor`/`:cuts`) with lower bounds and week-1 water values, then "Comparison CSVs written to: runs/warmstart_demo_2026-06-11". Confirm both CSVs exist and are non-empty:

```bash
julia --project=. -e 'd="runs/warmstart_demo_2026-06-11"; for f in ("warmstart_compare_wv.csv","warmstart_compare_policy.csv"); p=joinpath(d,f); @assert isfile(p) && filesize(p)>0 p; end; println("ok")'
```

Expected: `ok`.

- [ ] **Step 4: Write the client-facing doc**

Create `docs/WARMSTART.md`:

```markdown
# Warm-starting SDDP with prior water values

Two options for seeding the SDDP policy with the offer-implied water values
(`reservoir_implied_wv`) at the start of training. Both share the same WV source and
the same 13-week linear decay (`[wvanchor].decay_weeks`); they differ only in
mechanism. Select via `warm_start` on `run_model(engine=:sddp, ...)` or `solve_sddp`:

| `warm_start` | mechanism                              | effect                                  |
|--------------|----------------------------------------|-----------------------------------------|
| `:none`      | none                                   | cold baseline                           |
| `:anchor`    | **Option C** — objective opportunity-cost on near-term release (default) | biases dispatch; hydro bids its WV |
| `:cuts`      | **Option A** — value-function cuts seeded at iteration 0 | shapes the cost-to-go directly |
| `:both`      | A + C                                  | combined                                |

## Option A — value-function cuts
Each reservoir's prior WV becomes one linear cut per weekly node:
`V(s) ≥ lb + Σ_r π_{r,t}·(s_r − s0_r)`, with slope
`π_{r,t} = decay_t·(−WV_r·coeff_r·MWH_PER_MM3_PER_SP)`, anchored at the snapshot
storage `s0` with height = the model's lower bound `lb`. At the operating point the
height equals `lb` (iteration-0 bound not inflated); below it the cut pre-installs
"scarce water is expensive." These are **guidance** cuts, not certified global
under-estimators — SDDP's own valid cuts dominate them during training. The demo
prints cold-vs-warm bounds so any distortion is visible.

## Option C — objective anchor
The existing mechanism: near-term hydro release is priced at its offer-implied WV as
an opportunity cost in the stage objective, decayed over `decay_weeks`. On by default
(`[wvanchor].weight = 1.0`).

## Comparing them
`julia --project=. scripts/warmstart_demo.jl` runs `:none`/`:anchor`/`:cuts` on the
quick example and writes, under `runs/warmstart_demo_<date>/`:
- `warmstart_compare_wv.csv` — per-mode, per-reservoir water-value curves
  (`mode, reservoir, storage_gwh, water_value, week`).
- `warmstart_compare_policy.csv` — per-mode mean storage trajectory and mean weekly
  price (`mode, reservoir, week, mean_storage_mm3`; price rows carry the hub in
  `reservoir` and the price in `mean_storage_mm3`, disambiguated by `mode`/`week`).

Read the WV file to see how each mechanism reshapes the water-value curve; read the
policy file to see whether it changes operating decisions (conserve vs. release) and
the resulting prices.
```

- [ ] **Step 5: Commit**

```bash
git add scripts/warmstart_demo.jl docs/WARMSTART.md
git commit -m "feat(warmstart): comparison harness + client docs for warm-start options"
```

---

## Self-Review

**Spec coverage:**
- Two options A (cuts) + C (anchor), shared WV source + decay → Tasks 1–3 (A) and the reused anchor via the selector (C). ✓
- `warm_start` selector `:none/:anchor/:cuts/:both`, default `:anchor` → Task 3/4. ✓
- Cut math (slope sign, anchor at `initial_vol`, height = `lb`, coeff==0 excluded) → Task 1. ✓
- SDDP-format injection via `read_cuts_from_file` → Task 2. ✓
- Comparison harness showing policy + water values → Task 5. ✓
- Tests: cut construction, injection, selector wiring, 4-mode smoke, run_model passthrough → Tasks 1–4. ✓
- Default behaviour preserved (golden green) → Task 4 default `:anchor`; verified by existing suite. ✓

**Placeholder scan:** No TBD/TODO; all code blocks complete; commands have expected output. ✓

**Type consistency:** `wv_warmstart_cuts` / `apply_wv_warmstart!` / `_warmstart_plan` / `_zero_weight_anchor` signatures match across Tasks 1–3 and the `solve_sddp` call site. Cut JSON keys (`node`/`single_cuts`/`intercept`/`coefficients`/`state`) match the schema consumed by `SDDP.read_cuts_from_file`. `warm_start::Symbol` consistent in `solve_sddp` and `run_model`. ✓
```
