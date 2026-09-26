#!/bin/zsh
set -eu
project_dir="${0:A:h}"
exec /Applications/Godot.app/Contents/MacOS/Godot --path "$project_dir"
