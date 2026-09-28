# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "pillow", "soundfile", "scipy"]
# ///
"""Cuts the social post "how the AI learned to drive" from the Movie Maker footage, once per
aspect (render_film.sh runs it).

    uv run --python 3.12 tools/rl/cut_film.py <out_dir> [export_dir]  # reads <out_dir>/{wide,tall}/raw.avi
                                                                    # + cues.json, writes rl_post_16x9.mp4,
                                                                    # rl_post_9x16.mp4 and a sheet of each
                                                                    # to export_dir (default out_dir)
    uv run --python 3.12 tools/rl/cut_film.py practice <swarm_dir>  # writes <swarm_dir>/practice.json

film.gd renders every shot already timed to a whole number of the drive theme's beats, with
nothing drawn over it, and lists them in cues.json. This lays them end to end on the beat, puts
the cards over them (what the shot is, how long the generation practised, how many of its cars
finish; big enough to read on a phone, placed per aspect: lower left on 16:9, high on 9:16 clear
of the Shorts buttons), ends on the Momiji footage blurred under the Sakura Rally card, with
the drive theme under all of it (the footage is silent), normalised to -14 LUFS through a
-1 dBFS limiter. Then it measures how far the picture moves from frame to frame inside every
shot (phase correlation on the footage: px of the output frame) and saves a contact sheet and
the frames on it (<out_dir>/review/).
`practice` writes each recorded generation's training time (plot_training.train_seconds, parent
runs included) with the caption film.gd shows for it.
"""
import json
import re
import subprocess
import sys
from pathlib import Path

import numpy as np
import soundfile as sf
from PIL import Image, ImageDraw, ImageFilter, ImageFont
from scipy.signal import resample_poly

sys.path.insert(0, str(Path(__file__).resolve().parent))
import plot_training  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
FONTS = ROOT / "assets/fonts"
MUSIC = ROOT / "assets/audio/music/drive.ogg"
FPS, SR = 60, 48000
SAMPLES_PER_FRAME = SR // FPS
BEAT = 60.0 / json.loads((ROOT / "assets/audio/music/music.json").read_text())["drive"]["bpm"]
MUSIC_BEAT0 = 0.054
MUSIC_DB = -6.0
TARGET_LUFS = -14.0
CREAM, INK, PINK, MINT = (246, 241, 232), (42, 36, 51), (232, 81, 124), (63, 180, 137)
# aspect -> output size and file suffix
ASPECTS = {"wide": (1920, 1080, "16x9"), "tall": (1080, 1920, "9x16")}
# a frame moving more than this (px of the output frame) inside a shot is a jolt
JOLT_PX = 40.0


def font(name: str, size: int) -> ImageFont.FreeTypeFont:
	return ImageFont.truetype(str(FONTS / name), size)


TITLE, BODY, BOLD = "DelaGothicOne-Regular.ttf", "ZenMaruGothic-Medium.ttf", "ZenMaruGothic-Black.ttf"


def run(cmd: list[str]) -> subprocess.CompletedProcess:
	p = subprocess.run(cmd, capture_output=True, text=True)
	if p.returncode != 0:
		sys.exit(f"{cmd[0]} failed:\n{p.stderr[-3000:]}")
	return p


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


# ---------------------------------------------------------------- cards (transparent PNGs)

def wrap(d: ImageDraw.ImageDraw, text: str, fo: ImageFont.FreeTypeFont, width: float) -> list[str]:
	"""`text` in lines no wider than `width`."""
	lines, line = [], ""
	for word in text.split():
		trial = f"{line} {word}".strip()
		if line and d.textlength(trial, font=fo) > width:
			lines.append(line)
			line = word
		else:
			line = trial
	return lines + [line]


def card(path: Path, aspect: str, big: str, small: str = "", rows: list[tuple] = (), centre: bool = False) -> None:
	"""A paper card like the game's HUD over the footage: `big` in the title face, `small` under it
	in sakura pink, then `rows` of (colour dot, bold words, plain words). 16:9: lower left (or top
	centre with `centre`); 9:16: high in the frame, centred, clear of the Shorts buttons."""
	w, h, _ = ASPECTS[aspect]
	tall = aspect == "tall"
	img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
	d = ImageDraw.Draw(img)
	fb, fs, fr, frb = font(TITLE, 84 if tall else 78), font(BOLD, 52 if tall else 48), font(BODY, 40), font(BOLD, 40)
	pad = 44 if tall else 40
	most = w - 2 * (60 if tall else 80) - 2 * pad
	big_lines = wrap(d, big, fb, most)
	small_lines = wrap(d, small, fs, most) if small else []
	row_lines = [(c, a, b) for c, a, b in rows]
	widths = [d.textlength(t, font=fb) for t in big_lines] + [d.textlength(t, font=fs) for t in small_lines]
	widths += [58 + d.textlength(a + "  ", font=frb) + d.textlength(b, font=fr) for _, a, b in row_lines]
	bw = max(widths)
	lh_big, lh_small, lh_row = int(fb.size * 1.22), int(fs.size * 1.3), int(fr.size * 1.5)
	bh = lh_big * len(big_lines) + (12 + lh_small * len(small_lines) if small_lines else 0) \
			+ (16 + lh_row * len(row_lines) if row_lines else 0)
	cw, ch = bw + 2 * pad, bh + 2 * pad - 6
	if tall:
		x0, y0 = (w - cw) / 2, 250
	elif centre:
		x0, y0 = (w - cw) / 2, 80
	else:
		x0, y0 = 80, h - 86 - ch
	d.rounded_rectangle((x0 + 8, y0 + 10, x0 + cw + 8, y0 + ch + 10), 34, fill=INK + (70,))
	d.rounded_rectangle((x0, y0, x0 + cw, y0 + ch), 34, fill=CREAM + (246,))
	y = y0 + pad - fb.size * 0.18
	for t in big_lines:
		tx = (w - d.textlength(t, font=fb)) / 2 if tall or centre else x0 + pad
		d.text((tx, y), t, font=fb, fill=INK)
		y += lh_big
	y += 12
	for t in small_lines:
		tx = (w - d.textlength(t, font=fs)) / 2 if tall or centre else x0 + pad
		d.text((tx, y), t, font=fs, fill=PINK)
		y += lh_small
	if row_lines:
		y += 16
		rx = (w - bw) / 2 if tall or centre else x0 + pad
		for c, a, b in row_lines:
			r = fr.size * 0.36
			cy = y + fr.size * 0.62
			d.ellipse((rx + 4, cy - r, rx + 4 + 2 * r, cy + r), fill=c)
			d.text((rx + 58, y), a, font=frb, fill=INK)
			d.text((rx + 58 + d.textlength(a + "  ", font=frb), y), b, font=fr, fill=INK + (215,))
			y += lh_row
	img.save(path)


def end_card(path: Path, aspect: str) -> None:
	"""The closing card over the blurred Momiji footage: the game, how to see this in it, the repo."""
	w, h, _ = ASPECTS[aspect]
	tall = aspect == "tall"
	img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
	d = ImageDraw.Draw(img)
	lines = [("Sakura Rally", font(TITLE, 124 if tall else 132), PINK),
			("press G to race its generations", font(BOLD, 56 if tall else 60), INK),
			("github.com/SummerEngine/sakura-rally", font(BOLD, 46 if tall else 50), INK)]
	most = w - 160
	laid = []
	for t, fo, c in lines:
		for part in wrap(d, t, fo, most):
			laid.append((part, fo, c))
	gap = 30
	heights = [int(fo.size * 1.2) for _, fo, _ in laid]
	bw = max(d.textlength(t, font=fo) for t, fo, _ in laid)
	bh = sum(heights) + gap * (len(laid) - 1)
	pad = 70
	x0, y0 = (w - bw) / 2 - pad, (h - bh) / 2 - pad
	d.rounded_rectangle((x0 + 10, y0 + 12, x0 + bw + 2 * pad + 10, y0 + bh + 2 * pad + 12), 44, fill=INK + (70,))
	d.rounded_rectangle((x0, y0, x0 + bw + 2 * pad, y0 + bh + 2 * pad), 44, fill=CREAM + (240,))
	y = y0 + pad - 10
	for (t, fo, c), lh in zip(laid, heights):
		d.text(((w - d.textlength(t, font=fo)) / 2, y), t, font=fo, fill=c)
		y += lh + gap
	img.save(path)


# ---------------------------------------------------------------- the edit

def finish_line(cue: dict) -> str:
	return f"{cue['finished']} of {cue['cars']} finish"


def plan(cues: list[dict]) -> list[dict]:
	"""Segments in order: each shot film.gd rendered (its first `frames` frames from its cue), with
	its card, then the closing card over the rest of the last shot."""
	segs: list[dict] = []
	for c in cues:
		if "frames" not in c:
			continue
		seg = {"name": c["name"], "src": round(c["t"] * FPS), "frames": int(c["frames"]), "beats": int(c["beats"])}
		name = c["name"]
		if name == "hook":
			seg["card"] = {"big": "An AI learns to drive", "small": "Generation 1 · no practice", "centre": True}
		elif name.startswith("corner_"):
			seg["card"] = {"big": c["practice"], "small": finish_line(c)}
		elif name == "sees":
			seg["card"] = {"big": "What it sees", "rows": [(PINK, "9 rays", "to the edge of the road"),
					(MINT, "14 points", "where the road goes")]}
		elif name == "momiji":
			seg["card"] = {"big": "A road it never practised on", "small": finish_line(c)}
		segs.append(seg)
		if c.get("end_frames"):
			segs.append({"name": "end", "src": seg["src"] + seg["frames"], "frames": int(c["end_frames"]),
					"beats": int(c["end_beats"]), "end": True})
	return segs


def mix(total_frames: int, work: Path) -> Path:
	"""The drive theme from its first beat, faded out over the last 2.6 s, at -14 LUFS."""
	y, msr = sf.read(MUSIC, dtype="float32", always_2d=True)
	if msr != SR:
		g = np.gcd(msr, SR)
		y = resample_poly(y, SR // g, msr // g, axis=0).astype(np.float32)
	y = y[int(MUSIC_BEAT0 * SR):]
	total = total_frames * SAMPLES_PER_FRAME
	while len(y) < total:
		y = np.concatenate([y, y])
	m = y[:total] * np.float32(10 ** (MUSIC_DB / 20.0))
	tail = int(2.6 * SR)
	m[-tail:] *= (np.linspace(1.0, 0.0, tail) ** 2)[:, None].astype(np.float32)
	path = work / "mix.wav"
	sf.write(path, m, SR, subtype="FLOAT")
	lufs = float(re.findall(r"I:\s+(-?[\d.]+) LUFS", subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i",
			str(path), "-af", "ebur128", "-f", "null", "-"], capture_output=True, text=True).stderr)[-1])
	sf.write(path, m * np.float32(10 ** ((TARGET_LUFS - lufs) / 20.0)), SR, subtype="FLOAT")
	return path


def cut(out: Path, aspect: str, export: Path) -> Path:
	w, h, suffix = ASPECTS[aspect]
	src = out / aspect
	footage = src / "raw.mkv"
	avi = src / "raw.avi"
	if avi.exists():
		# Movie Maker's AVI has no seek index; a stream-copy remux to Matroska indexes it.
		run(["ffmpeg", "-v", "error", "-y", "-i", str(avi), "-map", "0", "-c", "copy", str(footage)])
		avi.unlink()
	cues = json.loads((src / "cues.json").read_text())
	work = src / "cut"
	work.mkdir(exist_ok=True)
	segs = plan(cues)
	edit0 = 0
	for s in segs:
		s["edit0"] = edit0
		edit0 += s["frames"]
	total_frames = edit0
	for i, s in enumerate(segs):
		if "card" in s:
			card(work / f"card_{i}.png", aspect, **s["card"])
		if s.get("end"):
			end_card(work / f"card_{i}.png", aspect)
	mixwav = mix(total_frames, work)

	# Video: one ffmpeg graph; every segment is its own frames of the footage, limited-range BT.709.
	cmd = ["ffmpeg", "-v", "error", "-y"]
	graph, labels, n_in = [], [], 0
	norm = f"scale={w}:{h}:in_range=full:in_color_matrix=bt601:out_range=limited:out_color_matrix=bt709,format=yuv420p"
	for i, s in enumerate(segs):
		d = s["frames"] / FPS
		cmd += ["-ss", f"{max(s['src'] / FPS - 0.5, 0):.6f}", "-t", f"{d + 1.0:.6f}", "-i", str(footage)]
		skip = s["src"] / FPS - max(s["src"] / FPS - 0.5, 0)
		chain = (f"[{n_in}:v]trim=start={skip:.6f},setpts=PTS-STARTPTS,trim=end_frame={s['frames']},"
				f"setpts=PTS-STARTPTS,{norm}")
		if s.get("end"):
			chain += ",gblur=sigma=14,eq=brightness=0.02:saturation=0.9"
		n_in += 1
		png = work / f"card_{i}.png"
		if png.exists():
			cmd += ["-loop", "1", "-framerate", str(FPS), "-t", f"{d:.6f}", "-i", str(png)]
			rise = "0" if s.get("end") else "if(lt(t\\,0.35)\\,46*pow(1-t/0.35\\,2)\\,0)"
			chain += (f"[b{i}];[{n_in}:v]format=rgba,fade=t=in:st=0.05:d=0.3:alpha=1[o{i}];"
					f"[b{i}][o{i}]overlay=x=0:y='{rise}':eval=frame:format=auto")
			n_in += 1
		fade = f",fade=t=out:st={d - 0.5:.3f}:d=0.5" if i == len(segs) - 1 else ""
		graph.append(chain + f",format=yuv420p{fade},setsar=1[s{i}]")
		labels.append(f"[s{i}]")
	cmd += ["-i", str(mixwav)]
	graph.append("".join(labels) + f"concat=n={len(segs)}:v=1:a=0,"
			+ "setparams=range=tv:colorspace=bt709:color_primaries=bt709:color_trc=bt709[v]")
	graph.append(f"[{n_in}:a]alimiter=limit=0.891:attack=4:release=60:level=false,aresample={SR}[a]")
	mp4 = export / f"rl_post_{suffix}.mp4"
	cmd += ["-filter_complex", ";".join(graph), "-map", "[v]", "-map", "[a]",
			"-c:v", "libx264", "-preset", "slow", "-crf", "18", "-profile:v", "high", "-maxrate", "30M", "-bufsize", "60M",
			"-r", str(FPS), "-c:a", "aac", "-b:a", "256k", "-movflags", "+faststart", str(mp4)]
	run(cmd)
	print(f"{mp4}: {total_frames / FPS:.1f} s, {len(segs)} segments, {mp4.stat().st_size / 1e6:.1f} MB")
	for s in segs:
		print(f"  {s['edit0'] / FPS:6.2f}s  {s['frames'] / FPS:5.2f}s  {s['beats']:2d} beats  {s['name']}")
	sheet(mp4, segs, export / f"rl_post_{suffix}_sheet.jpg", out / "review", aspect)
	motion(footage, segs, w, h)
	return mp4


def sheet(mp4: Path, segs: list[dict], path: Path, review: Path, aspect: str) -> None:
	"""12 frames of the edit (two of each long shot, one of the short ones and the end card) as
	PNGs in `review` and tiled into a contact sheet."""
	picks = []
	for s in segs:
		k = 1 if s.get("end") or s["name"] == "sees" else 2
		picks += [s["edit0"] + round(s["frames"] * (j + 1) / (k + 1)) for j in range(k)]
	picks = picks[:12]
	review.mkdir(exist_ok=True)
	suffix = ASPECTS[aspect][2]
	for old in review.glob(f"{suffix}_*.png"):
		old.unlink()
	sel = "+".join(f"eq(n\\,{p})" for p in picks)
	run(["ffmpeg", "-v", "error", "-y", "-i", str(mp4), "-vf", f"select={sel}", "-fps_mode", "passthrough",
			str(review / f"{suffix}_%02d.png")])
	tiles = [Image.open(p) for p in sorted(review.glob(f"{suffix}_*.png"))]
	cols = 4 if aspect == "wide" else 6
	tw = 480 if aspect == "wide" else 320
	th = round(tw * tiles[0].height / tiles[0].width)
	rows = (len(tiles) + cols - 1) // cols
	img = Image.new("RGB", (cols * tw, rows * th), INK)
	for i, t in enumerate(tiles):
		img.paste(t.resize((tw, th), Image.LANCZOS), ((i % cols) * tw, (i // cols) * th))
	img.save(path, quality=90)
	print(f"{path}: frames {picks}")


def motion(footage: Path, segs: list[dict], w: int, h: int) -> None:
	"""How far the picture moves from one frame to the next inside each shot: the phase
	correlation peak between consecutive frames of the footage (half size, grey, windowed), in px
	of the output frame. Prints each shot's largest move, its 95th percentile and the frames over
	JOLT_PX."""
	hw, hh = w // 2, h // 2
	win = np.outer(np.hanning(hh), np.hanning(hw)).astype(np.float32)
	worst = 0.0
	jolts = 0
	for s in segs:
		if s.get("end"):
			continue
		p = subprocess.run(["ffmpeg", "-v", "error", "-ss", f"{s['src'] / FPS:.6f}", "-i", str(footage), "-frames:v",
				str(s["frames"]), "-vf", f"scale={hw}:{hh},format=gray", "-f", "rawvideo", "-"], capture_output=True)
		frames = np.frombuffer(p.stdout, np.uint8).reshape(-1, hh, hw).astype(np.float32)
		moves = []
		last = None
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
		print(f"  motion {s['name']:<9} {len(frames):4d} frames: max {m.max():5.1f} px, p95 {np.percentile(m, 95):5.1f} px, "
				f"median {np.median(m):4.1f} px, over {JOLT_PX:.0f} px: {over}")
	print(f"  motion inside shots: largest {worst:.1f} px, frames over {JOLT_PX:.0f} px: {jolts}")


def main() -> None:
	if len(sys.argv) > 2 and sys.argv[1] == "practice":
		practice(Path(sys.argv[2]))
		return
	out = Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/sakura_film")
	export = Path(sys.argv[2]).expanduser() if len(sys.argv) > 2 else out
	export.mkdir(parents=True, exist_ok=True)
	aspects = [a for a in ASPECTS if (out / a / "cues.json").exists()]
	if not aspects:
		sys.exit(f"no footage in {out}/wide or {out}/tall (render_film.sh)")
	for a in aspects:
		cut(out, a, export)


if __name__ == "__main__":
	main()
