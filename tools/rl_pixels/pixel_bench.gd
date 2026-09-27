extends SceneTree
## What pixel observations would cost: one process drives N stripped cars (tools/rl/rl_car.gd,
## as train_env.gd) and gives each its own small SubViewport camera, rendered once per decision
## (12 physics ticks at 120 Hz) and read back to the CPU. Prints one PIXBENCH line per config:
## milliseconds per decision for the physics, the draw and the readback, and car-decisions per
## second. Rendering is manual: the render loop is off (RenderingServer.render_loop_enabled) and
## each decision calls RenderingServer.force_draw() once, with every car viewport set to
## UPDATE_ONCE, so no frame is drawn between decisions. The root window draws no 3D. With
## --fixed-fps 10 one main-loop iteration runs the decision's 12 physics ticks (project
## max_physics_steps_per_frame is 12) and the steering runs in a _physics_process node.
## Pixels, so offscreen on the agents' dev build, under the render lock (tools/rl_pixels/run_bench.sh
## runs the whole benchmark):
##
##   D=~/opt/summer-dev/SummerDev.app/Contents/MacOS/Summer
##   /usr/bin/lockf -k /tmp/sakura-render.lock timeout -k 10 900 nice -n 10 $D --summer-offscreen \
##       --audio-driver Dummy --disable-crash-handler --fixed-fps 10 --path . \
##       -s res://tools/rl_pixels/pixel_bench.gd -- configs="low/64x64/16/atlas;lean/96x96/32/each" \
##       decisions=40 samples=/tmp/pixel_rl/samples
##
## A config is look/WxH/N/readback:
##   look      none: no camera (the physics alone); full: the game's high preset in the car view
##             (sun shadows 4 splits 320 m, glow, MSAA 4x, the ink lines); low: the low preset
##             (2 splits 160 m, no vegetation shadows, no glow, FXAA, ink); lean: low without sun
##             shadows, ink or AA; bare: lean without the props (trees, buildings, dressing) and
##             sky particles, a stripped training world; road: the hood view of the road meshes
##             alone on a flat background (a segmentation-like render); top: an orthographic
##             top-down camera over the car (60 m tall view), road meshes alone.
##   readback  each: ViewportTexture.get_image() per car; atlas: the car viewports are drawn
##             into one atlas SubViewport, one get_image() for all; gpu: no readback, then
##             RenderingServer.force_sync().
## Options: map (route to drive), cars (spawned; a config simulates only its first N),
## decisions (measured, after `warmup`), samples=<dir> (PNGs of the first cars' images at each
## config's end, or the atlas), cam=bumper|hood, fov, pitch (degrees down), season=<spring,
## summer,autumn weights> (forces the look, e.g. 0,0,1), step=frame|tick (tick: 12 awaits of
## physics_frame, for --fixed-fps 120), loop=1 (keep the render loop on), sleep (usec).

const RLCar := preload("res://tools/rl/rl_car.gd")
const ROAD_BIT := 1 << 19
const TICKS := 12

var opts := {"map": "hanami", "configs": "low/64x64/16/atlas", "decisions": "40", "warmup": "8",
		"samples": "", "cam": "hood", "fov": "90", "pitch": "8", "season": "", "car": "sakura", "cars": "64",
		"step": "frame", "loop": "0", "sleep": "0"}
var game: Node
var map: MapWorld
var track: Track
var cars: Array[Car] = []
var hints := PackedInt32Array()
var driving := 0
var post: Node3D


## Pure pursuit on the centre line (tools/rl/bench.gd) for the first `driving` cars, every tick.
class Driver extends Node:
	var bench

	func _physics_process(_dt: float) -> void:
		bench.steer_all()


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	_run.call_deferred()


func _run() -> void:
	game = root.get_node("Game")
	RenderingServer.render_loop_enabled = opts["loop"] == "1"
	OS.low_processor_usage_mode_sleep_usec = int(opts["sleep"])
	root.disable_3d = true
	var t_build := Time.get_ticks_msec()
	map = MapWorld.new()
	map.name = "Map"
	map.map_id = opts["map"]
	root.add_child(map)
	await map.build()
	for gate: RoadGate in map.gates.values():
		gate.set_open(true, false)
	track = map.track
	if opts["season"] != "":
		var w: PackedStringArray = str(opts["season"]).split(",")
		map.set_process(false)
		map._apply_season(Vector3(float(w[0]), float(w[1]), float(w[2])))
	post = load("res://scripts/fx/post_fx.gd").new()
	root.add_child(post)
	post.apply_preset(map.atmosphere.preset, map.sun_dir)
	(post.get(&"grade_layer") as CanvasLayer).visible = false
	for node in map.get_node(^"Road").get_children():
		if node is VisualInstance3D:
			(node as VisualInstance3D).layers |= ROAD_BIT
	print("BUILD map=%s ms=%d adapter=%s" % [opts["map"], Time.get_ticks_msec() - t_build,
			RenderingServer.get_video_adapter_name()])

	var n_max := int(opts["cars"])
	for k in n_max:
		cars.append(RLCar.spawn(root, str(game.get_car(opts["car"])["scene"])))
	hints.resize(n_max)
	hints.fill(-1)
	await physics_frame
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for k in n_max:
		cars[k].place_at_rest(track.transform_at_progress(track.length * float(k) / n_max, rng.randf_range(-1.5, 1.5)))
	var driver := Driver.new()
	driver.bench = self
	root.add_child(driver)

	for spec: String in str(opts["configs"]).split(";"):
		if spec.strip_edges() != "":
			await _bench(spec.strip_edges())
	game.request_quit(0)


func steer_all() -> void:
	for k in driving:
		var car := cars[k]
		var i := track.nearest(car.global_position, hints[k], 12)
		hints[k] = i
		var s := track.abs_s(i, car.global_position)
		var aim := track.position_at_abs(s + 18.0)
		var local := car.global_transform.affine_inverse() * aim
		car.input_steer = clampf(atan2(local.x, -local.z) * 2.0, -1.0, 1.0)
		var v := car.speed_kmh
		car.input_throttle = 1.0 if v < 70.0 else 0.0
		car.input_brake = 0.4 if v > 85.0 else 0.0


func _bench(spec: String) -> void:
	var p: PackedStringArray = spec.split("/")
	var look := p[0]
	var wh: PackedStringArray = p[1].split("x")
	var size := Vector2i(int(wh[0]), int(wh[1]))
	var n := int(p[2])
	var readback := p[3]
	driving = n
	_apply_look(look)
	# Only the config's cars simulate: a parked car costs as much physics as a driving one.
	for k in cars.size():
		cars[k].process_mode = Node.PROCESS_MODE_INHERIT if k < n else Node.PROCESS_MODE_DISABLED

	var holder: Node = Node.new()
	var atlas: SubViewport = null
	var cols := int(ceil(sqrt(float(n))))
	if readback == "atlas" and look != "none":
		atlas = SubViewport.new()
		atlas.disable_3d = true
		atlas.size = Vector2i(size.x * cols, size.y * int(ceil(float(n) / cols)))
		atlas.render_target_update_mode = SubViewport.UPDATE_DISABLED
		holder = atlas
	root.add_child(holder)
	var vps: Array[SubViewport] = []
	var cams: Array[Camera3D] = []
	if look != "none":
		for k in n:
			var vp := SubViewport.new()
			vp.size = size
			vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
			vp.positional_shadow_atlas_size = 0
			_viewport_look(vp, look)
			var cam := Camera3D.new()
			cam.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
			_camera_look(cam, look)
			vp.add_child(cam)
			holder.add_child(vp)
			cam.current = true
			RenderingServer.viewport_set_measure_render_time(vp.get_viewport_rid(), true)
			vps.append(vp)
			cams.append(cam)
			if atlas != null:
				var tr := TextureRect.new()
				tr.texture = vp.get_texture()
				tr.position = Vector2(size.x * (k % cols), size.y * (k / cols))
				tr.size = Vector2(size)
				atlas.add_child(tr)

	var warm := int(opts["warmup"])
	var total := warm + int(opts["decisions"])
	var t_step := 0
	var f_start := 0
	var t_draw := 0
	var t_read := 0
	var gpu_ms := 0.0
	var cpu_ms := 0.0
	var bytes := 0
	var imgs: Array[Image] = []
	for d in total:
		var t0 := Time.get_ticks_usec()
		if d == warm:
			f_start = Engine.get_physics_frames()
		if opts["step"] == "frame":
			await process_frame
		else:
			for t in TICKS:
				await physics_frame
		var t1 := Time.get_ticks_usec()
		imgs.clear()
		if look != "none":
			for k in n:
				_pose(cams[k], cars[k].global_transform, look)
				RenderingServer.viewport_set_update_mode(vps[k].get_viewport_rid(), RenderingServer.VIEWPORT_UPDATE_ONCE)
			if atlas != null:
				RenderingServer.viewport_set_update_mode(atlas.get_viewport_rid(), RenderingServer.VIEWPORT_UPDATE_ONCE)
			RenderingServer.force_draw(false)
		var t2 := Time.get_ticks_usec()
		if look != "none":
			match readback:
				"each":
					for vp in vps:
						imgs.append(vp.get_texture().get_image())
				"atlas":
					imgs.append(atlas.get_texture().get_image())
				_:
					RenderingServer.force_sync()
		var t3 := Time.get_ticks_usec()
		if d >= warm:
			t_step += t1 - t0
			t_draw += t2 - t1
			t_read += t3 - t2
			for img in imgs:
				bytes += img.get_data().size()
			for vp in vps:
				gpu_ms += RenderingServer.viewport_get_measured_render_time_gpu(vp.get_viewport_rid())
				cpu_ms += RenderingServer.viewport_get_measured_render_time_cpu(vp.get_viewport_rid())
	var m := float(int(opts["decisions"]))
	var step_ms := t_step / m / 1000.0
	var draw_ms := t_draw / m / 1000.0
	var read_ms := t_read / m / 1000.0
	var sum := step_ms + draw_ms + read_ms
	var off := 0
	for k in n:
		var i := track.nearest(cars[k].global_position)
		if absf(track.lateral(i, cars[k].global_position)) > track.half_width(i) + track.verge:
			off += 1
	print("PIXBENCH look=%s size=%dx%d n=%d read=%s ticks_per_dec=%.1f step_ms=%.2f draw_ms=%.2f read_ms=%.2f total_ms=%.2f car_dec_per_s=%.0f render_per_car_ms=%.3f vp_gpu_ms=%.2f vp_cpu_ms=%.2f kb_per_dec=%.0f off_road=%d" % [
			look, size.x, size.y, n, readback, (Engine.get_physics_frames() - f_start) / m, step_ms, draw_ms, read_ms, sum, n * 1000.0 / sum,
			(draw_ms + read_ms) / n, gpu_ms / m, cpu_ms / m, bytes / m / 1024.0, off])
	if opts["samples"] != "" and look != "none":
		var dir: String = opts["samples"]
		DirAccess.make_dir_recursive_absolute(dir)
		var tag := "%s_%dx%d" % [look, size.x, size.y]
		if readback == "atlas":
			imgs[0].save_png("%s/%s_atlas%d.png" % [dir, tag, n])
		else:
			for k in mini(n, 4):
				var img := vps[k].get_texture().get_image()
				img.save_png("%s/%s_car%d.png" % [dir, tag, k])
	holder.queue_free()
	await process_frame


## World-wide settings of a look: the sun's shadows and reach, glow, the ink quad.
func _apply_look(look: String) -> void:
	var q := "high" if look == "full" else "low"
	Quality.apply(q, root, map)
	var sun := map.atmosphere.sun
	sun.shadow_enabled = look in ["full", "low"]
	map.atmosphere.environment.glow_enabled = look == "full"
	post.visible = look in ["full", "low"]
	post.call(&"apply_quality", q)
	# bare: lean in a stripped world, no props (vegetation, buildings, dressing) and no sky particles
	for path in [^"Props", ^"SkyRig"]:
		var node := map.get_node_or_null(path) as Node3D
		if node != null:
			node.visible = look != "bare"


func _viewport_look(vp: SubViewport, look: String) -> void:
	match look:
		"full":
			vp.msaa_3d = Viewport.MSAA_4X
		"low":
			vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA


func _camera_look(cam: Camera3D, look: String) -> void:
	cam.fov = float(opts["fov"])
	cam.near = 0.1
	cam.far = 1500.0
	if look in ["road", "top"]:
		cam.cull_mask = ROAD_BIT
		var env := Environment.new()
		env.background_mode = Environment.BG_COLOR
		env.background_color = Color.BLACK
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color.WHITE
		cam.environment = env
	if look == "top":
		cam.projection = Camera3D.PROJECTION_ORTHOGONAL
		cam.size = 60.0
		cam.near = 1.0
		cam.far = 300.0


func _pose(cam: Camera3D, xf: Transform3D, look: String) -> void:
	var fwd := -xf.basis.z
	if look == "top":
		var flat := Vector3(fwd.x, 0.0, fwd.z).normalized()
		cam.global_transform = Transform3D(Basis.looking_at(Vector3.DOWN, flat), xf.origin + flat * 22.0 + Vector3.UP * 120.0)
		return
	var hood: bool = opts["cam"] == "hood"
	var pos := xf * (Vector3(0.0, 1.34, -0.45) if hood else Vector3(0.0, 0.6, -2.2))
	var up := xf.basis.y.lerp(Vector3.UP, 0.6).normalized()
	var b := Basis.looking_at(fwd, up)
	b = b.rotated(b.x, -deg_to_rad(float(opts["pitch"])))
	cam.global_transform = Transform3D(b, pos)
