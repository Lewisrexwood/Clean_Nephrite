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

`:both` stacks the same prior through *both* channels (objective anchor + value-function cuts), so it applies the strongest near-term conservation pressure.

## Option A — value-function cuts
Each reservoir's prior WV becomes one linear cut per weekly node:
`V(s) ≥ lb + Σ_r π_{r,t}·(s_r − s0_r)`, with slope
`π_{r,t} = decay_t·(−WV_r·coeff_r·MWH_PER_MM3_PER_SP)`, anchored at the snapshot
storage `s0` with height = the model's lower bound `lb`. At the operating point the
height equals `lb` (iteration-0 bound not inflated); below it the cut pre-installs
"scarce water is expensive." These are **guidance** cuts, not certified global
under-estimators — SDDP's own valid cuts dominate them during training. The demo
prints cold-vs-warm bounds so any distortion is visible.

Because these are *guidance* (not certified) cuts, the `lower_bound` reported for `:cuts`/`:both` is **diagnostic only — not a valid dual bound**. Use `:none` or `:anchor` when you need a trustworthy bound.

> **Note:** the FINAL (terminal) stage is NOT seeded with a warm-start cut. Its
> cost-to-go is structurally zero in a finite policy graph (no future stages), so
> `solve_sddp` clips the cut weights to the first `nW-1` stages before injecting.

## Option C — objective anchor
The existing mechanism: near-term hydro release is priced at its offer-implied WV as
an opportunity cost in the stage objective, decayed over `decay_weeks`. On by default
(`[wvanchor].weight = 1.0`).

## Comparing them
`julia --project=. scripts/warmstart_demo.jl` runs `:none`/`:anchor`/`:cuts` on the
quick example and writes, under `runs/warmstart_demo_<date>/`:
- `warmstart_compare_wv.csv` — per-mode, per-reservoir water-value curves (`mode, reservoir, storage_gwh, water_value, week`).
- `warmstart_compare_storage.csv` — per-mode mean end-of-week storage trajectory (`mode, reservoir, week, mean_storage_mm3`).
- `warmstart_compare_price.csv` — per-mode mean weekly nodal price (`mode, hub, week, mean_price`, $/MWh).

Read the WV file to see how each mechanism reshapes the water-value curve; read the
storage and price files to see whether it changes operating decisions (conserve vs. release) and
the resulting prices.
