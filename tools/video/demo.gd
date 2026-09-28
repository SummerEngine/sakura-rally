extends SceneTree
## Episode 3 trailer footage, rendered offline by Movie Maker: run tools/video/render_demo.sh, not
## this script directly (cue times count Movie Maker frames at 60 fps). The real game in the one
## world, in free roam (the branch gates open), under a shot list of directed cameras:
##   Hanami in spring: a low drone over the cherry valley; the car at speed through the blossoms;
##   past the hairpin warning sign; wide through the hay bales under the crowd (slow motion); the
##   crowd at the next hairpin; sideways along a gravel guardrail. The road between the stages in
##   summer: over the stone bridge, down the festival street. Momiji in autumn at golden hour: the
##   river bridge, a crane up from a hairpin. A wide aerial over the Hanami start village under the
##   title card. Then back to the title hub for the garage workshop and one livery brushed on (the
##   edit puts the garage before the card).
## Each car shot puts the car on its road ahead of the in-point, at speed, under the showoff
## autopilot, so it arrives settled; the camera is on its rig from that moment, so streaming and
## the season (which follows the camera) have settled by the in-point too.
##
## The take is square (1920x1920): cut_demo.py crops the 16:9 edit (1920x1080, the full width)
## and the 9:16 edit (1080x1920, the full height) from the same frames, so every rig keeps its
## subject in the middle. FOVs below are the square's; with another window shape the camera keeps
## the view of the 16:9 crop (stills) or of the 9:16 crop.
## Music is muted here: cut_demo.py lays one continuous track under the edit. Cues (footage seconds)
## go to <footage>/cues.json: every shot's camera cut (<name>_start), in-point (<name>), the car
## passing a roadside camera (<name>_pass) and end (<name>_end); the first smash, the livery
## change and the title card.
##
## Check the flow headless (no pixels; --fixed-fps 60 steps time as Movie Maker does):
##   timeout -k 10 900 nice -n 10 $S --headless --fixed-fps 60 --audio-driver Dummy \
##       --disable-crash-handler --path . -s res://tools/video/demo.gd -- footage=/tmp/sakura_trailer_check
## Stills instead of footage (render_demo.sh --stills):
##   ... -- stills=<dir>             each shot's `still` moment as a PNG
##   ... -- stills=<dir> frames=5    five frames per shot, in to out, for composition checks
## shots=<name,...> runs only those shots.

const SLOWMO := 0.35
const LIVERY := 1 ## the garage brushes this livery on (Game.CAR_COLORS: Momiji, vermilion)

## The shot list, in take order (the edit picks and orders them). Keys:
##   route  the road the car drives ("" = a camera move without the car)
##   at     route progress (m) of the in-point: the shot's cue fires when the car gets there
##   kmh    the car's speed where it is put down, `lead` s of driving before `at`
##   lead   s before the in-point (settling time); for a shot without the car, plain seconds
##   len    s the shot runs after the in-point
##   style  the autopilot's style (default &"showoff"); speed: its speed_scale (default 1);
##          max_kmh: its top speed (default the autopilot's)
##   slow   [from, to] route progress of a slow-motion stretch
##   swerve [peak, half length, lead, lateral] the autopilot's line bent out into the dressing
##   still  s after the in-point for the shot's 2560x1440 still (absent: no still)
##   park   a shot without the car parks it at this route's start, out of the way
##   card   s after the in-point when the title card comes in
##   livery s after the in-point when the garage brushes on LIVERY
##   rig    the camera, one of:
##     fly      from/to [x, height above ground, z] at the in-point / `dur` s later (constant
##              speed, before and after too), looking along [yaw°, pitch°] (yaw 0 = +x, 90 = +z);
##              abs: true reads the heights as world y
##     follow   off [right, up, back] in the car's frame (heading smoothed over `smooth` s, from
##              where it travels, so a slide shows), looking at car + look [right, up, ahead]
##     lead     on the road `d` m ahead of the car (lateral lat, h above the road), looking back
##              at it (look_h above its origin): a tracking shot that stays on the road in bends
##     roadside at route progress s, lateral lat, h above the road or the ground there, whichever
##              is higher; moving to s2 / lat2 / h2 over `dur` s from the in-point when given (a
##              crane or a dolly). Aims at `aim` [s, lat, h] (placed the same way) blended with the
##              car by `follow` (default: the car alone); the car counts once it is `ahead` m past
##              s (before that, the road there), `tilt` m higher. A critically damped spring over
##              `smooth` s turns the camera, led by the car's velocity so a car on the move stays
##              centred. The car passing s is cued as <name>_pass (slow motion stretches a shot, so
##              the edit counts from there).
##     orbit    around the garage display spot: radius, h, angle a0 -> a1 (° from the road side
##              toward the car's front) over `dur` s from the in-point
##   fov is the square frame's field of view (degrees).
const SHOTS: Array[Dictionary] = [
	{"name": "opener", "route": "", "park": "momiji", "lead": 1.5, "len": 3.0, "still": 1.0,
		"rig": {"type": "fly", "from": [80.0, 14.0, 390.0], "to": [30.0, 14.0, 316.0], "dur": 3.0,
			"look": [235.0, -5.0], "fov": 56.0}},
	{"name": "valley", "route": "hanami", "at": 110.0, "kmh": 125.0, "lead": 3.0, "len": 3.5,
		"rig": {"type": "lead", "d": 13.0, "lat": 0.6, "h": 1.1, "look_h": 0.6, "fov": 34.0}},
	{"name": "sign", "route": "hanami", "at": 590.0, "kmh": 115.0, "lead": 3.0, "len": 3.3,
		"rig": {"type": "follow", "off": [0.0, 1.0, 6.5], "look": [0.0, 1.5, 10.0], "fov": 48.0, "smooth": 0.35}},
	{"name": "crash", "route": "hanami", "at": 630.0, "kmh": 100.0, "lead": 3.0, "len": 5.0, "still": 2.3,
		"swerve": [672.0, 30.0, 4.0, 8.5], "slow": [655.0, 700.0],
		"rig": {"type": "roadside", "s": 686.0, "lat": -15.0, "h": 1.6, "ahead": -40.0, "tilt": 2.2, "fov": 46.0,
			"smooth": 0.3}},
	{"name": "crowd", "route": "hanami", "at": 925.0, "kmh": 90.0, "lead": 3.0, "len": 5.5, "still": 3.8,
		"rig": {"type": "roadside", "s": 950.0, "lat": 36.0, "h": 2.4, "ahead": -12.0, "fov": 42.0, "smooth": 0.3}},
	{"name": "rail", "route": "hanami", "at": 2355.0, "kmh": 85.0, "lead": 3.0, "len": 5.2, "still": 2.9,
		"slow": [2396.0, 2426.0],
		"rig": {"type": "roadside", "s": 2432.0, "lat": -9.5, "h": 2.0, "ahead": -74.0, "fov": 34.0, "smooth": 0.3}},
	{"name": "bridge", "route": "liaison", "at": 1100.0, "kmh": 95.0, "lead": 3.0, "len": 3.5, "max_kmh": 100.0,
		"rig": {"type": "roadside", "s": 1150.0, "lat": 34.0, "h": 6.0, "aim": [1150.0, 0.0, 1.0], "follow": 0.8,
			"ahead": -40.0, "fov": 40.0, "smooth": 0.3}},
	{"name": "village", "route": "liaison", "at": 1300.0, "kmh": 60.0, "lead": 3.0, "len": 4.0, "still": 2.0,
		"style": &"tidy", "max_kmh": 62.0,
		"rig": {"type": "follow", "off": [1.2, 2.2, 9.0], "look": [0.0, 0.6, 6.0], "fov": 50.0, "smooth": 0.6}},
	{"name": "momiji_bridge", "route": "momiji", "at": 735.0, "kmh": 90.0, "lead": 3.0, "len": 3.2, "still": 1.2,
		"rig": {"type": "roadside", "s": 770.0, "lat": 40.0, "h": 12.0, "ahead": -35.0, "fov": 38.0, "smooth": 0.35}},
	{"name": "momiji_crane", "route": "momiji", "at": 1040.0, "kmh": 90.0, "lead": 3.0, "len": 5.2, "still": 3.8,
		"rig": {"type": "roadside", "s": 1086.0, "lat": 15.0, "h": 1.2, "lat2": 17.0, "h2": 13.0, "dur": 5.0,
			"ahead": -40.0, "fov": 50.0, "smooth": 0.3}},
	{"name": "aerial", "route": "", "park": "momiji", "lead": 2.0, "len": 7.0, "card": 0.8,
		"rig": {"type": "fly", "from": [190.0, 110.0, 490.0], "to": [165.0, 108.0, 465.0], "dur": 7.0,
			"look": [235.0, -14.0], "fov": 58.0}},
	{"name": "garage", "route": "", "lead": 1.5, "len": 4.0, "still": 2.6, "livery": 1.0,
		"rig": {"type": "orbit", "radius": 9.5, "h": 1.5, "a0": 25.0, "a1": 45.0, "dur": 4.0, "fov": 50.0}},
]

## footage=<dir>: where cues.json goes. (Not `out=`: under --summer-offscreen Summer reads an
## `out=` user argument as a probe's results folder and closes the window ~30 s into the take.)
var opts := {"footage": "/tmp/sakura_trailer"}
var main: Node
var game: Node
var reached: Dictionary = {}
var marked: Dictionary = {}
var cues: Array[Dictionary] = []
var director: Director
var card: Control
var _frame0 := 0
var _keep: KeepDrawing
var _smashed := 0
var _knocked := 0
var _stills := 0


## Runs last in every _process: when the engine will not draw this iteration (macOS reports the
## window covered, as it does under a fullscreen video), renders the frame into the viewport
## texture that Movie Maker and the stills read, in this iteration. Noticing the skipped draw one
## iteration late held one frame and doubled the next at every covered/visible switch; the frame
## drawn here matches the engine's own because the Director pushes its camera to the renderer
## the moment it moves it and the car moves in physics.
class KeepDrawing extends Node:
	var forced := 0

	func _init() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		process_priority = 1 << 30

	func _process(delta: float) -> void:
		if not DisplayServer.window_can_draw() or not RenderingServer.render_loop_enabled:
			RenderingServer.force_draw(false, delta)
			forced += 1


## Moves the trailer camera every frame by the current shot's rig, after everything else has
## moved (the car's interpolated transform is final by then), and keeps the speed lines off
## (they belong to the chase camera).
class Director extends Node:
	var cam := Camera3D.new()
	var car: Car
	var track: Track
	var post: Node
	var rig: Dictionary = {}
	var t := 0.0 ## rig time (s, slowed with the game)
	var t_in := -1.0 ## rig time of the in-point, -1 before it
	var lead := 0.0 ## a shot without the car reaches its in-point `lead` s after the start
	var fixed := Vector3.ZERO ## roadside / fly start, orbit centre, worked out when the shot starts
	var fixed2 := Vector3.ZERO ## roadside / fly end, orbit side
	var still_aim := Vector3.ZERO ## roadside `aim`
	var aim := Vector3.ZERO
	var aim_vel := Vector3.ZERO
	var heading := Vector3.FORWARD
	var _hint := -1

	func _init() -> void:
		process_priority = (1 << 30) - 1
		cam.name = "TrailerCamera"
		cam.near = 0.1
		cam.far = 12000.0
		cam.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		add_child(cam)

	func start(new_rig: Dictionary, new_track: Track, new_lead: float, space: PhysicsDirectSpaceState3D) -> void:
		rig = new_rig
		track = new_track
		lead = new_lead
		t = 0.0
		t_in = -1.0
		_hint = -1
		match str(rig["type"]):
			"roadside":
				fixed = _spot(rig["s"], rig["lat"], rig["h"], space)
				fixed2 = _spot(rig.get("s2", rig["s"]), rig.get("lat2", rig["lat"]), rig.get("h2", rig["h"]), space)
				if rig.has("aim"):
					var a: Array = rig["aim"]
					still_aim = _spot(a[0], a[1], a[2], space)
			"fly":
				var a: Array = rig["from"]
				var b: Array = rig["to"]
				var ga := Vector3(a[0], 0.0, a[2]) if rig.get("abs", false) else _ground(Vector3(a[0], 0.0, a[2]), space)
				var gb := Vector3(b[0], 0.0, b[2]) if rig.get("abs", false) else _ground(Vector3(b[0], 0.0, b[2]), space)
				fixed = ga + Vector3.UP * float(a[1])
				fixed2 = gb + Vector3.UP * float(b[1])
		if car != null:
			var xf := car.get_global_transform_interpolated()
			heading = _flat(-xf.basis.z)
			aim = xf.origin
			aim_vel = Vector3.ZERO
		_update(0.0, true)

	func mark_in() -> void:
		t_in = t

	func _process(delta: float) -> void:
		if post != null:
			post.grade_material.set_shader_parameter("speed", 0.0)
		# Native pixels: the quality budget would render a take bigger than 1080p at 0.75 and
		# upscale it (Quality.RENDER_BUDGET_PX); Main re-applies it on car spawns.
		var win := get_window()
		if win.scaling_3d_scale != 1.0:
			win.scaling_3d_scale = 1.0
			win.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
		if rig.is_empty():
			return
		if not cam.current: # Main's cameras (the garage orbit, the chase) take over on state changes
			cam.make_current()
		t += delta
		_update(delta, false)

	## Seconds since the in-point (0 before it for car shots; by the clock for the others).
	func since_in() -> float:
		if t_in >= 0.0:
			return t - t_in
		return t - lead if car == null or track == null else 0.0

	func _update(dt: float, snap: bool) -> void:
		var pos := cam.global_position
		var look := Vector3.ZERO
		var u := since_in()
		match str(rig["type"]):
			"fly":
				pos = fixed.lerp(fixed2, u / float(rig["dur"]))
				var dir: Array = rig["look"]
				var yaw := deg_to_rad(float(dir[0]))
				var pitch := deg_to_rad(float(dir[1]))
				look = pos + Vector3(cos(yaw) * cos(pitch), sin(pitch), sin(yaw) * cos(pitch))
			"follow":
				var xf := car.get_global_transform_interpolated()
				var v := car.linear_velocity
				v.y = 0.0
				var want := v.normalized() if v.length() > 3.0 else _flat(-xf.basis.z)
				if snap:
					heading = want
				else:
					heading = heading.slerp(want, 1.0 - exp(-dt / float(rig["smooth"]))).normalized()
				var right := heading.cross(Vector3.UP).normalized()
				var o: Array = rig["off"]
				var l: Array = rig["look"]
				pos = xf.origin + right * float(o[0]) + Vector3.UP * float(o[1]) - heading * float(o[2])
				pos.y = maxf(pos.y, _ground_y(pos) + 0.5)
				look = xf.origin + right * float(l[0]) + Vector3.UP * float(l[1]) + heading * float(l[2])
			"lead":
				var xf := car.get_global_transform_interpolated()
				_hint = track.nearest(xf.origin, _hint)
				var ahead := track.progress_of(_hint, xf.origin) + float(rig["d"])
				pos = track.transform_at_progress(fposmod(ahead, track.length) if track.closed else ahead,
						rig["lat"]).origin + Vector3.UP * float(rig["h"])
				look = xf.origin + Vector3.UP * float(rig["look_h"])
			"roadside":
				pos = fixed
				if rig.has("dur"):
					pos = fixed.lerp(fixed2, smoothstep(0.0, float(rig["dur"]), u))
				look = _aim(dt, snap)
			"orbit":
				var a := deg_to_rad(lerpf(float(rig["a0"]), float(rig["a1"]), u / float(rig["dur"])))
				var side := fixed2.rotated(Vector3.UP, a)
				pos = fixed + side * float(rig["radius"]) + Vector3.UP * float(rig["h"])
				look = fixed + Vector3.UP * 0.75
		cam.global_position = pos
		if (look - pos).normalized().cross(Vector3.UP).length() > 1e-3:
			cam.look_at(look, Vector3.UP)
		var vs := cam.get_viewport().get_visible_rect().size
		# The square's FOV on the wider axis: a 16:9 window keeps the 16:9 crop's view, a
		# 9:16 window the 9:16 crop's (KEEP_HEIGHT: `fov` is vertical).
		var sq := deg_to_rad(float(rig["fov"]))
		cam.fov = rad_to_deg(2.0 * atan(tan(sq * 0.5) * minf(1.0, vs.y / maxf(vs.x, 1.0))))
		# To the renderer now, not at the tree's transform flush after _process: KeepDrawing may
		# draw this frame before that flush.
		cam.force_update_transform()

	## Roadside aim: `aim` blended with the car by `follow`. The car counts once it is `ahead` m
	## past the camera's spot on the road (a negative `ahead` watches it come from that far),
	## before that the road there. A critically damped spring turns the camera without overshoot;
	## the target leads the car by its velocity over the spring's time, which cancels the lag a
	## spring has behind a moving target, so the car stays in the middle of the frame.
	func _aim(dt: float, snap: bool) -> Vector3:
		var xf := car.get_global_transform_interpolated()
		_hint = track.nearest(xf.origin, _hint)
		var p := track.progress_of(_hint, xf.origin)
		var smooth: float = rig["smooth"]
		var v := car.linear_velocity
		v.y = 0.0
		var at_car := xf.origin + Vector3.UP * (0.55 + float(rig.get("tilt", 0.0))) + v * smooth
		var from := float(rig["s"]) + float(rig["ahead"])
		if p < from:
			at_car = track.transform_at_progress(from, track.lateral(_hint, xf.origin)).origin + Vector3.UP * 0.55
		var target := at_car
		if rig.has("aim"):
			target = still_aim.lerp(at_car, float(rig.get("follow", 0.0)))
		if snap:
			aim = target
			aim_vel = Vector3.ZERO
			return aim
		var omega := 2.0 / smooth
		var x := omega * dt
		var e := 1.0 / (1.0 + x + 0.48 * x * x + 0.235 * x * x * x)
		var change := aim - target
		var temp := (aim_vel + omega * change) * dt
		aim_vel = (aim_vel - omega * temp) * e
		aim = target + (change + temp) * e
		return aim

	## Route progress s, lateral lat: h above the road there or the ground, whichever is higher
	## (over a river or a drop the road's height, on a bank the bank's).
	func _spot(s: float, lat: float, h: float, space: PhysicsDirectSpaceState3D) -> Vector3:
		var p := track.transform_at_progress(s, lat).origin
		return Vector3(p.x, maxf(p.y, _ground(p, space).y) + h, p.z)

	func _ground(p: Vector3, space: PhysicsDirectSpaceState3D) -> Vector3:
		var q := PhysicsRayQueryParameters3D.create(Vector3(p.x, 900.0, p.z), Vector3(p.x, -200.0, p.z), 1)
		var hit := space.intersect_ray(q)
		return Vector3(p.x, float(hit["position"].y) if hit else p.y, p.z)

	func _ground_y(p: Vector3) -> float:
		return _ground(p, cam.get_world_3d().direct_space_state).y

	static func _flat(v: Vector3) -> Vector3:
		v.y = 0.0
		return v.normalized() if v.length_squared() > 1e-6 else Vector3.FORWARD


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	DirAccess.make_dir_recursive_absolute(opts["footage"])
	if opts.has("stills"):
		DirAccess.make_dir_recursive_absolute(opts["stills"])
	game = root.get_node("Game")
	game.set_setting("music_volume", 0.0) # a -s harness never saves settings (Game.persistent)
	game.state_changed.connect(func(s: int, _o: int) -> void:
		reached[s] = int(reached.get(s, 0)) + 1)
	# A window close request quits the game mid-take: say so in the log.
	root.close_requested.connect(func() -> void: print("WINDOW close requested at %.2f s" % _now()))
	_frame0 = Engine.get_process_frames()
	_keep = KeepDrawing.new()
	root.add_child(_keep)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred()


func _run() -> void:
	await _until_state(&"MENU", 60.0)
	main.ui.set_ui_visible(false)
	director = Director.new()
	director.post = main.post
	main.add_child(director)
	card = _title_card()
	var wanted: PackedStringArray = str(opts.get("shots", "")).split(",", false)
	var shots: Array[Dictionary] = []
	for sh in SHOTS:
		if wanted.is_empty() or wanted.has(str(sh["name"])):
			shots.append(sh)

	_mark()
	game.request_start("hanami", game.MODE_FREE_ROAM)
	await _until_state(&"FREE_ROAM", 90.0)
	var car: Car = main.car
	car.controlled_by_player = false
	main.map.soft_course.smashed.connect(func(_p: String, _at: Vector3, _v: float, _l: float) -> void:
		_smashed += 1)
	main.map.soft_course.crowd.knocked.connect(func(_p: String, _at: Vector3, _v: float, _l: float) -> void:
		_knocked += 1)
	for sh in shots:
		if str(sh["name"]) != "garage":
			await _shot(car, sh)

	for sh in shots:
		if str(sh["name"]) == "garage":
			await _garage(sh)
	print("KEEP_DRAWING %d frames drawn by the tool (window covered)" % _keep.forced)
	var f := FileAccess.open("%s/cues.json" % opts["footage"], FileAccess.WRITE)
	f.store_string(JSON.stringify(cues, "  "))
	f.close()
	print("DONE %d cues, %d stills, %.2f s of footage" % [cues.size(), _stills, _now()])
	game.request_quit()


## One shot: the car put down on its road `lead` s ahead of the in-point (or kept out of the way),
## the rig on the trailer camera, the cue at the in-point, `len` s more.
func _shot(car: Car, sh: Dictionary) -> void:
	var route := str(sh.get("route", ""))
	var smashed := _smashed
	var knocked := _knocked
	var space: PhysicsDirectSpaceState3D = car.get_world_3d().direct_space_state
	for ap in car.get_children():
		if ap is Autopilot:
			ap.queue_free()
	if route == "":
		director.car = null
		car.place_at_rest(main.map.routes[str(sh.get("park", "hanami"))]["spawn"])
		director.start(sh["rig"], null, float(sh["lead"]), space)
		director.cam.make_current()
		_cue(str(sh["name"]) + "_start")
		await _seconds(float(sh["lead"]))
		_cue(str(sh["name"]))
		if sh.has("card"):
			_show_card.call_deferred(float(sh["card"]))
		await _hold(sh, car, null)
		_cue(str(sh["name"]) + "_end")
		card.visible = false
		return
	var track: Track = main.map.routes[route]["track"]
	var v := float(sh["kmh"]) / 3.6
	var at: float = sh["at"]
	var p0 := at - v * float(sh["lead"])
	if track.closed:
		p0 = fposmod(p0, track.length)
	car.place_at_rest(track.transform_at_progress(maxf(p0, 0.0), float(sh.get("lat", 0.0))))
	await physics_frame
	car.linear_velocity = -car.global_basis.z * v
	for w: WheelState in car.wheels:
		w.spin_speed = v / Car.WHEEL_RADIUS
	var dt: Drivetrain = car.drivetrain
	var g := 1
	while g < dt.top_gear() and dt.rpm_for_speed(v, g, Car.WHEEL_RADIUS) > dt.upshift_rpm_full * 0.8:
		g += 1
	dt.gear = g
	var ap := Autopilot.new()
	ap.curve = track.to_curve()
	ap.closed = track.closed
	ap.style = sh.get("style", &"showoff")
	ap.speed_scale = float(sh.get("speed", 1.0))
	if sh.has("max_kmh"):
		ap.max_speed_kmh = sh["max_kmh"]
	car.add_child(ap)
	director.car = car
	director.start(sh["rig"], track, float(sh["lead"]), space)
	director.cam.make_current()
	_cue(str(sh["name"]) + "_start")
	if sh.has("swerve"):
		_swerve(car, ap, track, sh["swerve"])
	if sh.has("slow"):
		_slow(car, track, sh["slow"])
	await _until_progress(car, track, at)
	director.mark_in()
	_cue(str(sh["name"]), car, track)
	await _hold(sh, car, track)
	_cue(str(sh["name"]) + "_end")
	_slowmo(1.0, 0.01)
	print("SHOT %-14s end kmh=%5.1f smashed=%d knocked=%d" % [sh["name"], car.speed_kmh,
			_smashed - smashed, _knocked - knocked])


## The rest of a shot after its in-point: stills (the shot's `still` moment, or `frames` moments
## from in to out), the first smash of the take cued.
func _hold(sh: Dictionary, car: Car, track: Track) -> void:
	var length: float = sh["len"]
	var marks: Array[float] = []
	if opts.has("stills"):
		if opts.has("frames"):
			marks = _spread(length, int(opts["frames"]))
		elif sh.has("still"):
			marks = [float(sh["still"])]
	var smashed := _smashed
	var rig: Dictionary = sh["rig"]
	var pass_at: float = rig["s"] if track != null and str(rig["type"]) == "roadside" else INF
	var hint := -1
	var done := 0.0
	while done < length:
		if pass_at < INF and is_instance_valid(car):
			hint = track.nearest(car.global_position, hint)
			var p := track.progress_of(hint, car.global_position)
			if p >= pass_at and p < pass_at + 100.0:
				_cue("%s_pass" % sh["name"], car, track)
				pass_at = INF
		if not marks.is_empty() and director.since_in() >= marks[0]:
			await _save_still("%s_%.1f" % [sh["name"], marks.pop_front()])
		if _smashed > smashed and not _cued("smash"):
			_cue("smash", car, track)
		await process_frame
		done = director.since_in()


## `n` moments from just after the in-point to just before the end of a shot `length` s long.
func _spread(length: float, n: int) -> Array[float]:
	var marks: Array[float] = []
	for i in n:
		marks.append(lerpf(0.05, length - 0.05, float(i) / maxf(n - 1, 1)))
	return marks


## The garage: back to the title hub, the car parked at the workshop, the trailer camera orbiting
## it; the livery brushed on `livery` s after the in-point.
func _garage(sh: Dictionary) -> void:
	_mark()
	# The way to the menu frees the car: the last shot's rig stops first.
	director.rig = {}
	director.car = null
	game.request_menu()
	await _until_state(&"MENU", 90.0)
	main.ui.set_ui_visible(false)
	game.set_menu_view("garage")
	await _seconds(0.2)
	var spot: Transform3D = main.menu_stage.display_spot()
	var track: Track = main.map.routes["hanami"]["track"]
	var road := track.point(track.nearest(spot.origin)) - spot.origin
	road.y = 0.0
	director.fixed = spot.origin
	director.fixed2 = road.normalized()
	director.start(sh["rig"], null, float(sh["lead"]), main.car.get_world_3d().direct_space_state)
	director.cam.make_current()
	_cue("garage_start")
	await _seconds(float(sh["lead"]))
	_cue("garage")
	var colour_set := false
	var marks: Array[float] = []
	if opts.has("stills"):
		marks.append(float(sh["still"]))
	if opts.has("frames"):
		marks = _spread(float(sh["len"]), int(opts["frames"]))
	while director.since_in() < float(sh["len"]):
		if not colour_set and director.since_in() >= float(sh["livery"]):
			colour_set = true
			_cue("livery")
			game.set_setting("car_color", LIVERY)
		if not marks.is_empty() and director.since_in() >= marks[0]:
			await _save_still("garage_%.1f" % marks.pop_front())
		await process_frame
	_cue("garage_end")


## Bends the autopilot's line out along a cosine bump while the car passes (SHOTS `swerve`).
func _swerve(car: Car, ap: Autopilot, track: Track, s: Array) -> void:
	var peak: float = s[0]
	var half: float = s[1]
	var lead: float = s[2]
	var amount: float = s[3]
	await _until_progress(car, track, peak - half - lead)
	var hint := -1
	while is_instance_valid(ap) and is_instance_valid(car):
		hint = track.nearest(car.global_position, hint)
		var x := (track.progress_of(hint, car.global_position) + lead - peak) / half
		if x >= 1.0:
			break
		ap.lateral_offset = amount * 0.5 * (1.0 + cos(PI * clampf(x, -1.0, 1.0)))
		await physics_frame
	if is_instance_valid(ap):
		ap.lateral_offset = 0.0


## Slow motion while the car covers a stretch of road (SHOTS `slow`).
func _slow(car: Car, track: Track, stretch: Array) -> void:
	await _until_progress(car, track, stretch[0])
	_slowmo(SLOWMO, 0.3)
	await _until_progress(car, track, stretch[1])
	_slowmo(1.0, 0.6)


func _slowmo(to: float, ramp: float) -> void:
	root.get_node("Sound").set_slowmo(to)
	var tw := create_tween().set_ignore_time_scale(true)
	tw.tween_method(func(v: float) -> void: Engine.time_scale = v, Engine.time_scale, to, ramp)


## The end card: the title screen's logo (brush 桜, the wordmark dropping in, the hanko, 桜ラリー)
## and under it the episode line, large enough to read on a phone; centred, where both crops
## see it.
func _title_card() -> Control:
	var theme: GDScript = load("res://scripts/ui/ui_theme.gd")
	var layer := CanvasLayer.new()
	layer.layer = 20
	main.add_child(layer)
	var box := Control.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.visible = false
	layer.add_child(box)
	var logo := Control.new()
	logo.name = "Logo"
	logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(logo)
	var kanji: Control = load("res://scripts/ui/widgets/brush_kanji.gd").new()
	kanji.name = "Kanji"
	kanji.text = "桜"
	kanji.size = Vector2(250, 250)
	kanji.color = theme.INK
	kanji.halo = Color(1, 1, 1, 0.5)
	kanji.halo_size = 26
	logo.add_child(kanji)
	var col := VBoxContainer.new()
	col.name = "Col"
	col.position = Vector2(262, 62)
	col.add_theme_constant_override("separation", 10)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	logo.add_child(col)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(row)
	var word: Control = load("res://scripts/ui/widgets/kinetic_text.gd").new()
	word.name = "Wordmark"
	word.text = "SAKURA RALLY"
	word.font = theme.FONT_TITLE
	word.font_size = 66
	word.tracking = 14.0
	word.color = theme.INK
	word.halo = Color(1, 1, 1, 0.55)
	word.halo_size = 16
	word.stepped_fps = 12.0
	word.stagger = 0.05
	word.char_duration = 0.55
	word.distance = 56.0
	row.add_child(word)
	var hanko: Control = load("res://scripts/ui/widgets/hanko.gd").new()
	hanko.name = "Hanko"
	hanko.text = "山道"
	hanko.custom_minimum_size = Vector2(52, 86)
	hanko.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hanko.rest_rotation = 0.08
	row.add_child(hanko)
	var jp: Label = theme.make_label("桜ラリー", theme.FONT_BRUSH, 34, theme.SAKURA)
	jp.name = "Jp"
	jp.label_settings.outline_size = 12
	jp.label_settings.outline_color = Color(1, 1, 1, 0.6)
	col.add_child(jp)
	var ep: Label = theme.make_label("EPISODE 3  ·  ONE WORLD", theme.FONT_UI_BOLD, 56, theme.INK)
	ep.name = "Episode"
	ep.label_settings.outline_size = 14
	ep.label_settings.outline_color = Color(1, 1, 1, 0.7)
	box.add_child(ep)
	return box


func _show_card(delay: float) -> void:
	await _seconds(delay)
	_cue("card")
	card.visible = true
	var logo: Control = card.get_node("Logo")
	var col: Control = logo.get_node("Col")
	var ep: Label = card.get_node("Episode")
	var vp := card.get_viewport_rect().size
	# Scaled to fit 86 % of the 9:16 crop's width (1080 of the square's 1920 px), centred.
	var size := Vector2(col.position.x + col.get_combined_minimum_size().x, 250.0)
	var k := minf(1.0, vp.x * 1080.0 / 1920.0 * 0.86 / size.x) if vp.y >= vp.x else 1.0
	logo.scale = Vector2(k, k)
	logo.position = (vp - size * k) * 0.5 - Vector2(0.0, 40.0)
	ep.position = Vector2((vp.x - ep.get_combined_minimum_size().x) * 0.5, logo.position.y + size.y * k + 26.0)
	logo.get_node("Kanji").play(1.8, 0.1)
	(logo.find_children("Wordmark", "", true, false)[0] as Control).call(&"play", 0.55)
	var hanko: Control = logo.find_children("Hanko", "", true, false)[0]
	hanko.modulate.a = 0.0
	hanko.call(&"stamp", 1.75)
	var fade: Array[Control] = [col.get_node("Jp"), ep]
	for c in fade:
		c.modulate.a = 0.0
	var tw := create_tween().set_ignore_time_scale(true).set_parallel(true)
	tw.tween_property(fade[0], "modulate:a", 1.0, 0.6).set_delay(1.1)
	tw.tween_property(fade[1], "modulate:a", 1.0, 0.7).set_delay(1.6)


# ---------------------------------------------------------------- helpers

## Returns once the car reaches a route progress (at once when the car is gone).
func _until_progress(car: Car, track: Track, progress: float) -> void:
	var hint := -1
	while is_instance_valid(car):
		hint = track.nearest(car.global_position, hint)
		var p := track.progress_of(hint, car.global_position)
		if p >= progress and p < progress + 200.0:
			return
		await process_frame


func _cue(cue_name: String, car: Car = null, track: Track = null) -> void:
	var t := _now()
	var cue := {"name": cue_name, "t": snappedf(t, 0.001)}
	var line := "CUE %8.3f %s" % [t, cue_name]
	if car != null and track != null:
		var i := track.nearest(car.global_position)
		cue["progress"] = snappedf(track.progress_of(i, car.global_position), 0.1)
		line += "  progress=%.1f lat=%.1f kmh=%.0f cam=%.1f m" % [cue["progress"],
				track.lateral(i, car.global_position), car.speed_kmh,
				director.cam.global_position.distance_to(car.global_position)]
	cues.append(cue)
	print(line)


func _cued(cue_name: String) -> bool:
	for c in cues:
		if c["name"] == cue_name:
			return true
	return false


func _save_still(tag: String) -> void:
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	img.save_png("%s/%s.png" % [opts["stills"], tag])
	_stills += 1


## Seconds of footage since the start (60 fps).
func _now() -> float:
	return (Engine.get_process_frames() - _frame0) / 60.0


func _seconds(s: float) -> void:
	await create_timer(s, true, false, true).timeout


func _mark() -> void:
	marked = reached.duplicate()


## Waits for the next entry into a state after the last _mark(). Timeouts are in real seconds,
## generous because Movie Maker renders slower than real time.
func _until_state(state_name: StringName, timeout: float) -> void:
	var s: int = game.State[state_name]
	var start := Time.get_ticks_msec()
	while int(reached.get(s, 0)) <= int(marked.get(s, 0)):
		if (Time.get_ticks_msec() - start) / 1000.0 > timeout * 20.0:
			print("TIMEOUT waiting for %s" % state_name)
			return
		await process_frame
