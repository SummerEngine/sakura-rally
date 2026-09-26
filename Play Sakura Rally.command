#!/bin/zsh
# Starts the game with Godot 4.7 or Summer Engine, whichever is installed in /Applications.
set -eu
project_dir="${0:A:h}"
for engine in /Applications/Godot.app/Contents/MacOS/Godot /Applications/Summer.app/Contents/MacOS/Summer; do
	if [[ -x $engine ]]; then
		exec "$engine" --path "$project_dir"
	fi
done
echo "Sakura Rally needs Godot 4.7 or Summer Engine in /Applications." >&2
exit 1
