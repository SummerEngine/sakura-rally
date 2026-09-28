#!/usr/bin/env bash
# Episode 3 trailer. Renders the take offline with Movie Maker (1920x1920, 60 fps, MJPEG + PCM in
# an AVI) while tools/video/demo.gd drives the real game, then cuts the 16:9 and the 9:16 edit
# from that one square take (cut_demo.py).
#   tools/video/render_demo.sh [out_dir]             # default /tmp/sakura_trailer
#   tools/video/render_demo.sh --cut-only [out_dir]  # re-cut existing footage
#   tools/video/render_demo.sh --stills [out_dir]    # 2560x1440 PNG stills, no UI:
#                                                    # export/trailer_ep3_stills/
#   tools/video/render_demo.sh --frames [out_dir]    # composition check: 1080x1080, five frames a shot
# The take (~2 min of footage, ~12 GB) renders at ~20 % of real time under nice; the cut takes a few
# minutes. Nothing shows on screen and nothing plays aloud: --summer-offscreen keeps the window
# hidden, Movie Maker records the game mix itself, and the Dummy audio driver only mutes the
# speakers. Every render holds /tmp/sakura-render.lock, so renders on this Mac run one at a time.
set -euo pipefail
cd "$(dirname "$0")/../.."

MODE=take
case "${1:-}" in
	--cut-only) MODE=cut; shift ;;
	--stills) MODE=stills; shift ;;
	--frames) MODE=frames; shift ;;
esac
OUT="${1:-/tmp/sakura_trailer}"
# The engine: $SUMMER, else the agents' dev build when this Mac has one, else the installed
# Summer. The render opens an offscreen window, which Summer 0.5.68 puts on screen at the top
# left of the active Space (over a fullscreen video too, and a click on it leaves fullscreen);
# the dev build (0.5.68 with SummerEngine PR #397) keeps it transparent and click-through.
DEV_SUMMER="$HOME/opt/summer-dev/SummerDev.app/Contents/MacOS/Summer"
if [ -z "${SUMMER:-}" ]; then
	SUMMER=/Applications/Summer.app/Contents/MacOS/Summer
	if [ -x "$DEV_SUMMER" ]; then
		SUMMER="$DEV_SUMMER"
	fi
fi
mkdir -p "$OUT"

# render <width> <height> <engine args...>: the window size comes from a temporary override.cfg
# (Movie Maker records at the window-override size, 1600x900 in project.godot), removed on any exit.
render() {
	if [ -e override.cfg ]; then
		echo "override.cfg already exists; move it away first" >&2
		exit 1
	fi
	trap 'rm -f override.cfg' EXIT
	cat > override.cfg <<EOF
[display]

window/size/window_width_override=$1
window/size/window_height_override=$2

[editor]

movie_writer/video_quality=0.95
movie_writer/disable_vsync=true
EOF
	shift 2
	/usr/bin/lockf -k /tmp/sakura-render.lock timeout -k 10 3600 nice -n 15 "$SUMMER" --summer-offscreen \
		--audio-driver Dummy --disable-crash-handler --path . "$@" > "$OUT/log.txt" 2>&1 || true
	rm -f override.cfg
	grep -E "^(CUE|SHOT|DONE|TIMEOUT)|SCRIPT ERROR|Parse Error" "$OUT/log.txt" || true
	if grep -q "SCRIPT ERROR\|Parse Error\|TIMEOUT" "$OUT/log.txt" || ! grep -q "^DONE" "$OUT/log.txt"; then
		echo "render failed: see $OUT/log.txt" >&2
		exit 1
	fi
}

case "$MODE" in
	take)
		rm -f "$OUT/raw.avi" "$OUT/raw.mkv"
		render 1920 1920 --write-movie "$OUT/raw.avi" -s res://tools/video/demo.gd -- footage="$OUT"
		;;
	stills)
		rm -rf "$OUT/stills"
		render 2560 1440 --fixed-fps 60 -s res://tools/video/demo.gd -- footage="$OUT" stills="$OUT/stills"
		rm -rf export/trailer_ep3_stills
		mkdir -p export/trailer_ep3_stills
		for f in "$OUT"/stills/*.png; do
			b=$(basename "$f")
			cp "$f" "export/trailer_ep3_stills/${b%_*}.png"
		done
		ls export/trailer_ep3_stills
		exit 0
		;;
	frames)
		render 1080 1080 --fixed-fps 60 -s res://tools/video/demo.gd -- footage="$OUT" stills="$OUT/frames" frames=5
		exit 0
		;;
esac

uv run --python 3.12 tools/video/cut_demo.py "$OUT"
