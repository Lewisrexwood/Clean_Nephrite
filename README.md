# Nephrite — NZ electricity fundamental price & FCF model

Nephrite ingests the daily NZ system state (lake storage, spot offer stacks) and
solves a forward dispatch model on an 8-hub topology matching the NZ FTR hubs to
produce forward price views at OTA/BEN and, via SDDP, per-reservoir **water-value
curves (the FCF)** for use in a dispatch/stack model.

## Quickstart
```
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. -e 'using Pkg; Pkg.test()'        # ~minutes, all green
julia --project=. scripts/get_fcf.jl                # QUICK FCF example (~minutes)
julia --project=. scripts/get_fcf.jl --full         # the 2-year policy (~hours)
```
Outputs land in `runs/<id>/`: `fcf_curves.csv` (per-reservoir offer curves) and
`fcf_cuts.json` (the full FCF as SDDP cuts). A ready-made quick example is in
`examples/quick_fcf/`. See `docs/FCF.md` for how to consume these.

Storage state (NZ 2700 / SI 2200 GWh for the 2-year run) is a manual input — there
is no automatable daily controlled-storage feed; change it in `scripts/get_fcf.jl`.

## Backtest (JADE scenario comparison)

Everything the historical backtest needs ships in the repo: the pinned
2022-01-05 point-in-time snapshot (`data/snapshots/2022-01-05/`), HMD lake
storage (`data/static/hmd/`), ASX forward + realized spot references
(`data/static/forward_prices/`), and the precomputed demand shape
(`data/static/demand_shape.csv`, byte-identical to the full-history build).

```
julia --project=. --threads=auto scripts/compare_jade.jl 2022-01-05 --iters 100 --train-samples 10 --price-seqs 15
python scripts/plot_jade_compare.py 2022-01-05
```

This trains the 104-week SDDP policy on the 2022-01-05 system state (~hours;
checkpointed every 25 iterations, resumable with `--resume`), replays 94
coherent historical inflow year-sequences through the policy, prices a
dry-to-wet subset, and writes storage/price fans plus deterministic/ASX/realized
overlays to `runs/jade_compare/2022-01-05/`.

### Known issue — perturbation sensitivity (patch underway)

SDDP training amplifies tiny numerical perturbations in its inputs: a ~0.01%
difference in assembled inputs or LP duals yields a visibly different cut set,
and the tail quantiles of the priced fan (p90) can move ~10% between
otherwise-identical runs in different environments. Known perturbation sources
are multi-threaded DuckDB float aggregation during input assembly and
warm-started model reuse in the threaded pricing pass. A determinism patch
(single-threaded deterministic input queries, per-solve basis reset in pricing,
and a run manifest for `compare_jade`) is underway in the main Nephrite repo.
Until it lands: compare backtest runs only against runs from the same
machine/session, treat fan tail quantiles as indicative rather than precise,
and prefer `--price-all` (all 94 sequences) when quantile stability matters —
15-point fans put heavy weight on individual sequences.

See `ARCHITECTURE.md` for the module map.
