# FCF & SDDP water-value warm-start — guide

This is the practical guide to Nephrite's Future Cost Function (FCF) workflow and
the **two options for seeding the SDDP policy with prior water values** at the start
of training. It covers *how to use* each option and *how each one works*.

- For the **output file formats** (`fcf_curves.csv`, `fcf_cuts.json`) see [FCF.md](FCF.md).
- For a **one-page cheat-sheet** of the options see [WARMSTART.md](WARMSTART.md).

---

## 1. The 30-second version

Nephrite trains an SDDP policy over a weekly horizon and reads a **water-value curve
(the FCF)** off the trained value function. You can **warm-start** that training with
a *prior* on water values — the offer-implied water values already computed from the
market's own energy offers (`reservoir_implied_wv`). There are two mechanisms, chosen
with one keyword:

```julia
run_model(snapshot_date; engine = :sddp, warm_start = :cuts, extract_fcf = true, …)
#                                          ^^^^^^^^^^^^^^^^^^^
```

| `warm_start` | what it seeds | mechanism |
|--------------|---------------|-----------|
| `:none`   | nothing (cold) | — |
| `:anchor` | the **stage objective** (default) | **Option C** — opportunity cost on release |
| `:cuts`   | the **value function** | **Option A** — linear cuts on the cost-to-go |
| `:both`   | both | A + C together |

Both options draw from the **same source** (offer-implied water values) and fade over
the **same horizon** (`[wvanchor].decay_weeks`, default 13 weeks). They differ only in
*where in the Bellman equation* they act.

---

## 2. Background: FCF, water values, and the policy

A hydro reservoir's **water value** is the marginal value ($/MWh) of the water stored
in it — the future thermal cost it displaces. SDDP represents the expected future cost
as a **cost-to-go function** `V(s)` over the joint reservoir storage state `s` (Mm³),
built up as a set of linear **cuts** `V(s) ≥ α + Σ_r β_r·s_r`. The water value of
reservoir `r` is read off the slope:

```
WV_r  =  −(∂V/∂s_r) / (coeff_r · MWH_PER_MM3_PER_SP)          [$/MWh]
```

where `coeff_r = downstream_energy_coeff(net)[r]` converts a Mm³ of `r`'s water into
the MWh of generation it enables downstream. This is the exact convention the FCF
reader uses (`src/fcfsddp.jl`).

**Cold** SDDP starts with no cuts and discovers this shape from scratch over many
iterations. **Warm-starting** injects a prior so training begins from a non-trivial
approximation — useful when you trust the market's near-term signal and want the
early policy to reflect it.

---

## 3. Option A — value-function cuts (`warm_start = :cuts`)

Seeds the **cost-to-go `V` directly** with linear cuts built from the prior water
values. This is the textbook SDDP warm start: it shapes the value function that every
stage's dispatch decision optimises against.

### How to use

```julia
# End-to-end run that also extracts the FCF:
rr = Nephrite.run_model(Date(2026, 6, 11);
        root = "data", config_dir = "config",
        history_dir = joinpath("data","history","demand"),
        nz_gwh = 2700.0, si_gwh = 2200.0,
        n_weeks = 104, engine = :sddp,
        warm_start = :cuts,          # Option A
        extract_fcf = true)
# → writes runs/<id>/fcf_curves.csv and fcf_cuts.json

# Or lower-level, if you already have ModelInputs `mi` + inflow scenarios `scen`:
sr = Nephrite.solve_sddp(mi, scen; warm_start = :cuts,
                         n_scenarios = 50, iteration_limit = 100, seed = 1)
```

The prior water values are the offer-implied values (`reservoir_implied_wv`), which
`run_model` already computes; nothing extra to supply.

### How it works

For each reservoir `r` and each weekly node `t`, one linear cut is added to that
node's cost-to-go at iteration 0:

```
cut_t:   V(s)  ≥  lb  +  Σ_r π_{r,t} · (s_r − s0_r)

slope    π_{r,t}  =  decay_t · ( −WV_r · coeff_r · MWH_PER_MM3_PER_SP )      [$/Mm³]
```

- **Slope** `π` is the exact inverse of the FCF reader's convention, so a cut built
  from `WV` and read back through `extract_run_fcf` round-trips. `WV_r ≥ 0` ⇒ `π ≤ 0`
  (more water ⇒ lower future cost).
- **`decay_t`** is the per-stage weight from `anchor_weights(decay_weeks, n_weeks)` —
  1.0 in week 1, linear down to 0 at `decay_weeks` (13), then 0. So the prior bites
  near-term and fades out. **This is the same taper Option C uses.**
- **Anchor point** `s0` is the snapshot storage (`initial_vol`) — where the policy
  actually starts.
- **Height** is pinned to the model's lower bound `lb` at `s0`, so at the operating
  point the cut equals the trivial bound (the iteration-0 bound is *not* inflated);
  below `s0` (scarce water) the cut lifts the cost-to-go — pre-installing "scarce
  water is expensive," exactly where water value matters.
- Reservoirs with `coeff_r == 0` (run-of-river / no downstream station) get no cut.
- **Terminal stage is not seeded.** A finite policy graph's last node has no
  successor cost-to-go (the horizon end is handled by the terminal-value envelope
  in-stage), so a cut there makes the backward pass *infeasible* — `solve_sddp` clips
  the weights to the first `nW-1` stages.
- Near-zero slopes (`|π| < 1e-9`) are dropped to keep the injected cut numerically
  clean (they are basis noise, not information).

Cuts are injected via the public `SDDP.read_cuts_from_file` (the same cut format the
FCF export uses), so no dependence on SDDP internals.

> **Bound caveat.** These are *guidance* cuts, not certified global under-estimators.
> The `lower_bound` reported for `:cuts` (and `:both`) is therefore **diagnostic only —
> not a valid dual bound.** Use `:none` or `:anchor` if you need a trustworthy bound.
> SDDP's own valid cuts dominate the guidance cuts as training proceeds.

---

## 4. Option C — objective anchor (`warm_start = :anchor`, default)

Seeds the **stage objective** rather than the value function. This is the pre-existing
"anchor" mechanism, now selectable.

### How to use

```julia
rr = Nephrite.run_model(Date(2026, 6, 11);
        engine = :sddp, warm_start = :anchor,   # the default
        extract_fcf = true, … )
```

Strength and taper come from config `config/model.toml`:

```toml
[wvanchor]
weight      = 1.0     # scales the anchor term; 0 disables it
decay_weeks = 13      # linear fade from full (week 1) to zero (week 13)
```

### How it works

Near-term hydro **release** is priced at its offer-implied water value `av` as an
**opportunity cost** added to the stage objective:

```
stage_obj  +=  (weight · decay_t · av) · release_energy_mwh
```

i.e. the model behaves as if hydro *offered* its water at the market-implied value, so
whenever anchored hydro is marginal the near-term nodal price is pulled toward `av`.
It biases *dispatch decisions*; it does not change the cost-to-go approximation. With
`weight = 0` the term vanishes (equivalent to cold on this channel).

---

## 5. `:both` and `:none`

- **`:both`** — applies A *and* C simultaneously. Because they act on different terms
  of the Bellman equation there is no arithmetic double-counting, but both push toward
  near-term conservation through the *same* decayed prior, so it is the **most
  aggressive** setting. Good for stress-testing the prior's influence.
- **`:none`** — cold baseline: no objective anchor, no cuts. Use it as the reference
  when comparing.

---

## 6. Which option should I use?

| You want… | Use |
|-----------|-----|
| The trained **policy/value function** to reflect the prior (drives every stage) | `:cuts` (A) |
| To bias **near-term dispatch/prices** toward the offer signal without touching the cost-to-go | `:anchor` (C) |
| A trustworthy SDDP **lower bound** | `:none` or `:anchor` (not `:cuts`/`:both`) |
| Maximum prior influence for a sensitivity test | `:both` |
| A clean fundamentals-only run | `:none` |

Both A and C use the same prior and the same decay, so the difference you observe
between them is purely *mechanism* — value-function shaping vs. objective bias.

---

## 7. Getting the FCF out

Set `extract_fcf = true` on an `engine = :sddp` run. Two artifacts land in
`runs/<id>/`:

- **`fcf_curves.csv`** — per-reservoir water-value-vs-own-storage curves (the
  "diagonal"), offer-reconciled near-term. Drop-in for a stack / merit-order sim: look
  up a reservoir's current storage → that's its hydro offer price.
- **`fcf_cuts.json`** — the full, coupling-aware value function as SDDP cuts. Load with
  `SDDP.read_cuts_from_file`, or evaluate `−∂V/∂s_r` at the current joint storage for
  an exact hydro offer at any timestep.

See [FCF.md](FCF.md) for the exact schemas and consumption patterns. Quick driver:

```bash
julia --project=. scripts/get_fcf.jl          # quick example  (~minutes)
julia --project=. scripts/get_fcf.jl --full   # 2-year policy  (~hours)
```

---

## 8. Comparing the options

`scripts/warmstart_demo.jl` runs `:none`, `:anchor`, and `:cuts` over **one** assembled
input set (only the warm-start differs) on the quick example, and writes:

```bash
julia --project=. scripts/warmstart_demo.jl
```

Outputs under `runs/warmstart_demo_<date>/`:

- `warmstart_compare_wv.csv` — per-mode, per-reservoir water-value curves.
- `warmstart_compare_storage.csv` — per-mode mean storage trajectory (`mode, reservoir, week, mean_storage_mm3`).
- `warmstart_compare_price.csv` — per-mode mean weekly nodal price (`mode, hub, week, mean_price`).

plus a console table of each mode's lower bound and week-1 water values. Read the WV
file to see how each mechanism reshapes the curve; read the storage/price files to see
whether it changes *operating decisions* (conserve vs. release) and the resulting
prices. In practice the near-term water-value *curve* converges across modes (it is
offer-reconciled), while the **storage trajectory and lower bound diverge** — that is
where the two mechanisms show their effect.

---

## 9. Config & API reference

**`config/model.toml`**

```toml
[wvanchor]                 # Option C strength + shared decay
weight        = 1.0
decay_weeks   = 13         # shared by BOTH options' taper

[fcf_extract]              # FCF curve extraction
reslice_weeks = [1,2,3,4]  # weeks to re-evaluate curves at realised storage
grid_points   = 9          # storage grid points per reservoir
decay_weeks   = 13
forward_weight = 0.0
```

**Key functions**

- `run_model(date; engine=:sddp, warm_start=:anchor, extract_fcf=false, …)` — top-level run.
- `solve_sddp(mi, scen; warm_start=:anchor, n_scenarios, iteration_limit, seed)` — trains + prices; returns `SddpResult`.
- `wv_warmstart_cuts(net, anchor_vol, wv_values, decay_weights, lb)` — build the Option A cuts (pure).
- `apply_wv_warmstart!(graph, cuts)` — inject them into a policy graph.
- `reservoir_implied_wv(ds, plant, sm)` — the offer-implied prior both options use.

---

## 10. Gotchas

- `extract_fcf = true` requires `engine = :sddp` (there is no value function to sample
  on the deterministic path) — `run_model` errors otherwise.
- Default `warm_start = :anchor` reproduces prior behaviour exactly; switching to
  `:none`/`:cuts`/`:both` is opt-in.
- The `:cuts` lower bound is diagnostic, not a valid dual bound (see §3).
- Runtimes: the quick example (`n_weeks≈8, iters≈15, scen≈4`) is minutes; the full
  2-year policy (`n_weeks=104, iters=100, scen=50`) is hours — and the comparison
  harness runs three modes, so budget accordingly.
