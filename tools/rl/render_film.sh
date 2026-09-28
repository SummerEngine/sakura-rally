#!/usr/bin/env bash
# "How the AI learned to drive": records the AI's practice as replays (tools/rl/swarm.gd,
# headless: each generation's 64 cars from the start line), renders the footage offline with
# Movie Maker (1920x1080, 60 fps, MJPEG in an AVI; the replays are silent) while
# tools/rl/film.gd plays those replays back, then cuts the edit (tools/rl/cut_film.py). Like
# tools/video/render_demo.sh.
#   tools/rl/render_film.sh [out_dir]              # default /tmp/sakura_film
#   tools/rl/render_film.sh --no-record [out_dir]  # render and cut from the recordings there
#   tools/rl/render_film.sh --cut-only [out_dir]   # re-cut existing footage
# Recordings go to <out_dir>/swarm (under 100 MB, ~5 min), the footage to <out_dir>/raw.mkv
# (~3.5 GB). The recording runs headless; only the render needs pixels, offscreen, with the
# engine SUMMER picks below.
set -euo pipefail
cd "$(dirname "$0")/../.."

STEP=all
case "${1:-}" in
	--no-record) STEP=render; shift ;;
	--cut-only) STEP=cut; shift ;;
esac
OUT="${1:-/tmp/sakura_film}"
SWARM="$OUT/swarm"
# The engine: $SUMMER, else the agents' dev build when this Mac has one, else the installed
# Summer. The render opens an offscreen window, which Summer 0.5.68 puts on screen at the top
# left of the active Space (over a fullscreen video too, and a click on it leaves fullscreen);
# the dev build (0.5.68 with SummerEngine PR #397) keeps it transparent and click-through
# (docs/CONTRACTS.md).
DEV_SUMMER="$HOME/opt/summer-dev/SummerDev.app/Contents/MacOS/Summer"
if [ -z "${SUMMER:-}" ]; then
	SUMMER=/Applications/Summer.app/Contents/MacOS/Summer
	if [ -x "$DEV_SUMMER" ]; then
		SUMMER="$DEV_SUMMER"
	fi
fi
mkdir -p "$OUT"

if [ "$STEP" = all ]; then
	# What film.gd shows: GENERATIONS on Hanami, and SHIPPED on Hanami and on Momiji, in four
	# processes of about equal length (a 64-car swarm of a late generation takes ~3 min).
	rm -rf "$SWARM"
	mkdir -p "$SWARM"
	record() {
		timeout -k 10 1800 nice -n 10 "$SUMMER" --headless --disable-crash-handler --fixed-fps 120 \
			--audio-driver Dummy --path . -s res://tools/rl/swarm.gd -- route="$1" policies="$2" cars=64 \
			dest="$SWARM" > "$SWARM/log_$3.txt" 2>&1
	}
	pids=()
	record hanami demo_0,demo_100032,demo_300032,gen1_1000000,gen1_2000000 a & pids+=($!)
	record hanami gen1_3000000,gen1_6000000 b & pids+=($!)
	record hanami gen2_7000000 c & pids+=($!)
	record momiji gen2_7000000 d & pids+=($!)
	failed=0
	for p in "${pids[@]}"; do
		wait "$p" || failed=1
	done
	grep -h "^SWARM" "$SWARM"/log_*.txt || true
	if [ "$failed" = 1 ] || grep -q "SCRIPT ERROR\|Parse Error" "$SWARM"/log_*.txt; then
		echo "recording failed: see $SWARM/log_*.txt" >&2
		exit 1
	fi
	uv run --python 3.12 tools/rl/cut_film.py practice "$SWARM"
fi

if [ "$STEP" != cut ]; then
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
	rm -f "$OUT/raw.avi" "$OUT/raw.mkv"
	timeout -k 10 1800 nice -n 15 "$SUMMER" --summer-offscreen --audio-driver Dummy --disable-crash-handler \
		--path . --write-movie "$OUT/raw.avi" -s res://tools/rl/film.gd -- swarm="$SWARM" footage="$OUT"
	rm -f override.cfg
fi

uv run --python 3.12 tools/rl/cut_film.py "$OUT"
