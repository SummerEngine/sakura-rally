extends Node
## Autoload `Sound`: audio buses, music, ambience, UI sounds and one-shots.
## API is fixed by docs/CONTRACTS.md; mixing notes live in docs/AUDIO.md.
##
## Bus layout (created at startup): Master -> Music, Ambience, UI, SFX -> (Engine, World)
## Master carries a gentle glue compressor and a -1 dB hard limiter. Loop points for music
## and ambience are baked into the .import files (see tools/audio/set_loop_imports.py).

const BUSES := ["Music", "Ambience", "UI", "SFX", "Engine", "World"]

## Base trims (dB) applied under the user's volume settings, so that at 100 % the mix sits:
## engine/world SFX on top, music clearly behind it, UI soft.
const BUS_TRIM_DB := {
	"Music": -5.0,
	"Ambience": -2.0,
	"UI": -6.0,
	"SFX": 0.0,
	"Engine": 2.0,
	"World": 0.0,
}

const MUSIC := {
	&"menu": "res://assets/audio/music/menu.ogg",
	&"drive": "res://assets/audio/music/drive.ogg",
	&"results": "res://assets/audio/music/results.ogg",
}

const AMBIENCE := {
	"hanami": "res://assets/audio/ambience/hanami.ogg",
	"momiji": "res://assets/audio/ambience/momiji.ogg",
}

const UI_SOUNDS := {
	&"hover": "res://assets/audio/ui/hover.wav",
	&"click": "res://assets/audio/ui/click.wav",
	&"back": "res://assets/audio/ui/back.wav",
	&"start": "res://assets/audio/ui/start.wav",
	&"toggle": "res://assets/audio/ui/toggle.wav",
}

const STINGERS := {
	&"countdown": "res://assets/audio/stingers/countdown.wav",
	&"go": "res://assets/audio/stingers/go.wav",
	&"checkpoint": "res://assets/audio/stingers/checkpoint.wav",
	&"finish": "res://assets/audio/stingers/finish.wav",
	&"record": "res://assets/audio/stingers/record.wav",
}

## Stingers that briefly duck music + ambience so the phrase reads clearly.
const DUCKING_STINGERS := {&"go": 5.0, &"finish": 8.0, &"record": 10.0}

## Named positional one-shots for play_3d (a random variant is picked per call).
## A full "res://..." path is accepted as well.
const SFX_3D := {
	&"impact_light": ["res://assets/audio/car/impact_light_1.wav", "res://assets/audio/car/impact_light_2.wav", "res://assets/audio/car/impact_light_3.wav"],
	&"impact_heavy": ["res://assets/audio/car/impact_heavy_1.wav", "res://assets/audio/car/impact_heavy_2.wav", "res://assets/audio/car/impact_heavy_3.wav"],
	&"thump": ["res://assets/audio/car/thump_1.wav", "res://assets/audio/car/thump_2.wav", "res://assets/audio/car/thump_3.wav"],
	&"stone": ["res://assets/audio/car/stone_1.wav", "res://assets/audio/car/stone_2.wav", "res://assets/audio/car/stone_3.wav", "res://assets/audio/car/stone_4.wav", "res://assets/audio/car/stone_5.wav", "res://assets/audio/car/stone_6.wav"],
	&"backfire": ["res://assets/audio/engine/backfire_1.wav", "res://assets/audio/engine/backfire_2.wav", "res://assets/audio/engine/backfire_3.wav", "res://assets/audio/engine/backfire_4.wav"],
	&"blowoff": ["res://assets/audio/engine/bov_1.wav", "res://assets/audio/engine/bov_2.wav"],
	&"shift": ["res://assets/audio/engine/shift_up_1.wav", "res://assets/audio/engine/shift_up_2.wav"],
}

const SILENT_DB := -80.0
const POOL_3D := 16
const POOL_UI := 4
## Title-screen mix: the flyover car's engine and world sounds sit this far under the music.
const BACKDROP_DB := -11.0

## Current slow-motion factor (1.0 = real time). Car audio multiplies its pitches by this.
var slowmo: float = 1.0

var _music_a: AudioStreamPlayer
var _music_b: AudioStreamPlayer
var _music_active: AudioStreamPlayer
var _music_track: StringName = &""
var _music_tween: Tween
var _amb_a: AudioStreamPlayer
var _amb_b: AudioStreamPlayer
var _amb_active: AudioStreamPlayer
var _amb_id: String = ""
var _amb_tween: Tween
var _ui_players: Array[AudioStreamPlayer] = []
var _ui_next: int = 0
var _stinger_player: AudioStreamPlayer
var _pool_3d: Array[AudioStreamPlayer3D] = []
var _pool_3d_next: int = 0
var _duck_tween: Tween
var _pause_tween: Tween
var _slowmo_tween: Tween
var _duck_db: float = 0.0
var _cache: Dictionary = {}
var _warned: Dictionary = {}
var _music_lowpass: AudioEffectLowPassFilter
var _sfx_lowpass: AudioEffectLowPassFilter
var _backdrop_db: float = 0.0
var _backdrop_tween: Tween


func _enter_tree() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ensure_buses()


func _ready() -> void:
	_music_a = _make_player(&"Music")
	_music_b = _make_player(&"Music")
	_amb_a = _make_player(&"Ambience")
	_amb_b = _make_player(&"Ambience")
	for i in POOL_UI:
		_ui_players.append(_make_player(&"UI"))
	_stinger_player = _make_player(&"UI")
	for i in POOL_3D:
		var p := AudioStreamPlayer3D.new()
		p.bus = &"World"
		p.unit_size = 6.0
		p.max_distance = 220.0
		p.attenuation_filter_cutoff_hz = 6000.0
		p.attenuation_filter_db = -12.0
		p.panning_strength = 0.8
		add_child(p)
		_pool_3d.append(p)
	var game := _game()
	if game != null:
		game.settings_changed.connect(_apply_volumes)
		game.paused_changed.connect(_on_paused_changed)
	_apply_volumes()


# ---------------------------------------------------------------- buses

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
	_ensure_effects()


func _ensure_effects() -> void:
	var master := AudioServer.get_bus_index("Master")
	if AudioServer.get_bus_effect_count(master) == 0:
		var glue := AudioEffectCompressor.new()
		glue.threshold = -10.0
		glue.ratio = 2.0
		glue.attack_us = 20000.0
		glue.release_ms = 250.0
		glue.gain = 0.0
		AudioServer.add_bus_effect(master, glue)
		var limiter := AudioEffectHardLimiter.new()
		limiter.ceiling_db = -1.0
		limiter.pre_gain_db = 0.0
		limiter.release = 0.12
		AudioServer.add_bus_effect(master, limiter)
	var music := AudioServer.get_bus_index("Music")
	if AudioServer.get_bus_effect_count(music) == 0:
		_music_lowpass = AudioEffectLowPassFilter.new()
		_music_lowpass.cutoff_hz = 20500.0
		AudioServer.add_bus_effect(music, _music_lowpass)
	else:
		_music_lowpass = AudioServer.get_bus_effect(music, 0) as AudioEffectLowPassFilter
	var sfx := AudioServer.get_bus_index("SFX")
	if AudioServer.get_bus_effect_count(sfx) == 0:
		# A touch of open-air slap: mountain roads are never fully dry.
		var verb := AudioEffectReverb.new()
		verb.predelay_msec = 45.0
		verb.predelay_feedback = 0.25
		verb.room_size = 0.55
		verb.damping = 0.65
		verb.spread = 1.0
		verb.hipass = 0.25
		verb.dry = 1.0
		verb.wet = 0.07
		AudioServer.add_bus_effect(sfx, verb)
		_sfx_lowpass = AudioEffectLowPassFilter.new()
		_sfx_lowpass.cutoff_hz = 20500.0
		AudioServer.add_bus_effect(sfx, _sfx_lowpass)
	else:
		_sfx_lowpass = AudioServer.get_bus_effect(sfx, 1) as AudioEffectLowPassFilter
	var engine_bus := AudioServer.get_bus_index("Engine")
	if AudioServer.get_bus_effect_count(engine_bus) == 0:
		var comp := AudioEffectCompressor.new()
		comp.threshold = -14.0
		comp.ratio = 2.5
		comp.attack_us = 8000.0
		comp.release_ms = 180.0
		AudioServer.add_bus_effect(engine_bus, comp)


func _apply_volumes() -> void:
	var master_v := _setting_volume("master_volume", 0.9)
	var music_v := _setting_volume("music_volume", 0.6)
	var sfx_v := _setting_volume("sfx_volume", 0.9)
	_set_bus_db("Master", _linear_db(master_v))
	_set_bus_db("Music", _linear_db(music_v) + BUS_TRIM_DB["Music"] - _duck_db)
	_set_bus_db("Ambience", _linear_db(sfx_v) + BUS_TRIM_DB["Ambience"] - _duck_db * 0.5)
	_set_bus_db("UI", _linear_db(sfx_v) + BUS_TRIM_DB["UI"])
	_set_bus_db("SFX", _linear_db(sfx_v) + BUS_TRIM_DB["SFX"])
	_set_bus_db("Engine", BUS_TRIM_DB["Engine"] + _backdrop_db)
	_set_bus_db("World", BUS_TRIM_DB["World"] + _backdrop_db)


## On while the title screen shows the flyover car; off for driving.
func set_backdrop_mix(on: bool, fade: float = 1.2) -> void:
	if _backdrop_tween != null and _backdrop_tween.is_valid():
		_backdrop_tween.kill()
	_backdrop_tween = create_tween()
	_backdrop_tween.tween_method(_set_backdrop, _backdrop_db, BACKDROP_DB if on else 0.0, maxf(fade, 0.01))


func _set_backdrop(value_db: float) -> void:
	_backdrop_db = value_db
	_apply_volumes()


func _setting_volume(key: String, fallback: float) -> float:
	var game := _game()
	if game == null:
		return fallback
	var v: Variant = game.get_setting(key)
	if v is float or v is int:
		return clampf(float(v), 0.0, 1.0)
	return fallback


func _set_bus_db(bus_name: String, value_db: float) -> void:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx == -1:
		return
	AudioServer.set_bus_volume_db(idx, value_db)
	AudioServer.set_bus_mute(idx, value_db <= SILENT_DB + 1.0)


static func _linear_db(v: float) -> float:
	return SILENT_DB if v <= 0.001 else maxf(linear_to_db(v), SILENT_DB)


# ---------------------------------------------------------------- UI and stingers

## UI one-shots: &"hover", &"click", &"back", &"start", &"toggle".
func play_ui(sound_name: StringName) -> void:
	var stream := _stream_from(UI_SOUNDS, sound_name, "UI sound")
	if stream == null:
		return
	var p := _ui_players[_ui_next]
	_ui_next = (_ui_next + 1) % _ui_players.size()
	p.stream = stream
	p.pitch_scale = randf_range(0.97, 1.03) if sound_name == &"hover" else 1.0
	p.volume_db = -4.0 if sound_name == &"hover" else 0.0
	p.play()


## Stingers: &"countdown", &"go", &"checkpoint", &"finish", &"record".
func play_stinger(sound_name: StringName) -> void:
	var stream := _stream_from(STINGERS, sound_name, "stinger")
	if stream == null:
		return
	_stinger_player.stream = stream
	_stinger_player.play()
	if DUCKING_STINGERS.has(sound_name):
		_duck(DUCKING_STINGERS[sound_name], stream.get_length())


func _duck(amount_db: float, hold: float) -> void:
	if _duck_tween != null and _duck_tween.is_valid():
		_duck_tween.kill()
	_duck_tween = create_tween()
	_duck_tween.tween_method(_set_duck, _duck_db, amount_db, 0.12)
	_duck_tween.tween_interval(maxf(hold - 0.6, 0.2))
	_duck_tween.tween_method(_set_duck, amount_db, 0.0, 1.2).set_trans(Tween.TRANS_SINE)


func _set_duck(value_db: float) -> void:
	_duck_db = value_db
	_apply_volumes()


# ---------------------------------------------------------------- music

## Music: &"menu", &"drive", &"results". Crossfades from whatever is playing.
func play_music(track: StringName, fade: float = 1.5) -> void:
	if track == _music_track and _music_active != null and _music_active.playing:
		return
	var stream := _stream_from(MUSIC, track, "music track")
	if stream == null:
		return
	var incoming := _music_b if _music_active == _music_a else _music_a
	var outgoing := _music_active
	incoming.stream = stream
	incoming.volume_db = SILENT_DB
	incoming.play()
	_music_active = incoming
	_music_track = track
	_music_tween = _crossfade(_music_tween, incoming, outgoing, fade)


func stop_music(fade: float = 1.5) -> void:
	_music_track = &""
	_music_tween = _crossfade(_music_tween, null, _music_active, fade)
	_music_active = null


# ---------------------------------------------------------------- ambience

## Ambience bed for a map id ("hanami", "momiji"). Unknown ids fade the bed out.
func play_ambience(map_id: String, fade: float = 2.0) -> void:
	if map_id == _amb_id and _amb_active != null and _amb_active.playing:
		return
	var stream := _stream_from(AMBIENCE, map_id, "ambience")
	if stream == null:
		stop_ambience(fade)
		return
	var incoming := _amb_b if _amb_active == _amb_a else _amb_a
	var outgoing := _amb_active
	incoming.stream = stream
	incoming.volume_db = SILENT_DB
	# Start somewhere inside the loop so repeated sessions do not always open identically.
	incoming.play(randf() * stream.get_length() * 0.8)
	_amb_active = incoming
	_amb_id = map_id
	_amb_tween = _crossfade(_amb_tween, incoming, outgoing, fade)


func stop_ambience(fade: float = 2.0) -> void:
	_amb_id = ""
	_amb_tween = _crossfade(_amb_tween, null, _amb_active, fade)
	_amb_active = null


## Equal-power crossfade between two players (either may be null). Returns the new tween.
func _crossfade(old_tween: Tween, incoming: AudioStreamPlayer, outgoing: AudioStreamPlayer,
		fade: float) -> Tween:
	if old_tween != null and old_tween.is_valid():
		old_tween.kill()
	var out_start := db_to_linear(outgoing.volume_db) if outgoing != null and outgoing.playing else 0.0
	var in_start := db_to_linear(incoming.volume_db) if incoming != null else 0.0
	if fade <= 0.0:
		if incoming != null:
			incoming.volume_db = 0.0
		if outgoing != null and outgoing != incoming:
			outgoing.stop()
		return null
	var tw := create_tween()
	tw.tween_method(func(t: float) -> void:
		if incoming != null:
			var gi := lerpf(in_start, 1.0, sin(t * PI * 0.5))
			incoming.volume_db = linear_to_db(maxf(gi, 0.0001))
		if outgoing != null and outgoing != incoming:
			var go := out_start * cos(t * PI * 0.5)
			outgoing.volume_db = linear_to_db(maxf(go, 0.0001))
	, 0.0, 1.0, fade)
	if outgoing != null and outgoing != incoming:
		tw.tween_callback(outgoing.stop)
	return tw


# ---------------------------------------------------------------- positional one-shots

## Positional one-shot in the world (impacts, bells...). `sound_name` is a key of SFX_3D
## or a "res://" path to any AudioStream.
func play_3d(sound_name: StringName, position: Vector3, volume_db: float = 0.0) -> void:
	var stream: AudioStream = null
	if SFX_3D.has(sound_name):
		var variants: Array = SFX_3D[sound_name]
		stream = _load(variants[randi() % variants.size()])
	elif String(sound_name).begins_with("res://"):
		stream = _load(String(sound_name))
	else:
		_warn_once("play_3d: unknown sound '%s'" % sound_name)
		return
	if stream == null:
		return
	var p := _pool_3d[_pool_3d_next]
	_pool_3d_next = (_pool_3d_next + 1) % _pool_3d.size()
	p.stop()
	p.stream = stream
	p.global_position = position
	p.volume_db = volume_db
	p.pitch_scale = randf_range(0.94, 1.06) * slowmo
	p.play()


# ---------------------------------------------------------------- slow motion and pause

## Keep audio in step with Engine.time_scale for slow motion (1.0 = normal).
## Car audio and play_3d pitch down by `slowmo`; SFX get a soft low-pass and music a
## gentle one, so slow motion reads as cinematic instead of a tape slowdown.
func set_slowmo(time_scale: float) -> void:
	var target := clampf(time_scale, 0.1, 1.0)
	if _slowmo_tween != null and _slowmo_tween.is_valid():
		_slowmo_tween.kill()
	_slowmo_tween = create_tween()
	_slowmo_tween.tween_method(_set_slowmo_value, slowmo, target, 0.25)


func _set_slowmo_value(value: float) -> void:
	slowmo = value
	# The low-passes stay enabled (open at 20.5 kHz): toggling an effect mid-stream clicks.
	var amount := clampf((1.0 - value) / 0.7, 0.0, 1.0)
	_sfx_lowpass.cutoff_hz = lerpf(20500.0, 2200.0, amount)
	if not _game_paused():
		_music_lowpass.cutoff_hz = lerpf(20500.0, 5000.0, amount)


func _on_paused_changed(paused: bool) -> void:
	# Paused: music drifts behind a soft low-pass, like hearing it from the next room.
	if _pause_tween != null and _pause_tween.is_valid():
		_pause_tween.kill()
	_pause_tween = create_tween()
	var open_hz := lerpf(20500.0, 5000.0, clampf((1.0 - slowmo) / 0.7, 0.0, 1.0))
	var target := 900.0 if paused else open_hz
	_pause_tween.tween_property(_music_lowpass, "cutoff_hz", target, 0.35).set_trans(Tween.TRANS_SINE)


func _game_paused() -> bool:
	var game := _game()
	return game != null and bool(game.get("paused"))


# ---------------------------------------------------------------- helpers

func _make_player(bus_name: StringName) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.bus = bus_name
	add_child(p)
	return p


func _game() -> Node:
	return get_node_or_null(^"/root/Game")


func _stream_from(table: Dictionary, key: Variant, kind: String) -> AudioStream:
	if not table.has(key):
		_warn_once("Sound: unknown %s '%s'" % [kind, key])
		return null
	return _load(table[key])


func _load(path: String) -> AudioStream:
	if _cache.has(path):
		return _cache[path]
	if not ResourceLoader.exists(path):
		_warn_once("Sound: missing audio file %s" % path)
		_cache[path] = null
		return null
	var stream := load(path) as AudioStream
	_cache[path] = stream
	return stream


func _warn_once(message: String) -> void:
	if _warned.has(message):
		return
	_warned[message] = true
	push_warning(message)
