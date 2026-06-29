# Architecture

Deterministic pipeline + SDDP engine; the FCF extraction reads the trained policy.

- `src/ingest.jl`, `snapshots.jl`, `datastore.jl` — point-in-time EMI snapshots + DuckDB query layer.
- `src/hubmap.jl`, `supplycurves.jl`, `thermal.jl`, `demand.jl`, `profile.jl` — market transforms (POC→hub, offers, SRMC, demand).
- `src/jadedata.jl`, `hydronet.jl`, `hydroenergy.jl`, `stationmap.jl` — JADE hydro network + water↔energy.
- `src/dispatch.jl` — shared JuMP dispatch builder (`build_dispatch!`).
- `src/master.jl`, `subproblem.jl` — 104-week master water-budget LP + weekly 336-step subproblem.
- `src/sddp.jl` — SDDP policy graph (reuses `build_dispatch!`), train, simulate, price.
- `src/inputs.jl`, `runner.jl`, `outputs.jl` — assemble inputs, orchestrate `run_model`, write curves.
- **FCF extraction** — `src/fcfshape.jl`, `fcfreconcile.jl`, `fcfexport.jl`, `fcfextract.jl`, `fcfsddp.jl`:
  per-reservoir water-value curves sampled from the trained SDDP value function,
  calibrated to offer-implied water values. See `docs/FCF.md`.

`scripts/get_fcf.jl` is the entry point. `config/*.toml` holds all model config.
