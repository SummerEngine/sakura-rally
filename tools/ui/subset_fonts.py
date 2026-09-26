"""Download the UI fonts (SIL OFL 1.1, github.com/google/fonts) and subset them.

The full CJK fonts are ~22 MB, so the game ships subsets: Latin, punctuation, kana and
every CJK character found in the project's scripts/scenes (plus a small base list).
Re-run after adding new Japanese strings anywhere in `scripts/` or `scenes/`:

    cd <project root>
    uv venv tools/ui/.venv && uv pip install --python tools/ui/.venv/bin/python fonttools
    tools/ui/.venv/bin/python tools/ui/subset_fonts.py
    $S --headless --disable-crash-handler --path . --import
"""

from __future__ import annotations

import pathlib
import re
import shutil
import urllib.request

from fontTools import subset

ROOT = pathlib.Path(__file__).resolve().parents[2]
CACHE = ROOT / "tools" / "ui" / ".cache"
OUT = ROOT / "assets" / "fonts"
BASE_URL = "https://raw.githubusercontent.com/google/fonts/main/ofl/"

FONTS = {
    "ZenMaruGothic-Medium.ttf": "zenmarugothic",
    "ZenMaruGothic-Bold.ttf": "zenmarugothic",
    "ZenMaruGothic-Black.ttf": "zenmarugothic",
    "DelaGothicOne-Regular.ttf": "delagothicone",
    "YujiSyuku-Regular.ttf": "yujisyuku",
}

# Always-included kanji: numerals, seasons, medals and common racing words so small copy
# edits do not immediately need a re-subset.
BASE_KANJI = (
    "零一二三四五六七八九十百千万"
    "春夏秋冬朝昼夕夜空雲風雨雪花桜櫻紅葉楓山峠谷道路川海森林里村"
    "金銀銅完走出発新記録最速度時間秒分区記録休憩停止再開始戻設定"
    "音量画質変速機自動手動視点単位全面地図選択車色勝負旅"
)

RANGES = [
    (0x0020, 0x007E), (0x00A0, 0x00FF), (0x2010, 0x2027), (0x2030, 0x203A),
    (0x2190, 0x2193), (0x2212, 0x2212), (0x2022, 0x2022), (0x25B2, 0x25BC),
    (0x25CB, 0x25CF), (0x2605, 0x2606), (0x3000, 0x303F), (0x3040, 0x309F),
    (0x30A0, 0x30FF), (0xFF01, 0xFF5E),
]

CJK = re.compile(r"[\u3000-\u30ff\u3400-\u9fff\uf900-\ufaff\uff00-\uffef]")


def project_chars() -> set[str]:
    chars: set[str] = set()
    for folder in ("scripts", "scenes"):
        for path in (ROOT / folder).rglob("*"):
            if path.suffix in (".gd", ".tscn", ".tres") and path.is_file():
                chars.update(CJK.findall(path.read_text(encoding="utf-8", errors="ignore")))
    return chars


def fetch(name: str, family: str) -> pathlib.Path:
    CACHE.mkdir(parents=True, exist_ok=True)
    dest = CACHE / name
    if not dest.exists():
        print("downloading", name)
        urllib.request.urlretrieve(BASE_URL + family + "/" + name, dest)
    lic = CACHE / (family + "_OFL.txt")
    if not lic.exists():
        urllib.request.urlretrieve(BASE_URL + family + "/OFL.txt", lic)
    return dest


def main() -> None:
    codepoints: set[int] = set()
    for lo, hi in RANGES:
        codepoints.update(range(lo, hi + 1))
    text = BASE_KANJI + "".join(sorted(project_chars()))
    codepoints.update(ord(c) for c in text)
    OUT.mkdir(parents=True, exist_ok=True)
    for name, family in FONTS.items():
        src = fetch(name, family)
        options = subset.Options()
        options.layout_features = ["*"]
        options.name_IDs = ["*"]
        options.notdef_outline = True
        options.hinting = True
        font = subset.load_font(str(src), options)
        sub = subset.Subsetter(options)
        sub.populate(unicodes=codepoints)
        sub.subset(font)
        dest = OUT / name
        subset.save_font(font, str(dest), options)
        print(f"{name}: {src.stat().st_size // 1024} KB -> {dest.stat().st_size // 1024} KB")
    # All three families share the same OFL 1.1 text; keep one copy per family for attribution.
    for family in sorted(set(FONTS.values())):
        shutil.copy(CACHE / (family + "_OFL.txt"), OUT / f"OFL-{family}.txt")
    print("kanji/kana in project:", "".join(sorted(project_chars())))


if __name__ == "__main__":
    main()
