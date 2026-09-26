#!/bin/zsh
# Starts the game with Summer Engine, or with Godot 4.7 when Summer is not installed in /Applications.
set -eu
project_dir="${0:A:h}"
for engine in /Applications/Summer.app/Contents/MacOS/Summer /Applications/Godot.app/Contents/MacOS/Godot; do
	if [[ -x $engine ]]; then
		exec "$engine" --path "$project_dir"
	fi
done
echo "Sakura Rally needs Summer Engine or Godot 4.7 in /Applications." >&2
exit 1
