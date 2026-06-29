# data/static — tracked reference files

Static reference datasets committed to the repository. These are not
point-in-time snapshots; they are versioned input files used across multiple
model runs. Update them deliberately (with a commit note) when the source
publishes a new release.

---

## jade_inflows_2025w52.csv

- **File name:** `jade_inflows_2025w52.csv`
- **Source URL:** `https://www.emi.ea.govt.nz/Wholesale/Datasets/Expected%20water%20values/2025/Week%2052/Inputs/data_files/202512250609/inflows.csv`
- **Downloaded:** 2026-06-13
- **File size:** 1,289,921 bytes (~1.26 MB)
- **Total lines:** 4,944 (5 header lines + 4,939 data rows)

### Structure

The file has a non-standard multi-line header before the data:

```
Line 1: % Historical weekly inflow sequences [cumecs].
Line 2: (blank)
Line 3: CATCHMENT,,Lake_Arapuni,Lake_Aratiatia,...   ← lake names (27 columns after CATCHMENT)
Line 4: INFLOW_REGION,,NI,NI,NI,SI,SI,...            ← NI/SI region per lake
Line 5: YEAR,WEEK                                    ← column headers for the data rows
Lines 6+: 1932,1,<27 float values>,...               ← weekly inflow data
```

### Columns (line 5 is the header; 29 values per data row)

| Column | Description |
|--------|-------------|
| YEAR   | Calendar year (1932–2025) |
| WEEK   | ISO week number (1–52) |
| Lake_Arapuni | Inflow in cumecs (m³/s), weekly average |
| Lake_Aratiatia | " |
| Lake_Atiamuri | " |
| Lake_Aviemore | " |
| Lake_Benmore | " |
| Lake_Dunstan | " |
| Lake_Cobb | " |
| Lake_Coleridge | " |
| Lake_Hawea | " |
| Lake_Karapiro | " |
| Lakes_Manapouri_Te_Anau | " |
| Mangahao_head | " |
| Lake_Maraetai | " |
| Lake_Matahina | " |
| Lake_Pukaki | " |
| Lake_Tekapo | " |
| Lake_Ohakuri | " |
| Lake_Ohau | " |
| Lake_Moawhango | " |
| Lake_Roxburgh | " |
| Lake_Taupo | " |
| Lake_Rotoaira | " |
| Lake_Waikaremoana | " |
| Lake_Waipapa | " |
| Lake_Waitaki | " |
| Lake_Wanaka | " |
| Lake_Whakamaru | " |

**Key columns consumed by Nephrite:** YEAR, WEEK, and the per-lake inflow columns
(units: cumecs = m³/s, weekly average). To re-fetch:

```powershell
Invoke-WebRequest -Uri "https://www.emi.ea.govt.nz/Wholesale/Datasets/Expected%20water%20values/2025/Week%2052/Inputs/data_files/202512250609/inflows.csv" -OutFile "data\static\jade_inflows_2025w52.csv" -MaximumRedirection 5
```

---

## jade_reservoirs_2025w52.csv

- **File name:** `jade_reservoirs_2025w52.csv`
- **Source URL:** `https://www.emi.ea.govt.nz/Wholesale/Datasets/Expected%20water%20values/2025/Week%2052/Inputs/data_files/202512250609/reservoirs.csv`
- **Downloaded:** 2026-06-13
- **File size:** 208 bytes
- **Total lines:** 8 (1 header + 7 data rows)

### Structure

Standard CSV. Columns: `RESERVOIR, INFLOW_REGION, INI_STATE`

| Column | Description |
|--------|-------------|
| RESERVOIR | Lake name matching the column headers in jade_inflows_2025w52.csv |
| INFLOW_REGION | SI or NI (South/North Island) |
| INI_STATE | Initial reservoir state as of Week 52 2025 (units: GWh equivalent) |

### Data rows (complete file)

```
Lake_Hawea,SI,1060.094
Lake_Ohau,SI,3.05
Lake_Pukaki,SI,2444.693
Lake_Taupo,NI,749.628
Lake_Tekapo,SI,476.421
Lake_Waikaremoana,NI,90.744
Lakes_Manapouri_Te_Anau,SI,1034.492
```

To re-fetch:

```powershell
Invoke-WebRequest -Uri "https://www.emi.ea.govt.nz/Wholesale/Datasets/Expected%20water%20values/2025/Week%2052/Inputs/data_files/202512250609/reservoirs.csv" -OutFile "data\static\jade_reservoirs_2025w52.csv" -MaximumRedirection 5
```

---

## hmd/ — HMD lake storage time series

Historical daily lake storage series from the EA Hydrological Modelling
Dataset (HMD), release `3_StorageAndSpill_20241231` (data through end-2024).
Used to compute the per-reservoir monthly storage shares in
`config/reservoirs.toml`.

- **Folder:** `data/static/hmd/`
- **Source base URL:** `https://www.emi.ea.govt.nz/Environment/Datasets/HydrologicalModellingDataset/3_StorageAndSpill_20241231/3_1_Storage/`
- **Release:** HMD 3_StorageAndSpill_20241231

### Files

| File | Lake |
|------|------|
| `SI_TKA_Storage_LakeTekapo.csv` | Lake Tekapo (SI) |
| `SI_PKI_Storage_LakePukaki.csv` | Lake Pukaki (SI) |
| `SI_HWE_Storage_LakeHawea.csv` | Lake Hawea (SI) |
| `SI_TAU_Storage_LakeTeAnau.csv` | Lake Te Anau (SI) |
| `SI_MAN_Storage_LakeManapouri.csv` | Lake Manapouri (SI) |
| `NI_TPO_Storage_LakeTaupo.csv` | Lake Taupo (NI) |

### Columns

| Column | Description |
|--------|-------------|
| Date | Calendar date (YYYY-MM-DD) |
| Time | Time of observation |
| Lake level (m) | Lake surface elevation in metres |
| Active storage (Mm³) | Active storage volume in million cubic metres |
| Active contingent storage (Mm³) | Active contingent storage volume in million cubic metres |
| QualityCode | EA data quality flag |

### Consumed by

`scripts/compute_storage_shares.jl` — reads these files to compute the
`monthly_share` vectors written to `config/reservoirs.toml`.

### Re-fetch

Re-running the script will download any missing lake files automatically:

```powershell
julia --project=. scripts/compute_storage_shares.jl
```
