class_name ReplayView
extends Node3D
## What the player saw, rebuilt for renders (tools/replay/review.gd): the recorded route's map
## with its atmosphere, colour grade and ink lines (PostFX, as Main sets them up), the drive's
## quality preset, the car as a ReplayGhost and a camera on the recorded camera transform, FOV
## and lens, the road gates open or closed as they were. The HUD is not drawn. `show_at(t)`
## poses everything for replay time t.

const DRIVING_STATES: Array[String] = ["RACING", "LIAISON", "FREE_ROAM"]
const LETTERBOX_STATES: Array[String] = ["INTRO", "FINISHED", "ARRIVED"]

var replay: ReplayData
var map: MapWorld
var post: PostFX
var ghost: ReplayGhost
var camera: Camera3D
var _last_t: float = NAN
## Gate id -> open at the start of the recording, and the "gate" events that changed them.
var _gates_at_start: Dictionary = {}
var _gate_events: Array[Dictionary] = []


## Builds the scene for `data` (awaitable). Pass `existing_map` to reuse a map that is already
## built (it must be the recorded route); otherwise the route's map is built here.
func setup(data: ReplayData, existing_map: MapWorld = null) -> void:
	replay = data
	var q := str((data.header.get("settings", {}) as Dictionary).get("quality", "high"))
	await build_world(str(data.header.get("route", "hanami")), q, existing_map)
	ghost = ReplayGhost.spawn(self, data.header)
	_gates_at_start = data.header.get("gates", {})
	_gate_events = data.events_of("gate")


## The world without a replay (awaitable): `route`'s map (unless `existing_map`, which must be
## that route) with its atmosphere, colour grade and ink lines at quality preset `quality`, and
## the current camera. setup() starts with it; tools that pose cars of their own call it alone
## (tools/rl/film.gd: the AI's practice runs).
func build_world(route: String, quality: String, existing_map: MapWorld = null) -> void:
	map = existing_map
	if map == null:
		map = MapWorld.new()
		map.name = "Map"
		map.map_id = route
		add_child(map)
		await map.build()
	post = PostFX.new()
	post.name = "ReplayPostFX"
	add_child(post)
	post.apply_preset(map.atmosphere.preset, map.sun_dir)
	Quality.apply(quality, get_window(), map)
	post.apply_quality(quality)
	camera = Camera3D.new()
	camera.name = "ReplayCamera"
	camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(camera)
	camera.make_current()


## Poses the car, the camera and the screen passes for replay time t. A jump back or of more
## than a second snaps the eased screen passes instead of blending them.
func show_at(t: float) -> void:
	var dt := t - _last_t if is_finite(_last_t) else INF
	var snap := not (dt >= 0.0 and dt < 1.0)
	if snap:
		dt = 1.0 / 60.0
	_last_t = t
	var car := replay.car_at(t)
	if ghost != null:
		ghost.pose(car, dt)
	var cam := replay.camera_at(t)
	camera.global_transform = cam["xform"]
	camera.fov = cam["fov"]
	var lens: Dictionary = cam["camera"]
	camera.near = float(lens.get("near", 0.05))
	camera.far = float(lens.get("far", 4000.0))
	camera.h_offset = float(lens.get("h_offset", 0.0))
	camera.v_offset = float(lens.get("v_offset", 0.0))
	var state := replay.state_name(replay.index_at(t))
	var kmh: float = car["kmh"]
	post.speed_target = smoothstep(115.0, 175.0, kmh) * 0.8 if state in DRIVING_STATES else 0.0
	post.letterbox_target = 1.0 if state in LETTERBOX_STATES else 0.0
	if snap:
		post.snap()
	_pose_gates(t)


## Each gate as it stood at replay time t (a gate that changed during the drive switches at
## the time of its event, without the swing).
func _pose_gates(t: float) -> void:
	var open := _gates_at_start.duplicate()
	for e in _gate_events:
		if float(e["t"]) <= t:
			open[e["id"]] = e["open"]
	for id: String in open:
		var gate: RoadGate = map.gates.get(id)
		if gate != null and gate.is_open != bool(open[id]):
			gate.set_open(bool(open[id]), false)
