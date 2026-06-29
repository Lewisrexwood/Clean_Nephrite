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

See `ARCHITECTURE.md` for the module map.
