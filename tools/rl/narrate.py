# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "soundfile", "faster-whisper"]
# ///
"""Voices the film's narration (tools/rl/film.json), times every word and lays the edit out.

    ELEVENLABS_API_KEY=... uv run --python 3.12 tools/rl/narrate.py <out_dir> [voice ...]

For each voice in film.json's "voices" (or only those named): every line through ElevenLabs
text-to-speech (the neighbouring lines go along as previous_text / next_text, so the reading
flows from line to line), trimmed of the silence around it and saved as
<out_dir>/voice/<voice>/NN.wav (24 kHz mono). faster-whisper then times its words, and the
recognised words are matched back to the script's, so captions show the script's spelling
("forty-six", not "46"); a script word it missed takes its time from its neighbours. A line
keeps its audio while its text, its neighbours and the voice's settings stay the same (the key
is in NN.json), so editing one line re-voices that line only.

The layout (the same for every voice, from each voice's own line lengths): the first line
starts after LEAD_S; lines of one shot follow each other after GAP_S (plus a line's "pause");
the next shot cuts in CUT_LEAD_S before its first line, which starts SHOT_GAP_S after the last
line of the shot before; a shot lasts at least its "min" seconds in film.json (the time is
added after its last line); the last shot holds END_S after the last line. Writes
<out_dir>/voice/<voice>/edit.json: {length, lines: [{file, t0, t1, words: [{w, t0, t1}]}],
shots: [{tag, t0, t1}]} in edit seconds, and <out_dir>/voice/lengths.json: per shot the longest
any voice keeps it on screen (film.gd renders each shot that long).
"""
import difflib
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

import numpy as np
import soundfile as sf

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "tools/rl/film.json"
SR = 24000
LEAD_S = 0.15
GAP_S = 0.22
SHOT_GAP_S = 0.45
CUT_LEAD_S = 0.2
END_S = 3.0
# silence: below this (dBFS, 10 ms windows) at either end is trimmed, TRIM_KEEP_S kept
SILENCE_DB = -45.0
TRIM_KEEP_S = 0.03


def tts(voice: dict, text: str, prev: str, nxt: str) -> np.ndarray:
	key = os.environ.get("ELEVENLABS_API_KEY")
	if not key:
		sys.exit("narrate: set ELEVENLABS_API_KEY")
	body = {"text": text, "model_id": voice["model"], "voice_settings": voice["settings"], "seed": voice.get("seed", 1)}
	if voice["model"] != "eleven_v3":  # v3 takes no request stitching
		body["previous_text"] = prev
		body["next_text"] = nxt
	req = urllib.request.Request(
		f"https://api.elevenlabs.io/v1/text-to-speech/{voice['id']}?output_format=pcm_{SR}",
		data=json.dumps(body).encode(), headers={"Content-Type": "application/json", "xi-api-key": key})
	try:
		with urllib.request.urlopen(req, timeout=180) as r:
			pcm = r.read()
	except urllib.error.HTTPError as e:
		sys.exit(f"narrate: ElevenLabs HTTP {e.code}: {e.read()[:300]!r}")
	return np.frombuffer(pcm, dtype="<i2").astype(np.float32) / 32768.0


def trim(a: np.ndarray) -> np.ndarray:
	win = SR // 100
	n = len(a) // win
	db = 20 * np.log10(np.sqrt(np.mean(a[: n * win].reshape(n, win) ** 2, axis=1)) + 1e-9)
	loud = np.flatnonzero(db > SILENCE_DB)
	if loud.size == 0:
		return a
	keep = int(TRIM_KEEP_S * SR)
	return a[max(loud[0] * win - keep, 0): min((loud[-1] + 1) * win + keep, len(a))]


def norm(w: str) -> str:
	return re.sub(r"[^a-z0-9]", "", w.lower())


def time_words(model, wav: Path, text: str) -> list[dict]:
	"""The script's words with times from whisper; a word it did not match takes its time from
	its matched neighbours, shared out by letters."""
	segs, _ = model.transcribe(str(wav), word_timestamps=True, language="en", beam_size=5,
		initial_prompt=text)
	heard = [w for s in segs for w in s.words]
	words = text.split()
	times: list[tuple[float, float] | None] = [None] * len(words)
	sm = difflib.SequenceMatcher(a=[norm(w) for w in words], b=[norm(h.word) for h in heard], autojunk=False)
	for blk in sm.get_matching_blocks():
		for i in range(blk.size):
			h = heard[blk.b + i]
			times[blk.a + i] = (h.start, h.end)
	length = sf.info(str(wav)).duration
	i = 0
	while i < len(words):
		if times[i] is not None:
			i += 1
			continue
		j = i
		while j < len(words) and times[j] is None:
			j += 1
		t0 = times[i - 1][1] if i > 0 else 0.0
		t1 = times[j][0] if j < len(words) else length
		letters = [max(len(norm(w)), 1) for w in words[i:j]]
		at = t0
		for k, n in enumerate(letters):
			span = (t1 - t0) * n / sum(letters)
			times[i + k] = (at, at + span)
			at += span
		i = j
	return [{"w": w, "t0": round(t[0], 3), "t1": round(t[1], 3)} for w, t in zip(words, times)]


def voice_lines(script: dict, name: str, out: Path, model) -> list[dict]:
	voice = script["voices"][name]
	lines = script["lines"]
	folder = out / "voice" / name
	folder.mkdir(parents=True, exist_ok=True)
	done = []
	for i, line in enumerate(lines):
		prev = lines[i - 1]["say"] if i > 0 else ""
		nxt = lines[i + 1]["say"] if i + 1 < len(lines) else ""
		key = hashlib.sha1(json.dumps([voice, line["say"], prev, nxt], sort_keys=True).encode()).hexdigest()
		wav, meta = folder / f"{i:02d}.wav", folder / f"{i:02d}.json"
		if meta.exists() and wav.exists() and json.loads(meta.read_text()).get("key") == key:
			done.append(json.loads(meta.read_text()))
			continue
		audio = trim(tts(voice, line["say"], prev, nxt))
		sf.write(wav, audio, SR)
		info = {"key": key, "file": wav.name, "length": round(len(audio) / SR, 3),
			"words": time_words(model, wav, line["say"])}
		meta.write_text(json.dumps(info, indent=1))
		done.append(info)
		print(f"narrate {name} {i:02d} {info['length']:5.2f} s  {line['say']}")
	return done


def layout(script: dict, voiced: list[dict]) -> dict:
	lines = script["lines"]
	mins = {tag: float(s.get("min", 0.0)) for tag, s in script.get("shots", {}).items()}
	out_lines, shots = [], []
	t = LEAD_S
	for i, (line, v) in enumerate(zip(lines, voiced)):
		tag = line["shot"]
		if not shots or shots[-1]["tag"] != tag:
			if shots:
				t += SHOT_GAP_S
				cut = t - CUT_LEAD_S
				# a shot shorter than its min: the time goes after its last line
				short = mins.get(shots[-1]["tag"], 0.0) - (cut - shots[-1]["t0"])
				if short > 0:
					t += short
					cut += short
				shots[-1]["t1"] = round(cut, 3)
			shots.append({"tag": tag, "t0": round(t - CUT_LEAD_S, 3) if shots else 0.0})
		elif i > 0:
			t += GAP_S
		words = [{"w": w["w"], "t0": round(t + w["t0"], 3), "t1": round(t + w["t1"], 3)} for w in v["words"]]
		out_lines.append({"file": v["file"], "t0": round(t, 3), "t1": round(t + v["length"], 3), "words": words})
		t += v["length"] + float(line.get("pause", 0.0))
	end = max(t + END_S, shots[-1]["t0"] + mins.get(shots[-1]["tag"], 0.0))
	shots[-1]["t1"] = round(end, 3)
	return {"length": round(end, 3), "lines": out_lines, "shots": shots}


def main() -> None:
	if len(sys.argv) < 2:
		sys.exit(__doc__)
	out = Path(sys.argv[1])
	script = json.loads(SCRIPT.read_text())
	names = sys.argv[2:] or list(script["voices"])
	from faster_whisper import WhisperModel
	model = WhisperModel("small.en", device="cpu", compute_type="int8")
	lengths: dict[str, float] = {}
	lf = out / "voice" / "lengths.json"
	for name in script["voices"]:
		voiced = voice_lines(script, name, out, model) if name in names else None
		edit_file = out / "voice" / name / "edit.json"
		if voiced is not None:
			edit = layout(script, voiced)
			edit_file.write_text(json.dumps(edit, indent=1))
			print(f"narrate {name}: {edit['length']:.1f} s, " + ", ".join(f"{s['tag']} {s['t1'] - s['t0']:.1f}" for s in edit["shots"]))
		elif edit_file.exists():
			edit = json.loads(edit_file.read_text())
		else:
			continue
		for s in edit["shots"]:
			lengths[s["tag"]] = round(max(lengths.get(s["tag"], 0.0), s["t1"] - s["t0"]), 3)
	lf.write_text(json.dumps(lengths, indent=1))


if __name__ == "__main__":
	main()
