# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "matplotlib"]
# ///
"""Learning curve of a tools/rl run, read from runs/<run>/progress.csv (train.py).

    uv run --python 3.12 tools/rl/plot_training.py <run> [out.png] [--until <steps>]

A resumed run (--resume in its args.json) continues its parent's curve and clock from the
checkpoint it resumed, so gen2 plots as gen1 up to 6M and gen2 after. cut_film.py draws the
video's animated chart with the same functions.
"""
import argparse
import csv
import json
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
RUNS = HERE / "runs"
FONTS = HERE.parents[1] / "assets/fonts"
CREAM, INK, PINK, MINT, GRID = "#f6f1e8", "#2a2433", "#e8517c", "#3fb489", "#ddd5c8"
SMOOTH = 9  # rollouts in the moving average
## train.py averages the last 400 episodes; a resumed run starts that window empty, so its first
## rows average only the few (short) attempts that end first. They are left out until it is full.
RESUME_WARMUP_EPISODES = 400


def curve(run: str) -> dict[str, np.ndarray]:
	"""Steps, training seconds, metres per episode and off-road share of `run`, parents first."""
	d = RUNS / run
	with open(d / "progress.csv", newline="") as f:
		rows = list(csv.DictReader(f))
	c = {
		"steps": np.array([float(r["steps"]) for r in rows]),
		"wall": np.array([float(r["wall_s"]) for r in rows]),
		"metres": np.array([float(r["mean_m"]) for r in rows]),
		"off": np.array([float(r.get("off_road") or 0.0) for r in rows]),
		"episodes": np.array([float(r["episodes"]) for r in rows]),
	}
	args = json.loads((d / "args.json").read_text()) if (d / "args.json").exists() else {}
	resume = args.get("resume") or "None"
	if resume != "None":
		ckpt = Path(resume)
		at = float(ckpt.stem.split("_")[-1])
		p = curve(ckpt.parent.parent.name)
		keep = p["steps"] <= at
		warm = c["episodes"] >= RESUME_WARMUP_EPISODES
		wall0 = float(np.interp(at, p["steps"], p["wall"]))
		c = {k: np.concatenate([p[k][keep], c[k][warm] + (wall0 if k == "wall" else 0.0)]) for k in c}
	return c


def train_seconds(run: str, steps: float) -> float | None:
	"""Training time of `run` (parents included) when it reached `steps`; None without its log."""
	if not (RUNS / run / "progress.csv").exists():
		return None
	c = curve(run)
	return float(np.interp(steps, c["steps"], c["wall"], left=0.0))


def smoothed(y: np.ndarray, n: int = SMOOTH) -> np.ndarray:
	pad = np.pad(y, (n // 2, n - 1 - n // 2), mode="edge")
	return np.convolve(pad, np.ones(n) / n, mode="valid")


def minutes(s: float) -> str:
	return f"{s / 60:.0f} min" if s < 5400 else f"{s / 3600:.1f} h"


class Chart:
	"""The learning curve, 1920x1080 in the game's colours; reveal(f) draws the first f of it."""

	def __init__(self, run: str, until: float, marks: list[tuple[float, str]]):
		import matplotlib
		matplotlib.use("Agg")
		import matplotlib.pyplot as plt
		from matplotlib import font_manager

		self.plt = plt
		for f in ("DelaGothicOne-Regular.ttf", "ZenMaruGothic-Bold.ttf"):
			font_manager.fontManager.addfont(str(FONTS / f))
		title = font_manager.FontProperties(fname=FONTS / "DelaGothicOne-Regular.ttf")
		body = font_manager.FontProperties(fname=FONTS / "ZenMaruGothic-Bold.ttf")
		c = curve(run)
		keep = c["steps"] <= until
		self.x = c["steps"][keep] / 1e6
		self.y = smoothed(c["metres"][keep])
		self.until = until / 1e6
		fig = plt.figure(figsize=(19.2, 10.8), dpi=100, facecolor=CREAM)
		ax = fig.add_axes((0.08, 0.14, 0.86, 0.62), facecolor=CREAM)
		fig.text(0.08, 0.89, "How far it gets before it crashes", fontproperties=title, fontsize=40, color=INK)
		fig.text(0.08, 0.83, "metres per attempt while it trains · an attempt ends at a crash or after 90 s",
				fontproperties=body, fontsize=21, color=INK, alpha=0.75)
		ax.set_xlim(0.0, self.until * 1.02)
		ax.set_ylim(0.0, 3000.0)
		ticks = np.arange(0.0, self.until + 1e-6, 1.0)
		ax.set_xticks(ticks)
		ax.set_xticklabels([("0" if t == 0 else f"{t:.0f}M") + f"\n{minutes(train_seconds(run, t * 1e6) or 0)}"
				for t in ticks], fontproperties=body, fontsize=18, color=INK)
		ax.set_yticks([0, 1000, 2000, 3000])
		ax.set_yticklabels(["0", "1 km", "2 km", "3 km"], fontproperties=body, fontsize=18, color=INK)
		ax.set_xlabel("training steps · time on a laptop", fontproperties=body, fontsize=19, color=INK, labelpad=14)
		for side in ("top", "right"):
			ax.spines[side].set_visible(False)
		for side in ("left", "bottom"):
			ax.spines[side].set_color(INK)
			ax.spines[side].set_linewidth(2)
		ax.tick_params(colors=INK, width=2, length=7)
		ax.grid(axis="y", color=GRID, linewidth=1.5)
		ax.set_axisbelow(True)
		(self.line,) = ax.plot([], [], color=PINK, linewidth=6, solid_capstyle="round")
		self.marks = []
		for steps, label in marks:
			mx = steps / 1e6
			my = float(np.interp(mx, self.x, self.y))
			dot = ax.scatter([mx], [my], s=260, color=MINT, edgecolors=INK, linewidths=2.5, zorder=5)
			# gen 1 and gen 2 sit together in the steep start: labels right of the curve, each tied
			# to its dot by a short line
			if mx < 0.5:
				text = ax.annotate(label, (mx, my), xytext=(48, 6) if mx < 0.05 else (31, 10),
						textcoords="offset points", ha="left", va="center", fontproperties=body, fontsize=21,
						color=INK, zorder=6, arrowprops=dict(arrowstyle="-", color=INK, lw=1.5, shrinkA=4, shrinkB=11))
			else:
				text = ax.annotate(label, (mx, my), xytext=(0, 26), textcoords="offset points", ha="center",
						va="bottom", fontproperties=body, fontsize=21, color=INK, zorder=6)
			self.marks.append((mx, dot, text))
		self.fig = fig

	def reveal(self, f: float) -> None:
		end = self.until * f
		n = int(np.searchsorted(self.x, end, side="right"))
		self.line.set_data(self.x[:n], self.y[:n])
		for mx, dot, text in self.marks:
			dot.set_visible(mx <= end + 1e-9)
			text.set_visible(mx <= end + 1e-9)

	def save(self, path: Path) -> None:
		self.fig.savefig(path, facecolor=CREAM)


def main() -> None:
	p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
	p.add_argument("run")
	p.add_argument("out", nargs="?", type=Path)
	p.add_argument("--until", type=float, help="last step to plot (default: the whole run)")
	args = p.parse_args()
	until = args.until or float(curve(args.run)["steps"][-1])
	chart = Chart(args.run, until, [])
	chart.reveal(1.0)
	out = args.out or RUNS / args.run / "curve.png"
	chart.save(out)
	print(out)


if __name__ == "__main__":
	main()
