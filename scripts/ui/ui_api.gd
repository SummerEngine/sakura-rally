extends RefCounted
## Access to the `Game` and `Sound` autoloads by node path, so UI scripts also compile when
## loaded from `-s` tool scripts (where autoload names are not identifiers).
## The UI depends on nothing else from the game (see docs/CONTRACTS.md).


static func game() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	return tree.root.get_node_or_null(^"Game") if tree != null else null


static func sound() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	return tree.root.get_node_or_null(^"Sound") if tree != null else null


## Game.State value by name ("MENU", "RACING", ...).
static func state(state_name: String) -> int:
	return int(game().State[state_name])


static func ui_sound(sound_name: StringName) -> void:
	var s := sound()
	if s != null:
		s.play_ui(sound_name)


static func stinger(sound_name: StringName) -> void:
	var s := sound()
	if s != null:
		s.play_stinger(sound_name)


static func setting(key: String) -> Variant:
	return game().get_setting(key)


static func speed_in_units(kmh: float) -> float:
	return kmh * 0.621371 if str(setting("units")) == "mph" else kmh


static func unit_label() -> String:
	return "mph" if str(setting("units")) == "mph" else "km/h"


## Numeric property of a duck-typed runtime node (car / session); `fallback` when missing.
static func num(obj: Object, prop: StringName, fallback: float = 0.0) -> float:
	if obj == null or not is_instance_valid(obj):
		return fallback
	var v: Variant = obj.get(prop)
	if v == null:
		return fallback
	return float(v)
