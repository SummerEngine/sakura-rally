extends Node
## Autoload `Sound`: audio buses, music, ambience, UI sounds and one-shots.
## API is fixed by docs/CONTRACTS.md; the audio pass fills in the bodies.
##
## Bus layout (created at startup): Master -> Music, Ambience, UI, SFX -> (Engine, World)

const BUSES := ["Music", "Ambience", "UI", "SFX", "Engine", "World"]


func _enter_tree() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ensure_buses()


func _ensure_buses() -> void:
	for bus_name in BUSES:
		if AudioServer.get_bus_index(bus_name) == -1:
			AudioServer.add_bus()
			var idx := AudioServer.bus_count - 1
			AudioServer.set_bus_name(idx, bus_name)
	for bus_name in ["Music", "Ambience", "UI", "SFX"]:
		AudioServer.set_bus_send(AudioServer.get_bus_index(bus_name), "Master")
	for bus_name in ["Engine", "World"]:
		AudioServer.set_bus_send(AudioServer.get_bus_index(bus_name), "SFX")


## UI one-shots: &"hover", &"click", &"back", &"start", &"toggle".
func play_ui(_name: StringName) -> void:
	pass


## Music: &"menu", &"drive", &"results". Crossfades from whatever is playing.
func play_music(_track: StringName, _fade: float = 1.5) -> void:
	pass


func stop_music(_fade: float = 1.5) -> void:
	pass


## Ambience bed for a map id ("hanami", "momiji").
func play_ambience(_map_id: String, _fade: float = 2.0) -> void:
	pass


func stop_ambience(_fade: float = 2.0) -> void:
	pass


## Stingers: &"countdown", &"go", &"checkpoint", &"finish", &"record".
func play_stinger(_name: StringName) -> void:
	pass


## Positional one-shot in the world (impacts, bells...).
func play_3d(_name: StringName, _position: Vector3, _volume_db: float = 0.0) -> void:
	pass


## Keep audio in step with Engine.time_scale for slow motion (1.0 = normal).
func set_slowmo(_time_scale: float) -> void:
	pass
