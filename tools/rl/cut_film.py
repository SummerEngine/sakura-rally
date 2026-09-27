# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "matplotlib", "pillow", "soundfile", "scipy"]
# ///
"""Cuts "how the AI learned to drive" from the Movie Maker footage (render_film.sh runs it).

    uv run --python 3.12 tools/rl/cut_film.py <out_dir>   # reads raw.avi + cues.json
                                                          # writes sakura_ai_learns.mp4 + sheet.jpg

Title cards and captions are drawn with the game's fonts in its colours, the learning curve is
animated from runs/<run>/progress.csv (plot_training.py), every clip keeps its game audio (engine,
gravel) under the drive theme, and the mix is normalised to -14 LUFS through a -1 dBFS limiter.
Captions state only what the footage shows: each generation's clip is captioned with its steps,
its training time and where film.gd saw it leave the road.
"""
import json
import re
import subprocess
import sys
from pathlib import Path

import numpy as np
import soundfile as sf
from PIL import Image, ImageDraw, ImageFont
from scipy.signal import resample_poly

sys.path.insert(0, str(Path(__file__).resolve().parent))
import plot_training  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
FONTS = ROOT / "assets/fonts"
MUSIC = ROOT / "assets/audio/music/drive.ogg"
W, H, FPS, SR = 1920, 1080, 60, 48000
SAMPLES_PER_FRAME = SR // FPS
BEAT = 60.0 / json.loads((ROOT / "assets/audio/music/music.json").read_text())["drive"]["bpm"]
MUSIC_BEAT0 = 0.054
MUSIC_DB, CLIP_MUSIC_DB = -6.0, -12.0  # the bed over cards and chart, and under game audio
TARGET_LUFS = -14.0
CREAM, INK, PINK, MINT = (246, 241, 232), (42, 36, 51), (232, 81, 124), (63, 180, 137)
CURVE_RUN = "gen2"  # gen1 up to 6M, then gen2's fine-tune: the shipped driver's history
CURVE_UNTIL = 7e6
LEAD = 1.2  # seconds of each clip before its cue (the car standing, then moving off)


def font(name: str, size: int) -> ImageFont.FreeTypeFont:
	return ImageFont.truetype(str(FONTS / name), size)


TITLE, BODY, BOLD = "DelaGothicOne-Regular.ttf", "ZenMaruGothic-Medium.ttf", "ZenMaruGothic-Black.ttf"


def run(cmd: list[str]) -> subprocess.CompletedProcess:
	p = subprocess.run(cmd, capture_output=True, text=True)
	if p.returncode != 0:
		sys.exit(f"{cmd[0]} failed:\n{p.stderr[-3000:]}")
	return p


def steps_label(steps: int) -> str:
	if steps <= 0:
		return "untrained"
	return f"{steps / 1e6:.0f}M steps" if steps >= 1e6 else f"{steps / 1e3:.0f}k steps"


def age_label(cue: dict) -> str:
	"""Training time behind a generation, from its run's progress.csv."""
	steps = int(cue.get("steps", 0))
	if steps <= 0:
		return "no practice"
	s = plot_training.train_seconds(str(cue.get("run", "")), steps)
	if s is None:
		return steps_label(steps)
	if s >= 5400:
		return f"{s / 3600:.1f} hours of practice"
	m = round(s / 60)
	return f"{m} minute{'' if m == 1 else 's'} of practice"


# ---------------------------------------------------------------- cards and captions (PNG)

def card(path: Path, lines: list[tuple[str, str, int, tuple]], bg=CREAM) -> None:
	"""A full-frame card: lines of (text, font, size, colour), centred as a block."""
	img = Image.new("RGB", (W, H), bg)
	d = ImageDraw.Draw(img)
	fonts = [font(f, s) for _, f, s, _ in lines]
	heights = [d.textbbox((0, 0), t, font=fo)[3] for (t, _, _, _), fo in zip(lines, fonts)]
	gap = 34
	y = (H - sum(heights) - gap * (len(lines) - 1)) // 2
	for (t, _, _, c), fo, h in zip(lines, fonts, heights):
		w = d.textlength(t, font=fo)
		d.text(((W - w) / 2, y), t, font=fo, fill=c)
		y += h + gap
	img.save(path)


def caption(path: Path, big: str, small: str, badge: str = "", badge_colour=PINK) -> None:
	"""A lower-third over the footage (transparent PNG): a paper card like the game's HUD."""
	img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
	d = ImageDraw.Draw(img)
	fb, fs, fg = font(TITLE, 58), font(BOLD, 32), font(BOLD, 30)
	bw = max(d.textlength(big, font=fb), d.textlength(small, font=fs))
	pad, x0, y1 = 36, 70, H - 80
	h = 58 + 18 + 36 + pad * 2
	y0 = y1 - h
	d.rounded_rectangle((x0 + 6, y0 + 8, x0 + bw + pad * 2 + 6, y1 + 8), 26, fill=(42, 36, 51, 60))
	d.rounded_rectangle((x0, y0, x0 + bw + pad * 2, y1), 26, fill=CREAM + (245,))
	d.text((x0 + pad, y0 + pad - 6), big, font=fb, fill=INK)
	d.text((x0 + pad, y0 + pad + 70), small, font=fs, fill=INK + (200,))
	if badge:
		tw = d.textlength(badge, font=fg)
		bx0, by1 = x0, y0 - 18
		d.rounded_rectangle((bx0, by1 - 58, bx0 + tw + 44, by1), 20, fill=badge_colour + (255,))
		d.text((bx0 + 22, by1 - 50), badge, font=fg, fill=CREAM)
	img.save(path)


def legend(path: Path) -> None:
	"""The key to the 'what it sees' clip (top right): all the network gets, the parts film.gd's
	SenseView draws by their colour, the rest (DriveSense motion and hands) as a ring."""
	img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
	d = ImageDraw.Draw(img)
	fb, fs = font(BOLD, 34), font(BODY, 28)
	head = "All it gets, 10 times a second"
	rows = [((232, 81, 124), "9 rays", "how far to the edge of the road"),
			((63, 180, 137), "14 points", "where the road goes, up to 220 m ahead"),
			(None, "9 numbers", "its speed, slide, spin, surface and controls")]
	pad, indent, row_h = 32, 48, 66
	w = pad * 2 + max([d.textlength(head, font=fb)]
			+ [indent + d.textlength(a + "  ", font=fb) + d.textlength(b, font=fs) for _, a, b in rows])
	x1, y0 = W - 70, 70
	x0 = x1 - w
	d.rounded_rectangle((x0, y0, x1, y0 + 98 + row_h * len(rows)), 26, fill=CREAM + (240,))
	d.text((x0 + pad, y0 + 22), head, font=fb, fill=INK)
	for i, (c, a, b) in enumerate(rows):
		y = y0 + 88 + i * row_h
		ring = (x0 + pad + 2, y + 8, x0 + pad + 30, y + 36)
		if c:
			d.ellipse(ring, fill=c)
		else:
			d.ellipse(ring, outline=INK, width=3)
		d.text((x0 + pad + indent, y), a, font=fb, fill=INK)
		d.text((x0 + pad + indent + d.textlength(a + "  ", font=fb), y + 4), b, font=fs, fill=INK + (200,))
	img.save(path)


# ---------------------------------------------------------------- the edit

def plan(cues: dict[str, dict]) -> list[dict]:
	"""Segments in order: ("card"|"chart"|"clip"), length, source window and overlays."""
	gens = sorted((c for n, c in cues.items() if re.fullmatch(r"gen_\d+", n)), key=lambda c: c["t"])
	segs: list[dict] = [
		{"kind": "card", "beats": 8, "lines": [
			("Sakura Rally", TITLE, 64, PINK),
			("An AI learns to drive", TITLE, 104, INK),
			("trial and error, on a laptop, in the real game", BODY, 42, INK)]},
		{"kind": "card", "beats": 8, "lines": [
			("No one shows it how.", TITLE, 76, INK),
			("It only gets points for road covered, and loses them for crashing.", BODY, 42, INK),
			("64 cars practise at once, faster than real time.", BODY, 42, INK)]},
	]
	for i, g in enumerate(gens):
		name = f"gen_{i}"
		off = cues.get(name + "_off")
		start = g["t"] - LEAD
		if off:
			# stay on the crash for a moment, then cut
			end = off["t"] + 1.6
			how = f"off the road after {off['progress'] - plot_training_from(cues):.0f} m, at {off['kmh']} km/h"
		else:
			nxt = cues.get(name + "_hairpin") or cues.get(name + "_bend")
			end = (nxt["t"] + 3.0) if nxt else g["t"] + 12.0
			bend = cues.get(name + "_bend")
			how = f"takes the corners · {bend['kmh']} km/h into the first" if bend else "stays on the road"
		segs.append({"kind": "clip", "src": start, "dur": max(end - start, 3.0),
				"caption": (f"Generation {i + 1}", f"{age_label(g)} · {how}",
						steps_label(int(g.get("steps", 0))), PINK if off else MINT)})
	segs.append({"kind": "chart", "beats": 16})
	sees = cues["sees"]
	segs.append({"kind": "clip", "src": sees["t"] - 0.4, "dur": 10.5, "legend": True,
			"caption": ("What it sees", "no map, no track name: the same network drives any road", "", MINT)})
	segs.append({"kind": "card", "beats": 6, "lines": [
			("Every generation, one race", TITLE, 76, INK),
			("the newest starts last", BODY, 42, INK)]})
	race, grid = cues["race"], cues["grid"]
	segs.append({"kind": "clip", "src": grid["t"] + 0.2, "dur": race["t"] - grid["t"] + 14.0,
			"caption": ("The newest, from the back", "over each car: its generation and training steps", "", PINK)})
	held = cues["held_out"]
	segs.append({"kind": "card", "beats": 6, "lines": [
			("A road it has never seen", TITLE, 76, INK),
			("Momiji Valley was kept out of training", BODY, 42, INK)]})
	gravel = cues.get("held_out_gravel")
	segs.append({"kind": "clip", "src": held["t"] - 0.6,
			"dur": ((gravel["t"] + 3.5) if gravel else held["t"] + 12.0) - (held["t"] - 0.6),
			"caption": ("Momiji Valley", "tarmac into gravel, first time", "", MINT)})
	segs.append({"kind": "card", "beats": 8, "lines": [
			("Sakura Rally", TITLE, 64, PINK),
			("The AI is in the game: press I to let it drive, G to race its generations", BODY, 40, INK),
			("github.com/SummerEngine/sakura-rally", BOLD, 38, INK)]})
	return segs


def plot_training_from(cues: dict) -> float:
	"""Where the generation clips start on Hanami (film.gd CORNER_FROM, logged as a cue)."""
	return float(cues["corner_from"]["progress"])


def main() -> None:
	out = Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/sakura_film")
	footage = out / "raw.mkv"
	avi = out / "raw.avi"
	if avi.exists():
		# Movie Maker's AVI has no seek index; a stream-copy remux to Matroska indexes it.
		run(["ffmpeg", "-v", "error", "-y", "-i", str(avi), "-map", "0", "-c", "copy", str(footage)])
		avi.unlink()
	cues: dict[str, dict] = {}
	for c in json.loads((out / "cues.json").read_text()):
		cues.setdefault(c["name"], c)
	work = out / "cut"
	work.mkdir(exist_ok=True)
	segs = plan(cues)

	# Frames of every segment; cards and the chart on the beat grid, clips as long as they need.
	for s in segs:
		s["frames"] = round(s["beats"] * BEAT * FPS) if "beats" in s else round(s["dur"] * FPS)
	edit0 = 0
	for s in segs:
		s["edit0"] = edit0
		edit0 += s["frames"]
	total_frames = edit0
	seconds = total_frames / FPS

	# Pictures: cards, captions, the chart frames.
	for i, s in enumerate(segs):
		if s["kind"] == "card":
			card(work / f"card_{i}.png", s["lines"])
		elif s["kind"] == "clip":
			big, small, badge, colour = s["caption"]
			caption(work / f"cap_{i}.png", big, small, badge, colour)
			if s.get("legend"):
				legend(work / f"legend_{i}.png")
		elif s["kind"] == "chart":
			# Every generation on the curve: its steps on gen1/gen2's axis (the early ones come from a
			# run of the same recipe saved every 100k steps; the curves agree to within the noise).
			gens = sorted((c for n, c in cues.items() if re.fullmatch(r"gen_\d+", n)), key=lambda c: c["t"])
			marks = [(float(g.get("steps", 0)), f"gen {k + 1}") for k, g in enumerate(gens)
					if float(g.get("steps", 0)) <= CURVE_UNTIL]
			chart = plot_training.Chart(CURVE_RUN, CURVE_UNTIL, marks)
			frames_dir = work / f"chart_{i}"
			frames_dir.mkdir(exist_ok=True)
			draw = int(s["frames"] * 0.75)  # draws the curve, then holds it whole
			for f in range(0, s["frames"], 2):  # 30 fps of chart, doubled
				chart.reveal(min(f / draw, 1.0))
				chart.save(frames_dir / f"{f // 2:04d}.png")

	# Audio: each clip's game audio, the drive theme under everything.
	wav = work / "footage.wav"
	run(["ffmpeg", "-v", "error", "-y", "-i", str(footage), "-vn", "-ac", "2", "-ar", str(SR), "-c:a", "pcm_f32le", str(wav)])
	src, sr = sf.read(wav, dtype="float32", always_2d=True)
	total = total_frames * SAMPLES_PER_FRAME
	game = np.zeros((total, 2), np.float32)
	under = np.zeros(total, bool)
	fade = int(0.01 * SR)
	ramp = np.linspace(0.0, 1.0, fade, dtype=np.float32)[:, None]
	for s in segs:
		if s["kind"] != "clip":
			continue
		a = round(s["src"] * SR)
		n = s["frames"] * SAMPLES_PER_FRAME
		clip = np.zeros((n, 2), np.float32)
		got = src[max(a, 0):a + n]
		clip[:len(got)] = got
		clip[:fade] *= ramp
		clip[-fade:] *= ramp[::-1]
		b = s["edit0"] * SAMPLES_PER_FRAME
		game[b:b + n] = clip
		under[b:b + n] = True
	y, msr = sf.read(MUSIC, dtype="float32", always_2d=True)
	if msr != SR:
		g = np.gcd(msr, SR)
		y = resample_poly(y, SR // g, msr // g, axis=0).astype(np.float32)
	y = y[int(MUSIC_BEAT0 * SR):]
	while len(y) < total:
		y = np.concatenate([y, y])
	y = y[:total]
	gain = np.where(under, 10 ** (CLIP_MUSIC_DB / 20.0), 10 ** (MUSIC_DB / 20.0)).astype(np.float32)
	k = int(0.25 * SR)
	gain = np.convolve(np.pad(gain, (k // 2, k - 1 - k // 2), mode="edge"), np.ones(k) / k, mode="valid").astype(np.float32)
	tail = int(2.6 * SR)
	gain[-tail:] *= np.linspace(1.0, 0.0, tail) ** 2
	gain[:int(0.02 * SR)] *= np.linspace(0.0, 1.0, int(0.02 * SR))
	mix = game + y * gain[:, None]
	mixwav = work / "mix.wav"
	sf.write(mixwav, mix, SR, subtype="FLOAT")
	lufs = float(re.findall(r"I:\s+(-?[\d.]+) LUFS", subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i",
			str(mixwav), "-af", "ebur128", "-f", "null", "-"], capture_output=True, text=True).stderr)[-1])
	sf.write(mixwav, mix * np.float32(10 ** ((TARGET_LUFS - lufs) / 20.0)), SR, subtype="FLOAT")

	# Video: one ffmpeg graph, every segment scaled to 1080p60 in limited-range BT.709.
	cmd = ["ffmpeg", "-v", "error", "-y"]
	graph, labels, n_in = [], [], 0
	norm = "scale=1920:1080:in_range=full:in_color_matrix=bt601:out_range=limited:out_color_matrix=bt709,format=yuv420p"
	for i, s in enumerate(segs):
		d = s["frames"] / FPS
		if s["kind"] == "card":
			cmd += ["-loop", "1", "-framerate", str(FPS), "-t", f"{d:.6f}", "-i", str(work / f"card_{i}.png")]
			graph.append(f"[{n_in}:v]fps={FPS},scale=1920:1080,format=yuv420p,fade=t=in:d=0.25,fade=t=out:st={d - 0.25:.3f}:d=0.25,setsar=1[s{i}]")
			n_in += 1
		elif s["kind"] == "chart":
			cmd += ["-framerate", str(FPS // 2), "-i", str(work / f"chart_{i}" / "%04d.png")]
			graph.append(f"[{n_in}:v]fps={FPS},trim=end_frame={s['frames']},setpts=PTS-STARTPTS,scale=1920:1080,format=yuv420p,"
					f"fade=t=in:d=0.25,fade=t=out:st={d - 0.3:.3f}:d=0.3,setsar=1[s{i}]")
			n_in += 1
		else:
			cmd += ["-ss", f"{max(s['src'] - 0.25, 0):.6f}", "-t", f"{d + 0.6:.6f}", "-i", str(footage)]
			v = n_in
			n_in += 1
			cmd += ["-loop", "1", "-framerate", str(FPS), "-t", f"{d:.6f}", "-i", str(work / f"cap_{i}.png")]
			c = n_in
			n_in += 1
			skip = min(0.25, s["src"])
			chain = (f"[{v}:v]trim=start={skip:.4f},setpts=PTS-STARTPTS,trim=end_frame={s['frames']},setpts=PTS-STARTPTS,{norm}[v{i}];"
					f"[{c}:v]format=rgba,fade=t=in:st=0.4:d=0.35:alpha=1,fade=t=out:st={d - 0.8:.3f}:d=0.35:alpha=1[c{i}];"
					f"[v{i}][c{i}]overlay=0:0:format=auto")
			if s.get("legend"):
				cmd += ["-loop", "1", "-framerate", str(FPS), "-t", f"{d:.6f}", "-i", str(work / f"legend_{i}.png")]
				chain += f"[vc{i}];[{n_in}:v]format=rgba,fade=t=in:st=0.6:d=0.35:alpha=1[l{i}];[vc{i}][l{i}]overlay=0:0:format=auto"
				n_in += 1
			graph.append(chain + f",format=yuv420p,fade=t=in:d=0.15,fade=t=out:st={d - 0.15:.3f}:d=0.15,setsar=1[s{i}]")
		labels.append(f"[s{i}]")
	cmd += ["-i", str(mixwav)]
	graph.append("".join(labels) + f"concat=n={len(segs)}:v=1:a=0,"
			+ "setparams=range=tv:colorspace=bt709:color_primaries=bt709:color_trc=bt709[v]")
	graph.append(f"[{n_in}:a]alimiter=limit=0.891:attack=4:release=60:level=false,aresample={SR}[a]")
	mp4 = out / "sakura_ai_learns.mp4"
	cmd += ["-filter_complex", ";".join(graph), "-map", "[v]", "-map", "[a]",
			"-c:v", "libx264", "-preset", "slow", "-crf", "18", "-profile:v", "high", "-maxrate", "30M", "-bufsize", "60M",
			"-r", str(FPS), "-c:a", "aac", "-b:a", "256k", "-movflags", "+faststart", str(mp4)]
	run(cmd)

	mids = "+".join(f"eq(n\\,{s['edit0'] + s['frames'] // 2})" for s in segs)
	run(["ffmpeg", "-v", "error", "-y", "-i", str(mp4), "-vf", f"select={mids},scale=480:-1,tile=4x{(len(segs) + 3) // 4}",
			"-frames:v", "1", "-fps_mode", "passthrough", str(out / "sheet.jpg")])
	print(f"{mp4}: {seconds:.1f} s, {len(segs)} segments, {mp4.stat().st_size / 1e6:.1f} MB")
	for s in segs:
		what = s.get("caption", ("",))[0] if s["kind"] == "clip" else (s["lines"][1][0] if s["kind"] == "card" else "chart")
		print(f"  {s['edit0'] / FPS:6.1f}s  {s['kind']:<5} {s['frames'] / FPS:5.1f}s  {what}")


if __name__ == "__main__":
	main()
