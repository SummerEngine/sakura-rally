#!/usr/bin/env bash
# Demo reel for X. Renders the footage offline with Movie Maker (1920x1080, 60 fps, MJPEG + PCM
# in an AVI) while tools/video/demo.gd drives the real game, then cuts the edit (cut_demo.py).
#   tools/video/render_demo.sh [out_dir]             # default /tmp/sakura_demo
#   tools/video/render_demo.sh --cut-only [out_dir]  # re-cut existing footage
# The footage (4.4 min, ~11 GB) renders in ~10 min on an M-series Mac; the cut takes ~3 min.
set -euo pipefail
cd "$(dirname "$0")/../.."

CUT_ONLY=0
if [ "${1:-}" = "--cut-only" ]; then
	CUT_ONLY=1
	shift
fi
OUT="${1:-/tmp/sakura_demo}"
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
	"$SUMMER" --disable-crash-handler --path . --write-movie "$OUT/raw.avi" \
		-s res://tools/video/demo.gd -- out="$OUT"
	rm -f override.cfg
fi

tools/audio/.venv/bin/python tools/video/cut_demo.py "$OUT"
