#!/usr/bin/env bash
# "How the AI learned to drive": renders the footage offline with Movie Maker (1920x1080, 60 fps,
# MJPEG + PCM in an AVI) while tools/rl/film.gd drives the real game, then cuts the edit
# (tools/rl/cut_film.py). Like tools/video/render_demo.sh.
#   tools/rl/render_film.sh [out_dir]             # default /tmp/sakura_film
#   tools/rl/render_film.sh --cut-only [out_dir]  # re-cut existing footage
# The footage (~2.5 min, ~6 GB) renders offscreen and muted: Movie Maker records the game mix
# itself, so the Dummy audio driver only mutes the speakers. The offscreen window can still come
# to the front over a fullscreen app (Summer 0.5.68): one take, nothing else rendered.
set -euo pipefail
cd "$(dirname "$0")/../.."

CUT_ONLY=0
if [ "${1:-}" = "--cut-only" ]; then
	CUT_ONLY=1
	shift
fi
OUT="${1:-/tmp/sakura_film}"
SUMMER="${SUMMER:-/Applications/Summer.app/Contents/MacOS/Summer}"
mkdir -p "$OUT"

if [ "$CUT_ONLY" = 0 ]; then
	# Movie Maker records at the window-override size (1600x900 in project.godot). A temporary
	# override.cfg renders at 1080p without touching project.godot; it is removed on any exit.
	if [ -e override.cfg ]; then
		echo "override.cfg already exists; move it away first" >&2
		exit 1
	fi
	trap 'rm -f override.cfg' EXIT
	cat > override.cfg <<'EOF'
[display]

window/size/window_width_override=1920
window/size/window_height_override=1080

[editor]

movie_writer/video_quality=0.95
movie_writer/disable_vsync=true
EOF
	timeout -k 10 1800 nice -n 15 "$SUMMER" --summer-offscreen --audio-driver Dummy --disable-crash-handler \
		--path . --write-movie "$OUT/raw.avi" -s res://tools/rl/film.gd -- footage="$OUT"
	rm -f override.cfg
fi

uv run --python 3.12 tools/rl/cut_film.py "$OUT"
