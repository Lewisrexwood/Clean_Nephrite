# SDDP warm-start with prior water values — design

**Date:** 2026-06-30
**Status:** Approved design, pending spec review → implementation plan
**Topic:** Inject offer-implied water values into SDDP at training start, as two
client-facing options (value-function cuts vs. objective anchor), and show how each
affects the policy and water values.

## 1. Goal & context

The SDDP engine (`src/sddp.jl`) trains a risk-neutral `LinearPolicyGraph` cold. We
want to **warm-start** training with a *prior* on water values — specifically the
offer-implied per-reservoir water values already computed by `reservoir_implied_wv`
(`src/wvanchor.jl` / `src/watervalues.jl`) — injected "at the start time" (iteration
0, before `train_policy!`).

Two mechanisms are delivered as **client options**:

- **Option A — value-function cuts.** Convert the prior water values into linear
  cuts and seed every weekly node's cost-to-go approximation. This is the textbook
  SDDP warm start: it shapes the *value function* directly.
- **Option C — objective anchor.** The existing "mechanism A" anchor
  (`src/master.jl`, `src/sddp.jl`): prices near-term hydro release at its
  offer-implied water value as an opportunity cost in the *stage objective*. Already
  implemented and on by default (`[wvanchor].weight = 1.0`).

Both draw from the **same source** (`mi.anchor.values`, the offer-implied WV) and
**decay over the same horizon** (`mi.anchor.weights` = `anchor_weights(decay_weeks,
n_weeks)`, `decay_weeks = 13`). They differ only in *mechanism*, making them a fair
A/B for the client.

**Success criterion (chosen):** *wire it and observe.* Get both injections working
end-to-end, confirm cuts are present at iteration 0, confirm runs complete and still
produce FCF curves, and produce comparison artifacts showing how `:none` / `:anchor`
/ `:cuts` differ in policy and water values. No hard pass/fail bound assertion.

### Out of scope (YAGNI)
- Consuming the FCF downstream in a start-time dispatch (the other interpretation;
  see `docs/FCF.md`).
- Warm-starting from a *previously trained* `fcf_cuts.json` (Option A's loader
  supports it for free later, but it is not built or tested here).
- Certified-valid global under-estimator cuts; tuning for convergence speed.

## 2. Architecture

A single **warm-start selector** on the SDDP path exposes the two mechanisms over
shared inputs:

```
run_model(engine=:sddp, warm_start = :anchor | :cuts | :both | :none)
        │
        ├─ mi.anchor.values   (offer-implied per-reservoir WV $/MWh)   ─┐ shared
        ├─ mi.anchor.weights  (linear decay over decay_weeks = 13)     ─┘ inputs
        │
   solve_sddp(mi, scen; warm_start)
        │
        ├─ effective_anchor = mi.anchor            if :anchor / :both   ← Option C
        │                     zero-weight copy     if :cuts / :none       (objective)
        │
        ├─ build_policy_graph(... effective_anchor ...)
        │
        ├─ if :cuts / :both → apply_wv_warmstart!(graph, cuts)          ← Option A
        │                       (value-function cuts; NEW)
        │
        └─ train_policy! → simulate → price → SddpResult
```

**A and C are orthogonal, composable knobs** unified under one selector:
`:none` (cold baseline), `:anchor` (C only), `:cuts` (A only), `:both`.

### Components

**New — `src/warmstart.jl`** (single purpose: build & inject WV cuts):
- `wv_warmstart_cuts(net, anchor_vol, wv_values, decay_weights, lb) -> Vector{Dict}`
  — **pure**, no SDDP calls. Builds the per-node SDDP-format `single_cuts`. Fully
  unit-testable in isolation.
- `apply_wv_warmstart!(graph, cuts) -> graph` — serializes `cuts` to a temp JSON in
  the exact `write_cuts_to_file` schema and calls `SDDP.read_cuts_from_file`
  (public-API injection). Returns the graph.

**Changed — `src/sddp.jl`:**
- `solve_sddp(mi, scen; warm_start::Symbol = :anchor, n_scenarios, iteration_limit,
  seed)` — validates `warm_start`, derives `effective_anchor`, injects cuts when
  requested, then trains. `build_policy_graph` is **unchanged** (already takes an
  `anchor` argument; we pass the effective one).
- Small helper `_zero_weight_anchor(anchor)` — returns a copy with `weight = 0.0`,
  preserving `.values` / `.weights`.

**Changed — `src/runner.jl`:**
- `run_model(...; warm_start::Symbol = :anchor)` threads the selector to
  `solve_sddp`. **Default `:anchor` preserves today's behaviour byte-for-byte** —
  the golden/regression tests stay green.

**New — `src/Nephrite.jl`:** `include("warmstart.jl")` (after `sddp.jl`).

**New deliverable — `scripts/warmstart_demo.jl`:** the client-facing comparison
(see §5).

**New tests — `test/test_warmstart.jl`** (see §6).

## 3. Cut construction (Option A core)

Each reservoir `r` with offer-implied water value `WV_r` ($/MWh) becomes one linear
cut per weekly node `t`. A cut in SDDP.jl's file schema is point-slope:
`V(s) ≥ height + Σ_r coeff_r·(s_r − state_r)`, where `state` is the anchor point.

**1. Slope** ($/Mm³), the payload:
```
π_{r,t} = decay_t · ( −WV_r · coeff_r · MWH_PER_MM3_PER_SP )
```
- `coeff_r = downstream_energy_coeff(net)[r]`.
- Sign: `V` is the min cost-to-go; more water ⇒ lower future cost ⇒ `∂V/∂s_r ≤ 0`,
  so `π_{r,t} ≤ 0`. This is the exact inverse of the FCF extraction convention
  `WV = −∂V/∂s_r / (coeff_r·MWH_PER_MM3_PER_SP)` in `src/fcfsddp.jl:31`, so Option A
  round-trips against the FCF reader.
- `decay_t = decay_weights[t] = mi.anchor.weights[t]` — **the same taper as Option
  C** (1.0 at week 1, linear to 0 at `decay_weeks = 13`, 0 thereafter).
- Reservoirs with `coeff_r == 0` (run-of-river / no downstream station) get **no
  cut** — same exclusion as `reservoir_energy_capacities`.

**2. Anchor point** = the snapshot storage `initial_vol` (Mm³), stored in the cut's
`"state"`. It is where the policy actually starts.

**3. Height / intercept** — anchored at the model's existing lower bound
`lb = sddp_lower_bound(net, terminal_wv)` at the anchor point:
```
cut_t:  V(s) ≥ lb + Σ_r π_{r,t} · (s_r − initial_vol_r)
```
Rationale:
- At `s = initial_vol` the height is exactly `lb` — identical to SDDP's trivial
  initial cut, so `calculate_bound` is **not inflated at iteration 0**.
- Below the anchor (`s_r < initial_vol_r`, scarce water): `π ≤ 0` makes the term
  positive ⇒ the cut raises the cost-to-go ⇒ pre-installs "scarce water is
  expensive," exactly where water value matters.
- Above the anchor: the cut falls below `lb`, so SDDP's `θ ≥ lb` dominates and the
  warm cut is inert. No harm.

**Validity caveat (explicit).** These are *guidance* cuts, not certified global
under-estimators: in the low-storage region a cut can exceed the true `V` until
SDDP's own valid cuts dominate it. Acceptable here because (a) the bound is
uninflated at the operating point, (b) SDDP refines over training, and (c) the demo
**prints cold-vs-warm `calculate_bound`** so any distortion is observed, not hidden.
The height convention is a single documented constant, trivial to swap for a
strictly-valid (looser) variant later.

**Edge cases:**
- Last node `t = nW`: its cost-to-go approximation has no successor stage (beyond
  the horizon is handled in-stage by the terminal-value envelope), so a cut seeded
  there is inert regardless of `decay_t`. We still write it for uniformity; it is a
  harmless no-op. (Note: with `n_weeks < decay_weeks` — e.g. the 8-week quick
  example vs `decay_weeks = 13` — `decay_t` is *not* ~0 at `nW`; inertness comes from
  the missing successor, not from decay.)
- Empty `wv_values` (no offers): produces no cuts; `:cuts` degenerates to cold. Logged.

### SDDP.jl cut-file schema (target for `apply_wv_warmstart!`)
Per node, a list of `single_cuts`, each:
```json
{ "intercept": <height at state>,
  "coefficients": { "s[<reservoir>]": <π_r>, ... },
  "state":        { "s[<reservoir>]": <initial_vol_r>, ... } }
```
Node names are `string(t)` for `t in 1:nW`; state keys are `s[<reservoir>]`
(matching `_fcf_state_key`). `read_cuts_from_file` reconstructs the cut and (because
`"state"` is present) runs cut selection. Verified against
`SDDP.write_cuts_to_file` / `read_cuts_from_file` in SDDP.jl 1.13.2.

## 4. Data flow per mode

| mode      | objective anchor | value-function cuts | notes                          |
|-----------|------------------|---------------------|--------------------------------|
| `:none`   | off (weight 0)   | none                | cold baseline                  |
| `:anchor` | on (Option C)    | none                | today's default behaviour      |
| `:cuts`   | off (weight 0)   | injected (Option A) | A isolated                     |
| `:both`   | on               | injected            | A + C combined (experiments)   |

`solve_sddp` returns the existing `SddpResult { lower_bound, trajectories,
price_dist, policy }` unchanged for every mode.

## 5. Comparison harness — `scripts/warmstart_demo.jl`

The client-facing deliverable. Assembles `mi` once for the quick example
(`n_weeks = 8, iteration_limit = 15, n_scenarios = 4`, snapshot 2026-06-11), then
runs `solve_sddp` for `:none`, `:anchor`, `:cuts` (only the warm-start differs).

Emits, per mode, into a comparison run dir:

- **Water values — `warmstart_compare_wv.csv`** (columns: `mode, reservoir,
  storage_gwh, water_value, week`): per-reservoir WV curves from `extract_run_fcf`
  (week-1 reslice), overlaid across modes — shows how each mechanism reshapes the
  water-value curve.
- **Policy — `warmstart_compare_policy.csv`** (columns: `mode, reservoir, week,
  mean_storage_mm3` and `mode, hub, week, mean_price`): mean simulated storage
  trajectory (from `sr.trajectories`) and mean weekly price (from `sr.price_dist`) —
  shows whether the warm-start changes *operating decisions* (conserve vs. release)
  and the resulting prices.
- **Console summary table:** `mode | lower_bound | week-1 WV per reservoir |
  cuts@iter0`, plus cold-vs-warm `calculate_bound`.
- **Optional overlay plot:** extend `scripts/plot_fcf.py` to overlay the per-mode WV
  curves.

Pure observation — no assertions. Matches the "wire it & observe" criterion.

## 6. Testing — `test/test_warmstart.jl`

Follows the toy-net / stub style of `test/test_fcfsddp.jl`.

- **Cut construction (pure, A):**
  - slope `π = −WV·coeff·MWH_PER_MM3_PER_SP` (sign + magnitude);
  - per-stage decay scaling (`decay_t` applied; week with weight 0 ⇒ slope 0);
  - anchor `"state"` equals `initial_vol`; height equals `lb` at the anchor;
  - `coeff == 0` reservoir omitted; empty `wv_values` ⇒ no cuts;
  - emitted JSON schema has `intercept` / `coefficients` / `state`, keyed
    `s[<reservoir>]`.
- **Injection (integration, A):** on a toy 2-week graph, after
  `apply_wv_warmstart!` the node bellman holds the cut and `calculate_bound`
  reflects the seeded shape (≈ `lb` at `initial_vol`; rises below it).
- **Selector wiring:** `solve_sddp(:cuts)` injects with anchor off; `:anchor`
  injects nothing, anchor active; `:none` neither; `:both` both — observed via the
  returned policy (cut counts) / effective anchor weight.
- **Comparison smoke (A + C):** all four modes run end-to-end on the toy and still
  produce finite FCF curves via `extract_run_fcf`.

## 7. Risks & mitigations

- **Guidance cuts can transiently inflate the bound** in low-storage regions →
  mitigated by the height convention (uninflated at operating point) + printing
  cold-vs-warm bound; SDDP refines during training.
- **SDDP.jl cut-schema drift across versions** → we use the public
  `read_cuts_from_file` and match the `write_cuts_to_file` schema; a round-trip
  assertion in tests guards against silent drift.
- **Default behaviour regression** → default `warm_start = :anchor` keeps the
  current path identical; covered by existing golden tests staying green.
```
