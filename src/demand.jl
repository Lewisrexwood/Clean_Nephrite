using TOML, DataFrames

"Tiwai POC list from demand config."
tiwai_pocs(config_path::AbstractString) =
    String[String(p) for p in TOML.parsefile(config_path)["tiwai"]["pocs"]]

"Build a SQL `IN (...)` value list from POC codes (config-controlled values)."
sql_in_list(pocs) = join(["'$p'" for p in pocs], ",")

"""
30-minute hub demand from the snapshot's 5-minute RTD load. Dedupes to the
latest dispatch case per (POC, interval), averages the 5-min MW within each
trading period, maps POC->hub, and excludes the Tiwai block (returned by
`tiwai_block` instead). Returns (date, tp, hub, mw).
Dedup keeps the highest CaseID per (POC, interval) — EMI assigns higher
CaseIDs to later dispatch runs, so this selects the most recent case.
"""
function hub_demand(ds::DataStore, hm::HubMap, config_path::AbstractString)
    tiwai = tiwai_pocs(config_path)
    placeholders = sql_in_list(tiwai)
    df = query(ds, """
        WITH latest AS (
            SELECT *, row_number() OVER (
                PARTITION BY PointOfConnectionCode, IntervalDateTime
                ORDER BY CaseID DESC) AS rn
            FROM grid_demand)
        SELECT TradingDate AS date, TradingPeriodNumber AS tp,
               PointOfConnectionCode AS poc, avg(LoadMegawatts) AS mw
        FROM latest
        WHERE rn = 1 AND LoadMegawatts > 0
          AND PointOfConnectionCode NOT IN ($placeholders)
        GROUP BY 1, 2, 3
    """)
    df.hub = [hub_for(hm, p) for p in df.poc]
    out = combine(groupby(df, [:date, :tp, :hub]), :mw => sum => :mw)
    sort!(out, [:date, :tp, :hub])
    return out[:, [:date, :tp, :hub, :mw]]
end

"""
The Tiwai block as configured: named, hub-assigned (via the hubmap), with
baseline MW and DR tranches. Phase 1 treats it as a constant block.
"""
function tiwai_block(hm::HubMap, config_path::AbstractString)
    cfg = TOML.parsefile(config_path)["tiwai"]
    # Tiwai is a single connection point; hub is taken from the first POC. (hub_demand excludes all configured Tiwai POCs.)
    poc = String(cfg["pocs"][1])
    return (name = "Tiwai", hub = hub_for(hm, poc),
            baseline_mw = Float64(cfg["baseline_mw"]),
            dr_tranches = [(mw = Float64(t["mw"]), note = String(t["trigger_note"]))
                           for t in get(cfg, "dr_tranches", [])])
end
