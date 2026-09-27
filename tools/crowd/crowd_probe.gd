extends SceneTree
## Crowd probe: spectator looks and knock-overs in the world, offscreen. `map=` is a route id
## (hanami, momiji, liaison); only spectators within 80 m of that route's road count. It prints
## how many spectators stand along each route (CROWD COUNTS).
##
## shots  Finds the spectator crowd on the outside of the tightest corner (the hairpin crowd;
##        `near=x,z` takes the crowd nearest that point instead) and renders it close up, at racing distance from the road (45 m and 25 m before the
##        apex, chase height) and from the side of the crowd, with the map's post FX.
## lineup Every people model (two dyes of each) lined up on the road ahead of the start, close
##        up, through the same materials, custom data and motion as in a crowd;
##        `focus=spectator_b,...` adds a close-up of each named model (front, three-quarter).
## knock  Drives a car straight into a spectator (the flattest open approach on the map),
##        first with nobody to knock (it builds the pipelines the car and the map need on that
##        line), then for real. That drive (the session's first knocks, nothing saved) logs
##        every frame: frame time, physics steps and the growth of pipeline compilations,
##        nodes and resources; it prints every compilation of the drive (COMPILES), the frames
##        around the first and second knock and the worst within 1 s of them (FRAMES), and the
##        car's speed loss per knock. It fails on a compilation, a node or resource created
##        within 1 s of a knock, or a frame there over 25 ms (or 3x the drive's median frame on
##        a busy machine). A reset must bring the whole crowd back. A last drive saves a frame
##        every 0.1 s from a fixed camera (knock_NNN): tumble, lie, get-up, walk back.
##
##   timeout 300 nice -n 5 $S --summer-offscreen --audio-driver Dummy --disable-crash-handler \
##       --path . -s res://tools/crowd/crowd_probe.gd -- map=hanami mode=all dir=/tmp/ep3/people/new
##
## (`dir=`, not `out=`: Summer's offscreen mode treats an `out=` argument as a probe results
## folder and closes the window early.)

const PostFXScript := preload("res://scripts/fx/post_fx.gd")
const FRAME_BUDGET_MS := 25.0
const MONITORS := [
	[Performance.PIPELINE_COMPILATIONS_DRAW, "draw_compiles"],
	[Performance.PIPELINE_COMPILATIONS_SURFACE, "surface_compiles"],
	[Performance.PIPELINE_COMPILATIONS_SPECIALIZATION, "specialization_compiles"],
	[Performance.OBJECT_NODE_COUNT, "nodes"],
	[Performance.OBJECT_RESOURCE_COUNT, "resources"],
]

var opts := {"map": "hanami", "mode": "all", "dir": "/tmp/ep3/people/probe", "car": "sakura", "kmh": "45"}
var map: MapWorld
var _people: Array = [] ## the selected route's spectators
var game: Node
var cam: Camera3D
var post: Node3D
var car: Car
var crowd: Node ## Crowd, when the branch has it
var failures: Array[String] = []

var _f_usec := PackedInt64Array()
var _f_ms := PackedFloat32Array()
var _f_steps := PackedInt32Array()
var _f_perf: Array[PackedInt64Array] = []
var _last_usec := 0
var _steps := 0
var _logging := false
var _marks: Array[Dictionary] = []
var _knocks: Array[Dictionary] = []


func _process(_delta: float) -> bool:
	var now := Time.get_ticks_usec()
	if _logging and _last_usec > 0:
		_f_usec.append(now)
		_f_ms.append((now - _last_usec) / 1000.0)
		_f_steps.append(_steps)
		for k in MONITORS.size():
			_f_perf[k].append(int(Performance.get_monitor(MONITORS[k][0])))
	_last_usec = now
	_steps = 0
	return false


func _physics_process(_delta: float) -> bool:
	_steps += 1
	return false


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	game = root.get_node("Game")
	for k in MONITORS.size():
		_f_perf.append(PackedInt64Array())
	DirAccess.make_dir_recursive_absolute(opts["dir"])
	root.size = Vector2i(1600, 900)
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		print("crowd_probe needs pixels: run it with --summer-offscreen")
		game.request_quit(2)
		return
	cam = Camera3D.new()
	cam.fov = 55.0
	cam.near = 0.05
	cam.far = 6000.0
	root.add_child(cam)
	cam.make_current()
	map = MapWorld.new()
	map.name = "Map"
	map.map_id = opts["map"]
	root.add_child(map)
	await map.build()
	post = PostFXScript.new()
	root.add_child(post)
	post.apply_preset(map.atmosphere.preset, map.sun_dir)
	crowd = map.soft_course.get(&"crowd") if map.soft_course != null else null
	_route_counts()
	var spot := _crowd_near(opts["near"]) if opts.has("near") else _hairpin_crowd()
	if spot.is_empty():
		failures.append("no spectator crowd found")
	else:
		print("CROWD %s  %d spectators within 14 m of (%.1f, %.1f, %.1f)  road radius %.0f m  crowd %s" % [
			map.map_id, spot["n"], spot["c"].x, spot["c"].y, spot["c"].z, spot["radius"],
			("%d people" % crowd.person_count()) if crowd != null else "none (rigid spectators)"])
		# the camera sits by the crowd while pipelines warm (SoftCourse and Crowd warm in view)
		cam.global_position = spot["c"] + Vector3(0.0, 3.0, 8.0)
		cam.look_at(spot["c"])
		for i in 20:
			await process_frame
		if crowd != null:
			var waited := 0
			while not crowd.is_warm() and waited < 600:
				await process_frame
				waited += 1
			print("WARM crowd %s after %d frames" % [crowd.is_warm(), waited])
		if opts["mode"] in ["shots", "all"]:
			await _shots(spot)
		if opts["mode"] in ["lineup", "all"]:
			await _lineup()
		if opts["mode"] in ["knock", "all"]:
			if crowd == null:
				print("KNOCK skipped: this branch has no Crowd")
			else:
				await _knock(spot)
	print("SUMMARY: %d failures" % failures.size())
	for f in failures:
		print("  FAIL %s" % f)
	game.request_quit(1 if failures.size() > 0 else 0)


# ---------------------------------------------------------------- the hairpin crowd

## Spectators farther than this from a route's road are not that route's crowd (m).
const ROUTE_REACH := 80.0


## Every spectator instance of the world along the selected route: [position, yaw, name].
func _spectators() -> Array:
	if not _people.is_empty():
		return _people
	var track := map.track
	for p in _all_spectators():
		if (p[0] as Vector3).distance_to(track.point(track.nearest(p[0]))) <= ROUTE_REACH:
			_people.append(p)
	return _people


func _all_spectators() -> Array:
	var out := []
	var inst: Dictionary = map.info["instances"]
	for n: String in inst:
		if not n.begins_with("spectator_"):
			continue
		for e in inst[n]:
			out.append([Vector3(e[0], e[1], e[2]), float(e[3]), n])
	return out


## How many spectators stand along each route of the world (within ROUTE_REACH of its road;
## a crowd between two roads counts for both) and how many belong to none.
func _route_counts() -> void:
	var all := _all_spectators()
	var parts: Array[String] = []
	var claimed := {}
	for id: String in map.routes:
		var t: Track = map.routes[id]["track"]
		var n := 0
		for k in all.size():
			var q: Vector3 = all[k][0]
			if q.distance_to(t.point(t.nearest(q))) <= ROUTE_REACH:
				n += 1
				claimed[k] = true
		parts.append("%s %d" % [id, n])
	print("CROWD COUNTS  world %d spectators (Crowd %d people)  per route: %s  off every route %d" % [
			all.size(), crowd.person_count() if crowd != null else 0, ", ".join(parts), all.size() - claimed.size()])


## `near=x,z`: the crowd around that point instead of the tightest hairpin crowd.
func _crowd_near(xz: String) -> Dictionary:
	var v := xz.split(",")
	var at := Vector3(float(v[0]), 0.0, float(v[1]))
	var people := _all_spectators()
	var best := {}
	var best_d := INF
	for p in people:
		var c: Vector3 = p[0]
		var d := Vector2(c.x - at.x, c.z - at.z).length()
		if d >= best_d:
			continue
		var n := 0
		var sum := Vector3.ZERO
		for q in people:
			if (q[0] as Vector3).distance_to(c) < 14.0:
				n += 1
				sum += q[0]
		if n < 4:
			continue
		var centre := sum / n
		var i := map.track.nearest(centre)
		var s := map.track.dist(i)
		var turn := absf(map.track.forward_at_abs(s - 12.0).signed_angle_to(map.track.forward_at_abs(s + 12.0), Vector3.UP))
		best_d = d
		best = {"c": centre, "n": n, "i": i, "s": s, "radius": 24.0 / maxf(turn, 1e-3)}
	return best


## The crowd (≥ 6 spectators within 14 m) whose nearest road point turns tightest.
func _hairpin_crowd() -> Dictionary:
	var track := map.track
	var people := _spectators()
	var best := {}
	var best_r := INF
	for p in people:
		var c: Vector3 = p[0]
		var n := 0
		var sum := Vector3.ZERO
		for q in people:
			if (q[0] as Vector3).distance_to(c) < 14.0:
				n += 1
				sum += q[0]
		if n < 6:
			continue
		var centre := sum / n
		var i := track.nearest(centre)
		if centre.distance_to(track.point(i)) > 40.0:
			continue
		var s := track.dist(i)
		var f0 := track.forward_at_abs(s - 12.0)
		var f1 := track.forward_at_abs(s + 12.0)
		var turn := absf(f0.signed_angle_to(f1, Vector3.UP))
		var radius := 24.0 / maxf(turn, 1e-3)
		if radius < best_r - 1.0 or (absf(radius - best_r) <= 1.0 and n > int(best.get("n", 0))):
			best_r = radius
			best = {"c": centre, "n": n, "i": i, "s": s, "radius": radius}
	return best


## The spectator nearest to `c` (for the close-up).
func _nearest_person(c: Vector3) -> Array:
	var best := []
	var d := INF
	for p in _spectators():
		var dd := (p[0] as Vector3).distance_to(c)
		if dd < d:
			d = dd
			best = p
	return best


# ---------------------------------------------------------------- shots

func _shots(spot: Dictionary) -> void:
	var track := map.track
	var c: Vector3 = spot["c"]
	var p := _nearest_person(c)
	var pos: Vector3 = p[0]
	var face := -Basis(Vector3.UP, p[1]).z # the prop's front
	# close-up: 3.6 m in front of the nearest spectator, a little to the side
	var side := face.cross(Vector3.UP).normalized()
	cam.fov = 45.0
	var eye := pos + face * 3.4 + side * 1.2
	eye.y = map.ground_height(eye.x, eye.z, pos.y + 20.0) + 1.45
	cam.global_position = eye
	cam.look_at(pos + Vector3.UP * 1.05)
	await _settle(12)
	_save("closeup")
	# wider group from the crowd's side
	cam.fov = 50.0
	eye = pos + face * 7.0 - side * 5.0
	eye.y = map.ground_height(eye.x, eye.z, pos.y + 20.0) + 2.2
	cam.global_position = eye
	cam.look_at(c + Vector3.UP * 1.0)
	await _settle(12)
	_save("group")
	# racing distance: the chase camera on the road before the apex, looking at the crowd
	cam.fov = 62.0
	for back in [45.0, 25.0]:
		var xf := track.transform_at_abs(float(spot["s"]) - back, 0.0, 0.0)
		var fwd := -xf.basis.z
		cam.global_position = xf.origin - fwd * 6.5 + Vector3.UP * 2.8
		cam.look_at(c + Vector3.UP * 1.0)
		await _settle(12)
		_save("race_%dm" % int(back))


# ---------------------------------------------------------------- lineup

func _lineup() -> void:
	var names: Array[String] = []
	for n: String in map.manifest:
		if map.manifest[n].get("category", "") == "spectator":
			names.append(n)
	names.sort()
	# on the tarmac ahead of the start (flat, open): the people face back down the road, towards
	# the camera
	var xf := map.track.transform_at_abs(map.track.dist(map.track.nearest(map.spawn.origin)) + 30.0, 0.0, 0.0)
	var out := -xf.basis.z
	out.y = 0.0
	out = out.normalized()
	var side := out.cross(Vector3.UP).normalized()
	var base := xf.origin
	base.y = map.ground_height(base.x, base.z, base.y + 30.0)
	var root3 := Node3D.new()
	root3.name = "Lineup"
	map.add_child(root3)
	var palette: Array = crowd.PALETTE if crowd != null else [Color.WHITE]
	var per_row := 7
	for j in names.size():
		var mesh: Mesh = map._prop_mesh(names[j])
		if mesh == null:
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = mesh
		mm.instance_count = 2
		var row := j / per_row
		var col := j % per_row
		for d in 2:
			var p := base + side * ((col - (per_row - 1) * 0.5) * 1.05 + (0.5 if row == 1 else 0.0)) \
					+ out * (row * 1.6 + d * 3.6)
			p.y = map.ground_height(p.x, p.z, p.y + 30.0)
			# the front (Godot -Z) toward the road
			mm.set_instance_transform(d, Transform3D(Basis.looking_at(-out, Vector3.UP), p))
			var dye: Color = palette[(j * 3 + d * 5) % palette.size()]
			mm.set_instance_custom_data(d, Color(dye.srgb_to_linear(), float(j * 2 + d) / 26.0))
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		root3.add_child(mmi)
	cam.fov = 38.0
	var eye := base - out * 6.2
	eye.y = map.ground_height(eye.x, eye.z, base.y + 30.0) + 1.3
	cam.global_position = eye
	cam.look_at(base + out * 1.0 + Vector3.UP * 0.9)
	await _settle(20)
	_save("lineup")
	cam.fov = 22.0
	cam.look_at(base - side * 2.1 + Vector3.UP * 1.0)
	await _settle(6)
	_save("lineup_zoom_a")
	cam.look_at(base + side * 2.1 + out * 1.6 + Vector3.UP * 1.0)
	await _settle(6)
	_save("lineup_zoom_b")
	# focus=spectator_b,spectator_c: each named model close up, front and three-quarter
	for n: String in String(opts.get("focus", "")).split(",", false):
		var j := names.find(n)
		if j < 0:
			continue
		var p := base + side * ((j % per_row - (per_row - 1) * 0.5) * 1.05 + (0.5 if j / per_row == 1 else 0.0)) \
				+ out * (j / per_row * 1.6)
		p.y = map.ground_height(p.x, p.z, p.y + 30.0)
		cam.fov = 9.0
		for view in 2:
			var dir := -out if view == 0 else (-out + side * 0.8).normalized()
			cam.global_position = p + dir * 9.0 + Vector3.UP * 1.1
			cam.look_at(p + Vector3.UP * 0.95)
			await _settle(4)
			_save("focus_%s_%d" % [n, view])
	root3.queue_free()
	await process_frame


# ---------------------------------------------------------------- knock-over

func _knock(_spot: Dictionary) -> void:
	var scene := "res://scenes/car/car_hayate.tscn" if opts["car"] == "hayate" else "res://scenes/car/car.tscn"
	car = (load(scene) as PackedScene).instantiate() as Car
	car.name = "ProbeCar"
	root.add_child(car)
	# pass 0: the drive with nobody to knock (the crowd's hash emptied for it), so the pipelines
	# the car and the map need along the line (tyre dust, shadow splits) are built before the
	# timed pass and every compilation left there belongs to the knocks. It also proves the
	# line: something the rays miss (a kerb, a ditch) that stops the car rules the spot out.
	var run := {}
	var tried: Array[Vector3] = []
	var cells: Dictionary = crowd._cells
	crowd._cells = {}
	while tried.size() < 6:
		run = _knock_run(tried)
		if run.is_empty():
			break
		tried.append(run["target"])
		car.place_at_rest(Transform3D(Basis.looking_at(-run["face"], Vector3.UP), run["start"]))
		for i in 10:
			await physics_frame
		cam.fov = 55.0
		cam.global_position = run["eye"]
		cam.look_at(run["target"] + Vector3.UP * 0.7 - run["face"] * 2.5)
		await _drive(run["target"], run["face"], 7.5, false)
		if (car.global_position - run["target"]).dot(-run["face"]) > 0.0:
			break
		print("KNOCK RUN at %s: the car did not get through, next spot" % run["target"])
		run = {}
	crowd._cells = cells
	if run.is_empty():
		failures.append("no spectator with a flat, open 24 m approach")
		return
	var target: Vector3 = run["target"]
	var face: Vector3 = run["face"]
	var start: Vector3 = run["start"]
	var heading := Basis.looking_at(-face, Vector3.UP)
	print("KNOCK RUN at (%.1f, %.1f, %.1f)  approach drop %.2f m" % [target.x, target.y, target.z, run["drop"]])
	crowd.knocked.connect(func(prop: String, point: Vector3, speed: float, loss: float) -> void:
		_knocks.append({"prop": prop, "point": point, "v": speed, "loss": loss, "usec": Time.get_ticks_usec()})
		if _knocks.size() <= 2:
			_mark("knock %d (%s)" % [_knocks.size(), prop]))
	# the camera stays beside the line, looking across it at the spectator (the tumble lands a
	# few metres past, along the car's travel)
	await _reset(heading, start)
	# pass 1, timed: the first knocks of the session, nothing saved
	_logging = true
	await _drive(target, face, 7.5, false)
	_logging = false
	for k in _knocks:
		print("KNOCK %-14s at %.1f km/h  speed share lost %.2f %%" % [k["prop"], float(k["v"]) * 3.6, float(k["loss"]) * 100.0])
	if _knocks.is_empty():
		failures.append("the car knocked nobody over")
	else:
		print("FLYERS live after the drive: %d  hidden people %d" % [crowd.live_flyers(), crowd.down_count()])
	_report_frames()
	# a reset (the car jumps) brings the crowd back whole
	await _reset(heading, start)
	# pass 2, the frame sequence: the same drive, a frame every 0.1 s until everyone is back
	await _drive(target, face, 11.0, true)
	print("FLYERS live after the filmed drive: %d  hidden people %d" % [crowd.live_flyers(), crowd.down_count()])
	await _reset(heading, start)


## Rolls the car straight at `target` along -`face` for `secs`, braking to a stop past it.
## The spectator to drive into: the flattest 24 m straight approach from the road side with
## nothing rigid in the way, and a camera spot 7-9 m to the side that sees the spectator.
## Tall props (posts, poles, signs, trees; the soft ones have no collider for the rays) in
## 10 m buckets: xz positions for the knock camera's line of sight.
func _tall_props() -> Dictionary:
	var cells := {}
	var inst: Dictionary = map.info["instances"]
	for n: String in inst:
		var m: Dictionary = map.manifest.get(n, {})
		if n.begins_with("spectator_") or float((m.get("size", [0, 0, 0]) as Array)[1]) < 1.2:
			continue
		for e in inst[n]:
			var key := Vector2i(floori(e[0] / 10.0), floori(e[2] / 10.0))
			if not cells.has(key):
				cells[key] = PackedVector2Array()
			(cells[key] as PackedVector2Array).append(Vector2(e[0], e[2]))
	return cells


## Whether a tall prop stands within 1.2 m of the camera's line from `a` to `b`.
func _blocked(cells: Dictionary, a: Vector3, b: Vector3) -> bool:
	var a2 := Vector2(a.x, a.z)
	var b2 := Vector2(b.x, b.z)
	var lo := Vector2i(floori(minf(a2.x, b2.x) / 10.0) - 1, floori(minf(a2.y, b2.y) / 10.0) - 1)
	var hi := Vector2i(floori(maxf(a2.x, b2.x) / 10.0) + 1, floori(maxf(a2.y, b2.y) / 10.0) + 1)
	for x in range(lo.x, hi.x + 1):
		for z in range(lo.y, hi.y + 1):
			for q in cells.get(Vector2i(x, z), PackedVector2Array()):
				if Geometry2D.get_closest_point_to_segment(q, a2, b2).distance_to(q) < 1.2:
					return true
	return false


## The best knock line whose spectator is not in `skip`.
func _knock_run(skip: Array[Vector3]) -> Dictionary:
	var run := _knock_run_where(true, skip)
	return run if not run.is_empty() else _knock_run_where(false, skip)


## `off_gates`: only spectators 25 m or more from a checkpoint (its fabric gate is a node, not
## an instance: it would stand in the shot).
func _knock_run_where(off_gates: bool, skip: Array[Vector3]) -> Dictionary:
	var space := map.get_world_3d().direct_space_state
	var tall := _tall_props()
	var best := {}
	for p in _spectators():
		var target: Vector3 = p[0]
		if target in skip:
			continue
		# the fabric gates (nodes, not instances) stand at the checkpoints: keep them out of shot
		var by_gate := false
		for cp in (map.checkpoints if off_gates else []):
			if Vector2(target.x - cp["position"].x, target.z - cp["position"].z).length() < 25.0:
				by_gate = true
		if by_gate:
			continue
		var front := -Basis(Vector3.UP, p[1]).z
		front.y = 0.0
		front = front.normalized()
		# from the front (the road side) first; barriers and slopes often close it off, so
		# from the sides and behind too
		for turn in [0.0, 60.0, -60.0, 120.0, -120.0, 180.0]:
			var face := front.rotated(Vector3.UP, deg_to_rad(turn))
			var start := target + face * 24.0
			start.y = map.ground_height(start.x, start.z, target.y + 30.0)
			var drop := absf(start.y - target.y)
			# the ground along the way must not bump more than the straight line
			var bumpy := false
			for k in range(1, 6):
				var q := target + face * 4.0 * k
				var gy := map.ground_height(q.x, q.z, target.y + 30.0)
				if absf(gy - lerpf(target.y, start.y, 4.0 * k / 24.0)) > 0.6:
					bumpy = true
			if bumpy or drop > float(best.get("drop", 3.0)):
				continue
			# nothing rigid (props, walls) between the start and the spectator
			var ray := PhysicsRayQueryParameters3D.create(start + Vector3.UP * 0.7, target + Vector3.UP * 0.7 - face * 3.0,
					MapWorld.LAYER_PROPS | MapWorld.LAYER_WORLD)
			if not space.intersect_ray(ray).is_empty():
				continue
			var side := face.cross(Vector3.UP).normalized()
			for cand in [[side, 7.0], [-side, 7.0], [side, 9.0], [-side, 9.0]]:
				var eye: Vector3 = target + face * 2.0 + cand[0] * cand[1]
				eye.y = map.ground_height(eye.x, eye.z, target.y + 30.0) + 1.7
				var look := PhysicsRayQueryParameters3D.create(eye, target + Vector3.UP * 1.0,
						MapWorld.LAYER_PROPS | MapWorld.LAYER_WORLD)
				var look2 := PhysicsRayQueryParameters3D.create(eye, start + Vector3.UP * 1.0 - face * 8.0,
						MapWorld.LAYER_PROPS | MapWorld.LAYER_WORLD)
				if space.intersect_ray(look).is_empty() and space.intersect_ray(look2).is_empty() \
						and not _blocked(tall, eye, target) and not _blocked(tall, eye, start - face * 8.0):
					best = {"target": target, "face": face, "start": start, "drop": drop, "eye": eye}
					break
	return best


func _drive(target: Vector3, face: Vector3, secs: float, film: bool) -> void:
	car.linear_velocity = -face * float(opts["kmh"]) / 3.6
	var frame := 0
	var t := 0.0
	while t < secs:
		var past := (car.global_position - target).dot(-face) > 6.0
		if past and not film and car.input_brake == 0.0 and not _knocks.is_empty():
			print("BRAKE %d ms after knock 1" % ((Time.get_ticks_usec() - int(_knocks[0]["usec"])) / 1000))
		car.input_throttle = 0.0 if past else 0.35
		car.input_brake = 1.0 if past else 0.0
		car.input_steer = 0.0
		await process_frame
		t += 1.0 / 60.0
		frame += 1
		if film and frame % 6 == 0:
			await RenderingServer.frame_post_draw
			_save("knock_%03d" % (frame / 6))
	car.input_brake = 0.0


func _reset(heading: Basis, start: Vector3) -> void:
	car.reset_to(Transform3D(heading, start + Vector3.UP * 0.2))
	for i in 3:
		await physics_frame
	print("RESTORE reset_to: flyers %d  people down %d  hidden spectator instances %d" % [
		crowd.live_flyers(), crowd.down_count(), _hidden_spectators()])
	if crowd.live_flyers() != 0 or crowd.down_count() != 0 or _hidden_spectators() != 0:
		failures.append("crowd not whole after reset_to")
	for i in 30:
		await physics_frame


func _hidden_spectators() -> int:
	var n := 0
	for mmi in map.find_children("spectator_*", "MultiMeshInstance3D", true, false):
		var mm: MultiMesh = (mmi as MultiMeshInstance3D).multimesh
		for i in mm.instance_count:
			if mm.get_instance_transform(i).basis.get_scale().length_squared() < 1e-8:
				n += 1
	return n


func _mark(label: String) -> void:
	_marks.append({"label": label, "usec": Time.get_ticks_usec()})


## Worst frames within 1 s of each mark and what was created in that second.
func _report_frames() -> void:
	# the budget: 25 ms, or three times the drive's median frame when the machine is busy
	var all := _f_ms.duplicate()
	all.sort()
	var budget := FRAME_BUDGET_MS
	if not all.is_empty():
		budget = maxf(FRAME_BUDGET_MS, all[all.size() / 2] * 3.0)
		print("FRAMES whole knock run: %d frames  median %.1f ms  p95 %.1f ms  worst %.1f ms  (hit budget %.1f ms)" % [
			all.size(), all[all.size() / 2], all[int(all.size() * 0.95)], all[all.size() - 1], budget])
	# every compilation of the drive, against the drive's start and the first knock
	if not _f_usec.is_empty():
		var at: Array[String] = []
		for i in range(1, _f_usec.size()):
			var d := 0
			for k in 3:
				d += maxi(_f_perf[k][i] - _f_perf[k][i - 1], 0)
			if d > 0:
				at.append("+%d at %d ms" % [d, (_f_usec[i] - _f_usec[0]) / 1000])
		var first_knock := "none"
		if not _knocks.is_empty():
			first_knock = "%d ms" % ((int(_knocks[0]["usec"]) - _f_usec[0]) / 1000)
		print("COMPILES during the drive: %s  (first knock at %s)" % [", ".join(at) if at else "none", first_knock])
	for m in _marks:
		var t0: int = m["usec"]
		var worst := 0.0
		var worst_steps := 0
		var first := -1
		var last := -1
		for i in _f_usec.size():
			if _f_usec[i] < t0:
				continue
			if _f_usec[i] > t0 + 1000000:
				break
			if first < 0:
				first = i
			last = i
			if _f_ms[i] > worst:
				worst = _f_ms[i]
				worst_steps = _f_steps[i]
		if first < 0:
			print("FRAMES %s: no frames logged" % m["label"])
			continue
		var base := first - 1 if first > 0 else first
		var parts: Array[String] = []
		var created := 0
		for k in MONITORS.size():
			var d := _f_perf[k][last] - _f_perf[k][base]
			parts.append("%s +%d" % [MONITORS[k][1], d])
			if k < 3:
				created += maxi(d, 0)
		var hit_nodes := _f_perf[3][first] - _f_perf[3][base]
		var hit_res := _f_perf[4][first] - _f_perf[4][base]
		var around: Array[String] = []
		for i in range(maxi(first - 2, 0), mini(first + 6, _f_ms.size())):
			around.append("%s%.1f" % ["*" if i == first else "", _f_ms[i]])
		print("FRAMES %-22s around the hit (ms, * = the hit frame): %s" % [m["label"], " ".join(around)])
		var sorted := _f_ms.slice(first, last + 1)
		sorted.sort()
		print("FRAMES %-22s %d frames in 1 s  worst %.1f ms (%d physics steps)  median %.1f ms  %s  | hit frame: nodes +%d resources +%d" % [
			m["label"], last - first + 1, worst, worst_steps, sorted[sorted.size() / 2], "  ".join(parts), hit_nodes, hit_res])
		if created > 0:
			var at: Array[String] = []
			for i in range(first, last + 1):
				var d := 0
				for k in 3:
					d += maxi(_f_perf[k][i] - _f_perf[k][maxi(i - 1, 0)], 0)
				if d > 0:
					at.append("+%d at %d ms" % [d, (_f_usec[i] - t0) / 1000])
			print("  compilations: %s" % ", ".join(at))
			failures.append("%s: %d pipeline compilations" % [m["label"], created])
		if hit_nodes > 0 or hit_res > 0:
			failures.append("%s: nodes +%d resources +%d at hit time" % [m["label"], hit_nodes, hit_res])
		if worst > budget:
			failures.append("%s: frame %.1f ms (budget %.1f ms)" % [m["label"], worst, budget])


func _settle(frames: int) -> void:
	for f in frames:
		await process_frame
	await RenderingServer.frame_post_draw


func _save(label: String) -> void:
	var path := "%s/%s_%s.png" % [opts["dir"], map.map_id, label]
	root.get_texture().get_image().save_png(path)
	if not label.begins_with("knock_"):
		print("SHOT ", path)
