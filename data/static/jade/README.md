# data/static/jade — JADE input dataset (2025-W52 vintage)

Tracked reference files for the JADE dispatch model inputs, pinned to the
EMI Expected Water Values 2025 Week 52 vintage. Downloaded 2026-06-18 via
`scripts/fetch_jade.jl`. Source base URL:

```
https://www.emi.ea.govt.nz/Wholesale/Datasets/Expected%20water%20values/2025/Week%2052/Inputs/data_files/202512250609
```

Column names and units verified by DuckDB `read_csv_auto` inspection on the
downloaded files. These are the contract for Task 2-6 loaders; see also
`config/jade.toml [columns.*]` overrides.

---

## thermal_stations.csv

- **Size:** 630 bytes
- **Rows:** 10 (one per thermal generator, all NI)
- **Columns:** `GENERATOR, NODE, FUEL, HEAT_RATE, CAPACITY, OMCOST, START_YEAR, START_WEEK, END_YEAR, END_WEEK`
- **Units:** HEAT_RATE in GJ/MWh; CAPACITY in MW; OMCOST in NZD/MWh
- **Notes:** START_YEAR/START_WEEK = 0 means "active since model start"; END_YEAR/END_WEEK = 0 means "no scheduled retirement". Stratford_220KV has END_YEAR=2024/END_WEEK=52 (retired). Junction_Road has START_YEAR=2020.
- **Fuels present:** coal, gas, diesel
- **Preamble:** 3 leading `%`-comment lines (lines 1–3). DuckDB `read_csv_auto` skips them automatically — no special handling needed.

---

## thermal_fuel_costs.csv

- **Size:** 26,271 bytes
- **Rows:** 884 data rows + 3 metadata/header rows = 887 lines total
- **Structure:** NON-STANDARD 3-row header before data. Raw layout:
  ```
  Row 1: ,,coal,diesel,gas,CO2          ← column labels
  Row 2: CO2_CONTENT,,0.09218,0.06939,0.05397,  ← CO2 intensity (tCO2/GJ) per fuel
  Row 3: YEAR,WEEK,,,, ← true data header
  Row 4+: 2010,1,5.89,28.58,7.2,20.25  ← weekly fuel prices
  ```
- **Columns (data rows):** `YEAR, WEEK, coal, diesel, gas, CO2`
- **Units:** Fuel price columns in NZD/GJ; CO2 column is aggregate CO2 emissions (units unclear — likely tCO2/MWh or index). CO2 intensity coefficients in row 2: coal=0.09218, diesel=0.06939, gas=0.05397 tCO2/GJ.
- **WARNING for loaders:** `read_csv_auto` misdetects row 1 as the header (naming columns blank/blank/coal/diesel/gas/CO2). Use `skip=3` and supply column names manually — `read_csv_auto` must NOT be used here. The canonical DuckDB call is:
  ```sql
  read_csv('thermal_fuel_costs.csv', skip=3, header=false,
           columns={'YEAR':'INTEGER','WEEK':'INTEGER','coal':'DOUBLE',
                    'diesel':'DOUBLE','gas':'DOUBLE','CO2':'DOUBLE'})
  ```
  CO2 intensity per fuel (tCO2/GJ) is in the skipped row 2: coal=0.09218, diesel=0.06939, gas=0.05397. Extract these from the raw file before skipping if needed for SRMC calculations.
- **Date range:** 2010-W1 through 2026-W52

---

## hydro_stations.csv

- **Size:** 1,442 bytes
- **Rows:** 26 (one row per hydro generator — NO multi-segment turbine rows)
- **Columns:** `GENERATOR, HEAD_WATER_FROM, TAIL_WATER_TO, POWER_SYSTEM_NODE, CAPACITY, SPECIFIC_POWER, SPILLWAY_MAX_FLOW`
- **Units:** CAPACITY in MW; SPECIFIC_POWER in MW/cumec (MW per m³/s — encodes effective head × efficiency as a single scalar); SPILLWAY_MAX_FLOW in cumecs ("na" if no cap)
- **Notes (important for Tasks 2 & 5):** SPECIFIC_POWER is a single scalar per station — there are NO multi-row turbine efficiency segments in this file. It acts as a linear generation coefficient: power(MW) = flow(cumecs) × SPECIFIC_POWER. HEAD_WATER_FROM and TAIL_WATER_TO are reservoir/node names that must match ORIG/DEST in hydro_arcs.csv or RESERVOIR in reservoirs.csv.
- **Islands:** NI: 13 generator rows, SI: 13 generator rows. All 26 rows are generator rows — arc-only intermediate nodes (e.g. canal junctions such as `Pukaki_Ohau_canal_junction`) appear in `hydro_arcs.csv`, not here.

---

## hydro_arcs.csv

- **Size:** 732 bytes
- **Rows:** 19
- **Columns:** `ORIG, DEST, MIN_FLOW, MAX_FLOW`
- **Units:** MIN_FLOW and MAX_FLOW in cumecs; "na" means unconstrained
- **Notes:** ORIG and DEST are reservoir names or tail-water nodes (e.g. `SEA`, `Karapiro_tail`, `Pukaki_Ohau_canal_junction`). Arc endpoints must be matched against HEAD_WATER_FROM/TAIL_WATER_TO in hydro_stations.csv and RESERVOIR in reservoirs.csv to build the full river graph.

---

## reservoirs.csv

- **Size:** 208 bytes
- **Rows:** 7
- **Columns:** `RESERVOIR, INFLOW_REGION, INI_STATE`
- **Units:** INI_STATE in Mm³ (lake storage volume; MIN_1 may be negative = contingent storage below normal minimum). Energy content is derived downstream via specific_power, not stored here (see Plan 3b hydroenergy).
- **Reservoirs:** Lake_Hawea (SI), Lake_Ohau (SI), Lake_Pukaki (SI), Lake_Taupo (NI), Lake_Tekapo (SI), Lake_Waikaremoana (NI), Lakes_Manapouri_Te_Anau (SI)
- **Notes:** These 7 reservoirs are the state variables in the JADE model. INFLOW_REGION maps to the inflow columns in `jade_inflows_2025w52.csv` (also in data/static/).

---

## reservoir_limits.csv

- **Size:** 78,899 bytes
- **Rows:** 884 (YEAR × WEEK, 2010-W1 through 2026-W52)
- **Columns:** `YEAR, WEEK` then per-lake constraint columns named `"<Lake_Name> MAX_LEVEL"`, `"<Lake_Name> MIN_1_LEVEL"`, `"<Lake_Name> MIN_1_PENALTY"` (note: space separator, not underscore)
- **Lakes with limits:** Lake_Hawea (3 cols), Lake_Ohau (1 col: MAX only), Lake_Pukaki (3 cols), Lake_Taupo (1 col: MAX only), Lake_Tekapo (3 cols), Lake_Waikaremoana (1 col: MAX only), Lakes_Manapouri_Te_Anau (1 col: MAX only)
- **Units:** Mm³ (lake storage volume; MIN_1 may be negative = contingent storage below normal minimum). MIN_1_PENALTY is a soft-constraint penalty cost. Energy content is derived downstream via specific_power, not stored here (see Plan 3b hydroenergy).
- **WARNING for loaders:** Column names contain spaces (e.g. `"Lake_Hawea MAX_LEVEL"`). DuckDB handles these correctly but Julia DataFrame column access requires `df[!, "Lake_Hawea MAX_LEVEL"]` syntax.

---

## fixed_stations.csv

- **Size:** 1,620,051 bytes (~1.6 MB, largest file)
- **Rows:** 33,963
- **Columns:** `STATION, NODE, YEAR, WEEK, PEAK, SHOULDER, OFFPEAK`
- **Units:** PEAK/SHOULDER/OFFPEAK in MW (must-run generation per time block)
- **Stations:** Glenbrook_cogen (NI), Kapuni_cogen (NI), Kinleith_cogen (NI) ...and ~36 more: geothermal, wind, run-of-river, regional aggregates (~39 distinct stations total)
- **Date range:** 2010-W1 through 2026-W52

---

## station_outages.csv

- **Size:** 80,948 bytes
- **Rows:** 884 (YEAR × WEEK, 2010-W1 through 2026-W52)
- **Columns:** `YEAR, WEEK` then one column per station (36 station columns)
- **Values:** 0 = available, 1 = on forced outage
- **Station columns (36):** Arapuni, Aratiatia, Atiamuri, Aviemore, Benmore, Clyde_220kV, Cobb, Coleridge, Huntly_e3p, Huntly_main_g1, Huntly_main_g2, Huntly_main_g4, Huntly_peaker, Junction_Road, Karapiro, Manapouri, Mangahao, Maraetai, Matahina, McKee_peakers, NI_Whirinaki_220KV, Ohakuri, Ohau_A, Ohau_B, Ohau_C, Rangipo, Roxburgh, Stratford_220KV, Stratford_peakers, Tekapo_A, Tekapo_B, Tokaanu, Waikaremoana, Waipapa, Waitaki, Whakamaru
- **Notes:** Station names match GENERATOR column in thermal_stations.csv and hydro_stations.csv exactly (except Clyde_220kV vs Clyde in hydro — verify at load time).

---

## terminal_water_value.csv

- **Size:** 596 bytes
- **Rows:** 31
- **Columns:** `STORED_ENERGY, VALUE`
- **Units:** STORED_ENERGY in GWh (aggregate system storage); VALUE in NZD/MWh
- **Notes:** Stepwise piecewise-linear terminal water value curve. Used as end-of-horizon boundary condition for the dispatch optimisation.
- **Preamble:** 1 leading `%`-comment line (line 1). DuckDB `read_csv_auto` skips it automatically — no special handling needed.

---

## lost_load.csv

- **Size:** 1,088 bytes
- **Rows:** 27
- **Columns:** `NODE, ISLAND, SECTOR, SEGMENT, PROPORTION, BOUND, COST`
- **Units:** COST in NZD/MWh; PROPORTION is fraction of node load in that sector; BOUND is max fraction that can be shed
- **Nodes:** NI, HAY, SI. Sectors: industrial (10%), commercial (30%), residential (60%).
- **Segments:** low / medium / high per sector
- **COST range:** 530–10,580 NZD/MWh (industrial low to residential high)
- **Preamble:** 2 leading `%`-comment lines (lines 1–2). DuckDB `read_csv_auto` skips them automatically — no special handling needed.
