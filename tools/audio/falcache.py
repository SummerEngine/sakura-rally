"""Cached fal.ai queue client for the Sakura Rally offline audio tools.

Every generation is keyed by a stable name. If `cache/<name>.<ext>` already exists the
call is skipped entirely, so generator scripts re-run from cached raw downloads without
spending generations. Every real call is appended to `fal_log.json` (the key is never logged).
"""

from __future__ import annotations

import json
import os
import subprocess
import time
import threading
from pathlib import Path

import numpy as np
import requests
import soundfile as sf

from audiolib import SR

HERE = Path(__file__).resolve().parent
CACHE = HERE / "cache"
LOG = HERE / "fal_log.json"
FFMPEG = "/opt/homebrew/bin/ffmpeg"
AUDIO_EXT = {".mp3", ".wav", ".flac", ".ogg", ".opus", ".m4a", ".aac"}


def _key() -> str:
    k = os.environ.get("FAL_KEY")
    if not k:
        raise RuntimeError("FAL_KEY is not set; it is only needed to generate uncached entries")
    return k


_LOCK = threading.Lock()


def _log(entry: dict) -> None:
    with _LOCK:
        data = json.loads(LOG.read_text()) if LOG.exists() else []
        data.append(entry)
        LOG.write_text(json.dumps(data, indent=2) + "\n")


def cached_path(name: str) -> Path | None:
    hits = [p for p in CACHE.glob(name + ".*") if p.suffix in AUDIO_EXT]
    return hits[0] if hits else None


def generate(name: str, model: str, params: dict, timeout_s: float = 900.0) -> Path:
    """Return the cached raw download for `name`, generating it via fal if missing."""
    hit = cached_path(name)
    if hit is not None:
        return hit
    CACHE.mkdir(parents=True, exist_ok=True)
    hdr = {"Authorization": f"Key {_key()}", "Content-Type": "application/json"}
    t0 = time.time()
    r = requests.post(f"https://queue.fal.run/{model}", headers=hdr, json=params, timeout=60)
    r.raise_for_status()
    sub = r.json()
    req_id = sub.get("request_id")
    status_url, response_url = sub["status_url"], sub["response_url"]
    while True:
        s = requests.get(status_url, headers=hdr, timeout=60).json()
        st = s.get("status")
        if st == "COMPLETED":
            break
        if st not in ("IN_QUEUE", "IN_PROGRESS"):
            _log({"name": name, "model": model, "params": params, "request_id": req_id,
                  "error": s, "time": time.strftime("%Y-%m-%dT%H:%M:%S")})
            raise RuntimeError(f"fal {model} {req_id}: {s}")
        if time.time() - t0 > timeout_s:
            raise TimeoutError(f"fal {model} {req_id} timed out")
        time.sleep(3)
    res = requests.get(response_url, headers=hdr, timeout=120)
    if res.status_code >= 400:
        _log({"name": name, "model": model, "params": params, "request_id": req_id,
              "error": res.text[:2000], "time": time.strftime("%Y-%m-%dT%H:%M:%S")})
        res.raise_for_status()
    out = res.json()
    audio = out["audio"]
    url = audio["url"]
    ext = Path(url.split("?")[0]).suffix or ".mp3"
    dest = CACHE / f"{name}{ext}"
    blob = requests.get(url, timeout=300)
    blob.raise_for_status()
    dest.write_bytes(blob.content)
    meta = {k: v for k, v in out.items() if k != "audio"}
    (CACHE / f"{name}.json").write_text(json.dumps(
        {"model": model, "params": params, "request_id": req_id, "response": meta,
         "audio": audio}, indent=2) + "\n")
    _log({"name": name, "model": model, "params": params, "request_id": req_id,
          "output_file": str(dest.relative_to(HERE.parents[1])), "response_extra": meta,
          "elapsed_s": round(time.time() - t0, 1), "time": time.strftime("%Y-%m-%dT%H:%M:%S")})
    return dest


def decode(path: Path, channels: int = 2, sr: int = SR) -> np.ndarray:
    """Decode any audio file to float64 (n, channels) at `sr` via ffmpeg."""
    raw = subprocess.run(
        [FFMPEG, "-v", "error", "-i", str(path), "-f", "f32le", "-acodec", "pcm_f32le",
         "-ac", str(channels), "-ar", str(sr), "-"],
        check=True, capture_output=True).stdout
    x = np.frombuffer(raw, dtype=np.float32).astype(np.float64)
    return x.reshape(-1, channels)


def source_info(path: Path) -> dict:
    info = sf.info(str(path)) if path.suffix in (".wav", ".flac", ".ogg") else None
    if info is not None:
        return {"sr": info.samplerate, "channels": info.channels, "dur": info.duration}
    probe = subprocess.run(
        ["/opt/homebrew/bin/ffprobe", "-v", "error", "-show_entries",
         "stream=sample_rate,channels:format=duration", "-of", "json", str(path)],
        check=True, capture_output=True, text=True).stdout
    d = json.loads(probe)
    st = d["streams"][0]
    return {"sr": int(st["sample_rate"]), "channels": int(st["channels"]),
            "dur": float(d["format"]["duration"])}
