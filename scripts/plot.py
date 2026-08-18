import sys, csv
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from datetime import date

csv_path, png_path = sys.argv[1], sys.argv[2]
dates = []
with open(csv_path) as f:
    r = csv.reader(f)
    header = next(r)
    series = {name: [] for name in header[1:]}
    for row in r:
        dates.append(date.fromisoformat(row[0]))
        for name, v in zip(header[1:], row[1:]):
            series[name].append(float(v))
fig, ax = plt.subplots(figsize=(12, 6))
for name, ys in series.items():
    ax.plot(dates, ys, label=name, linewidth=1.5)
ax.set_title("Equity curve (start = 1.0)")
ax.set_ylabel("equity")
ax.legend(loc="upper left")
ax.grid(True, alpha=0.4)
fig.autofmt_xdate()
fig.savefig(png_path, dpi=100, bbox_inches="tight")
