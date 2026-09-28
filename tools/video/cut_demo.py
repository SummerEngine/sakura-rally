#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "soundfile", "scipy"]
# ///
"""Cuts the episode 3 trailer from the Movie Maker take (render_demo.sh runs it).

    uv run --python 3.12 tools/video/cut_demo.py <out_dir>
        reads <out_dir>/raw.avi (or raw.mkv) + cues.json; writes export/trailer_ep3_16x9.mp4
        (1920x1080) and export/trailer_ep3_9x16.mp4 (1080x1920) in this checkout, each with a
        contact sheet (trailer_ep3_*_sheet.jpg)

The take is square: the 16:9 edit is its middle band at full width, the 9:16 edit its middle
column at full height, so both are native pixels of the same frames, cut identically. Every cut
lands on the beat of the drive theme, each shot keeps its own game audio (engine, gravel, the paint
sweep) under one continuous music bed, and the mix is normalised to -14 LUFS through a -1 dBFS
sample-peak limiter (AAC encoding lifts the true peak to about -0.7 dBTP).
"""
import json
import re
import subprocess
import sys
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy.signal import resample_poly

ROOT = Path(__file__).resolve().parents[2]
MUSIC = ROOT / "assets/audio/music/drive.ogg"
EXPORT = ROOT / "export"
FPS = 60
SR = 48000
SAMPLES_PER_FRAME = SR // FPS
BEAT = 60.0 / json.loads((ROOT / "assets/audio/music/music.json").read_text())["drive"]["bpm"]
MUSIC_BEAT0 = 0.054  # first beat of drive.ogg (librosa beat grid, 13 ms median residual)
MUSIC_DB = -5.0  # music bed under the game mix
TARGET_LUFS = -14.0

# (cue, offset from the cue in beats, length in beats). demo.gd cues each shot at its in-point
# (the car at the shot's `at` progress), the car passing a roadside camera (<shot>_pass), the
# first smash of soft dressing, the livery change and the title card.
EDIT = [
	("opener", 0.0, 4),  # low drone over the cherry valley
	("valley", 0.0, 5),  # the car at speed through the blossoms, a long lens on the road ahead
	("sign", -1.0, 5),  # past the hairpin warning signs into the hairpin
	("smash", -4, 8),  # slow motion: wide through the hay bales under the crowd
	("crowd", 3.8, 5),  # the next hairpin, under the fabric gate, the crowd on the bank
	("rail_pass", -6.5, 7),  # slow motion along the gravel guardrail
	("bridge", 0.5, 4),  # the road between the stages: over the stone bridge
	("village", 0.5, 5),  # down the festival street under its lanterns
	("momiji_bridge", -0.5, 4),  # Momiji at golden hour: over the river bridge
	("momiji_crane", 3.5, 5),  # a crane up from the hairpin
	("livery", -1.5, 5),  # the garage workshop: a new livery brushes on
	("card", -1.5, 11),  # the Hanami valley from the air under the title card
]
FADE_IN = 0.35
FADE_OUT = 1.4
MUSIC_FADE_OUT = 2.6


def run(cmd: list[str]) -> subprocess.CompletedProcess:
	p = subprocess.run(cmd, capture_output=True, text=True)
	if p.returncode != 0:
		sys.exit(f"{cmd[0]} failed:\n{p.stderr[-3000:]}")
	return p


def plan(cues: dict[str, float]) -> list[dict]:
	"""Source window (frames) and edit window (frames, beat-aligned) of every shot. Each window
	must lie inside the take's shot its cue falls in, a second after that shot's camera cut (the
	world streams in and the season settles around the new camera) and before its end."""
	takes = sorted((t, name[:-6]) for name, t in cues.items() if name.endswith("_start"))
	shots = []
	beat = 0.0
	for cue, offset, length in EDIT:
		if cue not in cues:
			sys.exit(f"cue {cue!r} missing from cues.json")
		edit0 = round(beat * BEAT * FPS)
		edit1 = round((beat + length) * BEAT * FPS)
		src0 = round((cues[cue] + offset * BEAT) * FPS)
		start, take = max((t, n) for t, n in takes if t <= cues[cue])
		end = cues[take + "_end"]
		if src0 / FPS < start + 1.0 or (src0 + edit1 - edit0) / FPS > end:
			sys.exit(f"{cue}: {src0 / FPS:.2f}-{(src0 + edit1 - edit0) / FPS:.2f} s leaves take shot "
					f"{take} ({start + 1.0:.2f}-{end:.2f} s)")
		shots.append({"cue": cue, "src0": src0, "frames": edit1 - edit0, "edit0": edit0, "beat0": beat})
		beat += length
	return shots


def game_audio(footage: Path, shots: list[dict], work: Path) -> np.ndarray:
	"""Each shot's own game audio, sliced sample-exact (Movie Maker mixes 800 samples a frame),
	with 6 ms fades at the cuts so they do not click."""
	wav = work / "footage.wav"
	run(["ffmpeg", "-v", "error", "-y", "-i", str(footage), "-vn", "-ac", "2", "-ar", str(SR),
			"-c:a", "pcm_f32le", str(wav)])
	src, sr = sf.read(wav, dtype="float32", always_2d=True)
	assert sr == SR
	fade = int(0.006 * SR)
	ramp = np.linspace(0.0, 1.0, fade, dtype=np.float32)[:, None]
	parts = []
	for s in shots:
		a = s["src0"] * SAMPLES_PER_FRAME
		n = s["frames"] * SAMPLES_PER_FRAME
		clip = np.zeros((n, 2), np.float32)
		got = src[max(a, 0):a + n]
		clip[:len(got)] = got
		clip[:fade] *= ramp
		clip[-fade:] *= ramp[::-1]
		parts.append(clip)
	return np.concatenate(parts)


def music_bed(total: int) -> np.ndarray:
	y, sr = sf.read(MUSIC, dtype="float32", always_2d=True)
	if sr != SR:
		g = np.gcd(sr, SR)
		y = resample_poly(y, SR // g, sr // g, axis=0).astype(np.float32)
	y = y[int(MUSIC_BEAT0 * SR):]
	if len(y) < total:
		sys.exit("edit is longer than the music track")
	gain = np.full(total, 10 ** (MUSIC_DB / 20.0), np.float32)
	start = int(0.02 * SR)
	gain[:start] *= np.linspace(0.0, 1.0, start)
	tail = int(MUSIC_FADE_OUT * SR)
	gain[-tail:] *= np.linspace(1.0, 0.0, tail) ** 2
	return y[:total] * gain[:, None]


def loudness(wav: Path) -> float:
	out = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", str(wav), "-af", "ebur128",
			"-f", "null", "-"], capture_output=True, text=True).stderr
	return float(re.findall(r"I:\s+(-?[\d.]+) LUFS", out)[-1])


def frame_size(footage: Path) -> tuple[int, int]:
	out = run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height",
			"-of", "csv=p=0", str(footage)]).stdout.strip()
	w, h = out.split(",")
	return int(w), int(h)


def encode(footage: Path, shots: list[dict], wav: Path, crop: str, mp4: Path) -> None:
	seconds = (shots[-1]["edit0"] + shots[-1]["frames"]) / FPS
	cmd = ["ffmpeg", "-v", "error", "-y"]
	graph = []
	for i, s in enumerate(shots):
		# Seek half a second early and trim by timestamp: a decoder that lands a frame late
		# after an input seek would otherwise shift the shot by a frame and run it one short
		# (the frame after it held for the rest of the shot's last frames).
		seek = max(s["src0"] / FPS - 0.5, 0.0)
		cmd += ["-ss", f"{seek:.6f}", "-t", f"{s['frames'] / FPS + 1.0:.6f}", "-i", str(footage)]
		graph.append(f"[{i}:v]trim=start={s['src0'] / FPS - seek:.6f},setpts=PTS-STARTPTS,"
				f"trim=end_frame={s['frames']},setpts=PTS-STARTPTS,{crop}[v{i}]")
	cmd += ["-i", str(wav)]
	# Movie Maker writes full-range BT.601 MJPEG. The delivery is limited-range BT.709 with the
	# tags written into the stream: X and YouTube re-encode uploads, and full range or an untagged
	# matrix is where re-encodes wash out or crush.
	graph.append("".join(f"[v{i}]" for i in range(len(shots)))
			+ f"concat=n={len(shots)}:v=1:a=0,fade=t=in:d={FADE_IN},"
			+ f"fade=t=out:st={seconds - FADE_OUT:.3f}:d={FADE_OUT},"
			+ "scale=in_range=full:in_color_matrix=bt601:out_range=limited:out_color_matrix=bt709,"
			+ "format=yuv420p,setparams=range=tv:colorspace=bt709:color_primaries=bt709:color_trc=bt709[v]")
	graph.append(f"[{len(shots)}:a]alimiter=limit=0.891:attack=4:release=60:level=false,"
			+ f"aresample={SR}[a]")
	cmd += ["-filter_complex", ";".join(graph), "-map", "[v]", "-map", "[a]",
			"-c:v", "libx264", "-preset", "slow", "-crf", "18", "-profile:v", "high",
			"-maxrate", "30M", "-bufsize", "60M", "-r", str(FPS),
			"-c:a", "aac", "-b:a", "256k", "-movflags", "+faststart", str(mp4)]
	run(cmd)
	# Contact sheet: the middle frame of every shot.
	mids = "+".join(f"eq(n\\,{s['edit0'] + s['frames'] // 2})" for s in shots)
	cols = 5 if "16x9" in mp4.name else 7
	rows = (len(shots) + cols - 1) // cols
	run(["ffmpeg", "-v", "error", "-y", "-i", str(mp4), "-vf",
			f"select={mids},scale=-1:360,tile={cols}x{rows}", "-frames:v", "1", "-fps_mode", "passthrough",
			str(mp4.with_name(mp4.stem + "_sheet.jpg"))])


def main() -> None:
	out = Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/sakura_trailer")
	footage = out / "raw.mkv"
	avi = out / "raw.avi"
	if avi.exists():
		# Movie Maker's AVI has no seek index: every -ss decodes from the first frame (~2 min per
		# shot deep in the take). A stream-copy remux to Matroska indexes it in seconds.
		run(["ffmpeg", "-v", "error", "-y", "-i", str(avi), "-map", "0", "-c", "copy", str(footage)])
		avi.unlink()
	cues: dict[str, float] = {}
	for c in json.loads((out / "cues.json").read_text()):
		cues.setdefault(c["name"], c["t"])
	shots = plan(cues)
	total_frames = shots[-1]["edit0"] + shots[-1]["frames"]
	total = total_frames * SAMPLES_PER_FRAME

	mix = game_audio(footage, shots, out) + music_bed(total)
	wav = out / "mix.wav"
	sf.write(wav, mix, SR, subtype="FLOAT")
	gain_db = TARGET_LUFS - loudness(wav)
	sf.write(wav, mix * np.float32(10 ** (gain_db / 20.0)), SR, subtype="FLOAT")

	w, h = frame_size(footage)
	band = w * 9 // 16 // 2 * 2
	column = h * 9 // 16 // 2 * 2
	EXPORT.mkdir(exist_ok=True)
	for name, crop in (("16x9", f"crop={w}:{band}:0:{(h - band) // 2}"),
			("9x16", f"crop={column}:{h}:{(w - column) // 2}:0")):
		mp4 = EXPORT / f"trailer_ep3_{name}.mp4"
		encode(footage, shots, wav, crop, mp4)
		print(f"{mp4}: {total_frames / FPS:.2f} s, {len(shots)} shots, {mp4.stat().st_size / 1e6:.1f} MB")
	print(f"take {w}x{h}, mix gain {gain_db:+.1f} dB")
	for s in shots:
		print(f"  {s['edit0'] / FPS:6.2f}s  beat {s['beat0']:5.1f}  {s['cue']:<14} src {s['src0'] / FPS:7.2f}s"
				f"  {s['frames'] / FPS:4.2f}s")


if __name__ == "__main__":
	main()
