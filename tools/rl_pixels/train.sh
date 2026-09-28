#!/usr/bin/env bash
# Pixel training (tools/rl_pixels/train_pixels.py) as it must run on this Mac: the workers render
# offscreen on the agents' dev build, so the run holds the render lock throughout (Movie Maker
# takes wait for it); the Mac stays awake (caffeinate), everything at low priority. A run that
# dies (a worker crash, a lost socket) resumes from its latest checkpoint, up to 5 times.
#   tools/rl_pixels/train.sh <imitate|ppo> --run <name> [train_pixels.py options]
set -uo pipefail
cd "$(dirname "$0")/../.."
PHASE="$1"
shift
RUN=""
prev=""
for a in "$@"; do
	[ "$prev" = "--run" ] && RUN="$a"
	prev="$a"
done
[ -n "$RUN" ] || { echo "train.sh: --run is required" >&2; exit 2; }
CK="tools/rl/runs/$RUN/ckpt/latest.pt"
for try in 1 2 3 4 5 6; do
	extra=()
	[ "$try" -gt 1 ] && [ -f "$CK" ] && extra=(--resume "$CK")
	caffeinate -i /usr/bin/lockf -k /tmp/sakura-render.lock nice -n 10 \
		uv run --python 3.12 tools/rl_pixels/train_pixels.py "$PHASE" "$@" ${extra[@]+"${extra[@]}"} && exit 0
	echo "train.sh: $RUN ended with an error (try $try of 6)" >&2
	sleep 15
done
exit 1
