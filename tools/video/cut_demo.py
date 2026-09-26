#!/usr/bin/env python3
"""Cuts the demo reel from the Movie Maker footage (render_demo.sh runs it).

    cut_demo.py <out_dir>    # reads raw.avi + cues.json; writes sakura_rally_demo.mp4 + sheet.jpg

Shots are addressed by the cues demo.gd logged. Every cut lands on the beat of the drive theme,
each shot keeps its own game audio (engine, gravel, UI stingers) under one continuous music bed,
and the mix is normalised to -14 LUFS through a -1 dBFS sample-peak limiter (AAC encoding
lifts the true peak to about -0.7 dBTP).
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
FPS = 60
SR = 48000
SAMPLES_PER_FRAME = SR // FPS
BEAT = 60.0 / json.loads((ROOT / "assets/audio/music/music.json").read_text())["drive"]["bpm"]
MUSIC_BEAT0 = 0.054  # first beat of drive.ogg (librosa beat grid, 13 ms median residual)
MUSIC_DB = -5.0  # music bed under the game mix
TARGET_LUFS = -14.0

# (cue, offset from the cue in beats, length in beats[, options]). Offsets keep an event on the
# grid: ("racing_1", -5, 8) puts GO on the sixth beat of an eight-beat shot.
# Options: "duck": (db, until_beat) holds the music down from the shot start until that beat.
EDIT = [
	("hanami_00_tracking", 0.5, 4),  # cold open: tracking through the blossom
	("hanami_01_wheel", 0.5, 4),  # the wheel turning, suspension working
	("menu_1", 1.0, 8),  # title card brushing in over the drifting flyover
	("garage_livery", -2, 6),  # garage: the next livery brushes onto the parked car
	("time_attack_start", -4, 5),  # Time Attack cards, Hanami picked
	("intro_1", 0.0, 4),  # intro swoop, HANAMI PASS card
	("racing_1", -5, 8, {"duck": (-15.0, 5)}),  # countdown revs under a quiet bed, GO! hits
	("hanami_gate_0", -3, 5),  # through the first fabric checkpoint gate
	("hanami_smash", -4, 6),  # tarmac hairpin: sideways and wide through the hay bales
	("hanami_04_drone", 0.5, 4),  # the valley from above
	("hanami_05_pass", -3, 4),  # the tightest corner
	("hanami_10_pass", -3, 4),  # over the river bridge
	("hanami_11_tracking", 0.5, 4),  # onto gravel: dust
	("hanami_14_pass", -5, 10),  # slow motion through the gravel esses
	("finished_1", -3, 8),  # FINISH
	("finished_1", 5, 6),  # results card, gold stamp
	("intro_2", 0.0, 4),  # Momiji, golden hour
	("momiji_00_drone", 7.0, 4),  # the road curving through the maples (earlier: a roof fills the frame)
	("momiji_03_pass", -3, 4),  # the bridge
	("momiji_04_tracking", 0.5, 4),  # gravel through the maples
	("momiji_05_pass", -5, 10),  # slow motion through the hairpin
	("momiji_08_wheel", 0.5, 4),
	("title_end", 1.0, 8),  # end card: the title over Momiji
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
	"""Source window (frames) and edit window (frames, beat-aligned) of every shot."""
	shots = []
	beat = 0.0
	for entry in EDIT:
		cue, offset, length = entry[:3]
		options = entry[3] if len(entry) > 3 else {}
		if cue not in cues:
			sys.exit(f"cue {cue!r} missing from cues.json")
		edit0 = round(beat * BEAT * FPS)
		edit1 = round((beat + length) * BEAT * FPS)
		src0 = round((cues[cue] + offset * BEAT) * FPS)
		shots.append({"cue": cue, "src0": src0, "frames": edit1 - edit0, "edit0": edit0,
				"beat0": beat, "options": options})
		beat += length
	return shots


def game_audio(avi: Path, shots: list[dict], work: Path) -> np.ndarray:
	"""Each shot's own game audio, sliced sample-exact (Movie Maker mixes 800 samples a frame),
	with 6 ms fades at the cuts so they do not click."""
	wav = work / "footage.wav"
	run(["ffmpeg", "-v", "error", "-y", "-i", str(avi), "-vn", "-ac", "2", "-ar", str(SR),
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


def music_bed(total: int, shots: list[dict]) -> np.ndarray:
	y, sr = sf.read(MUSIC, dtype="float32", always_2d=True)
	if sr != SR:
		g = np.gcd(sr, SR)
		y = resample_poly(y, SR // g, sr // g, axis=0).astype(np.float32)
	y = y[int(MUSIC_BEAT0 * SR):]
	if len(y) < total:
		sys.exit("edit is longer than the music track")
	y = y[:total].copy()
	full = 10 ** (MUSIC_DB / 20.0)
	gain = np.full(total, full, np.float32)
	for s in shots:
		if "duck" in s["options"]:
			db, until = s["options"]["duck"]
			low = 10 ** ((MUSIC_DB + db) / 20.0)
			a = s["edit0"] * SAMPLES_PER_FRAME
			b = round((s["beat0"] + until) * BEAT * SR)
			down = min(int(0.25 * SR), a)  # eases down over the previous shot's tail
			gain[a - down:a] = np.linspace(full, low, down)
			gain[a:b] = low
			up = int(0.012 * SR)  # back up on the hit: fast, but not a click
			gain[b:b + up] = np.linspace(low, full, up)
	start = int(0.02 * SR)
	gain[:start] *= np.linspace(0.0, 1.0, start)
	tail = int(MUSIC_FADE_OUT * SR)
	gain[-tail:] *= np.linspace(1.0, 0.0, tail) ** 2
	return y * gain[:, None]


def loudness(wav: Path) -> float:
	out = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", str(wav), "-af", "ebur128",
			"-f", "null", "-"], capture_output=True, text=True).stderr
	return float(re.findall(r"I:\s+(-?[\d.]+) LUFS", out)[-1])


def main() -> None:
	out = Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/sakura_demo")
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
	seconds = total_frames / FPS

	mix = game_audio(footage, shots, out) + music_bed(total, shots)
	wav = out / "mix.wav"
	sf.write(wav, mix, SR, subtype="FLOAT")
	gain_db = TARGET_LUFS - loudness(wav)
	sf.write(wav, mix * np.float32(10 ** (gain_db / 20.0)), SR, subtype="FLOAT")

	cmd = ["ffmpeg", "-v", "error", "-y"]
	graph = []
	for i, s in enumerate(shots):
		cmd += ["-ss", f"{(s['src0'] - 0.25) / FPS:.6f}", "-t", f"{(s['frames'] + 2) / FPS:.6f}",
				"-i", str(footage)]
		graph.append(f"[{i}:v]trim=end_frame={s['frames']},setpts=PTS-STARTPTS[v{i}]")
	cmd += ["-i", str(wav)]
	# Movie Maker writes full-range BT.601 MJPEG. The delivery is limited-range BT.709 with the
	# tags written into the stream: X re-encodes uploads, and full range or an untagged matrix
	# is where re-encodes wash out or crush.
	graph.append("".join(f"[v{i}]" for i in range(len(shots)))
			+ f"concat=n={len(shots)}:v=1:a=0,fade=t=in:d={FADE_IN},"
			+ f"fade=t=out:st={seconds - FADE_OUT:.3f}:d={FADE_OUT},"
			+ "scale=in_range=full:in_color_matrix=bt601:out_range=limited:out_color_matrix=bt709,"
			+ "format=yuv420p,setparams=range=tv:colorspace=bt709:color_primaries=bt709:color_trc=bt709[v]")
	graph.append(f"[{len(shots)}:a]alimiter=limit=0.891:attack=4:release=60:level=false,"
			+ f"aresample={SR}[a]")
	mp4 = out / "sakura_rally_demo.mp4"
	cmd += ["-filter_complex", ";".join(graph), "-map", "[v]", "-map", "[a]",
			"-c:v", "libx264", "-preset", "slow", "-crf", "18", "-profile:v", "high",
			"-maxrate", "30M", "-bufsize", "60M", "-r", str(FPS),
			"-c:a", "aac", "-b:a", "256k", "-movflags", "+faststart", str(mp4)]
	run(cmd)

	# Contact sheet: the middle frame of every shot.
	mids = "+".join(f"eq(n\\,{s['edit0'] + s['frames'] // 2})" for s in shots)
	rows = (len(shots) + 3) // 4
	run(["ffmpeg", "-v", "error", "-y", "-i", str(mp4), "-vf",
			f"select={mids},scale=480:-1,tile=4x{rows}", "-frames:v", "1", "-fps_mode", "passthrough",
			str(out / "sheet.jpg")])
	print(f"{mp4}: {seconds:.2f} s, {len(shots)} shots, mix gain {gain_db:+.1f} dB, "
			f"{mp4.stat().st_size / 1e6:.1f} MB")
	for s in shots:
		print(f"  {s['edit0'] / FPS:6.2f}s  beat {s['beat0']:5.1f}  {s['cue']:<22} src {s['src0'] / FPS:7.2f}s")


if __name__ == "__main__":
	main()
