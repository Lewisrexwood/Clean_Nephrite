# Test fixtures

Fixtures come from two EMI snapshots:
- **2026-06-09** — offers, final prices, grid demand, hydro storage (Plan 1 Task 8)
- **2026-06-11** — network supply points, JADE inflows (Plan 2 Task 2)

The hydro_storage fixture remains for reference but the `hydro_storage` dataset
is now `required = false`; tests no longer depend on it. The new fixture
(network_supply_points) is added in Plan 2 Task 2; hydro_storage_daily is deferred
with no fixture (see the hydro_storage_daily section below).

---

## offers_sample.csv

- **Source file:** `20260609_Offers.csv`
- **EMI URL:** `https://www.emi.ea.govt.nz/Wholesale/Datasets/BidsAndOffers/Offers/2026/20260609_Offers.csv`
- **Snapshot date:** 2026-06-09
- **Data rows in fixture:** 199
- **Total rows in full file:** 1,474,887
- **Columns (21):**
  `TradingDate, TradingPeriod, ParticipantCode, PointOfConnection, Unit,
  ProductType, ProductClass, ReserveType, ProductDescription,
  UTCSubmissionDate, UTCSubmissionTime, SubmissionOrder, IsLatestYesNo,
  Tranche, MaximumRampUpMegawattsPerHour, MaximumRampDownMegawattsPerHour,
  PartiallyLoadedSpinningReservePercent, MaximumOutputMegawatts,
  ForecastOfGenerationPotentialMegawatts, Megawatts, DollarsPerMegawattHour`
- **Note:** Contains BOTH energy offers (ProductType = "Energy") and reserve
  offers (ProductType = "Reserve", ReserveType in {"FIR", "SIR"}).

---

## final_energy_prices_sample.csv

- **Source file:** `20260609_FinalEnergyPrices.csv`
- **EMI URL:** `https://www.emi.ea.govt.nz/Wholesale/Datasets/DispatchAndPricing/FinalEnergyPrices/20260609_FinalEnergyPrices.csv`
- **Snapshot date:** 2026-06-09
- **Data rows in fixture:** 199
- **Total rows in full file:** 11,760
- **Note:** Files sit flat in the folder (no year subfolder). Completed-day
  files have no `_I` suffix; same-day interim files carry `_I`.

---

## final_reserve_prices_sample.csv

- **Source file:** `20260609_FinalReservePrices.csv`
- **EMI URL:** `https://www.emi.ea.govt.nz/Wholesale/Datasets/DispatchAndPricing/FinalReservePrices/20260609_FinalReservePrices.csv`
- **Snapshot date:** 2026-06-09
- **Data rows in fixture:** 96
- **Total rows in full file:** 96
- **Note:** Small file — 48 trading periods x 2 islands = 96 rows. The entire
  file fits in the fixture. Same flat folder structure as FinalEnergyPrices.

---

## grid_demand_sample.csv

- **Source file:** `20260609_DispatchNodalPricesAndVolumes.csv`
- **EMI URL:** `https://www.emi.ea.govt.nz/Wholesale/Datasets/DispatchAndPricing/NodalPricesAndVolumes/2026/20260609_DispatchNodalPricesAndVolumes.csv`
- **Snapshot date:** 2026-06-09
- **Data rows in fixture:** 199
- **Total rows in full file:** 68,364
- **Columns (17):**
  `TradingDate, TradingPeriodNumber, IntervalDateTime, RunDateTime,
  CaseTypeCode, CaseID, PointOfConnectionCode, UnitCode, PlantName, Island,
  LoadMegawatts, InitialMegawatts, GenerationMegawatts, LocationFactor,
  DollarsPerMegawattHour, IsDeadFlag, IsDisconnectedFlag`
- **Note:** 5-minute RTD intervals. `LoadMegawatts` is grid demand (offtake)
  at each POC; `GenerationMegawatts` is dispatched generation. Daily file
  in year subfolders.

---

## hydro_storage_sample.csv

- **Source file:** `SI_PKI_Storage_LakePukaki.csv`
- **EMI URL:** `https://www.emi.ea.govt.nz/Environment/Datasets/HydrologicalModellingDataset/3_StorageAndSpill_20241231/3_1_Storage/SI_PKI_Storage_LakePukaki.csv`
- **Snapshot date:** 2026-06-09 (as-of download time)
- **Data rows in fixture:** 199
- **Total rows in full file:** 16,438
- **Columns (6):**
  `Date, Time, Lake level (m), Active storage (Mm3), Active contingent storage (Mm3), QualityCode`
- **Note:** Full-history file (not daily-dated); covers approximately 1980
  through end-2024. Lake Pukaki (South Island, Waitaki catchment) is the
  largest regulated NZ reservoir. Nine other lake files follow the same
  naming pattern in the same folder. The HMD is updated roughly annually.
  The `hydro_storage` dataset is now `required = false`; this fixture is
  retained for reference but is no longer exercised by the standard test suite.

---

## network_supply_points_sample.csv

- **Source file:** `20260611_NetworkSupplyPointsTable.csv`
- **EMI URL:** `https://www.emi.ea.govt.nz/Wholesale/Datasets/MappingsAndGeospatial/NetworkSupplyPointsTable/20260611_NetworkSupplyPointsTable.csv`
- **Snapshot date:** 2026-06-11
- **Construction:** TARGETED fixture (not first-200 head). Built by selecting
  all rows whose `POC code` appears in either the `grid_demand_sample.csv` or
  `offers_sample.csv` fixtures, UNION with the first 100 rows of the full
  parquet. Deduped on (POC code, NSP). This ensures Task 5/6 hub_for lookups
  find every POC present in the other fixtures.
- **Data rows in fixture:** 304
- **Columns (27):**
  `Current flag, NSP, NSP replaced by, POC code, Network participant,
  Embedded under POC code, Embedded under network participant,
  Reconciliation type, X flow, I flow, Description, NZTM easting,
  NZTM northing, Network reporting region ID, Network reporting region,
  Zone, Island, Start date, Start TP, End date, End TP, SB ICP,
  Balancing code, MEP, Responsible participant, Certification expiry,
  Metering information exemption expiry date`
- **Key columns for hub mapping:**
  - POC code column name: `POC code`
  - Zone column name: `Zone`
  - Island column name: `Island`
  - Network reporting region column: `Network reporting region`
- **Overlap check:** All 171 distinct POC codes from grid_demand_sample.csv
  and offers_sample.csv are confirmed present in this fixture.
- **Tiwai Point smelter POC:** TWI2201. Absent from the 2026-06-09 grid_demand
  sample. Plan 2 Task 6 appended the real TWI2201 row (sourced from
  data/raw/2026-06-11/network_supply_points.csv, line 689) so that
  `build_hubmap` includes it in poc_to_hub and `tiwai_block` resolves via
  `hub_for(hm, "TWI2201")` → "INV". The config/hubmap.toml poc_override
  for TWI2201 is retained for auditability (redundant but explicit).

---

## hydro_storage_daily (deferred — no fixture)

No fixture exists for `hydro_storage_daily` because the dataset is `required = false`
and is not ingested by `ingest!`.

**Why deferred:** No free automatable daily aggregate controlled-storage feed exists
on EMI. The EMI "Historical Electricity Risk Curves" report (RM3RAS) states that
hydro storage data is sourced from NZX hydro (NIWA) and is not available for download.
Plain-GET export of RM3RAS returns only risk-curve thresholds (Watch/Alert/Emergency
GWh bands), not actual controlled storage values. NZX/NIWA daily per-lake or aggregate
storage is subscription-only.

The Plan 3 runner must take the initial aggregate storage state as a manual config/CLI
input. Task 8's storage_state will document this seam in config/reservoirs.toml.
