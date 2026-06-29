# test/fixtures/jade — hand-built toy JADE system

These are **hand-crafted toy fixture files** for offline testing of Tasks 2-6
loaders. They are NOT real JADE data and do NOT represent real stations,
reservoirs, or operating conditions. They use column names and file formats
identical to the real files in `data/static/jade/` (verified 2026-06-18).

## Toy system description

### Thermal stations (3 units)
- `ToyGas_NI` — 100 MW gas unit, NI
- `ToyCoal_NI` — 50 MW coal unit, NI (on outage in week 2 per station_outages)
- `ToyDiesel_SI` — 20 MW diesel unit, SI

### Hydro chains (2 chains, 4 reservoirs)

**NI chain** (2 reservoirs, 2 generators):
```
Lake_ToyTaupo --[ToyTaupo_gen 100MW]--> Lake_ToyWhaka --[ToyWhaka_gen 50MW]--> ToyWhaka_tail (SEA equiv)
```

**SI chain** (2 reservoirs, 2 generators):
```
Lake_ToyPukaki --[ToyPukaki_gen 200MW]--> Lake_ToyBenmore --[ToyBenmore_gen 150MW]--> ToyBenmore_tail (SEA equiv)
```

### Internal consistency
- `hydro_arcs.csv` ORIG/DEST reference exactly the reservoir names in `reservoirs.csv`
- `hydro_stations.csv` HEAD_WATER_FROM/TAIL_WATER_TO match arc endpoints
- `station_outages.csv` station columns match GENERATOR names in thermal_stations + hydro_stations
- `reservoir_limits.csv` uses Lake_ToyTaupo, Lake_ToyPukaki, Lake_ToyBenmore (not Lake_ToyWhaka — no min limit there)

### Format quirks preserved from real files
- `thermal_fuel_costs.csv` has the same 3-row metadata header (CO2_CONTENT row) as the real file
- `reservoir_limits.csv` column names use space separator: `"Lake_ToyTaupo MAX_LEVEL"` etc.
- `hydro_arcs.csv` and `hydro_stations.csv` use `"na"` for unconstrained flow/spillway values

## Files

| File | Rows | Notes |
|------|------|-------|
| thermal_stations.csv | 3 | gas + coal (NI), diesel (SI) |
| thermal_fuel_costs.csv | 2 data rows | 3-row metadata header preserved |
| hydro_stations.csv | 4 | NI 2-station chain + SI 2-station chain |
| hydro_arcs.csv | 4 | matching arcs for all 4 stations |
| reservoirs.csv | 4 | 2 NI + 2 SI reservoirs |
| reservoir_limits.csv | 2 | 2025-W1 and W2 only |
| station_outages.csv | 2 | ToyCoal_NI on outage in W2 |
| fixed_stations.csv | 2 | ToyCogen_NI must-run (not in thermal_stations — independent) |
| terminal_water_value.csv | 5 | 5-point stepwise curve |
| lost_load.csv | 6 | 1 segment per sector per island (NI + SI) |
