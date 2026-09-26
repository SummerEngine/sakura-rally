"""Objective checks for audio assets: levels, loop seams, spectrogram + seam PNGs.

Usage:
  tools/audio/.venv/bin/python tools/audio/analyze.py [paths or dirs ...] [--loops PATTERN ...]

Defaults to every .wav/.ogg under assets/audio. Files whose name matches a loop pattern
(default: engine_*, turbo_whistle, gear_whine, tyre_*, wind, horn, ambience/*) also get a
seam report and a seam-view PNG (the last 40 ms spliced to the first 40 ms, the exact
waveform the player hears at the wrap). PNGs go to tools/audio/renders/<subdir>/.
Prints one line per file and writes tools/audio/renders/report.json.
"""

from __future__ import annotations

import fnmatch
import json
import sys
from pathlib import Path

import numpy as np

import audiolib as al

DEFAULT_LOOPS = ["engine_*", "turbo_whistle*", "gear_whine*", "tyre_*", "wind*", "horn*",
                 "*/ambience/*"]


def seam_png(x: np.ndarray, sr: int, path: Path, title: str) -> None:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    w = int(0.04 * sr)
    joined = np.concatenate([x[-w:], x[:w]])
    t = (np.arange(joined.size) - w) / sr * 1000.0
    fig, ax = plt.subplots(figsize=(12, 3))
    ax.plot(t, joined, lw=0.7, color="#2a2235")
    ax.axvline(0, color="#e44a30", lw=0.8)
    ax.set_xlabel("ms around loop wrap (red line)")
    ax.set_title(title)
    fig.tight_layout()
    path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(path, dpi=80)
    plt.close(fig)


def main(argv: list[str]) -> None:
    loops = DEFAULT_LOOPS
    if "--loops" in argv:
        i = argv.index("--loops")
        loops = argv[i + 1:]
        argv = argv[:i]
    targets = [Path(a) for a in argv] or [al.ASSETS]
    files: list[Path] = []
    for tgt in targets:
        if tgt.is_dir():
            files += sorted(p for p in tgt.rglob("*") if p.suffix in (".wav", ".ogg"))
        else:
            files.append(tgt)
    report = {}
    for p in files:
        x, sr = al.read_wav(p)
        rel = p.relative_to(al.ROOT) if p.is_relative_to(al.ROOT) else p
        sub = p.parent.name
        is_loop = any(fnmatch.fnmatch(p.stem, pat) or fnmatch.fnmatch(str(rel), pat) for pat in loops)
        entry = {
            "seconds": round(x.size / sr, 3),
            "peak_dbfs": round(al.peak_db(x), 2),
            "lufs": round(al.lufs(x, sr), 2),
            "dc": round(float(np.mean(x)), 5),
        }
        if is_loop:
            entry["seam"] = {k: round(v, 4) for k, v in al.seam_metrics(x).items()}
            seam_png(x, sr, al.RENDERS / sub / f"{p.stem}_seam.png", f"{rel} loop wrap")
        al.spectrogram_png(x, al.RENDERS / sub / f"{p.stem}.png",
                           f"{rel}  peak {entry['peak_dbfs']} dBFS  {entry['lufs']} LUFS", sr=sr)
        report[str(rel)] = entry
        seam_txt = f" seam/p99={entry['seam']['wrap_jump_over_p99_step']:.3f}" if is_loop else ""
        print(f"{str(rel):55s} {entry['seconds']:7.2f}s peak {entry['peak_dbfs']:6.2f} "
              f"LUFS {entry['lufs']:7.2f}{seam_txt}")
    out = al.RENDERS / "report.json"
    old = json.loads(out.read_text()) if out.exists() else {}
    old.update(report)
    al.save_manifest(out, old)


if __name__ == "__main__":
    main(sys.argv[1:])
