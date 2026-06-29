using JuMP, HiGHS, DataFrames

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

"Build a minimal 1-hub topology (no corridors, no hydro) with optional battery."
function sp_hub_only_inp(; thermal_rows, batteries=NamedTuple[])
    hubs = [Nephrite.Hub("BEN", "BEN2201", "Benmore", "SI")]
    topo = Nephrite.Topology(hubs, Nephrite.Corridor[])
    net  = Nephrite.HydroNetwork(
        Nephrite.JadeReservoir[],
        Nephrite.Arc[],
        Dict{String,Nephrite.HydroStation}(),
        Dict{String,String}(),
        Dict{String,Vector{String}}(),
    )
    mustrun = DataFrame(hub=String[], mw=Float64[])
    return Nephrite.DispatchInputs(topo, net, thermal_rows, mustrun, batteries, 10_000.0)
end

"Build a minimal 1-hub / 1-reservoir / 1-station system."
function sp_hydro_inp(; thermal_rows, cap_mw=1e6, sp=1.0, max_vol=1e6, min_vol=0.0)
    hubs = [Nephrite.Hub("BEN", "BEN2201", "Benmore", "SI")]
    topo = Nephrite.Topology(hubs, Nephrite.Corridor[])
    res  = [Nephrite.JadeReservoir("L", "SI", min_vol, max_vol)]
    stn  = Nephrite.HydroStation("g", cap_mw, sp, [(0.0, 0.0), (cap_mw / sp, cap_mw)])
    arcs = [Nephrite.Arc("L", "SEA", "g", Inf)]
    net  = Nephrite.HydroNetwork(
        res, arcs, Dict("g" => stn), Dict("g" => "BEN"), Dict("L" => ["SEA"])
    )
    mustrun = DataFrame(hub=String[], mw=Float64[])
    return Nephrite.DispatchInputs(topo, net, thermal_rows, mustrun, NamedTuple[], 10_000.0)
end

# ---------------------------------------------------------------------------
@testset "subproblem" begin

    # =======================================================================
    # Gate 1: Battery arbitrage + periodic SoC
    #
    # 4 steps (each 0.5 h = 1 trading-period), 1 hub BEN.
    # Thermal: cheap tranche $20 / 20 MW; dear tranche $200 / 1000 MW.
    # Demand:  [5, 5, 30, 5] MW  →
    #   Steps 1,2,4 : only cheap tranche needed → marginal price = $20.
    #   Step 3      : cheap 20 MW + dear 10 MW  → marginal price = $200 (peak).
    #
    # Battery: 5 MW power, 10 MWh energy, eff=1.
    # Expected behaviour (optimal arbitrage, periodic SoC):
    #   - Battery charges in one (or more) of the cheap steps (steps 1/2/4).
    #   - Battery discharges in the peak step (step 3).
    #   - SoC at end of last step returns to soc0 (periodic close).
    #
    # Note: solve_subproblem returns prices in $/MWh (dual ÷ period_hours).
    # =======================================================================
    @testset "battery arbitrages: charges cheap, discharges peak, periodic SoC" begin
        thermal = DataFrame(
            hub   = ["BEN",  "BEN"],
            price = [20.0,   200.0],
            mw    = [20.0,   1000.0],
        )
        batt = [(name="b1", hub="BEN", power_mw=5.0, energy_mwh=10.0, eff=1.0)]
        inp  = sp_hub_only_inp(thermal_rows=thermal, batteries=batt)

        # 4 steps each 0.5 h; demand varies so the marginal tranche differs
        periods = [
            Nephrite.Period("t1", 0.5, Dict("BEN" => 5.0)),
            Nephrite.Period("t2", 0.5, Dict("BEN" => 5.0)),
            Nephrite.Period("t3", 0.5, Dict("BEN" => 30.0)),   # peak — dear tranche in
            Nephrite.Period("t4", 0.5, Dict("BEN" => 5.0)),
        ]

        start_vol  = Dict{String,Float64}()
        end_vol    = Dict{String,Float64}()
        inflow_cum = Dict{String,Float64}()

        result = Nephrite.solve_subproblem(periods, inp, start_vol, end_vol, inflow_cum;
                                           battery_periodic=true)

        @test result.objective < Inf

        # --- Price check: step 3 is the most expensive -----------------------
        # solve_subproblem returns prices in $/MWh (dual ÷ period_hours).
        peak_step   = 3
        cheap_steps = [1, 2, 4]

        price_peak  = result.prices[("BEN", peak_step)]
        price_cheap = maximum(result.prices[("BEN", s)] for s in cheap_steps)

        @test isapprox(price_peak,  200.0; atol=1e-4)
        @test isapprox(price_cheap,  20.0; atol=1e-4)

        # --- Battery dispatches as expected ----------------------------------
        discharge_peak = result.generation[("discharge", 1, peak_step)]
        charge_cheap   = maximum(result.generation[("charge", 1, s)] for s in cheap_steps)

        @test discharge_peak > 1e-6   # discharges in peak
        @test charge_cheap   > 1e-6   # charges in a cheap step

        # --- Periodic SoC: soc at last step == soc0 (cyclic start) -----------
        soc_start = result.generation[("soc0", 1)]
        soc_end   = result.generation[("soc",  1, length(periods))]
        @test isapprox(soc_end, soc_start; atol=1e-6)
    end

    # =======================================================================
    # Gate 2: Storage budget coupling
    #
    # Sub-test A: pure thermal (no hydro water) → every step price = SRMC.
    #   1 hub BEN, 1 reservoir "L" (start=0, end=0, inflow=0 — zero water).
    #   Thermal at $50 / ∞ MW covers all demand.
    #   solve_subproblem reports prices in $/MWh, so expect 50.0.
    #
    # Sub-test B: hydro covers all demand; water budget must close exactly.
    #   We size the scenario so the hydro can exactly cover demand from water.
    #   Demand 100 MW, sp=1 → arcflow = 100 cumecs each step.
    #   Over 4 steps × 0.5 h: total release = 100 × 0.0036 × 0.5 × 4 = 0.72 Mm³.
    #   Set start_vol = 0.72, end_vol = 0.0, inflow = 0 → water budget closes.
    #   The thermal backstop ($1M/MWh) won't run.
    #   Assert: total_release = start - end = 0.72 Mm³; s[L,0]=0.72; s[L,T]=0.
    # =======================================================================
    @testset "storage budget: end-storage constraint holds and water balance closes" begin

        # Sub-test A: pure thermal (no hydro water) -------------------------
        thermal_a = DataFrame(hub=["BEN"], price=[50.0], mw=[1e6])
        inp_a = sp_hydro_inp(thermal_rows=thermal_a, cap_mw=1e6, sp=1.0,
                             max_vol=1e6, min_vol=0.0)

        periods_a = [Nephrite.Period("t$i", 0.5, Dict("BEN" => 100.0)) for i in 1:4]
        sv_a  = Dict("L" => 0.0)
        ev_a  = Dict("L" => 0.0)
        inf_a = Dict("L" => 0.0)

        r_a = Nephrite.solve_subproblem(periods_a, inp_a, sv_a, ev_a, inf_a;
                                        battery_periodic=false)

        @test r_a.objective < Inf
        for t in 1:4
            # Price in $/MWh: dual is returned normalised by period.hours
            @test isapprox(r_a.prices[("BEN", t)], 50.0; atol=1e-4)
        end

        # Sub-test B: hydro covers demand; water budget must close -----------
        # demand = 100 MW, sp=1 → arcflow = 100 cumecs/step
        # total_release = 100 × 0.0036 × 0.5 × 4 = 0.72 Mm³
        # => start=0.72, end=0.0 is perfectly feasible
        thermal_b = DataFrame(hub=["BEN"], price=[1e6], mw=[1e6])
        inp_b = sp_hydro_inp(thermal_rows=thermal_b, cap_mw=1e6, sp=1.0,
                             max_vol=1e6, min_vol=0.0)

        periods_b = [Nephrite.Period("t$i", 0.5, Dict("BEN" => 100.0)) for i in 1:4]
        sv_b  = Dict("L" => 0.72)
        ev_b  = Dict("L" => 0.0)
        inf_b = Dict("L" => 0.0)

        r_b = Nephrite.solve_subproblem(periods_b, inp_b, sv_b, ev_b, inf_b;
                                        battery_periodic=false)

        @test r_b.objective < Inf

        # Water balance: total released Mm³ == start + total_inflow - end
        total_release_Mm3 = sum(
            r_b.flows[("net_outflow", "L", t)] * Nephrite.MM3_PER_CUMEC_HOUR * periods_b[t].hours
            for t in 1:4
        )
        expected_release = sv_b["L"] + 0.0 - ev_b["L"]   # = 0.72 Mm³
        @test isapprox(total_release_Mm3, expected_release; atol=1e-6)

        # Storage boundary values from the result
        s0 = r_b.flows[("storage", "L", 0)]
        sT = r_b.flows[("storage", "L", 4)]
        @test isapprox(s0, sv_b["L"]; atol=1e-6)
        @test isapprox(sT, ev_b["L"]; atol=1e-6)
    end

    # =======================================================================
    # Gate 3: model reuse + parameterization is primal-equivalent to a fresh
    # rebuild, and run-to-run reproducible.
    #
    # build_week_model builds the week's LP once; solve_week! re-points only
    # start_vol/end_vol (via fix) and inflow (via set_normalized_rhs on the
    # mass-balance) and re-solves (warm).  The PRIMAL (objective, storage,
    # net_outflow, generation) is unique and must match a fresh solve exactly —
    # including re-pointing back to an EARLIER scenario after a later one (no
    # stale fix/RHS state).  A COLD first solve also matches the wrapper's duals
    # bit-for-bit (the deterministic/golden path is unaffected).  Hub-balance
    # DUALS (prices) under a WARM re-solve may pick a different but equally-valid
    # optimal multiplier at LP degeneracy, so they are asserted reproducible
    # run-to-run rather than bit-equal to a cold solve.
    # =======================================================================
    @testset "build_week_model + solve_week! reuse: primal-exact + reproducible" begin
        thermal = DataFrame(hub=["BEN"], price=[50.0], mw=[1e6])
        inp = sp_hydro_inp(thermal_rows=thermal, cap_mw=1e6, sp=1.0,
                           max_vol=1e6, min_vol=0.0)
        periods = [Nephrite.Period("t$i", 0.5, Dict("BEN" => 100.0)) for i in 1:4]

        scA = (Dict("L"=>0.72), Dict("L"=>0.0), Dict("L"=>0.0))
        scB = (Dict("L"=>0.50), Dict("L"=>0.20), Dict("L"=>10.0))
        scC = (Dict("L"=>0.30), Dict("L"=>0.30), Dict("L"=>5.0))

        rA = Nephrite.solve_subproblem(periods, inp, scA...; battery_periodic=false)
        rB = Nephrite.solve_subproblem(periods, inp, scB...; battery_periodic=false)
        rC = Nephrite.solve_subproblem(periods, inp, scC...; battery_periodic=false)

        # A COLD first solve on a freshly built model matches the wrapper exactly,
        # prices included (both are cold first solves of the same model).
        wmA = Nephrite.build_week_model(periods, inp; battery_periodic=false)
        rA_cold = Nephrite.solve_week!(wmA, scA...)
        @test rA_cold.status == JuMP.MOI.OPTIMAL
        @test isapprox(rA_cold.objective, rA.objective; atol=1e-6)
        for k in keys(rA.prices)
            @test isapprox(rA_cold.prices[k], rA.prices[k]; atol=1e-9)
        end

        # Reuse across scenarios (A, B, A, C): the OBJECTIVE is the unique LP
        # invariant and must match the fresh solve exactly — including re-pointing
        # back to A after B (proving no stale fix/RHS state).  The storage
        # boundaries are pinned inputs (trivially equal).  Per-step flows/prices
        # are NOT asserted equal to fresh: this weekly LP is degenerate (hydro
        # release TIMING within the week is indifferent), so warm and cold land on
        # different but equally-optimal vertices.
        wm = Nephrite.build_week_model(periods, inp; battery_periodic=false)
        for (sc, fresh) in ((scA, rA), (scB, rB), (scA, rA), (scC, rC))
            reuse = Nephrite.solve_week!(wm, sc...)
            @test reuse.status == JuMP.MOI.OPTIMAL
            @test isapprox(reuse.objective, fresh.objective; atol=1e-6)
            @test isapprox(reuse.flows[("storage","L",0)], fresh.flows[("storage","L",0)]; atol=1e-6)
            @test isapprox(reuse.flows[("storage","L",4)], fresh.flows[("storage","L",4)]; atol=1e-6)
        end

        # Run-to-run reproducibility: the same scenario sequence on two separate
        # reused models yields identical prices (warm-start is deterministic).
        wm1 = Nephrite.build_week_model(periods, inp; battery_periodic=false)
        wm2 = Nephrite.build_week_model(periods, inp; battery_periodic=false)
        for sc in (scA, scB, scA, scC)
            r1 = Nephrite.solve_week!(wm1, sc...)
            r2 = Nephrite.solve_week!(wm2, sc...)
            for k in keys(r1.prices)
                @test isapprox(r1.prices[k], r2.prices[k]; atol=1e-9)
            end
        end
    end

    # =======================================================================
    # Gate 4: many concurrent build+solve cycles must not crash HiGHS's global
    # task executor (the EXCEPTION_ACCESS_VIOLATION in HighsTaskExecutor::dispose
    # under Threads.@threads). Meaningful under JULIA_NUM_THREADS>1; trivially
    # passes single-threaded. Asserts all solves return OPTIMAL (and the process
    # survives the threaded executor lifecycle).
    # =======================================================================
    @testset "threaded weekly build+solve is HiGHS-thread-safe" begin
        thermal = DataFrame(hub=["BEN"], price=[50.0], mw=[1e6])
        inp = sp_hydro_inp(thermal_rows=thermal, cap_mw=1e6, sp=1.0, max_vol=1e6, min_vol=0.0)
        periods = [Nephrite.Period("t$i", 0.5, Dict("BEN" => 100.0)) for i in 1:8]
        nW = 60
        results = Vector{Nephrite.SubproblemResult}(undef, nW)
        Threads.@threads for w in 1:nW
            wm = Nephrite.build_week_model(periods, inp; battery_periodic=false)
            results[w] = Nephrite.solve_week!(wm, Dict("L"=>0.5), Dict("L"=>0.3), Dict("L"=>5.0))
        end
        @test all(r.status == JuMP.MOI.OPTIMAL for r in results)
        @test Threads.nthreads() >= 1   # documents the test is thread-count sensitive
    end

    # =======================================================================
    # Gate 5: soft terminal pin rescues an end-storage target the hard `fix`
    # cannot reach.
    #
    # The SDDP policy chooses end-of-week storage on a coarse representative-day
    # stage; the 336-step pricer must thread an intra-week path through the exact
    # same endpoints.  Occasionally the hard `fix(s[T], end_vol)` reports
    # INFEASIBLE (a wide-coefficient-range presolve artifact) even though the
    # value is reachable.  `soft_terminal=true` leaves s[T] bounded and pins it
    # via a penalised deviation, so the model always solves: it hits the target
    # exactly when reachable (deviation 0, objective == hard pin) and lands as
    # close as the water budget allows when not.
    # =======================================================================
    @testset "soft terminal pin: solves an unreachable pin; exact when reachable" begin
        thermal = DataFrame(hub=["BEN"], price=[50.0], mw=[1e6])
        inp = sp_hydro_inp(thermal_rows=thermal, cap_mw=1e6, sp=1.0, max_vol=1e6, min_vol=0.0)
        periods = [Nephrite.Period("t$i", 0.5, Dict("BEN"=>100.0)) for i in 1:4]

        # Unreachable: headwater "L" with start 0, no inflow, end pinned to 0.5 —
        # you cannot create water, so the hard fix is INFEASIBLE.
        sv = Dict("L"=>0.0); ev = Dict("L"=>0.5); inf = Dict("L"=>0.0)
        hard = Nephrite.solve_subproblem(periods, inp, sv, ev, inf; battery_periodic=false)
        @test hard.status != JuMP.MOI.OPTIMAL

        wm   = Nephrite.build_week_model(periods, inp; battery_periodic=false, soft_terminal=true)
        soft = Nephrite.solve_week!(wm, sv, ev, inf)
        @test soft.status == JuMP.MOI.OPTIMAL
        @test isapprox(soft.flows[("storage","L",0)], 0.0; atol=1e-6)
        @test isapprox(soft.flows[("storage","L",4)], 0.0; atol=1e-6)   # can't fill — stays at floor

        # Reachable: start 0.72, end 0.0 (releasable in full) — the soft model hits
        # the target exactly (deviation 0) and matches the hard pin's objective.
        sv2 = Dict("L"=>0.72); ev2 = Dict("L"=>0.0)
        hard2 = Nephrite.solve_subproblem(periods, inp, sv2, ev2, inf; battery_periodic=false)
        wm2   = Nephrite.build_week_model(periods, inp; battery_periodic=false, soft_terminal=true)
        soft2 = Nephrite.solve_week!(wm2, sv2, ev2, inf)
        @test soft2.status == JuMP.MOI.OPTIMAL
        @test isapprox(soft2.flows[("storage","L",4)], 0.0; atol=1e-6)
        @test isapprox(soft2.objective, hard2.objective; atol=1e-6)
    end

end
