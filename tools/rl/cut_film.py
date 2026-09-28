# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "pillow", "soundfile", "scipy"]
# ///
"""Cuts "How the AI learned to drive", the narrated vertical video (1080x1920, 60 fps), from
film.gd's footage and narrate.py's voices (render_film.sh runs it).

    uv run --python 3.12 tools/rl/cut_film.py <out_dir> [voice ...]            # rl_explainer_<voice>.mp4
    uv run --python 3.12 tools/rl/cut_film.py <out_dir> [voice ...] --preview  # stills of the look only
    uv run --python 3.12 tools/rl/cut_film.py practice <swarm_dir>             # <swarm_dir>/practice.json

Reads <out_dir>/tall/raw.avi (remuxed once to raw.mkv) and cues.json (film.gd),
<out_dir>/voice/<voice>/edit.json and its lines (narrate.py) and tools/rl/film.json (the
script: each shot's chip and counter, each line's `show` beats, timed to the word they name).
Per voice (all in film.json unless named), to $EXPORT (default <out_dir>): the shots end to end at
that voice's lengths, the narration on its times over the drive theme (ducked under the voice),
normalised to -14 LUFS through a -1 dBFS limiter, and drawn over the footage per frame (PIL,
piped to ffmpeg as RGBA): every word captioned as it is spoken; a shot's practice chip and how
many of its cars got round or finished; the 46 numbers the network gets, from the chased car ten
times a second; the network itself on those numbers (the shipped driver's weights, the untrained
generation's for "guessing"); the score rules; the odds and the learning loop; the learning curve
(runs/gen1/progress.csv); the end card. Then a contact sheet, and how far the footage moves from
frame to frame inside each shot. --preview writes only stills of the look (a frame of each shot
and of each beat with everything drawn over it) to <out_dir>/review_<voice>/.
`practice` writes each recorded generation's training time (plot_training.train_seconds, parent
runs included) with the caption film.gd shows for it.
"""
import json
import os
import re
import subprocess
import sys
from functools import lru_cache
from pathlib import Path

import numpy as np
import soundfile as sf
from PIL import Image, ImageDraw, ImageFont
from scipy.signal import resample_poly

sys.path.insert(0, str(Path(__file__).resolve().parent))
import plot_training  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "tools/rl/film.json"
FONTS = ROOT / "assets/fonts"
MUSIC = ROOT / "assets/audio/music/drive.ogg"
# the networks drawn: the shipped driver, and the first generation (no practice)
TRAINED = ROOT / "assets/ai/driver.json"
UNTRAINED = ROOT / "assets/ai/generations/01_0.json"
W, H, FPS, SR = 1080, 1920, 60, 48000
TAIL_FRAMES = 15  # film.gd renders every shot 0.25 s past its length
MUSIC_BEAT0 = 0.054
VOICE_LUFS, MUSIC_LUFS, DUCK_DB, TARGET_LUFS = -16.0, -25.0, -9.0, -14.0
JOLT_PX = 40.0
DECISION_FRAMES = 6  # the network decides ten times a second: every 6th frame
CREAM, INK, PINK, MINT = (246, 241, 232), (42, 36, 51), (232, 81, 124), (63, 180, 137)
ORANGE, YELLOW, BLUE = (240, 146, 48), (255, 224, 102), (86, 140, 214)
TITLE, BODY, BOLD, SEMI = "DelaGothicOne-Regular.ttf", "ZenMaruGothic-Medium.ttf", "ZenMaruGothic-Black.ttf", \
		"ZenMaruGothic-Bold.ttf"
# The 46 numbers (DriveSense.observe): name, first, end, colour, label, what they tell it.
GROUPS = [("rays", 0, 9, PINK, "9 rays", "how far to the edge of the road, in 9 directions"),
		("points", 9, 37, MINT, "14 points", "where the road goes, from 5 to 220 m ahead"),
		("body", 37, 46, ORANGE, "the car", "speed, slide, spin, and what it's pressing")]
# The moves (DriveHands.ACTION_DIMS): each group's name and its options' labels.
MOVES = [("steer", ["L", "", "", "", "", "", "R"]), ("pedals", ["brake", "coast", "gas"]),
		("handbrake", ["off", "on"])]
# The Shorts frame: cards start under its header, captions sit above its caption and buttons.
LEFT, TOP, CAPTION_Y, CAPTION_W = 60, 180, 1250, 860
SS = 2  # graphics are drawn at twice the size and scaled down (PIL draws shapes without AA)


@lru_cache(maxsize=None)
def font(name: str, size: int) -> ImageFont.FreeTypeFont:
	return ImageFont.truetype(str(FONTS / name), size)


def run(cmd: list[str]) -> subprocess.CompletedProcess:
	p = subprocess.run(cmd, capture_output=True, text=True)
	if p.returncode != 0:
		sys.exit(f"{cmd[0]} failed:\n{p.stderr[-3000:]}")
	return p


def smooth01(x: float) -> float:
	x = min(max(x, 0.0), 1.0)
	return x * x * (3.0 - 2.0 * x)


def tint(c: tuple, a: float) -> tuple:
	"""`c` at `a` over the cream of a card, opaque (drawing on RGBA replaces, it does not blend)."""
	return tuple(round(CREAM[i] + (c[i] - CREAM[i]) * a) for i in range(3)) + (255,)


def norm(w: str) -> str:
	return re.sub(r"[^a-z0-9]", "", w.lower())


# ---------------------------------------------------------------- practice captions

def age_label(steps: int, run_name: str) -> str:
	"""Training time behind a generation, from its run's progress.csv."""
	if steps <= 0:
		return "no practice"
	s = plot_training.train_seconds(run_name, steps)
	if s is None:
		return f"{steps / 1e6:.0f}M steps" if steps >= 1e6 else f"{steps / 1e3:.0f}k steps"
	if s >= 5400:
		return f"{s / 3600:.1f} hours of practice"
	m = round(s / 60)
	return f"{m} minute{'' if m == 1 else 's'} of practice"


def practice(swarm: Path) -> None:
	"""<swarm>/practice.json: {policy: {steps, run, seconds, label}} for every recorded generation."""
	out = {}
	for path in sorted(swarm.glob("*/*/runs.json")):
		info = json.loads(path.read_text())
		steps, run_name = int(info.get("steps", 0)), str(info.get("run", ""))
		seconds = plot_training.train_seconds(run_name, steps) if steps > 0 else 0.0
		out[info["policy"]] = {"steps": steps, "run": run_name, "seconds": seconds, "label": age_label(steps, run_name)}
	(swarm / "practice.json").write_text(json.dumps(out, indent=2))
	print(swarm / "practice.json")


# ---------------------------------------------------------------- drawing

class Pen:
	"""ImageDraw on a transparent image SS times the size, coordinates in output px; image()
	scales it down (premultiplied, so edges stay clean)."""

	def __init__(self, w: int, h: int, base: Image.Image | None = None):
		self.img = base.copy() if base is not None else Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))
		self.d = ImageDraw.Draw(self.img)

	def rrect(self, box, r, fill) -> None:
		self.d.rounded_rectangle([v * SS for v in box], r * SS, fill=fill)

	def line(self, pts, fill, width: float) -> None:
		self.d.line([v * SS for v in pts], fill=fill, width=max(round(width * SS), 1))

	def dot(self, x: float, y: float, r: float, fill, outline=None, width: float = 0) -> None:
		self.d.ellipse([(x - r) * SS, (y - r) * SS, (x + r) * SS, (y + r) * SS], fill=fill, outline=outline,
				width=round(width * SS))

	def poly(self, pts, fill) -> None:
		self.d.polygon([v * SS for v in pts], fill=fill)

	def arc(self, box, start: float, end: float, fill, width: float) -> None:
		self.d.arc([v * SS for v in box], start, end, fill=fill, width=round(width * SS))

	def text(self, xy, s: str, face: str, size: int, fill, anchor: str = "ls", stroke: int = 0, stroke_fill=None) -> None:
		self.d.text((xy[0] * SS, xy[1] * SS), s, font=font(face, size * SS), fill=fill, anchor=anchor,
				stroke_width=stroke * SS, stroke_fill=stroke_fill)

	def width(self, s: str, face: str, size: int) -> float:
		return self.d.textlength(s, font=font(face, size * SS)) / SS

	def card(self, w: float, h: float, x: float = 0, y: float = 0, r: float = 36) -> None:
		self.rrect((x + 8, y + 10, x + w + 8, y + h + 10), r, INK + (70,))
		self.rrect((x, y, x + w, y + h), r, CREAM + (244,))

	def image(self) -> Image.Image:
		return self.img.resize((self.img.width // SS, self.img.height // SS), Image.LANCZOS)


def pill(parts: list[tuple], fill=CREAM, pad_x: int = 34, pad_y: int = 18) -> Image.Image:
	"""A rounded label: `parts` of (text, face, size, colour) on one baseline."""
	probe = Pen(1, 1)
	widths = [probe.width(t, f, s) for t, f, s, _ in parts]
	asc = max(font(f, s).getmetrics()[0] for _, f, s, _ in parts)
	desc = max(font(f, s).getmetrics()[1] for _, f, s, _ in parts)
	w, h = round(sum(widths) + 2 * pad_x), round(asc + desc + 2 * pad_y)
	pen = Pen(w + 10, h + 12)
	pen.rrect((6, 8, w + 6, h + 8), h / 2, INK + (70,))
	pen.rrect((0, 0, w, h), h / 2, fill + (246,))
	x = pad_x
	for (t, f, s, c), tw in zip(parts, widths):
		pen.text((x, pad_y + asc), t, f, s, c)
		x += tw
	return pen.image()


class Captions:
	"""The narration as captions: each line in chunks of at most two balanced rows, shown from the
	chunk's first word, the word being spoken in yellow."""
	SIZE, STROKE, LEAD = 76, 11, 1.2
	MAX_WORDS = 7

	def __init__(self, lines: list[dict]):
		self.probe = Pen(1, 1)
		self.space = self.probe.width(" ", BOLD, self.SIZE)
		self.chunks: list[dict] = []
		for ln in lines:
			for words in self._split(ln["words"]):
				self.chunks.append({"words": words, "rows": self._rows(words)})
		for k, ch in enumerate(self.chunks):
			nxt = self.chunks[k + 1]["words"][0]["t0"] if k + 1 < len(self.chunks) else 1e9
			ch["t0"] = ch["words"][0]["t0"] - 0.05
			ch["t1"] = min(nxt - 0.05, ch["words"][-1]["t1"] + 0.6)
		self.cache: dict = {}

	def _width(self, words: list[dict]) -> float:
		return sum(self.probe.width(w["w"], BOLD, self.SIZE) for w in words) + self.space * (len(words) - 1)

	# a break after one of these leaves it hanging at the end of a row or chunk
	CLINGY = {"a", "an", "the", "of", "to", "in", "on", "its", "it", "my", "and", "or", "into", "for", "is",
			"how", "at", "no"}

	def _break_cost(self, words: list[dict], k: int) -> float:
		"""What breaking before words[k] costs, over how uneven the two sides are (px)."""
		cost = abs(self._width(words[:k]) - self._width(words[k:]))
		last = words[k - 1]["w"]
		if last[-1] in ",.:;?!":
			cost -= 400.0
		if norm(last) in self.CLINGY:
			cost += 500.0
		if k == len(words) - 1 or k == 1:
			cost += 300.0  # a lone word on a row
		return cost

	def _rows(self, words: list[dict]) -> list[list[int]] | None:
		"""One row, or the cheapest break into two rows; None when two rows cannot hold them."""
		idx = list(range(len(words)))
		if self._width(words) <= CAPTION_W:
			return [idx]
		ok = [k for k in range(1, len(words))
				if self._width(words[:k]) <= CAPTION_W and self._width(words[k:]) <= CAPTION_W]
		if not ok:
			return None
		cut = min(ok, key=lambda k: self._break_cost(words, k))
		return [idx[:cut], idx[cut:]]

	def _fits(self, words: list[dict]) -> bool:
		return len(words) <= self.MAX_WORDS and self._rows(words) is not None

	def _split(self, words: list[dict]) -> list[list[dict]]:
		"""Phrases (cut after every punctuation mark), a phrase too long for a chunk cut at its
		cheapest break until it fits; then phrases joined while they fit, never across the end of a
		sentence or a colon."""
		phrases, cur = [], []
		for w in words:
			cur.append(w)
			if w["w"][-1] in ",.:;?!":
				phrases.append(cur)
				cur = []
		if cur:
			phrases.append(cur)
		pieces: list[list[dict]] = []
		todo = phrases[::-1]
		while todo:
			p = todo.pop()
			if self._fits(p) or len(p) == 1:
				pieces.append(p)
			else:
				k = min(range(1, len(p)), key=lambda k: self._break_cost(p, k))
				todo += [p[k:], p[:k]]
		out: list[list[dict]] = []
		for p in pieces:
			if out and out[-1][-1]["w"][-1] not in ".?!:" and self._fits(out[-1] + p):
				out[-1] = out[-1] + p
			else:
				out.append(p)
		return out

	def at(self, t: float):
		"""(key, image, x, y) of the caption at `t`, or None."""
		for k, ch in enumerate(self.chunks):
			if ch["t0"] <= t < ch["t1"]:
				words = ch["words"]
				active = -1
				for i, w in enumerate(words):
					end = words[i + 1]["t0"] if i + 1 < len(words) else w["t1"] + 0.15
					if w["t0"] <= t < end:
						active = i
				img = self._image(k, active)
				return ("cap", k, active), img, 0, CAPTION_Y - img.height // 2
		return None

	def _image(self, k: int, active: int) -> Image.Image:
		if (k, active) in self.cache:
			return self.cache[(k, active)]
		ch = self.chunks[k]
		lh = self.SIZE * self.LEAD
		asc = font(BOLD, self.SIZE).getmetrics()[0]
		h = round(len(ch["rows"]) * lh + 2 * self.STROKE + 16)
		pen = Pen(W, h)
		for r, row in enumerate(ch["rows"]):
			ws = [ch["words"][i]["w"] for i in row]
			widths = [pen.width(w, BOLD, self.SIZE) for w in ws]
			x = (W - sum(widths) - self.space * (len(ws) - 1)) / 2
			y = self.STROKE + 8 + r * lh + asc
			for i, w, ww in zip(row, ws, widths):
				pen.text((x, y), w, BOLD, self.SIZE, YELLOW if i == active else CREAM, stroke=self.STROKE,
						stroke_fill=INK)
				x += ww + self.space
		img = pen.image()
		self.cache[(k, active)] = img
		return img


class Net:
	"""A DrivePolicy file in numpy: tanh layers, then the logits of each group of moves."""

	def __init__(self, path: Path):
		d = json.loads(path.read_text())
		self.layers = [(np.array(l["w"], np.float32).reshape(l["out"], l["in"]), np.array(l["b"], np.float32))
				for l in d["layers"]]
		h = d["head"]
		self.head = (np.array(h["w"], np.float32).reshape(h["out"], h["in"]), np.array(h["b"], np.float32))
		self.dims = [int(n) for n in d["action_dims"]]
		meta = d.get("meta", {})
		if "test_obs" in meta:
			z = self.logits(np.array([meta["test_obs"]], np.float32))[0]
			err = float(np.abs(z - np.array(meta["test_logits"], np.float32)).max())
			if err > 1e-3:
				sys.exit(f"cut_film: {path} does not reproduce its test logits (error {err})")

	def logits(self, x: np.ndarray) -> np.ndarray:
		for w, b in self.layers:
			x = np.tanh(x @ w.T + b)
		return x @ self.head[0].T + self.head[1]

	def run(self, x: np.ndarray) -> tuple[list[np.ndarray], list[np.ndarray]]:
		"""Each hidden layer's activations and each move group's odds, per row of `x`."""
		hidden = []
		for w, b in self.layers:
			x = np.tanh(x @ w.T + b)
			hidden.append(x)
		z = x @ self.head[0].T + self.head[1]
		odds, k = [], 0
		for n in self.dims:
			g = z[:, k:k + n]
			e = np.exp(g - g.max(axis=1, keepdims=True))
			odds.append(e / e.sum(axis=1, keepdims=True))
			k += n
		return hidden, odds


# ---------------------------------------------------------------- the edit

def beats(script: dict, edit: dict) -> dict[str, list[tuple[float, object]]]:
	"""Each `show` beat of the script at the time its word is spoken: {key: [(t, value)]}."""
	out: dict[str, list] = {}
	for line, laid in zip(script["lines"], edit["lines"]):
		for item in line.get("show", []):
			at = norm(item["at"])
			hit = next((w for w in laid["words"] if norm(w["w"]) == at), None)
			if hit is None:
				sys.exit(f"cut_film: no word {item['at']!r} in {line['say']!r}")
			key = next(k for k in item if k != "at")
			out.setdefault(key, []).append((hit["t0"], item[key]))
	for v in out.values():
		v.sort(key=lambda b: b[0])
	return out


class Film:
	"""One voice's edit: its shots over the footage and everything drawn over them."""

	def __init__(self, script: dict, edit: dict, cues: list[dict]):
		self.cue = {c["name"]: c for c in cues}
		self.beats = beats(script, edit)
		self.length = edit["length"]
		self.frames = round(self.length * FPS)
		self.shots = []
		for s in edit["shots"]:
			tag = s["tag"]
			if tag not in self.cue:
				sys.exit(f"cut_film: the footage has no shot {tag!r} (render film.gd again)")
			f0, f1 = round(s["t0"] * FPS), round(s["t1"] * FPS)
			have = int(self.cue[tag]["frames"]) + TAIL_FRAMES
			if f1 - f0 > have:
				sys.exit(f"cut_film: shot {tag} needs {f1 - f0} frames, the footage has {have} (render film.gd again "
						f"with this voice's lengths)")
			self.shots.append({"tag": tag, "t0": s["t0"], "t1": s["t1"], "f0": f0, "f1": f1,
					"src": round(self.cue[tag]["t"] * FPS), "spec": script["shots"].get(tag, {}),
					"cue": self.cue[tag], "end": self.cue.get(tag + "_end", {})})
		self.captions = Captions(edit["lines"])
		self.cache: dict = {}
		self._faded: dict = {}
		self._nets()
		self._numbers()

	# -- data

	def _numbers(self) -> None:
		obs = self.cue.get("sees_end", {}).get("obs")
		self.sense = np.array(obs, np.float32)[::DECISION_FRAMES] if obs else None

	def _nets(self) -> None:
		obs = self.cue.get("brain_end", {}).get("obs")
		self.net = {}
		if not obs:
			return
		rows = np.array(obs, np.float32)[::DECISION_FRAMES]
		dice = np.random.default_rng(7)
		for mode, path in (("trained", TRAINED), ("untrained", UNTRAINED)):
			net = Net(path)
			hidden, odds = net.run(rows)
			shown = [np.sort(np.argsort(-h.std(axis=0))[:16]) for h in hidden]
			if mode == "trained":
				picks = [o.argmax(axis=1) for o in odds]
			else:  # guessing: it plays its odds
				picks = [np.array([dice.choice(len(p), p=p / p.sum()) for p in o]) for o in odds]
			self.net[mode] = {"net": net, "rows": rows, "hidden": hidden, "odds": odds, "shown": shown, "picks": picks}

	def beat(self, key: str, t: float, lo: float = -1e9):
		"""(time, value) of the last `key` beat at or before `t` (and after `lo`), else None."""
		hit = None
		for bt, v in self.beats.get(key, []):
			if lo <= bt <= t:
				hit = (bt, v)
		return hit

	def first(self, key: str) -> float:
		b = self.beats.get(key)
		return b[0][0] if b else 1e9

	def shot_at(self, t: float) -> dict:
		for s in self.shots:
			if s["t0"] <= t < s["t1"]:
				return s
		return self.shots[-1]

	# -- what is drawn at time t

	def items(self, t: float, i: int) -> list[tuple]:
		"""(key, image, x, y, alpha) of everything over frame `i` (edit time `t`), bottom first."""
		out = []
		s = self.shot_at(t)
		spec = s["spec"]
		ending = self.first("end")
		if t >= ending:
			a = smooth01((t - ending) / 0.5)
			out.append((("veil",), self._veil(), 0, 0, a))
			img = self._end_card()
			out.append((("end",), img, (W - img.width) // 2, 470 + round((1 - a) * 30), a))
		else:
			y = TOP
			if "title" in spec:
				img = self._title(spec["title"])
				out.append(self._pop(("title", s["tag"]), img, (W - img.width) // 2, y, t - s["t0"]))
				y += img.height + 10
			if "chip" in spec:
				text = s["cue"].get("practice", "") if spec["chip"] == "practice" else spec["chip"]
				img = self._chip(text)
				out.append(self._pop(("chip", s["tag"]), img, (W - img.width) // 2, y, t - s["t0"] - 0.1))
				y += img.height + 12
			if "count" in spec:
				img = self._count(s, spec["count"])
				out.append(self._pop(("count", s["tag"]), img, (W - img.width) // 2, y, t - s["t0"] - 0.7))
			out += self._panels(s, t, i)
		cap = self.captions.at(t)
		if cap is not None:
			key, img, x, y = cap
			out.append((key, img, x, y, 1.0))
		return out

	def _pop(self, key, img, x, y, age: float) -> tuple:
		a = smooth01(age / 0.25)
		return key, img, x, y - round((1 - a) * 24), a

	def _panels(self, s: dict, t: float, i: int) -> list[tuple]:
		out = []
		fi = i - s["f0"]
		tag = s["tag"]
		if tag == "sees" and self.sense is not None:
			b = self.beat("numbers", t, s["t0"])
			if b:
				r = min(fi // DECISION_FRAMES, len(self.sense) - 1)
				out.append(self._pop(("num", r, b[1]), self._numbers_panel(r, b[1]), LEFT, TOP, t - self.first("numbers")))
			else:  # before the numbers: what the screen is not
				img = self._cached(("noscreen",), lambda: pill([("It never sees the screen", BOLD, 50, INK)]))
				out.append(self._pop(("noscreen",), img, (W - img.width) // 2, TOP, t - s["t0"] - 1.2))
		elif tag == "brain" and self.net:
			b = self.beat("net", t, s["t0"])
			if b:
				r = min(fi // DECISION_FRAMES, len(self.net[b[1]]["rows"]) - 1)
				out.append(self._pop(("net", r, b[1]), self._net_panel(r, b[1]), LEFT, TOP, t - self.first("net")))
		elif tag == "score":
			y = TOP
			for which, parts in (("plus", [("+1", TITLE, 60, MINT), ("   every 20 m of road", BOLD, 46, INK)]),
					("minus", [("-3", TITLE, 60, PINK), ("   crash or off the road", BOLD, 46, INK)])):
				b = next((bt for bt, v in self.beats.get("rule", []) if v == which), None)
				if b is not None and s["t0"] <= b <= t:
					img = self._cached(("rule", which), lambda p=parts: pill(p))
					out.append(self._pop(("rule", which), img, (W - img.width) // 2, y, t - b))
				y += 124
		elif tag == "loop":
			c0 = self.first("cycle")
			ob = self.beat("odds", t, s["t0"])
			if ob and t < c0:
				p = round(smooth01((t - ob[0] - 0.8) / 2.5) * 40) / 40
				out.append(self._pop(("odds", p), self._odds_card(p), LEFT, TOP, t - ob[0]))
			if t >= c0:
				active = max((v for bt, v in self.beats["cycle"] if bt <= t and isinstance(v, int)), default=0)
				named = any(v == "named" and bt <= t for bt, v in self.beats["cycle"])
				out.append(self._pop(("cycle", active, named), self._cycle_card(active, named), LEFT, TOP, t - c0))
		elif tag == "scale":
			cb = self.beat("curve", t, s["t0"])
			if cb:
				c0 = self.first("curve")
				img = self._cached(("carsnote",), lambda: pill([("64", TITLE, 56, PINK),
						(" cars at once, on one Mac", BOLD, 46, INK)]))
				out.append(self._pop(("carsnote",), img, (W - img.width) // 2, TOP, t - c0))
				p = round(smooth01((t - c0 - 0.3) / 1.6) * 60) / 60
				week = any(v == "week" and bt <= t for bt, v in self.beats["curve"])
				out.append(self._pop(("curve", p, week), self._curve_card(p, week), LEFT, TOP + img.height + 14, t - c0))
		return out

	# -- the pieces (cached)

	def _cached(self, key, make):
		if key not in self.cache:
			self.cache[key] = make()
		return self.cache[key]

	def faded(self, key, img: Image.Image, a: float) -> Image.Image:
		q = round(a * 32)
		if q >= 32:
			return img
		fk = (key, q)
		if fk not in self._faded:
			if len(self._faded) > 400:
				self._faded.clear()
			r, g, b, al = img.split()
			self._faded[fk] = Image.merge("RGBA", (r, g, b, al.point(lambda v: v * q // 32)))
		return self._faded[fk]

	def _title(self, text: str) -> Image.Image:
		def make():
			size, stroke = 96, 14
			probe = Pen(1, 1)
			words, rows, row = text.split(), [], ""
			for w in words:
				trial = f"{row} {w}".strip()
				if row and probe.width(trial, TITLE, size) > 900:
					rows.append(row)
					row = w
				else:
					row = trial
			rows.append(row)
			lh = round(size * 1.22)
			pen = Pen(W, lh * len(rows) + 2 * stroke + 10)
			asc = font(TITLE, size).getmetrics()[0]
			for k, r in enumerate(rows):
				pen.text((W / 2, stroke + 4 + k * lh + asc), r, TITLE, size, CREAM, anchor="ms", stroke=stroke, stroke_fill=INK)
			return pen.image()
		return self._cached(("title", text), make)

	def _chip(self, text: str) -> Image.Image:
		return self._cached(("chip", text), lambda: pill([(text, BOLD, 50, INK)]))

	def _count(self, s: dict, what: str) -> Image.Image:
		cue, runs = s["cue"], s["end"].get("runs", [])
		if what == "past":  # past the mark while its run lasted (a car off the road slides on)
			n, label = sum(1 for end, done, at in runs if at >= 0 and (at <= end or done)), "made it round"
		else:
			n, label = int(cue["finished"]), "finished"
		return self._cached(("count", s["tag"]), lambda: pill([(str(n), TITLE, 64, PINK),
				(f" of {cue['cars']} {label}", BOLD, 48, INK)]))

	def _veil(self) -> Image.Image:
		return self._cached(("veil",), lambda: Image.new("RGBA", (W, H), CREAM + (135,)))

	def _end_card(self) -> Image.Image:
		def make():
			w, h = 920, 520
			pen = Pen(w + 12, h + 14)
			pen.card(w, h, r=44)
			pen.text((w / 2, 150), "Sakura Rally", TITLE, 104, PINK, anchor="ms")
			pen.text((w / 2, 260), "press I: it drives for you", BOLD, 52, INK, anchor="ms")
			pen.text((w / 2, 340), "press G: race its generations", BOLD, 52, INK, anchor="ms")
			pen.text((w / 2, 440), "github.com/SummerEngine/sakura-rally", SEMI, 38, tint(INK, 0.7), anchor="ms")
			return pen.image()
		return self._cached(("end",), make)

	def _numbers_panel(self, r: int, mode: str) -> Image.Image:
		key = ("num", r, mode)
		if key in self.cache:
			return self.cache[key]
		row = self.sense[r]
		w, h = 960, 500 if mode == "all" else 548
		pen = Pen(w + 12, h + 14)
		pen.card(w, h)
		pen.text((44, 112), "46", TITLE, 88, PINK)
		pen.text((44 + pen.width("46 ", TITLE, 88), 104), "numbers, ten times a second", BOLD, 44, INK)
		x0, span, gap = 44.0, 872.0, 18.0
		pitch = (span - 2 * gap) / 46
		mid, half = 262.0, 96.0

		def bx(k: int) -> float:
			return x0 + k * pitch + (gap if k >= 9 else 0) + (gap if k >= 37 else 0)

		pen.line((x0, mid, x0 + span, mid), tint(INK, 0.25), 2)
		for name, a, b, col, label, desc in GROUPS:
			on = mode in ("all", name)
			c = col + (255,) if on else tint(col, 0.22)
			for k in range(a, b):
				v = float(np.clip(row[k], -1.0, 1.0))
				y0, y1 = sorted((mid, mid - v * half))
				pen.rrect((bx(k) + 1, y0, bx(k) + pitch - 5, max(y1, y0 + 4)), 3, c)
			gx0, gx1 = bx(a) + 1, bx(b - 1) + pitch - 5
			pen.line((gx0, 380, gx1, 380), c, 4)
			pen.text(((gx0 + gx1) / 2, 428), label, BOLD, 36, c, anchor="ms")
			if mode == name:
				pen.text((w / 2, 500), desc, SEMI, 34, col + (255,), anchor="ms")
		img = pen.image()
		self.cache[key] = img
		return img

	def _net_base(self, mode: str) -> Image.Image:
		"""The network's card and connections (between the shown neurons), at SS times the size."""
		key = ("netbase", mode)
		if key in self.cache:
			return self.cache[key]
		d = self.net[mode]
		net, shown = d["net"], d["shown"]
		w, h = 960, 740
		pen = Pen(w + 12, h + 14)
		pen.card(w, h)
		if mode == "trained":
			pen.text((44, 76), "A small neural network", BOLD, 48, INK)
			pen.text((44, 122), "46 numbers in, one move out", SEMI, 32, tint(INK, 0.6))
		else:
			pen.text((44, 76), "Before any practice", BOLD, 48, INK)
			pen.text((44, 122), "the same network, random weights: guessing", SEMI, 32, tint(INK, 0.6))
		lay = self._net_layout()
		w1, w2 = net.layers[0][0], net.layers[1][0]
		for layer, (src, dst, wm) in enumerate(((lay["in"], lay["h1"], w1[shown[0]][:, :]),
				(lay["h1"], lay["h2"], w2[shown[1]][:, shown[0]]))):
			m = float(np.abs(wm).max()) or 1.0
			for j, (xj, yj) in enumerate(dst):
				for k, (xk, yk) in enumerate(src):
					v = float(wm[j, k]) / m
					a = abs(v) ** 1.3 * (0.5 if layer == 0 else 0.8)
					if a > 0.04:
						pen.line((xk, yk, xj, yj), tint(PINK if v > 0 else BLUE, a), 1.0)
		head = net.head[0][:, shown[1]]
		start = 0
		for g, (gname, labels) in enumerate(MOVES):
			n = len(labels)
			hx, hy = lay["out"][g]
			strength = np.abs(head[start:start + n]).max(axis=0)
			m = float(strength.max()) or 1.0
			for k, (xk, yk) in enumerate(lay["h2"]):
				pen.line((xk, yk, hx - 12, hy), tint(INK, 0.1 + 0.3 * float(strength[k]) / m), 1.0)
			start += n
		self.cache[key] = pen.img
		return pen.img

	def _net_layout(self) -> dict:
		ins = [(96.0, 176 + k * (540 / 45)) for k in range(46)]
		h1 = [(330.0, 184 + k * (524 / 15)) for k in range(16)]
		h2 = [(540.0, 184 + k * (524 / 15)) for k in range(16)]
		outs = [(700.0, 250.0), (700.0, 460.0), (700.0, 640.0)]
		return {"in": ins, "h1": h1, "h2": h2, "out": outs}

	def _net_panel(self, r: int, mode: str) -> Image.Image:
		key = ("net", r, mode)
		if key in self.cache:
			return self.cache[key]
		d = self.net[mode]
		lay = self._net_layout()
		pen = Pen(0, 0, self._net_base(mode))
		row = d["rows"][r]
		for name, a, b, col, *_ in GROUPS:
			for k in range(a, b):
				x, y = lay["in"][k]
				pen.dot(x, y, 5, tint(col, 0.25 + 0.75 * min(abs(float(row[k])), 1.0)))
		for layer, pts in ((0, lay["h1"]), (1, lay["h2"])):
			acts = d["hidden"][layer][r][d["shown"][layer]]
			for (x, y), v in zip(pts, acts):
				v = float(v)
				pen.dot(x, y, 12, tint(PINK if v > 0 else BLUE, 0.15 + 0.85 * abs(v)), outline=tint(INK, 0.45), width=1.5)
		for g, (gname, labels) in enumerate(MOVES):
			hx, hy = lay["out"][g]
			odds = d["odds"][g][r]
			pick = int(d["picks"][g][r])
			n = len(labels)
			x0, x1 = 716.0, 924.0
			pitch = (x1 - x0) / n
			pen.text((x0, hy - 58), gname, BOLD, 32, INK)
			base = hy + 44
			for k in range(n):
				bh = 6 + 76 * float(odds[k])
				c = PINK + (255,) if k == pick else tint(INK, 0.35)
				pen.rrect((x0 + k * pitch + 3, base - bh, x0 + (k + 1) * pitch - 3, base), 4, c)
				if labels[k]:
					pen.text((x0 + (k + 0.5) * pitch, base + 30), labels[k], SEMI, 22 if n > 2 else 24,
							tint(INK, 0.75), anchor="ms")
		img = pen.image()
		self.cache[key] = img
		return img

	def _odds_card(self, p: float) -> Image.Image:
		def make():
			w, h = 960, 380
			pen = Pen(w + 12, h + 14)
			pen.card(w, h)
			pen.text((44, 78), "After every round", BOLD, 46, INK)
			for k, (label, col, a0, a1, note) in enumerate((
					("moves that scored more", MINT, 0.34, 0.78, "more likely"),
					("moves that scored less", PINK, 0.34, 0.07, "less likely"))):
				y = 150 + k * 118
				pen.text((44, y), label, SEMI, 36, tint(INK, 0.8))
				fill = a0 + (a1 - a0) * p
				bw = 872 * fill
				pen.rrect((44, y + 22, 44 + max(bw, 14), y + 66), 16, col + (255,))
				if p > 0.05:
					nx = 44 + bw + 18
					if nx + pen.width(note, BOLD, 34) > 916:
						pen.text((44 + bw - 18, y + 56), note, BOLD, 34, CREAM + (255,), anchor="rs")
					else:
						pen.text((nx, y + 56), note, BOLD, 34, col + (255,))
			return pen.image()
		return self._cached(("odds", p), make)

	def _cycle_card(self, active: int, named: bool) -> Image.Image:
		def make():
			w, h = 960, 700 if named else 600
			pen = Pen(w + 12, h + 14)
			pen.card(w, h)
			cx, cy, rx, ry = 480.0, 300.0, 250.0, 200.0
			words = ["TRY", "SCORE", "ADJUST", "REPEAT"]
			spots = [(cx, cy - ry), (cx + rx, cy), (cx, cy + ry), (cx - rx, cy)]
			for k in range(4):  # the arrows between them, clockwise
				a0, a1 = 270 + 90 * k + 26, 270 + 90 * (k + 1) - 26
				pen.arc((cx - rx, cy - ry, cx + rx, cy + ry), a0, a1, tint(INK, 0.45), 5)
				t = np.deg2rad(a1)
				tip = (cx + rx * np.cos(t), cy + ry * np.sin(t))
				tan = np.array([-rx * np.sin(t), ry * np.cos(t)])
				tan /= np.linalg.norm(tan)
				nrm = np.array([-tan[1], tan[0]])
				pts = [tip, tuple(tip - tan * 22 + nrm * 12), tuple(tip - tan * 22 - nrm * 12)]
				pen.poly([v for p in pts for v in p], tint(INK, 0.45))
			for k, (word, (x, y)) in enumerate(zip(words, spots)):
				tw = pen.width(word, BOLD, 46)
				bw, bh = tw + 60, 84
				on = k == active
				pen.rrect((x - bw / 2, y - bh / 2, x + bw / 2, y + bh / 2), bh / 2,
						PINK + (255,) if on else tint(INK, 0.08))
				pen.text((x, y + 16), word, BOLD, 46, CREAM + (255,) if on else tint(INK, 0.55 if k > active else 0.9),
						anchor="ms")
			if named:
				pen.text((cx, 640), "reinforcement learning", TITLE, 56, PINK + (255,), anchor="ms")
			return pen.image()
		return self._cached(("cycle", active, named), make)

	def _curve_card(self, p: float, week: bool) -> Image.Image:
		def make():
			c = self._curve()
			w, h = 960, 640 if week else 540
			pen = Pen(w + 12, h + 14)
			pen.card(w, h)
			pen.text((44, 76), "How far it gets per try", BOLD, 46, INK)
			x0, x1, y0, y1 = 150.0, 900.0, 450.0, 130.0
			top_m, lap = 3000.0, c["lap"]
			for m in (0, 1000, 2000, 3000):
				y = y0 + (y1 - y0) * m / top_m
				pen.line((x0, y, x1, y), tint(INK, 0.12), 2)
				pen.text((x0 - 16, y + 10), f"{m // 1000} km" if m else "0", SEMI, 28, tint(INK, 0.6), anchor="rs")
			ly = y0 + (y1 - y0) * lap / top_m
			for xx in np.arange(x0, x1, 28):
				pen.line((xx, ly, min(xx + 14, x1), ly), MINT + (255,), 3)
			pen.text((x1, ly - 12), "a whole stage", SEMI, 28, MINT + (255,), anchor="rs")
			for m in (0, 20, 40, 60, 80):
				x = x0 + (x1 - x0) * m / c["minutes"][-1]
				pen.text((x, y0 + 40), str(m), SEMI, 28, tint(INK, 0.6), anchor="ms")
			pen.text(((x0 + x1) / 2, y0 + 80), "minutes of practice", SEMI, 30, tint(INK, 0.7), anchor="ms")
			n = max(int(len(c["minutes"]) * p), 2)
			pts = [(x0 + (x1 - x0) * mi / c["minutes"][-1], y0 + (y1 - y0) * min(mm, top_m) / top_m)
					for mi, mm in zip(c["minutes"][:n], c["metres"][:n])]
			pen.line([v for q in pts for v in q], PINK + (255,), 7)
			pen.dot(pts[-1][0], pts[-1][1], 11, PINK + (255,))
			if week:
				pen.text((w / 2, 600), f"{c['decisions']} decisions: {c['days']} days of driving", BOLD, 42,
						INK + (255,), anchor="ms")
			return pen.image()
		return self._cached(("curve", p, week), make)

	def _curve(self) -> dict:
		def make():
			c = plot_training.curve("gen1")
			steps = float(c["steps"][-1])
			days = steps / 10.0 / 86400.0
			return {"minutes": c["wall"] / 60.0, "metres": plot_training.smoothed(c["metres"]), "lap": 2952.0,
					"decisions": f"{steps / 1e6:.0f} million", "days": f"{days:.0f}"}
		return self._cached(("curvedata",), make)

	# -- the frame

	def frame_bytes(self, i: int, last: dict) -> bytes:
		"""Frame i of the drawing, RGBA; the last frame's bytes again when nothing changed."""
		items = self.items(i / FPS, i)
		sig = tuple((k, x, y, round(a * 32)) for k, _, x, y, a in items)
		if sig == last.get("sig"):
			return last["bytes"]
		canvas = Image.new("RGBA", (W, H), (0, 0, 0, 0))
		for k, img, x, y, a in items:
			if a > 0.02:
				canvas.alpha_composite(self.faded(k, img, a), (int(x), int(y)))
		last["sig"], last["bytes"] = sig, canvas.tobytes()
		return last["bytes"]


# ---------------------------------------------------------------- sound

def lufs(path: Path) -> float:
	out = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", str(path), "-af", "ebur128", "-f", "null", "-"],
			capture_output=True, text=True).stderr
	return float(re.findall(r"I:\s+(-?[\d.]+) LUFS", out)[-1])


def at_lufs(a: np.ndarray, target: float, tmp: Path) -> np.ndarray:
	sf.write(tmp, a, SR, subtype="FLOAT")
	return a * np.float32(10 ** ((target - lufs(tmp)) / 20.0))


def resample(a: np.ndarray, sr: int) -> np.ndarray:
	if sr == SR:
		return a
	g = np.gcd(sr, SR)
	return resample_poly(a, SR // g, sr // g, axis=0).astype(np.float32)


def mix(edit: dict, voice_dir: Path, work: Path) -> Path:
	"""The narration on its times at VOICE_LUFS over the drive theme at MUSIC_LUFS, the music
	DUCK_DB lower while the voice speaks, faded out over the last 2.5 s; all at TARGET_LUFS."""
	total = round(edit["length"] * SR)
	voice = np.zeros(total, np.float32)
	speaking = np.zeros(total, np.float32)
	for ln in edit["lines"]:
		a, sr = sf.read(voice_dir / ln["file"], dtype="float32")
		a = resample(a, sr)
		i0 = round(ln["t0"] * SR)
		n = min(len(a), total - i0)
		voice[i0:i0 + n] += a[:n]
		speaking[max(i0 - int(0.12 * SR), 0):min(i0 + n + int(0.3 * SR), total)] = 1.0
	tmp = work / "level.wav"
	voice = at_lufs(voice, VOICE_LUFS, tmp)
	y, msr = sf.read(MUSIC, dtype="float32", always_2d=True)
	y = resample(y, msr)[int(MUSIC_BEAT0 * SR):]
	while len(y) < total:
		y = np.concatenate([y, y])
	music = at_lufs(y[:total].copy(), MUSIC_LUFS, tmp)
	k = int(0.15 * SR)
	env = np.convolve(speaking, np.ones(k, np.float32) / k, mode="same")
	music *= (10 ** (DUCK_DB * env / 20.0)).astype(np.float32)[:, None]
	tail = int(2.5 * SR)
	music[-tail:] *= (np.linspace(1.0, 0.0, tail) ** 2)[:, None].astype(np.float32)
	out = at_lufs(music + voice[:, None], TARGET_LUFS, tmp)
	tmp.unlink()
	path = work / "mix.wav"
	sf.write(path, out, SR, subtype="FLOAT")
	return path


# ---------------------------------------------------------------- output

def remux(src: Path) -> Path:
	footage, avi = src / "raw.mkv", src / "raw.avi"
	if avi.exists():
		# Movie Maker's AVI has no seek index; a stream-copy remux to Matroska indexes it.
		run(["ffmpeg", "-v", "error", "-y", "-i", str(avi), "-map", "0", "-c", "copy", str(footage)])
		avi.unlink()
	if not footage.exists():
		sys.exit(f"cut_film: no footage in {src} (film.gd under render_film.sh)")
	return footage


def cut(film: Film, footage: Path, voice_dir: Path, mp4: Path, work: Path) -> None:
	mixwav = mix(json.loads((voice_dir / "edit.json").read_text()), voice_dir, work)
	cmd = ["ffmpeg", "-v", "error", "-y"]
	graph, labels = [], []
	for k, s in enumerate(film.shots):
		n = s["f1"] - s["f0"]
		start = max(s["src"] / FPS - 0.5, 0.0)
		cmd += ["-ss", f"{start:.6f}", "-t", f"{n / FPS + 1.0:.6f}", "-i", str(footage)]
		graph.append(f"[{k}:v]trim=start={s['src'] / FPS - start:.6f},setpts=PTS-STARTPTS,trim=end_frame={n},"
				f"setpts=PTS-STARTPTS,scale={W}:{H}:in_range=full:in_color_matrix=bt601,format=gbrp,setsar=1[s{k}]")
		labels.append(f"[s{k}]")
	n_in = len(film.shots)
	cmd += ["-f", "rawvideo", "-pix_fmt", "rgba", "-s", f"{W}x{H}", "-framerate", str(FPS), "-i", "pipe:0",
			"-i", str(mixwav)]
	graph.append("".join(labels) + f"concat=n={len(labels)}:v=1:a=0[cat]")
	graph.append(f"[cat][{n_in}:v]overlay=0:0:format=gbrp:eof_action=repeat,"
			"scale=out_range=limited:out_color_matrix=bt709,format=yuv420p,"
			"setparams=range=tv:colorspace=bt709:color_primaries=bt709:color_trc=bt709[v]")
	graph.append(f"[{n_in + 1}:a]alimiter=limit=0.891:attack=4:release=60:level=false,aresample={SR}[a]")
	cmd += ["-filter_complex", ";".join(graph), "-map", "[v]", "-map", "[a]", "-frames:v", str(film.frames),
			"-c:v", "libx264", "-preset", "medium", "-crf", "18", "-profile:v", "high", "-maxrate", "30M",
			"-bufsize", "60M", "-r", str(FPS), "-c:a", "aac", "-b:a", "256k", "-movflags", "+faststart", str(mp4)]
	proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stderr=subprocess.PIPE)
	last: dict = {}
	try:
		for i in range(film.frames):
			proc.stdin.write(film.frame_bytes(i, last))
		proc.stdin.close()
	except BrokenPipeError:
		pass
	err = proc.stderr.read().decode()
	if proc.wait() != 0:
		sys.exit(f"ffmpeg failed:\n{err[-3000:]}")
	print(f"{mp4}: {film.frames / FPS:.1f} s, {len(film.shots)} shots, {mp4.stat().st_size / 1e6:.1f} MB")
	for s in film.shots:
		print(f"  {s['t0']:6.2f}s  {s['t1'] - s['t0']:5.2f}s  {s['tag']}")


def picks(film: Film) -> list[int]:
	"""The frames to look at: 1.2 s into each shot, its middle, and 0.7 s after each beat."""
	out = [min(s["f0"] + round(1.2 * FPS), s["f1"] - 1) for s in film.shots]
	out += [round((s["f0"] + s["f1"]) / 2) for s in film.shots]
	out += [round((bt + 0.7) * FPS) for v in film.beats.values() for bt, _ in v]
	return sorted(set(min(f, film.frames - 1) for f in out))


def sheet(frames: list[Image.Image], path: Path) -> None:
	cols, tw = 6, 300
	th = round(tw * H / W)
	rows = (len(frames) + cols - 1) // cols
	img = Image.new("RGB", (cols * tw, rows * th), INK)
	for i, f in enumerate(frames):
		img.paste(f.convert("RGB").resize((tw, th), Image.LANCZOS), ((i % cols) * tw, (i // cols) * th))
	img.save(path, quality=88)
	print(f"{path}: {len(frames)} frames")


def preview(film: Film, footage: Path, review: Path) -> None:
	"""Stills of the look without encoding: picks() frames of the footage with everything drawn."""
	review.mkdir(parents=True, exist_ok=True)
	for old in review.glob("*.png"):
		old.unlink()
	out = []
	for f in picks(film):
		s = film.shot_at(f / FPS)
		src = s["src"] + f - s["f0"]
		p = subprocess.run(["ffmpeg", "-v", "error", "-ss", f"{src / FPS:.6f}", "-i", str(footage), "-frames:v", "1",
				"-f", "rawvideo", "-pix_fmt", "rgba", "-"], capture_output=True)
		if p.returncode != 0 or len(p.stdout) != W * H * 4:
			sys.exit(f"cut_film: no frame {src} in {footage}: {p.stderr[-500:]!r}")
		base = Image.frombytes("RGBA", (W, H), p.stdout)
		over = Image.frombytes("RGBA", (W, H), film.frame_bytes(f, {}))
		base.alpha_composite(over)
		base.convert("RGB").save(review / f"{f:05d}_{s['tag']}.png")
		out.append(base)
	sheet(out, review / "sheet.jpg")


def review_sheet(mp4: Path, film: Film, path: Path, review: Path) -> None:
	review.mkdir(parents=True, exist_ok=True)
	for old in review.glob("*.png"):
		old.unlink()
	fs = picks(film)
	sel = "+".join(f"eq(n\\,{p})" for p in fs)
	run(["ffmpeg", "-v", "error", "-y", "-i", str(mp4), "-vf", f"select={sel}", "-fps_mode", "passthrough",
			str(review / "%03d.png")])
	sheet([Image.open(p) for p in sorted(review.glob("*.png"))], path)


def motion(footage: Path, film: Film) -> None:
	"""How far the picture moves from one frame to the next inside each shot: the phase
	correlation peak between consecutive frames of the footage (half size, grey, windowed), in px
	of the output frame. Prints each shot's largest move, its 95th percentile and the frames over
	JOLT_PX."""
	hw, hh = W // 2, H // 2
	win = np.outer(np.hanning(hh), np.hanning(hw)).astype(np.float32)
	worst, jolts = 0.0, 0
	for s in film.shots:
		n = s["f1"] - s["f0"]
		p = subprocess.run(["ffmpeg", "-v", "error", "-ss", f"{s['src'] / FPS:.6f}", "-i", str(footage), "-frames:v",
				str(n), "-vf", f"scale={hw}:{hh},format=gray", "-f", "rawvideo", "-"], capture_output=True)
		frames = np.frombuffer(p.stdout, np.uint8).reshape(-1, hh, hw).astype(np.float32)
		moves, last = [], None
		for f in frames:
			spec = np.fft.rfft2((f - f.mean()) * win)
			if last is not None:
				r = spec * np.conj(last)
				r /= np.abs(r) + 1e-9
				corr = np.fft.irfft2(r, s=(hh, hw))
				y, x = np.unravel_index(np.argmax(corr), corr.shape)
				y = y - hh if y > hh // 2 else y
				x = x - hw if x > hw // 2 else x
				moves.append(float(np.hypot(x, y)) * 2.0)
			last = spec
		m = np.array(moves) if moves else np.zeros(1)
		over = int((m > JOLT_PX).sum())
		worst, jolts = max(worst, float(m.max())), jolts + over
		print(f"  motion {s['tag']:<9} {len(frames):4d} frames: max {m.max():5.1f} px, p95 {np.percentile(m, 95):5.1f} px, "
				f"median {np.median(m):4.1f} px, over {JOLT_PX:.0f} px: {over}")
	print(f"  motion inside shots: largest {worst:.1f} px, frames over {JOLT_PX:.0f} px: {jolts}")


def main() -> None:
	args = [a for a in sys.argv[1:] if not a.startswith("--")]
	if len(args) > 1 and args[0] == "practice":
		practice(Path(args[1]))
		return
	if not args:
		sys.exit(__doc__)
	out = Path(args[0])
	export = Path(os.environ.get("EXPORT", out)).expanduser()
	export.mkdir(parents=True, exist_ok=True)
	script = json.loads(SCRIPT.read_text())
	footage = remux(out / "tall")
	cues = json.loads((out / "tall" / "cues.json").read_text())
	for name in args[1:] or list(script["voices"]):
		voice_dir = out / "voice" / name
		film = Film(script, json.loads((voice_dir / "edit.json").read_text()), cues)
		if "--preview" in sys.argv:
			preview(film, footage, out / f"review_{name}")
			continue
		work = out / "cut"
		work.mkdir(exist_ok=True)
		mp4 = export / f"rl_explainer_{name}.mp4"
		cut(film, footage, voice_dir, mp4, work)
		review_sheet(mp4, film, export / f"rl_explainer_{name}_sheet.jpg", out / f"review_{name}")
		motion(footage, film)


if __name__ == "__main__":
	main()
