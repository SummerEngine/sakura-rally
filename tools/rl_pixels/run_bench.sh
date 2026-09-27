#!/usr/bin/env bash
# The pixel-observation benchmark (tools/rl_pixels/pixel_bench.gd) on the agents' dev build,
# offscreen and under the render lock (one step holds it at a time).
#   tools/rl_pixels/run_bench.sh [grid|scale|res|renderer|samples|all] [dest]   # default all, /tmp/pixel_rl/bench
#   grid      every look x size x cars x readback in one process (grid.log)
#   scale     one config in 1, 2, 4 and 6 processes at once, long enough to overlap
#             (does another process add throughput, or is the GPU the limit): scale<P>_<i>.log
#   res       the stripped world (bare) and road-only views at every size: res.log
#   renderer  the same configs on the Mobile renderer (--rendering-method mobile): mobile.log
#   samples   what the network would see, PNGs: <dest>/samples/{hanami,hanami_autumn,momiji,mobile}
# The machine load before each step goes to load.txt.
set -euo pipefail
cd "$(dirname "$0")/../.."
STEP="${1:-all}"
DEST="${2:-/tmp/pixel_rl/bench}"
D="$HOME/opt/summer-dev/SummerDev.app/Contents/MacOS/Summer"
mkdir -p "$DEST"
touch "$DEST/load.txt"

run() { # <log> <configs> [user args...]; engine flags in $ENGINE_ARGS
	local log="$1" configs="$2"
	shift 2
	# shellcheck disable=SC2086
	timeout -k 10 1200 nice -n 10 "$D" --summer-offscreen --audio-driver Dummy --disable-crash-handler \
		--fixed-fps 10 ${ENGINE_ARGS:-} --path . -s res://tools/rl_pixels/pixel_bench.gd -- \
		configs="$configs" "$@" > "$log" 2>&1
}
locked() { # <step name> <bash code using run>
	echo "$1 $(date +%T) $(sysctl -n vm.loadavg)" >> "$DEST/load.txt"
	/usr/bin/lockf -k /tmp/sakura-render.lock bash -c "$(declare -f run); D='$D'; DEST='$DEST'; $2"
}

if [ "$STEP" = grid ] || [ "$STEP" = all ]; then
	grid=""
	for look in low lean; do
		for size in 64x64 96x96 128x72 160x120; do
			for n in 1 4 16 32; do grid="$grid;$look/$size/$n/each"; done
			grid="$grid;$look/$size/16/atlas"
		done
	done
	for n in 16 32; do grid="$grid;bare/64x64/$n/atlas;road/64x64/$n/atlas;top/64x64/$n/atlas"; done
	grid="$grid;full/64x64/16/atlas;full/128x72/16/atlas;low/64x64/16/gpu;lean/64x64/16/gpu"
	grid="$grid;none/64x64/16/each;none/64x64/32/each;lean/64x64/64/atlas;bare/64x64/64/atlas"
	locked grid "run \$DEST/grid.log '${grid#;}' decisions=30"
fi

if [ "$STEP" = scale ] || [ "$STEP" = all ]; then
	for P in 1 2 4 6; do
		locked "scale$P" "for i in \$(seq 1 $P); do run \$DEST/scale${P}_\$i.log 'none/64x64/16/each;bare/64x64/16/atlas;lean/64x64/16/atlas' warmup=20 decisions=120 & done; wait"
	done
fi

if [ "$STEP" = res ] || [ "$STEP" = all ]; then
	locked res "run \$DEST/res.log 'bare/64x64/16/atlas;bare/96x96/16/atlas;bare/128x72/16/atlas;bare/160x120/16/atlas;bare/128x72/32/atlas;top/128x72/16/atlas;road/128x72/16/atlas' decisions=40"
fi

if [ "$STEP" = renderer ] || [ "$STEP" = all ]; then
	locked renderer "ENGINE_ARGS='--rendering-method mobile' run \$DEST/mobile.log 'lean/64x64/16/atlas;bare/64x64/16/atlas;lean/64x64/32/atlas;low/64x64/16/atlas;full/64x64/16/atlas;lean/64x64/4/each' decisions=30 samples=\$DEST/samples/mobile"
fi

if [ "$STEP" = samples ] || [ "$STEP" = all ]; then
	S4="lean/64x64/4/each;lean/96x96/4/each;lean/128x72/4/each;bare/64x64/4/each;top/64x64/4/each;low/64x64/4/each;full/128x72/4/each"
	locked samples "run \$DEST/samples_hanami.log '$S4' cars=4 samples=\$DEST/samples/hanami decisions=25
		run \$DEST/samples_hanami_autumn.log 'lean/64x64/4/each;lean/96x96/4/each' cars=4 season=0,0,1 samples=\$DEST/samples/hanami_autumn decisions=25
		run \$DEST/samples_momiji.log '$S4' cars=4 map=momiji samples=\$DEST/samples/momiji decisions=25"
fi

grep -h "SCRIPT ERROR\|Parse Error" "$DEST"/*.log && echo "errors: see $DEST" >&2
echo "done: $DEST"
