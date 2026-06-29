"""Optional plot of FCF curves. Needs Python + matplotlib (NOT required to get the FCF).
Usage: python scripts/plot_fcf.py <fcf_curves.csv> [out.png]"""
import csv, sys, collections, matplotlib.pyplot as plt
src = sys.argv[1]
out = sys.argv[2] if len(sys.argv) > 2 else src.rsplit(".", 1)[0] + ".png"
with open(src, encoding="utf-8") as f:
    rows = list(csv.DictReader(f))
hasw = "week" in rows[0]
data = collections.defaultdict(lambda: collections.defaultdict(lambda: ([], [])))
for r in rows:
    w = int(r["week"]) if hasw else 1
    data[r["reservoir"]][w][0].append(float(r["storage_gwh"]))
    data[r["reservoir"]][w][1].append(float(r["water_value"]))
res = sorted(data); ncol = 4; nrow = (len(res) + ncol - 1) // ncol
fig, ax = plt.subplots(nrow, ncol, figsize=(4 * ncol, 3.2 * nrow), squeeze=False)
cmap = plt.get_cmap("viridis")
for i, r in enumerate(res):
    a = ax[i // ncol][i % ncol]; weeks = sorted(data[r])
    for j, w in enumerate(weeks):
        sg, wv = data[r][w]
        a.plot(sg, wv, "-o", ms=3, color=cmap(j / max(1, len(weeks) - 1)), label=f"wk {w}")
    a.set_title(r, fontsize=10); a.set_xlabel("storage (GWh)", fontsize=8)
    a.set_ylabel("water value $/MWh", fontsize=8); a.grid(alpha=0.2)
    if len(weeks) > 1: a.legend(fontsize=7)
for i in range(len(res), nrow * ncol): ax[i // ncol][i % ncol].axis("off")
fig.suptitle("FCF: per-reservoir water value vs own storage", fontsize=12)
fig.tight_layout(rect=(0, 0, 1, 0.96)); fig.savefig(out, dpi=130)
print("wrote", out)
