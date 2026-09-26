extends Node
## Replays autoload: records every drive the player controls to `user://replays/`, one file per
## session, so the lead can see afterwards where a drive went wrong - an input and state log, not
## video (format and review workflow: docs/REPLAYS.md, reader: ReplayData).
##
## Follows the Game autoload only (no Main hooks): a recording opens when the state enters
## COUNTDOWN, RACING, LIAISON or FREE_ROAM from any other state (or on a new session_started)
## while `Game.player_car` is set, runs through the countdown and the drive, keeps a short tail of
## FINISHED / ARRIVED, and closes on any other state, a new session, a different car, or quit.
## A campaign that chains legs on the same car (SS1 -> FINISHED -> LIAISON -> ARRIVED ->
## COUNTDOWN) therefore gets one file per leg.
##
## Every other physics tick (60 Hz) it stores a frame: the keys, the car's shaped inputs, pose,
## velocities, gear, rpm, wheels (contact, surface, spin, steer, travel), the route distance and
## lateral offset, the checkpoint and clock, and the camera of the last rendered frame. Events
## (state changes, countdown, checkpoints, finish, arrival, notices such as wrong way and
## off-route, impacts, landings, resets, smashes, pauses, camera and settings changes) carry
## their time. Frames and events go to a memory buffer; every BLOCK_SECONDS it is compressed and
## appended to the file on a worker thread, so nothing on the main thread touches the disk.
##
## Player runs record by default. Tool runs (`-s` scripts) never record unless a tool asks:
## `Replays.record_to(dir)`, or the command-line user argument `replays=<dir>`; either way never
## into the player's folder.

## Emitted on the main thread once a finished recording is complete on disk.
signal replay_saved(path: String)

const F := preload("res://scripts/game/replay_format.gd")
const PLAYER_FOLDER := "user://replays"
## Retention after each saved replay: the newest MAX_FILES files, at most MAX_BYTES in total.
const MAX_FILES := 100
const MAX_BYTES := 256 * 1024 * 1024
## Seconds of FINISHED / ARRIVED kept at the end of a recording.
const TAIL_SECONDS := 4.0
## Seconds of frames per compressed block.
const BLOCK_SECONDS := 10.0
## A tick in which the car moves this much farther than its speed explains was a teleport.
const RESET_JUMP := 4.0
## Road samples searched around the last one per tick for the route distance.
const SEARCH_WINDOW := 12
const DRIVE_STATES: Array[String] = ["COUNTDOWN", "RACING", "LIAISON", "FREE_ROAM"]
const TAIL_STATES: Array[String] = ["FINISHED", "ARRIVED"]

## Whether drives are recorded (player runs: true; tool runs: false until a tool asks).
var enabled: bool = false
## Where replays go (player runs: PLAYER_FOLDER).
var folder: String = ""
## Path of the recording in progress ("" when idle), and of the last one closed.
var current_path: String = ""
var last_path: String = ""
## Cost and size of the last recording: {"ticks", "mean_us", "max_us", "max_at" (replay time of
## the slowest tick), "over_1ms" (ticks over a millisecond), "frames", "bytes_raw", "seconds"}.
## The cost is the main-thread time of this autoload per physics tick while recording.
var stats: Dictionary = {}

var _game: Node
var _drive: Array[int] = []
var _tail: Array[int] = []
var _state_names: Array[String] = []
var _version: Dictionary = {}
var _want_new: bool = true

# the recording in progress
var _car: Car
var _session: Node
var _track: Track
var _soft: Node
var _t: float = 0.0
var _dt: float = 1.0 / 120.0
var _ticks: int = 0
var _frames: int = 0
var _tail_time: float = 0.0
## Frames (FRAME_SIZE bytes each) and event records since the last block.
var _fbuf := PackedByteArray()
var _flen: int = 0
var _ebuf := PackedByteArray()
var _elen: int = 0
var _block_start: float = 0.0
var _raw_total: int = 0
var _edges: int = 0
var _ti: int = -1
var _last_pos: Vector3
var _last_vel: Vector3
var _surfaces: Dictionary = {} ## surface name -> id (1-based in frames)
var _cameras: Dictionary = {} ## "name|mode" -> id
var _cam_id: int = 255
var _cam_xf: Transform3D
var _cam_fov: float = 70.0
var _cam_t: float = 0.0
var _settings: Dictionary = {}
var _outcome: Dictionary = {} ## the finish or the arrival, repeated in the "end" event
var _cost_sum: int = 0
var _cost_max: int = 0
var _cost_max_t: float = 0.0
var _cost_over: int = 0 ## ticks that took over 1 ms

# disk writer (worker thread)
var _mutex := Mutex.new()
var _jobs: Array[Dictionary] = []
var _draining: bool = false
var _task: int = -1


func _enter_tree() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	# The camera sample must see this frame's camera: process after everything else.
	process_priority = 1000
	var tool_run := get_tree().get_script() != null
	enabled = not tool_run
	folder = "" if tool_run else PLAYER_FOLDER
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("replays="):
			record_to(arg.substr(8))


func _ready() -> void:
	_game = get_node_or_null(^"/root/Game")
	if _game == null:
		enabled = false
		return
	var states: Dictionary = _game.State
	for key in states:
		while _state_names.size() <= int(states[key]):
			_state_names.append("")
		_state_names[int(states[key])] = str(key)
	for n in DRIVE_STATES:
		if states.has(n):
			_drive.append(int(states[n]))
	for n in TAIL_STATES:
		if states.has(n):
			_tail.append(int(states[n]))
	_version = _git_version()
	_game.state_changed.connect(_on_state_changed)
	_game.session_started.connect(_on_session_started)
	_game.countdown_tick.connect(func(v: int) -> void: _event({"type": "countdown", "value": v}))
	_game.race_started.connect(func() -> void: _event({"type": "start"}))
	_game.checkpoint_passed.connect(func(index: int, total: int, split: float, delta: float) -> void:
		_event({"type": "checkpoint", "index": index, "total": total, "split": split, "delta": delta}))
	_game.race_finished.connect(func(result: Dictionary) -> void:
		var e := result.duplicate()
		e["type"] = "finish"
		_event(e)
		_outcome = {"finished": result.get("time", 0.0), "medal": result.get("medal", ""),
				"record": result.get("is_record", false)})
	_game.arrived.connect(func() -> void:
		_event({"type": "arrived"})
		_outcome = {"arrived": true})
	_game.notice.connect(func(text: String) -> void: _event({"type": "notice", "text": text}))
	_game.paused_changed.connect(func(p: bool) -> void: _event({"type": "pause", "paused": p}))
	_game.settings_changed.connect(_on_settings_changed)


## Tools: record the drives of this run into `dir` (created if needed). Refused for the
## player's folder.
func record_to(dir: String) -> void:
	var abs_dir := ProjectSettings.globalize_path(dir).simplify_path()
	if abs_dir == ProjectSettings.globalize_path(PLAYER_FOLDER).simplify_path():
		push_warning("Replays: tool runs never record into the player's folder")
		return
	folder = abs_dir
	enabled = true


func is_recording() -> bool:
	return _car != null


## Replay time of the frame rendered last (tools pair live captures with replay renders).
func frame_time() -> float:
	return _cam_t


## Tools: closes the recording in progress and waits until every file is on disk.
func flush() -> void:
	if _car != null:
		_close("flush")
	_wait_writer()


func _exit_tree() -> void:
	if _car != null:
		_close("quit")
	_wait_writer()


# ---------------------------------------------------------------- session boundaries

func _on_state_changed(new_state: int, old_state: int) -> void:
	if new_state in _drive and not old_state in _drive:
		_want_new = true
	var e := {"type": "state", "from": _state_name(old_state), "to": _state_name(new_state)}
	_event(e)
	# Open at once (the countdown ticks follow in this frame) and close at once (also while
	# paused, e.g. pause -> main menu).
	if _sync(0.0):
		_event(e)


func _on_session_started(_map_id: String, _mode: String) -> void:
	if _car != null:
		_close("new session")
	_want_new = true


func _physics_process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_sync(delta)
	if _car == null:
		return
	if _ticks > 0:
		_t += delta
	_dt = delta
	_ticks += 1
	_tick()
	var cost := Time.get_ticks_usec() - t0
	_cost_sum += cost
	if cost > _cost_max:
		_cost_max = cost
		_cost_max_t = _t
	if cost > 1000:
		_cost_over += 1


## Opens or closes the recording for the current Game state and car; `delta` advances the
## FINISHED / ARRIVED tail. Returns true when it opened a recording.
func _sync(delta: float) -> bool:
	if not enabled or folder == "" or _game == null:
		if _car != null:
			_close("disabled")
			_want_new = true
		return false
	var car: Car = null
	if is_instance_valid(_game.player_car):
		car = _game.player_car as Car
	var state: int = _game.state
	if _car != null:
		if car != _car or not is_instance_valid(_car):
			_close("car changed")
			_want_new = true
		elif state in _tail:
			_tail_time += delta
			if _tail_time > TAIL_SECONDS:
				_close("end of " + _state_name(state))
		elif state in _drive:
			_tail_time = 0.0
			if _want_new:
				_close("next drive")
		else:
			_close("state " + _state_name(state))
	if _car == null and car != null and state in _drive and _want_new:
		_open(car)
		return true
	return false


func _process(_delta: float) -> void:
	if _car == null:
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		_cam_id = 255
		return
	_cam_xf = cam.get_global_transform_interpolated() if cam.is_physics_interpolated_and_enabled() \
			else cam.global_transform
	_cam_fov = cam.fov
	_cam_t = _t + Engine.get_physics_interpolation_fraction() * _dt
	var mode: String = str(cam.get(&"mode")) if &"mode" in cam else ""
	var key := "%s|%s" % [cam.name, mode]
	if not _cameras.has(key):
		_cameras[key] = _cameras.size()
		_event({"type": "camera", "id": _cameras[key], "name": String(cam.name), "mode": mode,
				"near": cam.near, "far": cam.far, "h_offset": cam.h_offset, "v_offset": cam.v_offset})
	_cam_id = _cameras[key]


# ---------------------------------------------------------------- recording

func _open(car: Car) -> void:
	_car = car
	_session = _game.session if is_instance_valid(_game.session) else null
	if _session != null and _session.get(&"car") != car:
		_session = null
	_track = _session.get(&"track") as Track if _session != null else null
	var map: Node = _session.get(&"map") if _session != null else null
	_soft = map.get(&"soft_course") if map != null and &"soft_course" in map else null
	_t = 0.0
	_ticks = 0
	_frames = 0
	_tail_time = 0.0
	_flen = 0
	_elen = 0
	_block_start = 0.0
	_raw_total = 0
	_edges = 0
	_ti = -1
	_last_pos = car.global_position
	_last_vel = car.linear_velocity
	_surfaces.clear()
	_cameras.clear()
	_cam_id = 255
	_cam_xf = Transform3D.IDENTITY
	_cost_sum = 0
	_cost_max = 0
	_cost_max_t = 0.0
	_cost_over = 0
	_want_new = false
	_outcome = {}
	var block_frames := int(BLOCK_SECONDS * Engine.physics_ticks_per_second / F.TICKS_PER_FRAME) + 8
	if _fbuf.size() < block_frames * F.FRAME_SIZE:
		_fbuf.resize(block_frames * F.FRAME_SIZE)
	if _ebuf.size() < 16 * 1024:
		_ebuf.resize(16 * 1024)
	_settings = (_game.settings as Dictionary).duplicate()
	var route: String = str(_game.map_id)
	if map != null:
		var rid: Variant = map.get(&"route_id")
		route = str(rid) if rid != null and str(rid) != "" else str(map.get(&"map_id"))
	var now := Time.get_datetime_dict_from_system()
	var stamp := "%04d-%02d-%02d_%02d-%02d-%02d" % [now.year, now.month, now.day, now.hour, now.minute, now.second]
	var base := "%s_%s_%s" % [stamp, route.validate_filename(), str(_game.mode).validate_filename()]
	current_path = folder.path_join(base + "." + F.EXTENSION)
	var n := 2
	while FileAccess.file_exists(current_path):
		current_path = folder.path_join("%s_%d.%s" % [base, n, F.EXTENSION])
		n += 1
	var car_id := str(_settings.get("car_id", ""))
	var track_info := {}
	if _track != null:
		var cps: Array[float] = []
		for cp: Dictionary in map.get(&"checkpoints"):
			cps.append(float(cp.get("progress", 0.0)))
		track_info = {"length": _track.length, "closed": _track.closed, "checkpoints": cps}
	var header := {
		"game": ProjectSettings.get_setting("application/config/name", ""),
		"version": _version,
		"engine": Engine.get_version_info().get("string", ""),
		"date": Time.get_datetime_string_from_system(false, true),
		"date_utc": Time.get_datetime_string_from_system(true, true),
		"unix": Time.get_unix_time_from_system(),
		"route": route,
		"mode": str(_game.mode),
		"state": _state_name(_game.state),
		"campaign": {"active": _game.campaign_active, "leg": _game.campaign_leg},
		"car": car_id,
		"car_scene": car.scene_file_path,
		"livery": {"index": _settings.get("car_color", 0), "primary": car.livery_primary,
				"secondary": car.livery_secondary},
		"settings": _settings,
		"tool_run": get_tree().get_script() != null,
		"os": OS.get_name(),
		"tick_rate": Engine.physics_ticks_per_second,
		"ticks_per_frame": F.TICKS_PER_FRAME,
		"frame_size": F.FRAME_SIZE,
		"states": _state_names,
		"buttons": F.BUTTONS,
		"surfaces": [],
		"track": track_info,
		"spawn": {"pos": car.global_position, "yaw": car.global_rotation.y},
	}
	_submit({"op": "create", "path": current_path, "bytes": F.header_bytes(header)})
	car.impact.connect(_on_impact)
	car.landed.connect(_on_landed)
	if _session != null and _session.has_signal(&"reset_needed"):
		_session.reset_needed.connect(_on_reset_needed)
	if _soft != null:
		if _soft.has_signal(&"smashed"):
			_soft.smashed.connect(_on_smashed)
		if _soft.has_signal(&"upright_hit"):
			_soft.upright_hit.connect(_on_upright_hit)


func _close(reason: String) -> void:
	var dur := _t
	stats = {"ticks": _ticks, "mean_us": float(_cost_sum) / maxf(_ticks, 1), "max_us": _cost_max, "max_at": _cost_max_t, "over_1ms": _cost_over,
			"frames": _frames, "bytes_raw": _raw_total + _flen + _elen, "seconds": dur}
	var end := stats.duplicate()
	end["type"] = "end"
	end["reason"] = reason
	end.merge(_outcome)
	_event(end)
	if is_instance_valid(_car):
		if _car.impact.is_connected(_on_impact):
			_car.impact.disconnect(_on_impact)
		if _car.landed.is_connected(_on_landed):
			_car.landed.disconnect(_on_landed)
	if is_instance_valid(_session) and _session.has_signal(&"reset_needed") \
			and _session.reset_needed.is_connected(_on_reset_needed):
		_session.reset_needed.disconnect(_on_reset_needed)
	if is_instance_valid(_soft):
		if _soft.has_signal(&"smashed") and _soft.smashed.is_connected(_on_smashed):
			_soft.smashed.disconnect(_on_smashed)
		if _soft.has_signal(&"upright_hit") and _soft.upright_hit.is_connected(_on_upright_hit):
			_soft.upright_hit.disconnect(_on_upright_hit)
	_flush_block()
	_submit({"op": "done", "path": current_path, "dir": folder})
	last_path = current_path
	current_path = ""
	_car = null
	_session = null
	_track = null
	_soft = null


func _tick() -> void:
	for b in range(F.HELD_BUTTONS, F.BUTTONS.size()):
		if Input.is_action_just_pressed(F.BUTTONS[b]):
			_edges |= 1 << b
	var pos := _car.global_position
	var vel := _car.linear_velocity
	if _ticks > 1 and pos.distance_to(_last_pos) > RESET_JUMP + maxf(vel.length(), _last_vel.length()) * _dt * 2.0:
		var key := _edges & (1 << F.BUTTONS.find(&"reset_car")) != 0 or Input.is_action_pressed(&"reset_car")
		_event({"type": "reset", "from": _last_pos, "to": pos, "key": key, "s": route_s_hint()})
		_ti = -1
	_last_pos = pos
	_last_vel = vel
	if (_ticks - 1) % F.TICKS_PER_FRAME == 0:
		_write_frame(pos, vel)
		if _t - _block_start >= BLOCK_SECONDS:
			_flush_block()
			_block_start = _t


## Route distance of the last frame (for events).
func route_s_hint() -> float:
	return _track.progress_of(_ti, _car.global_position) if _track != null and _ti >= 0 else -1.0


func _write_frame(pos: Vector3, vel: Vector3) -> void:
	if _fbuf.size() < _flen + F.FRAME_SIZE:
		_fbuf.resize(_fbuf.size() * 2)
	# Written straight into the member: a local copy of a packed array would copy on write.
	var o := _flen
	var car := _car
	var buttons := _edges
	for i in F.HELD_BUTTONS:
		if Input.is_action_pressed(F.BUTTONS[i]):
			buttons |= 1 << i
	_edges = 0
	var flags := 0
	if car.controlled_by_player:
		flags |= F.F_PLAYER
	if car.launch_hold:
		flags |= F.F_LAUNCH_HOLD
	if car.is_shifting:
		flags |= F.F_SHIFTING
	if car.player_input.analog_steer:
		flags |= F.F_ANALOG
	var s := -1.0
	var lat := 0.0
	var half := 0.0
	if _track != null:
		_ti = _track.nearest(pos, _ti, SEARCH_WINDOW) if _ti >= 0 else _track.nearest(pos)
		s = _track.progress_of(_ti, pos)
		lat = _track.lateral(_ti, pos)
		half = _track.half_width(_ti)
		if absf(lat) <= half:
			flags |= F.F_ON_ROAD
	var checkpoint := 0
	var elapsed := 0.0
	if _session != null and is_instance_valid(_session):
		checkpoint = int(_session.get(&"checkpoint_index"))
		elapsed = float(_session.get(&"elapsed"))
		if _session.get(&"running"):
			flags |= F.F_RUNNING
	_fbuf.encode_float(o + F.O_T, _t)
	_fbuf.encode_u16(o + F.O_BUTTONS, buttons)
	_fbuf.encode_u16(o + F.O_FLAGS, flags)
	_fbuf[o + F.O_STATE] = clampi(_game.state, 0, 255)
	_fbuf.encode_s8(o + F.O_GEAR, clampi(car.gear, -127, 127))
	_fbuf.encode_s8(o + F.O_IN_STEER, int(roundf(clampf(car.input_steer, -1.0, 1.0) * 127.0)))
	_fbuf[o + F.O_IN_THROTTLE] = int(roundf(clampf(car.input_throttle, 0.0, 1.0) * 255.0))
	_fbuf[o + F.O_IN_BRAKE] = int(roundf(clampf(car.input_brake, 0.0, 1.0) * 255.0))
	_fbuf.encode_s8(o + F.O_STEER, int(roundf(clampf(car.steer, -1.0, 1.0) * 127.0)))
	_fbuf[o + F.O_HANDBRAKE] = int(roundf(clampf(car.handbrake, 0.0, 1.0) * 255.0))
	_fbuf[o + F.O_GROUNDED] = clampi(car.grounded_wheels, 0, 255)
	_fbuf.encode_float(o + F.O_POS, pos.x)
	_fbuf.encode_float(o + F.O_POS + 4, pos.y)
	_fbuf.encode_float(o + F.O_POS + 8, pos.z)
	F.quat_encode(_fbuf, o + F.O_ROT, car.global_basis.get_rotation_quaternion())
	_fbuf.encode_half(o + F.O_LIN, vel.x)
	_fbuf.encode_half(o + F.O_LIN + 2, vel.y)
	_fbuf.encode_half(o + F.O_LIN + 4, vel.z)
	var ang := car.angular_velocity
	_fbuf.encode_half(o + F.O_ANG, ang.x)
	_fbuf.encode_half(o + F.O_ANG + 2, ang.y)
	_fbuf.encode_half(o + F.O_ANG + 4, ang.z)
	_fbuf.encode_u16(o + F.O_RPM, clampi(int(car.rpm), 0, 65535))
	_fbuf.encode_half(o + F.O_KMH, car.speed_kmh)
	_fbuf.encode_half(o + F.O_SLIP, car.body_slip)
	for w in 4:
		var ws: WheelState = car.wheels[w]
		var wo := o + F.O_WHEELS + w * F.WHEEL_SIZE
		_fbuf[wo + F.W_SURFACE] = _surface_id(ws.surface) if ws.contact else 0
		_fbuf[wo + F.W_COMPRESSION] = int(roundf(clampf(ws.compression, 0.0, 1.0) * 255.0))
		_fbuf.encode_u16(wo + F.W_SPIN_ANGLE, int(fposmod(ws.spin_angle, TAU) / TAU * 65536.0) & 0xffff)
		_fbuf.encode_half(wo + F.W_SPIN_SPEED, ws.spin_speed)
		_fbuf.encode_half(wo + F.W_STEER, ws.steer_angle)
		_fbuf.encode_half(wo + F.W_OFFSET, ws.offset_y)
	_fbuf.encode_float(o + F.O_S, s)
	_fbuf.encode_half(o + F.O_LAT, lat)
	_fbuf[o + F.O_HALF] = clampi(int(roundf(half * 10.0)), 0, 255)
	_fbuf[o + F.O_CHECKPOINT] = clampi(checkpoint, 0, 255)
	_fbuf[o + F.O_CAMERA] = _cam_id
	_fbuf[o + F.O_PAD] = 0
	_fbuf.encode_float(o + F.O_ELAPSED, elapsed)
	var cam := _cam_xf.origin - pos
	_fbuf.encode_half(o + F.O_CAM_POS, cam.x)
	_fbuf.encode_half(o + F.O_CAM_POS + 2, cam.y)
	_fbuf.encode_half(o + F.O_CAM_POS + 4, cam.z)
	F.quat_encode(_fbuf, o + F.O_CAM_ROT, _cam_xf.basis.get_rotation_quaternion())
	_fbuf.encode_half(o + F.O_CAM_FOV, _cam_fov)
	_fbuf.encode_half(o + F.O_CAM_DT, _cam_t - _t)
	_flen += F.FRAME_SIZE
	_frames += 1


func _surface_id(surface: StringName) -> int:
	var id: int = _surfaces.get(surface, 0)
	if id == 0:
		id = _surfaces.size() + 1
		_surfaces[surface] = id
		_event({"type": "surface", "id": id - 1, "name": String(surface)})
	return id


func _event(e: Dictionary) -> void:
	if _car == null:
		return
	_elen = F.append_event(_ebuf, _elen, _t, e)


func _flush_block() -> void:
	if _flen == 0 and _elen == 0:
		return
	_raw_total += _flen + _elen
	_submit({"op": "block", "path": current_path, "frames": _fbuf.slice(0, _flen),
			"count": _flen / F.FRAME_SIZE, "events": _ebuf.slice(0, _elen)})
	_flen = 0
	_elen = 0


# ---------------------------------------------------------------- car / course events

func _on_impact(strength: float, point: Vector3) -> void:
	_event({"type": "impact", "strength": strength, "point": point, "kmh": _car.speed_kmh})


func _on_landed(strength: float) -> void:
	_event({"type": "landed", "strength": strength, "kmh": _car.speed_kmh})


func _on_reset_needed(reason: String) -> void:
	_event({"type": "hazard", "reason": reason})


func _on_smashed(prop: String, point: Vector3, speed_before: float, loss: float) -> void:
	_event({"type": "smash", "prop": prop, "point": point, "speed": speed_before, "loss": loss})


func _on_upright_hit(point: Vector3, speed_before: float, loss: float) -> void:
	_event({"type": "upright", "point": point, "speed": speed_before, "loss": loss})


func _on_settings_changed() -> void:
	var changed := {}
	for key in _game.settings:
		if _settings.get(key) != _game.settings[key]:
			changed[key] = _game.settings[key]
	_settings = (_game.settings as Dictionary).duplicate()
	if not changed.is_empty():
		_event({"type": "settings", "changed": changed})


func _state_name(s: int) -> String:
	return _state_names[s] if s >= 0 and s < _state_names.size() else str(s)


# ---------------------------------------------------------------- disk (worker thread)

func _submit(job: Dictionary) -> void:
	_mutex.lock()
	_jobs.append(job)
	var start := not _draining
	_draining = true
	_mutex.unlock()
	if start:
		if _task >= 0:
			WorkerThreadPool.wait_for_task_completion(_task)
		_task = WorkerThreadPool.add_task(_drain, false, "Replays writer")


func _wait_writer() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1


func _drain() -> void:
	while true:
		_mutex.lock()
		if _jobs.is_empty():
			_draining = false
			_mutex.unlock()
			return
		var job: Dictionary = _jobs.pop_front()
		_mutex.unlock()
		_run_job(job)


func _run_job(job: Dictionary) -> void:
	var path: String = job["path"]
	match str(job["op"]):
		"create":
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
			var f := FileAccess.open(path, FileAccess.WRITE)
			if f != null:
				f.store_buffer(job["bytes"])
		"block":
			var f := FileAccess.open(path, FileAccess.READ_WRITE)
			if f != null:
				f.seek_end()
				f.store_buffer(F.block_bytes(job["frames"], job["count"], job["events"]))
		"done":
			_prune(str(job["dir"]))
			_saved.call_deferred(path)


func _saved(path: String) -> void:
	replay_saved.emit(path)


## Keeps the newest MAX_FILES replays and at most MAX_BYTES (names start with the date).
static func _prune(dir: String) -> void:
	var names := Array(DirAccess.get_files_at(dir)).filter(
			func(n: String) -> bool: return n.get_extension() == F.EXTENSION)
	names.sort()
	names.reverse()
	var total := 0
	for i in names.size():
		var p := dir.path_join(names[i])
		var f := FileAccess.open(p, FileAccess.READ)
		total += f.get_length() if f != null else 0
		f = null
		if i >= MAX_FILES or total > MAX_BYTES:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


## The source checkout's commit and branch when running from one (cheap file reads), else {}.
static func _git_version() -> Dictionary:
	var root := ProjectSettings.globalize_path("res://")
	if root == "":
		return {}
	var git := root.path_join(".git")
	if FileAccess.file_exists(git):
		var line := FileAccess.get_file_as_string(git).strip_edges()
		if not line.begins_with("gitdir:"):
			return {}
		git = line.substr(7).strip_edges()
	if not DirAccess.dir_exists_absolute(git):
		return {}
	var head := FileAccess.get_file_as_string(git.path_join("HEAD")).strip_edges()
	if not head.begins_with("ref:"):
		return {"commit": head.left(12)}
	var ref := head.substr(4).strip_edges()
	var common := git
	if FileAccess.file_exists(git.path_join("commondir")):
		common = git.path_join(FileAccess.get_file_as_string(git.path_join("commondir")).strip_edges()).simplify_path()
	var out := {"branch": ref.trim_prefix("refs/heads/")}
	for dir in [git, common]:
		if FileAccess.file_exists(dir.path_join(ref)):
			out["commit"] = FileAccess.get_file_as_string(dir.path_join(ref)).strip_edges().left(12)
			return out
	for line in FileAccess.get_file_as_string(common.path_join("packed-refs")).split("\n"):
		if line.ends_with(" " + ref):
			out["commit"] = line.left(12)
	return out
