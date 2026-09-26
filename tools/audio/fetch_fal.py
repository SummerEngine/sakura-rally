"""Fetch every fal generation in audio_specs (parallel). Cached names are skipped.

Usage: tools/audio/.venv/bin/python tools/audio/fetch_fal.py [name ...]
"""

import sys
from concurrent.futures import ThreadPoolExecutor, as_completed

import falcache
from audio_specs import MUSIC, SFX


def main(names: list[str]) -> None:
    specs = {**MUSIC, **SFX}
    todo = names or list(specs)
    with ThreadPoolExecutor(max_workers=8) as ex:
        futs = {ex.submit(falcache.generate, n, specs[n]["model"], specs[n]["params"]): n
                for n in todo}
        for f in as_completed(futs):
            n = futs[f]
            try:
                print(f"OK   {n}: {f.result()}", flush=True)
            except Exception as e:  # report and keep fetching the rest
                print(f"FAIL {n}: {e}", flush=True)


if __name__ == "__main__":
    main(sys.argv[1:])
