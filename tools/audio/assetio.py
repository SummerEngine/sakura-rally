"""Asset writing/metering helpers shared by the Sakura Rally music/ambience generators."""

from __future__ import annotations

import math
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy import signal

from audiolib import SR


def write_ogg(path: Path | str, x: np.ndarray, sr: int = SR, quality: float = 0.6) -> Path:
    """OGG Vorbis writer. libsndfile 1.2.2 segfaults on one huge Vorbis write, so stream it
    in blocks. quality 0..1 maps to Vorbis VBR quality (0.6 ~ q6, ~190 kbps stereo)."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    y = np.ascontiguousarray(np.clip(x, -1.0, 1.0).astype(np.float32))
    ch = 1 if y.ndim == 1 else y.shape[1]
    with sf.SoundFile(str(path), "w", sr, ch, format="OGG", subtype="VORBIS",
                      compression_level=1.0 - quality) as f:
        for i in range(0, len(y), 16384):
            f.write(y[i:i + 16384])
    return path


def read_any(path: Path | str) -> tuple[np.ndarray, int]:
    x, sr = sf.read(str(path), dtype="float64", always_2d=True)
    return x, sr


def true_peak_db(x: np.ndarray) -> float:
    """4x-oversampled peak (BS.1770 style true-peak approximation)."""
    up = signal.resample_poly(x, 4, 1, axis=0)
    return 20 * math.log10(float(np.max(np.abs(up))) + 1e-12)
