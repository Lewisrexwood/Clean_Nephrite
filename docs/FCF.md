# The FCF (Future Cost Function) outputs

`get_fcf.jl` writes two artifacts per run:

## 1. `fcf_curves.csv` — per-reservoir offer curves (the "diagonal")
Columns: `reservoir, storage_gwh, water_value [, week]`. For each reservoir, the
marginal water value ($/MWh) as a function of its own storage, sampled from the
trained SDDP value function and calibrated to offer-implied water values near-term.

**Use in a stack / merit-order simulator:** look up each reservoir's current
storage on its curve → that is its hydro offer price; offer thermal at SRMC. This
is the direct, drop-in form for vSPD-with-offers or a Spectra-like sim.

Caveat: each curve holds the *other* reservoirs at a reference (mean simulated
storage), so it omits cross-reservoir coupling. Fine for short horizons; re-evaluate
at the realised joint storage for long runs.

## 2. `fcf_cuts.json` — the full FCF (SDDP cuts)
The complete, exact, coupling-aware value function as a set of linear cuts
(`V(x) ≥ α_k + Σ_r β_kr · x_r`) per stage, in SDDP.jl format. Load with
`SDDP.read_cuts_from_file`, or parse the JSON (per stage: intercept + per-state
coefficients keyed `s[<reservoir>]`) and embed the max-affine `V` in your own LP.

**Use in an LP/value-function engine:** add a free `θ` with `θ ≥ α_k + Σ β_kr·s_r`
and minimise — or evaluate `−∂V/∂s_r` at the current joint storage to get an exact,
coupling-aware hydro offer at every timestep (the same gradient `get_fcf.jl` reads).

Conversion: water value $/MWh = `−(∂V/∂s_r) / (coeff_r · MWH_PER_MM3_PER_SP)`,
identical to the storage-dual convention in `src/master.jl`.
