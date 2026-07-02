# Render the JADE scenario comparison fans from runs/jade_compare/<date>/.
#   python visuals/plot_jade_compare.py 2022-01-05
import sys, os
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

date = sys.argv[1] if len(sys.argv) > 1 else "2022-01-05"
d = os.path.join(os.path.dirname(__file__), "..", "runs", "jade_compare", date)

sfan = pd.read_csv(os.path.join(d, "storage_fan.csv"))
monthly = pd.read_csv(os.path.join(d, "price_fan_monthly.csv"))
cal = pd.read_csv(os.path.join(d, "cal2023_annual.csv"))
ov = pd.read_csv(os.path.join(d, "overlays.csv")).set_index("hub")

# 1) Aggregate-storage fan: one line per start-year.
fig, ax = plt.subplots(figsize=(10, 5))
for y, g in sfan.groupby("start_year"):
    ax.plot(g["week"], g["agg_gwh"], color="steelblue", alpha=0.15, lw=0.8)
ax.set(title=f"Aggregate storage fan across historical years — {date}",
       xlabel="week", ylabel="stored energy (GWh)")
fig.tight_layout(); fig.savefig(os.path.join(d, "fig_storage_fan.png"), dpi=130)

# 2) Monthly OTA/BEN base price band (p10–p90, p50, mean).
#    The y-axis is capped so the scenario spread stays readable — the dry-year
#    tail runs to ~VOLL ($10k+) and otherwise flattens the whole band to a line.
PRICE_YMAX = 600.0
fig, axes = plt.subplots(1, 2, figsize=(13, 5), sharey=True)
for ax, hub in zip(axes, ("OTA", "BEN")):
    sub = monthly[(monthly["hub"] == hub) & (monthly["product"] == "base")]
    piv = sub.pivot(index="month", columns="distribution", values="price").sort_index()
    x = range(len(piv))
    if {"p10", "p50", "p90"}.issubset(piv.columns):
        ax.fill_between(x, piv["p10"], piv["p90"], color="steelblue", alpha=0.25, label="p10–p90")
        ax.plot(x, piv["p90"], color="steelblue", lw=1.0, alpha=0.8)   # band edges drawn so
        ax.plot(x, piv["p10"], color="steelblue", lw=1.0, alpha=0.8)   # the spread reads clearly
        ax.plot(x, piv["p50"], color="navy", lw=1.8, label="p50")
    if "mean" in piv.columns:
        ax.plot(x, piv["mean"], color="darkorange", lw=1.2, ls="--", label="mean")
    ax.set(title=f"{hub} monthly base price fan", xlabel="month index", ylabel="$/MWh")
    ax.set_ylim(0.0, PRICE_YMAX)
    if "p90" in piv.columns and (piv["p90"] > PRICE_YMAX).any():
        ax.annotate(f"p90 exceeds ${PRICE_YMAX:.0f} in dry-year scarcity months (clipped)",
                    xy=(0.02, 0.97), xycoords="axes fraction", va="top",
                    fontsize=8, color="gray")
    ax.legend(loc="upper right", fontsize=8)
fig.tight_layout(); fig.savefig(os.path.join(d, "fig_price_fan_monthly.png"), dpi=130)

# 3) Calendar-2023 annual base distribution with overlays.
fig, axes = plt.subplots(1, 2, figsize=(12, 5), sharey=True)
for ax, hub in zip(axes, ("OTA", "BEN")):
    vals = cal[cal["hub"] == hub]["annual_base"].values
    if len(vals):
        ax.violinplot([vals], showextrema=True)
    for name, color in (("deterministic", "black"), ("asx_forward", "darkorange"), ("realized", "crimson")):
        v = ov.loc[hub, name]
        if pd.notna(v):
            ax.axhline(v, color=color, lw=2, label=name)
    ax.set(title=f"{hub} calendar-2023 base", xticks=[], ylabel="$/MWh")
    ax.legend()
fig.tight_layout(); fig.savefig(os.path.join(d, "fig_cal2023_annual.png"), dpi=130)

# 4) Per-period (half-hourly) price fan — full ~2-year series, OTA & BEN.
#    Same y-cap as the monthly fan so the spread reads (the dry-year tail spikes
#    to ~VOLL).  Skipped gracefully if the run predates this output.
pfan_path = os.path.join(d, "period_price_fan.csv")
if os.path.exists(pfan_path):
    pfan = pd.read_csv(pfan_path, parse_dates=["datetime"])
    fig, axes = plt.subplots(2, 1, figsize=(14, 8), sharex=True)
    for ax, hub in zip(axes, ("OTA", "BEN")):
        piv = (pfan[pfan["hub"] == hub]
               .pivot(index="datetime", columns="distribution", values="price").sort_index())
        x = piv.index
        if {"p10", "p50", "p90"}.issubset(piv.columns):
            ax.fill_between(x, piv["p10"], piv["p90"], color="steelblue", alpha=0.25, label="p10–p90")
            ax.plot(x, piv["p50"], color="navy", lw=0.5, label="p50")
        ax.set(title=f"{hub} half-hourly price fan", ylabel="$/MWh")
        ax.set_ylim(0.0, PRICE_YMAX)
        if "p90" in piv.columns and (piv["p90"] > PRICE_YMAX).any():
            ax.annotate(f"p90 exceeds ${PRICE_YMAX:.0f} in dry-year scarcity periods (clipped)",
                        xy=(0.01, 0.96), xycoords="axes fraction", va="top",
                        fontsize=8, color="gray")
        ax.legend(loc="upper right", fontsize=8)
    axes[-1].set_xlabel("date")
    fig.tight_layout(); fig.savefig(os.path.join(d, "fig_period_price_fan.png"), dpi=130)

    # 5) Sample-week diurnal view — one representative week (the median-priced
    #    week, so it shows normal peak/off-peak shape, not a scarcity outlier) at
    #    full 30-min resolution.  Autoscaled (no cap) so the diurnal swing reads.
    #    Demand (MW) overlaid in red on a second y-axis, if available.
    snap = pd.Timestamp(date)
    pfan["week_idx"] = ((pfan["datetime"] - snap).dt.days // 7).astype(int)
    ota_p50 = pfan[(pfan["hub"] == "OTA") & (pfan["distribution"] == "p50")]
    wk_mean = ota_p50.groupby("week_idx")["price"].mean().sort_values()
    target = int(wk_mean.index[len(wk_mean) // 2])              # median-priced week

    dem_path = os.path.join(d, "period_demand.csv")
    dem = pd.read_csv(dem_path, parse_dates=["datetime"]) if os.path.exists(dem_path) else None
    if dem is not None:
        dem["week_idx"] = ((dem["datetime"] - snap).dt.days // 7).astype(int)

    fig, axes = plt.subplots(2, 1, figsize=(13, 8), sharex=True)
    for ax, hub in zip(axes, ("OTA", "BEN")):
        piv = (pfan[(pfan["hub"] == hub) & (pfan["week_idx"] == target)]
               .pivot(index="datetime", columns="distribution", values="price").sort_index())
        x = piv.index
        if {"p10", "p50", "p90"}.issubset(piv.columns):
            ax.fill_between(x, piv["p10"], piv["p90"], color="steelblue", alpha=0.25, label="p10–p90")
            ax.plot(x, piv["p50"], color="navy", lw=1.2, label="p50")
        start = x[0].strftime("%Y-%m-%d") if len(x) else "?"
        ax.set(title=f"{hub} half-hourly price — sample week {target} (starting {start})", ylabel="$/MWh")
        ax.legend(loc="upper left", fontsize=8)
        if dem is not None:
            ds = (dem[(dem["hub"] == hub) & (dem["week_idx"] == target)]
                  .set_index("datetime")["demand_mw"].sort_index())
            ax2 = ax.twinx()
            ax2.plot(ds.index, ds.values, color="red", lw=1.0, alpha=0.8, label="demand (MW)")
            ax2.set_ylabel("demand (MW)", color="red")
            ax2.tick_params(axis="y", labelcolor="red")
            ax2.legend(loc="upper right", fontsize=8)
    axes[-1].set_xlabel("date / hour")
    fig.tight_layout(); fig.savefig(os.path.join(d, "fig_period_sample_week.png"), dpi=130)

print(f"Wrote fig_storage_fan.png, fig_price_fan_monthly.png, fig_cal2023_annual.png, "
      f"fig_period_price_fan.png, fig_period_sample_week.png -> {d}")
