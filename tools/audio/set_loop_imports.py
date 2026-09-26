"""Bake loop settings into Godot .import files for every audio asset.

- WAV: uncompressed PCM (`compress/mode=0`, exact seams, clean pitch shifting); loops get
  `edit/loop_mode=2` (forward) over the whole file, one-shots `edit/loop_mode=1` (disabled).
- OGG music: `loop=true`, `loop_offset` from assets/audio/music/music.json (seconds).
- OGG ambience: `loop=true`, `loop_offset=0`.

Workflow: write assets -> Godot `--import` (creates .import files) -> run this script ->
Godot `--import` again (re-imports with the patched params). Idempotent.
Run: tools/audio/.venv/bin/python tools/audio/set_loop_imports.py
"""

from __future__ import annotations

import fnmatch
import json
import re
from pathlib import Path

import audiolib as al

WAV_LOOPS = ["engine_on_*", "engine_off_*", "engine_idle", "turbo_whistle", "gear_whine",
             "tyre_*", "wind", "horn"]


def set_params(path: Path, values: dict[str, str]) -> bool:
    text = path.read_text()
    changed = False
    for key, val in values.items():
        pat = re.compile(rf"^{re.escape(key)}=.*$", re.M)
        line = f"{key}={val}"
        if pat.search(text):
            new = pat.sub(line, text)
        else:
            new = text.rstrip("\n") + f"\n{line}\n"
        changed |= new != text
        text = new
    if changed:
        path.write_text(text)
    return changed


def main() -> None:
    music_meta = {}
    mj = al.ASSETS / "music" / "music.json"
    if mj.exists():
        music_meta = json.loads(mj.read_text())
    count = 0
    for imp in sorted(al.ASSETS.rglob("*.import")):
        src = imp.with_suffix("")
        stem = src.stem
        if src.suffix == ".wav":
            loop = any(fnmatch.fnmatch(stem, p) for p in WAV_LOOPS)
            vals = {"compress/mode": "0", "edit/loop_mode": "2" if loop else "1",
                    "edit/loop_begin": "0", "edit/loop_end": "-1", "edit/trim": "false",
                    "edit/normalize": "false"}
        elif src.suffix == ".ogg" and src.parent.name == "music":
            offset = float(music_meta.get(stem, {}).get("loop_offset", 0.0))
            vals = {"loop": "true", "loop_offset": repr(offset)}
        elif src.suffix == ".ogg":
            vals = {"loop": "true", "loop_offset": "0.0"}
        else:
            continue
        if set_params(imp, vals):
            count += 1
            print("patched", imp.relative_to(al.ROOT))
    print(f"{count} import files changed")


if __name__ == "__main__":
    main()
