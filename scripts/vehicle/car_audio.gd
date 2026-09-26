extends Node3D
## CarAudio: engine, turbo, gearbox, tyres, wind and event sounds for one car.
##
## Child (named `CarAudio`) of any node implementing the car runtime API in
## docs/CONTRACTS.md; the API is read every frame, signals are connected when present.
## All layers are AudioStreamPlayer3D so the chase camera hears the car where it is:
## the player's car uses low panning strength (engine stays centred, impacts and stones
## still localise), other cars use full 3D panning and distance filtering.
## Mixing logic is documented in docs/AUDIO.md.

const ENGINE_DIR := "res://assets/audio/engine/"
const CAR_DIR := "res://assets/audio/car/"

## Loop set rpm points (must match tools/audio/synth_engine.py). Index 0 of the off set is
## the idle loop: with the throttle closed at low rpm the engine idles rather than overruns.
const ON_RPMS: Array[float] = [1000.0, 1750.0, 2500.0, 3500.0, 4500.0, 5500.0, 6500.0, 7500.0]
const OFF_RPMS: Array[float] = [900.0, 1750.0, 2500.0, 3500.0, 4500.0, 5500.0, 6500.0, 7500.0]
const WHINE_BASE_KMH := 82.0

## Physical surface -> rolling loop / slide loop (+ slide weight).
const ROLL_KEYS := {&"tarmac": &"tarmac", &"gravel": &"gravel", &"dirt": &"dirt", &"sand": &"dirt", &"grass": &"grass"}
const SLIDE_KEYS := {&"tarmac": &"tarmac", &"gravel": &"gravel", &"dirt": &"dirt", &"sand": &"dirt", &"grass": &"dirt"}
const SLIDE_WEIGHT := {&"tarmac": 1.0, &"gravel": 1.0, &"dirt": 1.0, &"sand": 0.8, &"grass": 0.55}
const ROLL_LOOPS: Array[StringName] = [&"tarmac", &"gravel", &"dirt", &"grass"]
const SLIDE_LOOPS: Array[StringName] = [&"tarmac", &"gravel", &"dirt"]

## Layer trims in dB (relative balance; bus levels are set by the Sound autoload).
const ENGINE_DB := -1.0
const TURBO_DB := -16.0
const WHINE_DB := -21.0
const ROLL_DB := -12.0
const SLIDE_DB := {&"tarmac": -9.0, &"gravel": -5.0, &"dirt": -6.0}
const WIND_DB := -13.0
const HORN_DB := -9.0
const SHIFT_DB := -5.0
const BOV_DB := -9.0
const BACKFIRE_DB := -2.0
const STONE_DB := -9.0
const THUMP_DB := -2.0
const IMPACT_DB := 0.0

const LIMITER_HZ := 17.0
const SILENT := 0.00001

## Positions in car space (forward is -Z).
const ENGINE_POS := Vector3(0.0, 0.6, -1.25)
const EXHAUST_POS := Vector3(0.4, 0.3, 2.15)
const GEARBOX_POS := Vector3(0.0, 0.35, -0.3)
const BODY_POS := Vector3(0.0, 0.45, 0.0)
const WHEEL_POS: Array[Vector3] = [Vector3(-0.78, 0.1, -1.27), Vector3(0.78, 0.1, -1.27), Vector3(-0.78, 0.1, 1.28), Vector3(0.78, 0.1, 1.28)]

var car: Node

var _on_players: Array[AudioStreamPlayer3D] = []
var _off_players: Array[AudioStreamPlayer3D] = []
var _turbo: AudioStreamPlayer3D
var _whine: AudioStreamPlayer3D
var _wind: AudioStreamPlayer3D
var _horn: AudioStreamPlayer3D
var _roll: Dictionary = {} ## StringName -> AudioStreamPlayer3D
var _slide: Dictionary = {}
var _shift_up: AudioStreamPlayer3D
var _shift_down: AudioStreamPlayer3D
var _bov: AudioStreamPlayer3D
var _flutter: AudioStreamPlayer3D
var _backfire: AudioStreamPlayer3D
var _stones: Array[AudioStreamPlayer3D] = []
var _stone_next: int = 0
var _thump: AudioStreamPlayer3D
var _impact_light: AudioStreamPlayer3D
var _impact_heavy: AudioStreamPlayer3D
var _all_players: Array[AudioStreamPlayer3D] = []

var _t: float = 0.0
var _rpm: float = 900.0
var _load: float = 0.0
var _boost: float = 0.0
var _prev_throttle: float = 0.0
var _shift_dip_until: float = -1.0
var _limiter_until: float = -1.0
var _last_limiter_pop: float = -1.0
var _last_bov: float = -1.0
var _roll_gain: Dictionary = {}
var _slide_gain: Dictionary = {}
var _turbo_gain: float = 0.0
var _whine_gain: float = 0.0
var _wind_gain: float = 0.0
var _horn_gain: float = 0.0
var _is_player: bool = false
var _player_config_applied: int = -1
var _sound: Node


func _ready() -> void:
	car = get_parent()
	_sound = get_node_or_null(^"/root/Sound")
	for i in ON_RPMS.size():
		_on_players.append(_loop(ENGINE_DIR + "engine_on_%d.wav" % int(ON_RPMS[i]), &"Engine", ENGINE_POS))
	_off_players.append(_loop(ENGINE_DIR + "engine_idle.wav", &"Engine", ENGINE_POS))
	for i in range(1, OFF_RPMS.size()):
		_off_players.append(_loop(ENGINE_DIR + "engine_off_%d.wav" % int(OFF_RPMS[i]), &"Engine", ENGINE_POS))
	_turbo = _loop(ENGINE_DIR + "turbo_whistle.wav", &"Engine", ENGINE_POS)
	_whine = _loop(ENGINE_DIR + "gear_whine.wav", &"Engine", GEARBOX_POS)
	_wind = _loop(CAR_DIR + "wind.wav", &"World", BODY_POS + Vector3(0, 0.6, -0.4))
	_horn = _loop(CAR_DIR + "horn.wav", &"World", ENGINE_POS + Vector3(0, -0.2, -0.8))
	for key in ROLL_LOOPS:
		_roll[key] = _loop(CAR_DIR + "tyre_roll_%s.wav" % key, &"World", Vector3(0, 0.1, 0))
		_roll_gain[key] = 0.0
	for key in SLIDE_LOOPS:
		_slide[key] = _loop(CAR_DIR + "tyre_slide_%s.wav" % key, &"World", Vector3(0, 0.1, 0.4))
		_slide_gain[key] = 0.0
	_shift_up = _shot(_variants(ENGINE_DIR, "shift_up_%d.wav", 2), &"Engine", GEARBOX_POS, 2)
	_shift_down = _shot(_variants(ENGINE_DIR, "shift_down_%d.wav", 2), &"Engine", GEARBOX_POS, 2)
	_bov = _shot(_variants(ENGINE_DIR, "bov_%d.wav", 2), &"Engine", ENGINE_POS, 2)
	_flutter = _shot([ENGINE_DIR + "bov_flutter.wav"], &"Engine", ENGINE_POS, 1)
	_backfire = _shot(_variants(ENGINE_DIR, "backfire_%d.wav", 4), &"Engine", EXHAUST_POS, 4)
	for i in 4:
		_stones.append(_shot(_variants(CAR_DIR, "stone_%d.wav", 6), &"World", WHEEL_POS[i], 3))
	_thump = _shot(_variants(CAR_DIR, "thump_%d.wav", 3), &"World", BODY_POS, 2)
	_impact_light = _shot(_variants(CAR_DIR, "impact_light_%d.wav", 3), &"World", BODY_POS, 3)
	_impact_heavy = _shot(_variants(CAR_DIR, "impact_heavy_%d.wav", 3), &"World", BODY_POS, 2)
	_connect_car_signals()
	_apply_player_config()


# ---------------------------------------------------------------- setup helpers

func _stream(path: String) -> AudioStream:
	if not ResourceLoader.exists(path):
		push_warning("CarAudio: missing %s" % path)
		return null
	return load(path) as AudioStream


func _variants(dir: String, pattern: String, count: int) -> Array[String]:
	var out: Array[String] = []
	for i in count:
		out.append(dir + pattern % (i + 1))
	return out


func _new_player(bus: StringName, pos: Vector3) -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	p.bus = bus
	p.position = pos
	p.unit_size = 10.0
	p.max_distance = 320.0
	p.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
	add_child(p)
	_all_players.append(p)
	return p


## Continuous loop: starts immediately (silent) at a random phase, gain driven per frame.
func _loop(path: String, bus: StringName, pos: Vector3) -> AudioStreamPlayer3D:
	var p := _new_player(bus, pos)
	p.stream = _stream(path)
	p.volume_db = linear_to_db(SILENT)
	if p.stream != null:
		p.play(randf() * p.stream.get_length())
	return p


## One-shot player with random variant choice, light pitch/volume randomisation, polyphony.
func _shot(paths: Array[String], bus: StringName, pos: Vector3, polyphony: int) -> AudioStreamPlayer3D:
	var p := _new_player(bus, pos)
	var rnd := AudioStreamRandomizer.new()
	rnd.playback_mode = AudioStreamRandomizer.PLAYBACK_RANDOM_NO_REPEATS if paths.size() > 2 else AudioStreamRandomizer.PLAYBACK_RANDOM
	rnd.random_pitch = 1.06
	rnd.random_volume_offset_db = 1.5
	for path in paths:
		var s := _stream(path)
		if s != null:
			rnd.add_stream(-1, s)
	p.stream = rnd if rnd.streams_count > 0 else null
	p.max_polyphony = polyphony
	return p


func _connect_car_signals() -> void:
	if car == null:
		return
	if car.has_signal(&"gear_changed"):
		car.connect(&"gear_changed", _on_gear_changed)
	if car.has_signal(&"backfire"):
		car.connect(&"backfire", _on_backfire)
	if car.has_signal(&"rev_limiter"):
		car.connect(&"rev_limiter", _on_rev_limiter)
	if car.has_signal(&"impact"):
		car.connect(&"impact", _on_impact)
	if car.has_signal(&"landed"):
		car.connect(&"landed", _on_landed)


func _apply_player_config() -> void:
	_is_player = car != null and bool(car.get(&"controlled_by_player"))
	var flag := 1 if _is_player else 0
	if flag == _player_config_applied:
		return
	_player_config_applied = flag
	for p in _all_players:
		# Own car: near-centred and unfiltered at chase distance. Others: full 3D cues.
		p.panning_strength = 0.35 if _is_player else 1.0
		p.attenuation_filter_db = 0.0 if _is_player else -18.0
		p.attenuation_filter_cutoff_hz = 5500.0


# ---------------------------------------------------------------- per-frame mixing

func _process(delta: float) -> void:
	if car == null or delta <= 0.0:
		return
	_t += delta
	_apply_player_config()
	var slowmo := _slowmo()
	var rpm_in := _num(&"rpm", 900.0)
	var max_rpm := _num(&"max_rpm", 7800.0)
	var throttle := clampf(_num(&"throttle", 0.0), 0.0, 1.0)
	var boost := clampf(_num(&"boost", 0.0), 0.0, 1.0)
	var speed := absf(_num(&"speed_kmh", 0.0))
	var shifting := bool(car.get(&"is_shifting"))

	_rpm = _smooth(_rpm, rpm_in, 0.015, delta)
	_boost = _smooth(_boost, boost, 0.05, delta)

	# Load: throttle, cut to zero during shifts; limiter chops it at ~17 Hz.
	var load_target := throttle
	if shifting or _t < _shift_dip_until:
		load_target = 0.0
	var limiting := _t < _limiter_until
	if limiting:
		load_target = 1.0 if fmod(_t * LIMITER_HZ, 1.0) < 0.55 else 0.0
	var tau := 0.012 if limiting else (0.045 if load_target > _load else 0.085)
	_load = _smooth(_load, load_target, tau, delta)

	_mix_engine(slowmo, limiting)
	_mix_turbo(throttle, slowmo, max_rpm)
	_mix_whine(speed, slowmo, delta)
	_mix_tyres(speed, slowmo, delta)
	_mix_wind(speed, slowmo, delta)
	_mix_horn(delta)

	# Lifting off hard at boost vents the blow-off valve.
	if _boost > 0.45 and _prev_throttle > 0.6 and throttle < 0.25 and _t - _last_bov > 0.8:
		_play_bov(_boost)
	_prev_throttle = throttle


func _mix_engine(slowmo: float, limiting: bool) -> void:
	var on_set := sin(_load * PI * 0.5)
	var off_set := cos(_load * PI * 0.5)
	var cut := 0.82 if limiting and _load < 0.5 else 1.0
	_mix_set(_on_players, ON_RPMS, on_set * cut, slowmo)
	_mix_set(_off_players, OFF_RPMS, off_set * cut, slowmo)


## Equal-power crossfade between the two loops that bracket the current rpm.
func _mix_set(players: Array[AudioStreamPlayer3D], rpms: Array[float], set_gain: float, slowmo: float) -> void:
	var n := rpms.size()
	var lo := 0
	while lo < n - 1 and _rpm >= rpms[lo + 1]:
		lo += 1
	var hi := mini(lo + 1, n - 1)
	var x := 0.0
	if hi != lo:
		x = clampf((_rpm - rpms[lo]) / (rpms[hi] - rpms[lo]), 0.0, 1.0)
	for i in n:
		var g := 0.0
		if i == lo:
			g = cos(x * PI * 0.5) if hi != lo else 1.0
		elif i == hi:
			g = sin(x * PI * 0.5)
		var p := players[i]
		g *= set_gain
		p.volume_db = linear_to_db(maxf(g, SILENT)) + ENGINE_DB
		if g > SILENT * 10.0:
			p.pitch_scale = clampf(_rpm / rpms[i], 0.25, 3.0) * slowmo


func _mix_turbo(throttle: float, slowmo: float, max_rpm: float) -> void:
	var rpm_n := clampf(_rpm / maxf(max_rpm, 1000.0), 0.0, 1.1)
	var target := pow(_boost, 1.5) * lerpf(0.35, 1.0, maxf(_load, throttle))
	_turbo_gain = target
	_turbo.volume_db = linear_to_db(maxf(_turbo_gain, SILENT)) + TURBO_DB
	_turbo.pitch_scale = (0.42 + 0.72 * _boost) * (0.85 + 0.25 * rpm_n) * slowmo


func _mix_whine(speed: float, slowmo: float, delta: float) -> void:
	var target := smoothstep(6.0, 45.0, speed) * lerpf(1.0, 0.6, _load)
	_whine_gain = _smooth(_whine_gain, target, 0.08, delta)
	_whine.volume_db = linear_to_db(maxf(_whine_gain, SILENT)) + WHINE_DB
	_whine.pitch_scale = clampf(speed / WHINE_BASE_KMH, 0.05, 3.0) * slowmo


func _mix_tyres(speed: float, slowmo: float, delta: float) -> void:
	var roll_target := {}
	var slide_target := {}
	for key in ROLL_LOOPS:
		roll_target[key] = 0.0
	for key in SLIDE_LOOPS:
		slide_target[key] = 0.0
	var wheels: Variant = car.get(&"wheels")
	var max_slip := 0.0
	var gravel_rate := 0.0
	var roll_amt := pow(clampf(speed / 70.0, 0.0, 1.5), 0.85) * 0.25
	if wheels is Array:
		for i in mini((wheels as Array).size(), 4):
			var w: Variant = wheels[i]
			if w == null or not bool(w.get("contact")):
				continue
			var surface_v: Variant = w.get("surface")
			var surface: StringName = StringName(surface_v) if surface_v != null else &"none"
			var slip := absf(float(w.get("slip")))
			var spin_kmh := absf(float(w.get("spin_speed"))) * 0.33 * 3.6
			if ROLL_KEYS.has(surface):
				roll_target[ROLL_KEYS[surface]] += roll_amt
			if SLIDE_KEYS.has(surface):
				var motion := clampf(0.25 + maxf(speed, spin_kmh) / 35.0, 0.0, 1.0)
				var amt := smoothstep(0.55, 1.3, slip) * motion * 0.25 * float(SLIDE_WEIGHT[surface])
				slide_target[SLIDE_KEYS[surface]] += amt
				max_slip = maxf(max_slip, slip)
			if surface == &"gravel":
				gravel_rate += clampf(speed / 40.0, 0.0, 2.0) * 2.2 + smoothstep(0.8, 1.5, slip) * 5.0
			elif surface == &"dirt" or surface == &"sand":
				gravel_rate += clampf(speed / 40.0, 0.0, 2.0) * 0.5
	var roll_pitch := (0.75 + 0.5 * clampf(speed / 120.0, 0.0, 1.0)) * slowmo
	for key in ROLL_LOOPS:
		_roll_gain[key] = _smooth(_roll_gain[key], sqrt(roll_target[key]), 0.06, delta)
		var p: AudioStreamPlayer3D = _roll[key]
		p.volume_db = linear_to_db(maxf(_roll_gain[key], SILENT)) + ROLL_DB
		p.pitch_scale = roll_pitch
	for key in SLIDE_LOOPS:
		var target := sqrt(slide_target[key])
		var tau := 0.035 if target > _slide_gain[key] else 0.12
		_slide_gain[key] = _smooth(_slide_gain[key], target, tau, delta)
		var sp: AudioStreamPlayer3D = _slide[key]
		sp.volume_db = linear_to_db(maxf(_slide_gain[key], SILENT)) + float(SLIDE_DB[key])
		if key == &"tarmac":
			sp.pitch_scale = (0.93 + 0.12 * clampf(max_slip - 1.0, 0.0, 1.0)) * slowmo
		else:
			sp.pitch_scale = (0.85 + 0.3 * clampf(speed / 100.0, 0.0, 1.0)) * slowmo
	# Stones flicked into the wheel arches and underbody.
	if gravel_rate > 0.0 and randf() < gravel_rate * delta:
		var sp: AudioStreamPlayer3D = _stones[_stone_next]
		_stone_next = (_stone_next + 1) % _stones.size()
		sp.volume_db = STONE_DB + randf_range(-10.0, 0.0)
		sp.pitch_scale = randf_range(0.85, 1.2) * slowmo
		sp.play()


func _mix_wind(speed: float, slowmo: float, delta: float) -> void:
	var airborne := _num(&"airborne_time", 0.0) > 0.15
	var target := pow(smoothstep(15.0, 170.0, speed), 1.3) * (1.15 if airborne else 1.0)
	_wind_gain = _smooth(_wind_gain, target, 0.25, delta)
	_wind.volume_db = linear_to_db(maxf(_wind_gain, SILENT)) + WIND_DB
	_wind.pitch_scale = (0.85 + 0.35 * clampf(speed / 200.0, 0.0, 1.0)) * slowmo


func _mix_horn(delta: float) -> void:
	var pressed := _is_player and InputMap.has_action(&"horn") and Input.is_action_pressed(&"horn")
	var target := 1.0 if pressed else 0.0
	_horn_gain = _smooth(_horn_gain, target, 0.012 if pressed else 0.04, delta)
	_horn.volume_db = linear_to_db(maxf(_horn_gain, SILENT)) + HORN_DB


# ---------------------------------------------------------------- events

func _on_gear_changed(new_gear: int, old_gear: int) -> void:
	if new_gear == old_gear:
		return
	var upshift := new_gear > old_gear
	_shift_dip_until = _t + (0.11 if upshift else 0.07)
	var shot := _shift_up if upshift else _shift_down
	_fire(shot, SHIFT_DB, 1.0)
	if upshift and _boost > 0.3:
		_play_bov(_boost)
	elif not upshift and _rpm > 3000.0 and randf() < 0.35:
		_fire(_backfire, BACKFIRE_DB - 6.0, randf_range(0.95, 1.08))


func _on_backfire() -> void:
	_fire(_backfire, BACKFIRE_DB + randf_range(-4.0, 0.0), randf_range(0.92, 1.08))


func _on_rev_limiter() -> void:
	_limiter_until = _t + 0.12
	if _t - _last_limiter_pop > 0.35 and randf() < 0.3:
		_last_limiter_pop = _t
		_fire(_backfire, BACKFIRE_DB - 9.0, randf_range(1.0, 1.15))


func _on_impact(strength: float, point: Vector3) -> void:
	var s := clampf(strength, 0.0, 1.5)
	var shot := _impact_light if s < 0.4 else _impact_heavy
	shot.global_position = point
	var gain := lerpf(0.3, 1.0, clampf(s / 0.4, 0.0, 1.0)) if s < 0.4 else lerpf(0.55, 1.0, clampf((s - 0.4) / 0.8, 0.0, 1.0))
	_fire(shot, IMPACT_DB + linear_to_db(gain), 1.0)


func _on_landed(strength: float) -> void:
	var s := clampf(strength, 0.0, 1.5)
	_fire(_thump, THUMP_DB + linear_to_db(lerpf(0.25, 1.0, clampf(s, 0.0, 1.0))), 1.0)
	if s > 0.7:
		_impact_light.position = BODY_POS
		_fire(_impact_light, IMPACT_DB - 8.0, 0.9)


func _play_bov(boost: float) -> void:
	_last_bov = _t
	var shot := _flutter if randf() < 0.25 else _bov
	_fire(shot, BOV_DB + linear_to_db(clampf(boost, 0.3, 1.0)), 1.0)


func _fire(p: AudioStreamPlayer3D, volume_db: float, pitch: float) -> void:
	if p == null or p.stream == null:
		return
	p.volume_db = volume_db
	p.pitch_scale = pitch * _slowmo()
	p.play()


# ---------------------------------------------------------------- helpers

func _num(prop: StringName, fallback: float) -> float:
	var v: Variant = car.get(prop)
	return float(v) if (v is float or v is int) else fallback


func _slowmo() -> float:
	if _sound == null:
		return 1.0
	return clampf(float(_sound.get(&"slowmo")), 0.1, 1.0)


static func _smooth(current: float, target: float, tau: float, delta: float) -> float:
	return lerpf(current, target, 1.0 - exp(-delta / maxf(tau, 0.0001)))
