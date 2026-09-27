# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "pillow", "soundfile", "scipy"]
# ///
"""Cuts "how the AI learned to drive" from the Movie Maker footage (render_film.sh runs it).

    uv run --python 3.12 tools/rl/cut_film.py <out_dir>             # reads raw.avi + cues.json,
                                                                    # writes sakura_ai_learns.mp4 + sheet.jpg
    uv run --python 3.12 tools/rl/cut_film.py practice <swarm_dir>  # writes <swarm_dir>/practice.json

The footage is the AI's recorded practice played back (film.gd): every shot is already timed and
carries its own card (the generation, its training time, the cars still driving) and the strip of
where every car is. This cuts the shots on the drive theme's beat, lays the title over the first
one, the key over "what it sees" and a closing card at the end, with the drive theme under all of
it (the footage is silent), normalised to -14 LUFS through a -1 dBFS limiter.
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
MUSIC_DB = -6.0
TARGET_LUFS = -14.0
CREAM, INK, PINK, MINT = (246, 241, 232), (42, 36, 51), (232, 81, 124), (63, 180, 137)


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


def title(path: Path, big: str, small: str) -> None:
	"""The title over the first shot (transparent PNG): a paper card in the middle of the sky."""
	img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
	d = ImageDraw.Draw(img)
	fb, fs = font(TITLE, 92), font(BOLD, 38)
	bw = max(d.textlength(big, font=fb), d.textlength(small, font=fs))
	pad = 48
	x0, x1 = (W - bw) / 2 - pad, (W + bw) / 2 + pad
	y0, y1 = 300, 300 + 92 + 26 + 44 + pad * 2
	d.rounded_rectangle((x0 + 8, y0 + 10, x1 + 8, y1 + 10), 34, fill=INK + (60,))
	d.rounded_rectangle((x0, y0, x1, y1), 34, fill=CREAM + (246,))
	d.text(((W - d.textlength(big, font=fb)) / 2, y0 + pad - 14), big, font=fb, fill=INK)
	d.text(((W - d.textlength(small, font=fs)) / 2, y0 + pad + 104), small, font=fs, fill=PINK)
	img.save(path)


def caption(path: Path, big: str, small: str) -> None:
	"""A lower-third over the footage (transparent PNG): a paper card like the game's HUD."""
	img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
	d = ImageDraw.Draw(img)
	fb, fs = font(TITLE, 58), font(BOLD, 32)
	bw = max(d.textlength(big, font=fb), d.textlength(small, font=fs))
	pad, x0, y1 = 36, 70, H - 80
	h = 58 + 18 + 36 + pad * 2
	y0 = y1 - h
	d.rounded_rectangle((x0 + 6, y0 + 8, x0 + bw + pad * 2 + 6, y1 + 8), 26, fill=INK + (60,))
	d.rounded_rectangle((x0, y0, x0 + bw + pad * 2, y1), 26, fill=CREAM + (245,))
	d.text((x0 + pad, y0 + pad - 6), big, font=fb, fill=INK)
	d.text((x0 + pad, y0 + pad + 70), small, font=fs, fill=INK + (200,))
	img.save(path)


def legend(path: Path) -> None:
	"""The key to the 'what it sees' clip (top right): all the network gets, the parts film.gd's
	SenseView draws by their colour, the rest (DriveSense motion and hands) as a ring."""
	img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
	d = ImageDraw.Draw(img)
	fb, fs = font(BOLD, 34), font(BODY, 28)
	head = "All it gets, 10 times a second"
	rows = [(PINK, "9 rays", "how far to the edge of the road"),
			(MINT, "14 points", "where the road goes, up to 220 m ahead"),
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
	"""Segments in order: ("card"|"clip"), their length and, for clips, the footage window and overlays.
	A clip runs from its shot's cue to the shot's end cue (film.gd holds the last frame a moment),
	rounded to whole beats: a longer one ends early (on the held frame), a shorter one holds it."""
	shots = sorted((n for n in cues if re.fullmatch(r"gen_\d+", n)), key=lambda n: int(n[4:]))
	shots += [n for n in ("sees", "held_out") if n in cues]
	segs: list[dict] = []
	for name in shots:
		a, b = cues[name]["t"], cues[name + "_end"]["t"]
		seg = {"kind": "clip", "name": name, "src": a, "have": b - a, "beats": max(round((b - a) / BEAT), 1)}
		if name == "gen_0":
			seg["title"] = ("An AI learns to drive", "It only scores for road covered · 64 cars practise at once")
		if name == "sees":
			seg["legend"] = True
			seg["caption"] = ("What it sees", "no map, no track name: the same network drives any road")
		segs.append(seg)
	segs.append({"kind": "card", "name": "card", "beats": 8, "lines": [
			("Sakura Rally", TITLE, 64, PINK),
			("The AI is in the game: press I to let it drive, G to race its generations", BODY, 40, INK),
			("github.com/SummerEngine/sakura-rally", BOLD, 38, INK)]})
	return segs


def cut(out: Path) -> None:
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
	edit0 = 0
	for s in segs:
		s["frames"] = round(s["beats"] * BEAT * FPS)
		s["edit0"] = edit0
		edit0 += s["frames"]
	total_frames = edit0
	seconds = total_frames / FPS

	for i, s in enumerate(segs):
		if s["kind"] == "card":
			card(work / f"card_{i}.png", s["lines"])
		if "title" in s:
			title(work / f"title_{i}.png", *s["title"])
		if "caption" in s:
			caption(work / f"cap_{i}.png", *s["caption"])
		if s.get("legend"):
			legend(work / f"legend_{i}.png")

	# Audio: the drive theme from its first beat, faded out under the closing card.
	y, msr = sf.read(MUSIC, dtype="float32", always_2d=True)
	if msr != SR:
		g = np.gcd(msr, SR)
		y = resample_poly(y, SR // g, msr // g, axis=0).astype(np.float32)
	y = y[int(MUSIC_BEAT0 * SR):]
	total = total_frames * SAMPLES_PER_FRAME
	while len(y) < total:
		y = np.concatenate([y, y])
	mix = y[:total] * np.float32(10 ** (MUSIC_DB / 20.0))
	tail = int(2.6 * SR)
	mix[-tail:] *= (np.linspace(1.0, 0.0, tail) ** 2)[:, None].astype(np.float32)
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
			labels.append(f"[s{i}]")
			continue
		cmd += ["-ss", f"{max(s['src'] - 0.25, 0):.6f}", "-t", f"{s['have'] + 0.6:.6f}", "-i", str(footage)]
		skip = min(0.25, s["src"])
		# the shot's own frames, then its last one held when the beat grid asks for more
		chain = (f"[{n_in}:v]trim=start={skip:.4f},setpts=PTS-STARTPTS,trim=end_frame={round(s['have'] * FPS)},"
				f"setpts=PTS-STARTPTS,tpad=stop_mode=clone:stop_duration={d:.4f},trim=end_frame={s['frames']},"
				f"setpts=PTS-STARTPTS,{norm}")
		n_in += 1
		for key, fade_in, fade_out in (("title", 0.25, d - 0.9), ("caption", 0.4, d - 0.8), ("legend", 0.6, d - 0.5)):
			if not s.get(key):
				continue
			png = work / f"{'cap' if key == 'caption' else key}_{i}.png"
			if key == "title":
				fade_out = min(fade_out, 2.6)
			cmd += ["-loop", "1", "-framerate", str(FPS), "-t", f"{d:.6f}", "-i", str(png)]
			chain += (f"[b{i}{key}];[{n_in}:v]format=rgba,fade=t=in:st={fade_in:.3f}:d=0.35:alpha=1,"
					f"fade=t=out:st={fade_out:.3f}:d=0.35:alpha=1[o{i}{key}];[b{i}{key}][o{i}{key}]overlay=0:0:format=auto")
			n_in += 1
		graph.append(chain + f",format=yuv420p,fade=t=in:d=0.12,fade=t=out:st={d - 0.12:.3f}:d=0.12,setsar=1[s{i}]")
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
		print(f"  {s['edit0'] / FPS:6.1f}s  {s['kind']:<5} {s['frames'] / FPS:5.1f}s  {s['name']}")


def main() -> None:
	if len(sys.argv) > 2 and sys.argv[1] == "practice":
		practice(Path(sys.argv[2]))
		return
	cut(Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/sakura_film"))


if __name__ == "__main__":
	main()
