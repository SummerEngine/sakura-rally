extends SceneTree
## Soft course dressing probe (headless). On a real map the autopilot drives the car, on a
## lateral offset, through the densest row of roadside dressing it can find, then through the
## middle of a checkpoint gate, then into a gate upright. Per pass it prints the speed before
## and after each hit, the yaw rate the hit added, airborne time, hard impacts and the live
## debris count over time; then it checks that a reset to the start and a fresh car bring the
## whole course back. The row and gate passes use only the car API, so the same run on a
## branch without SoftCourse gives the "before" numbers.
##
## Rendered (`--summer-offscreen --audio-driver Dummy`) it also draws the drive from a camera
## behind the car and logs every frame: real frame time, physics steps, and the growth of
## draw-time pipeline compilations, nodes and resources. It prints the worst frames within 1 s
## of the 1st, 2nd and 10th smash, the first upright hit and the first gate pass (FRAMES lines),
## and fails on a compilation, node or resource created at hit time or a frame over 25 ms there.
##
## `map` is a route of the world (hanami, momiji, liaison); the passes run along that route.
##
##   timeout 300 $S --headless --disable-crash-handler --path . -s res://tools/game/softcourse_probe.gd \
##       -- map=hanami car=sakura
##   timeout 300 $S --summer-offscreen --audio-driver Dummy --disable-crash-handler --path . \
##       -s res://tools/game/softcourse_probe.gd

const DT := 1.0 / 120.0
## Hits are measured over this long after the contact (s).
const WINDOW := 0.6
## A row also needs the lane this far (m) past its offset clear: swinging out to it at speed the
## car runs up to a metre wide of its lane with the nose turned out (on the liaison it reached a
## maple 2.3 m behind the bale row).
const ROW_SWING := 1.2
## A row pass carries on this far (m) past the row's last prop on the row's offset, so the lane
## is checked clear that far too (a tree 12 m past a hairpin's tyre wall stopped the car dead).
const ROW_RUN_OUT := 25.0
## A row pass moves out onto the row's offset this far (m) before the row, and the lane is checked
## clear from there: moving out later, into a hairpin wall on the 10 m Hanami loop, the car ran
## 2-4 m wide of its lane into the trees behind the wall.
const ROW_MOVE_OUT := 60.0

var opts := {"map": "hanami", "car": "sakura", "kmh": "85"}
## Heavy dressing: a light row leaves these out; the heavy row is a tyre or bale wall.
const HEAVY := ["tire_stack", "hay_bale_round", "hay_bale_square", "marshal_post", "bench"]
var map: MapWorld
var car: Car
var game: Node
var failures: Array[String] = []
var soft: Node ## SoftCourse, when the branch has it
var events: Array[Dictionary] = []

# ---------------------------------------------------------------- frame log (windowed runs)
const FRAME_BUDGET_MS := 25.0
var windowed := false
var cam: Camera3D
var _f_usec := PackedInt64Array()
var _f_ms := PackedFloat32Array()
var _f_steps := PackedInt32Array()
var _f_perf: Array[PackedInt64Array] = [] ## per monitor: value at each frame
var _last_usec := 0
var _steps := 0
var _marks: Array[Dictionary] = [] ## {"label", "usec"}
var _smash_usec := PackedInt64Array() ## every smash
var _cut_usec := PackedInt64Array() ## the probe teleports, respawns or reloads: smash windows end here
var _kinds_seen: Array[String] = []
var _smash_n := 0
var _upright_marked := false
var _gate_marked := false
var _gate_hit_marked := false
var _pass_label := ""
const MONITORS := [
	[Performance.PIPELINE_COMPILATIONS_DRAW, "draw_compiles"],
	[Performance.PIPELINE_COMPILATIONS_SURFACE, "surface_compiles"],
	[Performance.PIPELINE_COMPILATIONS_SPECIALIZATION, "specialization_compiles"],
	[Performance.OBJECT_NODE_COUNT, "nodes"],
	[Performance.OBJECT_RESOURCE_COUNT, "resources"],
]


func _process(_delta: float) -> bool:
	var now := Time.get_ticks_usec()
	if _last_usec > 0:
		_f_usec.append(now)
		_f_ms.append((now - _last_usec) / 1000.0)
		_f_steps.append(_steps)
		for k in MONITORS.size():
			_f_perf[k].append(int(Performance.get_monitor(MONITORS[k][0])))
	_last_usec = now
	_steps = 0
	if cam != null and is_instance_valid(car):
		var xf := car.global_transform
		var back := xf.basis.z
		back.y = 0.0
		back = back.normalized() if back.length_squared() > 0.01 else Vector3.BACK
		cam.global_position = car.global_position + back * 6.5 + Vector3.UP * 2.6
		cam.look_at(car.global_position + Vector3.UP * 1.0)
	return false


func _physics_process(_delta: float) -> bool:
	_steps += 1
	return false


func _cut() -> void:
	_cut_usec.append(Time.get_ticks_usec())


func _mark(label: String) -> void:
	_marks.append({"label": label, "usec": Time.get_ticks_usec()})


func _cut_between(a: int, b: int) -> bool:
	for c in _cut_usec:
		if c > a and c <= b:
			return true
	return false


## Worst frames within 1 s of each mark, and what was created in that second.
func _report_frames() -> void:
	for m in _marks:
		var t0: int = m["usec"]
		var worst := 0.0
		var worst_steps := 0
		var first := -1
		var last := -1
		for i in _f_usec.size():
			if _f_usec[i] < t0:
				continue
			if _f_usec[i] > t0 + 1000000 or _cut_between(t0, _f_usec[i]):
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
		# nodes and resources: the frame of the hit itself (debris ages out later in the second)
		var hit_nodes := _f_perf[3][first] - _f_perf[3][base]
		var hit_res := _f_perf[4][first] - _f_perf[4][base]
		var sorted := _f_ms.slice(first, last + 1)
		sorted.sort()
		print("FRAMES %-18s %d frames in 1 s  worst %.1f ms (%d physics steps)  median %.1f ms  %s  | hit frame: nodes +%d resources +%d" % [
			m["label"], last - first + 1, worst, worst_steps, sorted[sorted.size() / 2], "  ".join(parts), hit_nodes, hit_res])
		if soft != null:
			if created > 0:
				failures.append("%s: %d pipeline compilations" % [m["label"], created])
			if hit_nodes > 0 or hit_res > 0:
				failures.append("%s: nodes +%d resources +%d at hit time" % [m["label"], hit_nodes, hit_res])
			if worst > FRAME_BUDGET_MS:
				failures.append("%s: frame %.1f ms" % [m["label"], worst])
	# every frame within 1 s after any smash
	# (a window ends early where the probe itself teleports, respawns or reloads)
	var worst_all := 0.0
	var worst_at := 0.0
	var n_all := 0
	var compiles := 0
	var j := -1 # latest smash at or before the frame
	for i in _f_usec.size():
		var t := _f_usec[i]
		while j + 1 < _smash_usec.size() and _smash_usec[j + 1] <= t:
			j += 1
		if j < 0 or t > _smash_usec[j] + 1000000 or _cut_between(_smash_usec[j], t):
			continue
		n_all += 1
		if _f_ms[i] > worst_all:
			worst_all = _f_ms[i]
			worst_at = (t - _smash_usec[j]) / 1000.0
		if i > 0:
			for k in 3:
				compiles += maxi(_f_perf[k][i] - _f_perf[k][i - 1], 0)
	print("FRAMES all %d smashes: %d frames within 1 s after one  worst %.1f ms (%.0f ms after its smash)  pipeline compilations %d" % [
		_smash_usec.size(), n_all, worst_all, worst_at, compiles])
	if soft != null and (worst_all > FRAME_BUDGET_MS or compiles > 0):
		failures.append("frames after smashes: worst %.1f ms, %d compilations" % [worst_all, compiles])


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	game = root.get_node("Game")
	windowed = DisplayServer.get_name() != "headless"
	for k in MONITORS.size():
		_f_perf.append(PackedInt64Array())
	if windowed:
		cam = Camera3D.new()
		cam.fov = 60.0
		cam.far = 3000.0
		root.add_child(cam)
		cam.make_current()
	_run.call_deferred()


func _run() -> void:
	map = MapWorld.new()
	map.name = "Map"
	map.map_id = opts["map"]
	root.add_child(map)
	await map.build()
	soft = map.get(&"soft_course")
	print("MAP %s  instances %d  static prop shapes %d  smashables %s  soft uprights %s  gates %s" % [
		map.map_id, map.stats.get("instances", 0), map.stats.get("prop_shapes", 0),
		map.stats.get("smashables", "-"), map.stats.get("soft_uprights", "-"),
		soft.gate_count() if soft != null else "-"])
	_spawn_car()
	if soft != null:
		soft.smashed.connect(func(prop: String, point: Vector3, v: float, loss: float) -> void:
			_smash_n += 1
			_smash_usec.append(Time.get_ticks_usec())
			if _smash_n in [1, 2, 10]:
				_mark("smash %d (%s)" % [_smash_n, prop])
			elif not prop in _kinds_seen:
				_mark("first %s" % prop)
			if not prop in _kinds_seen:
				_kinds_seen.append(prop)
			events.append({"kind": prop, "point": point, "v": v, "loss": loss, "tick": _ticks}))
		soft.upright_hit.connect(func(point: Vector3, v: float, loss: float) -> void:
			if not _upright_marked:
				_upright_marked = true
				_mark("first upright hit")
			if _pass_label == "gate_upright" and not _gate_hit_marked:
				_gate_hit_marked = true
				_mark("gate upright hit")
			events.append({"kind": "upright", "point": point, "v": v, "loss": loss, "tick": _ticks}))
		if soft.has_method(&"is_warm"):
			var waited := 0
			while windowed and not soft.is_warm() and waited < 600:
				await process_frame
				waited += 1
			print("WARM %s after %d frames" % [soft.is_warm(), waited])
	for i in 30:
		await physics_frame

	# ---------------------------------------------------------------- A: rows of dressing
	var row := {}
	for heavy in [false, true]:
		var r := _find_row(heavy)
		var forced: String = opts.get("heavy_row" if heavy else "light_row", "")
		if not forced.is_empty():
			# "s0,s1,lat": the same stretch as another run (a branch without SoftCourse
			# cannot search for a clear lane: its dressing is all rigid)
			var f := forced.split_floats(",")
			r = {"s0": f[0], "s1": f[1], "lat": f[2], "names": r["names"]}
		var label := "heavy_row" if heavy else "light_row"
		print("ROW %s  %s=%.1f,%.1f,%.2f  %d props: %s" % [label, label, r["s0"], r["s1"], r["lat"], r["names"].size(), _tally(r["names"])])
		var a := await _pass(label, r["s0"] - 90.0, r["s1"] + ROW_RUN_OUT, r["lat"], Callable(), r["s0"] - ROW_MOVE_OUT)
		if not heavy:
			row = r
		if soft != null:
			if int(a["hits"]) < 2:
				failures.append("%s: only %d smashes" % [label, a["hits"]])
			if float(a["worst_loss"]) > 0.13:
				failures.append("%s: one hit cost %.1f %%" % [label, float(a["worst_loss"]) * 100.0])
			if int(a["debris_peak"]) < 1 or int(a["debris_peak"]) > 24:
				failures.append("%s: debris peak %d" % [label, a["debris_peak"]])
			if int(a["hard_impacts"]) > 0:
				failures.append("%s: %d hard impacts" % [label, a["hard_impacts"]])

	# ---------------------------------------------------------------- B: through a gate
	# an open road's only gate stands at the time control, where the autopilot stops the car
	if not map.track.closed:
		print("GATE skipped on an open road (its gate is at the time control)")
	else:
		# the first checkpoint with a gate
		var cp: Dictionary = map.checkpoints[0]
		var gate: Node = null
		if soft != null:
			for c in map.checkpoints:
				if soft.gate_near(c["position"]) != null:
					cp = c
					gate = soft.gate_near(c["position"])
					break
		var cs := map.track.dist(map.track.nearest(cp["position"]))
		var billowed := [false]
		var b := await _pass("gate_centre", cs - 90.0, cs + 20.0, 0.0, func() -> void:
			if gate != null and gate.is_billowing():
				if not billowed[0] and not _gate_marked:
					_gate_marked = true
					_mark("first gate pass")
				billowed[0] = true)
		print("GATE centre  billowed %s" % billowed[0])
		if soft != null and not billowed[0]:
			failures.append("gate: banner did not billow")

		# C: into a gate upright
		# the car's right side runs into the right upright (ep2: the right post of checkpoint_gate)
		var lat: float = (float(gate.half_span) if gate != null else 6.5) - 0.9
		var c := await _pass("gate_upright", cs - 90.0, cs + 20.0, lat, Callable(), cs - 30.0)
		if soft != null:
			if int(c["upright_hits"]) < 1:
				failures.append("upright: no hit")
			if float(c["upright_loss"]) > 0.035:
				failures.append("upright: lost %.1f %%" % (float(c["upright_loss"]) * 100.0))

	# ---------------------------------------------------------------- E: into a road sign
	if soft != null:
		await _sign_pass()

	# ---------------------------------------------------------------- D: restoration
	if soft != null:
		await _restoration(row)

	if windowed:
		_report_frames()
	print("SUMMARY: %d failures" % failures.size())
	for f in failures:
		print("  FAIL %s" % f)
	game.request_quit(1 if failures.size() > 0 else 0)


var _ticks: int = 0


func _spawn_car() -> void:
	var scene := "res://scenes/car/car_hayate.tscn" if opts["car"] == "hayate" else "res://scenes/car/car.tscn"
	car = (load(scene) as PackedScene).instantiate() as Car
	car.name = "ProbeCar"
	root.add_child(car)
	_cut()
	car.reset_to(map.spawn)


## Densest run of smashable dressing within 60 m of road, on one side, at a common offset
## the car can drive (just past the road edge or on it).
func _find_row(heavy: bool) -> Dictionary:
	var track := map.track
	var names: Array[String] = []
	var smash: Array = SoftCourse.SMASHABLE.keys()
	var found: Array[Dictionary] = []
	var inst: Dictionary = map.info["instances"]
	for n in smash:
		if (n in HEAVY) != heavy:
			continue
		for e in inst.get(n, []):
			var p := Vector3(e[0], e[1], e[2])
			var i := track.nearest(p)
			var l := track.lateral(i, p)
			var hw := track.half_width(i)
			if absf(l) < hw - 0.5 or absf(l) > hw + track.verge + 4.5 or absf(p.y - track.point(i).y) > 1.5:
				continue
			found.append({"s": track.dist(i), "lat": l, "name": n, "hw": hw})
	found.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return x["s"] < y["s"])
	var best := {"s0": 600.0, "s1": 640.0, "lat": 6.0, "names": names}
	var best_n := 0
	for k in found.size():
		var f: Dictionary = found[k]
		var sel: Array[String] = []
		var s1: float = f["s"]
		for j in range(k, found.size()):
			var g: Dictionary = found[j]
			if float(g["s"]) - float(f["s"]) > 60.0:
				break
			if signf(g["lat"]) == signf(f["lat"]) and absf(float(g["lat"]) - float(f["lat"])) < 1.0:
				sel.append(g["name"])
				s1 = g["s"]
		# the row's own lane, every lane on the way out to it (a row behind a guardrail is out of
		# reach) and the lane just past it (ROW_SWING)
		var lat: float = f["lat"]
		var reach := sel.size() > best_n and float(f["s"]) > 150.0
		var l_out := float(f["hw"]) + 0.5
		while reach and l_out < absf(lat) + 0.5:
			reach = _lane_clear(float(f["s"]) - ROW_MOVE_OUT, s1 + ROW_RUN_OUT, signf(lat) * minf(l_out, absf(lat)))
			l_out += 1.0
		if reach:
			reach = _lane_clear(float(f["s"]) - ROW_MOVE_OUT, s1 + ROW_RUN_OUT, signf(lat) * (absf(lat) + ROW_SWING))
		if reach:
			best_n = sel.size()
			best = {"s0": f["s"], "s1": s1, "lat": lat, "names": sel}
	return best


## No rigid collider (layer 3) and no steep ground along a car-wide lane at lateral `lat`.
func _lane_clear(s0: float, s1: float, lat: float) -> bool:
	var track := map.track
	var space := map.get_world_3d().direct_space_state
	var q := PhysicsShapeQueryParameters3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2.2, 1.0, 4.0)
	q.shape = box
	q.collision_mask = MapWorld.LAYER_PROPS
	var s := s0
	while s < s1:
		var xf := track.transform_at_abs(s, lat, 0.0)
		var ground := map.ground_height(xf.origin.x, xf.origin.z, xf.origin.y + 20.0)
		if absf(ground - track.transform_at_abs(s, 0.0, 0.0).origin.y) > 1.2:
			return false
		q.transform = Transform3D(xf.basis, Vector3(xf.origin.x, ground + 0.8, xf.origin.z))
		if not space.intersect_shape(q, 1).is_empty():
			return false
		s += 3.0
	return true


func _tally(names: Array[String]) -> String:
	var c := {}
	for n in names:
		c[n] = int(c.get(n, 0)) + 1
	var parts: Array[String] = []
	for k in c:
		parts.append("%s x%d" % [k, c[k]])
	return ", ".join(parts)


## Autopilot pass from road distance s_from to s_to on lateral offset lat. Prints per-hit
## numbers and returns the pass summary.
## The car starts on the road and moves out to `lat` from road distance `s_out` on.
func _pass(label: String, s_from: float, s_to: float, lat: float, each_tick: Callable = Callable(), s_out: float = -INF) -> Dictionary:
	var track := map.track
	_pass_label = label
	for n in car.get_children():
		if n is Autopilot:
			n.queue_free()
	var road_lat := clampf(lat, -1.5, 1.5) if s_out > s_from else lat
	_cut()
	car.reset_to(track.transform_at_abs(s_from, road_lat, 0.35))
	events.clear()
	for i in 6:
		await physics_frame
	var ap := Autopilot.new()
	ap.curve = track.to_curve()
	ap.closed = track.closed
	ap.lateral_offset = road_lat
	ap.max_speed_kmh = float(opts["kmh"])
	ap.line_tolerance = 6.0
	car.add_child(ap)
	var impacts: Array[float] = []
	var on_impact := func(s: float, _p: Vector3) -> void: impacts.append(s)
	car.impact.connect(on_impact)
	var result := {"hits": 0, "max_added_yaw": 0.0, "max_yaw_step": 0.0, "airborne": 0.0, "debris_peak": 0,
			"worst_loss": 0.0, "hard_impacts": 0, "min_kmh": 999.0, "upright_hits": 0, "upright_loss": 0.0}
	var yaw_hist := PackedFloat32Array()
	var speed_hist := PackedFloat32Array()
	var debris_line: Array[String] = []
	var reported := 0
	var t := 0.0
	var entry_kmh := -1.0
	var idx := track.nearest(car.global_position)
	var gone := false
	while t < 30.0:
		await physics_frame
		_ticks += 1
		t += DT
		yaw_hist.append(car.angular_velocity.y)
		speed_hist.append(Vector2(car.linear_velocity.x, car.linear_velocity.z).length())
		if car.airborne_time > 0.0:
			result["airborne"] = maxf(result["airborne"], car.airborne_time)
		if each_tick.is_valid():
			each_tick.call()
		idx = track.nearest(car.global_position, idx, 10)
		var s := track.dist(idx)
		if s > s_out:
			ap.lateral_offset = lat
		if entry_kmh < 0.0 and s > s_from + 70.0:
			entry_kmh = car.speed_kmh
		if s > s_from + 70.0:
			result["min_kmh"] = minf(result["min_kmh"], absf(car.speed_kmh))
		if soft != null and int(t / DT) % 60 == 0:
			var live: int = soft.live_debris()
			result["debris_peak"] = maxi(result["debris_peak"], live)
			if s > s_from + 60.0:
				debris_line.append("%.1fs:%d" % [t, live])
		# hits settle over WINDOW: report each once the window has passed
		while reported < events.size() and _ticks - int(events[reported]["tick"]) > int(WINDOW / DT):
			var ev: Dictionary = events[reported]
			var k0 := yaw_hist.size() - 1 - (_ticks - int(ev["tick"]))
			var yaw0 := yaw_hist[maxi(k0 - 1, 0)]
			var added := 0.0
			for q in range(k0, mini(k0 + int(WINDOW / DT), yaw_hist.size())):
				added = maxf(added, absf(yaw_hist[q] - yaw0))
			var v_before := speed_hist[maxi(k0 - 1, 0)]
			var v_after := speed_hist[mini(k0 + 2, speed_hist.size() - 1)]
			# against the speed the car would have had: its trend over the 3 ticks before
			var v_trend := v_before + (v_before - speed_hist[maxi(k0 - 4, 0)])
			var lost := 1.0 - v_after / maxf(v_trend, 0.01)
			var step := absf(yaw_hist[mini(k0 + 2, yaw_hist.size() - 1)] - yaw0)
			if label != "rebreak":
				print("  HIT %-18s %6.1f -> %6.1f km/h  (%.1f %% lost, impulse %.1f %%)  yaw step %.3f rad/s, yaw drift over %.1f s %.3f rad/s" % [
					ev["kind"], v_before * 3.6, v_after * 3.6, lost * 100.0, float(ev["loss"]) * 100.0, step, WINDOW, added])
			result["hits"] += 1
			result["max_added_yaw"] = maxf(result["max_added_yaw"], added)
			result["max_yaw_step"] = maxf(result["max_yaw_step"], step)
			result["worst_loss"] = maxf(result["worst_loss"], lost)
			if ev["kind"] == "upright":
				result["upright_hits"] += 1
				result["upright_loss"] = maxf(result["upright_loss"], lost)
			reported += 1
		if s > s_to or (track.closed and s < s_from - 50.0 and t > 3.0):
			gone = true
			break
	car.impact.disconnect(on_impact)
	for imp in impacts:
		if imp > 0.25:
			result["hard_impacts"] += 1
	# yaw over the whole pass as a crash measure that needs no SoftCourse
	var max_yaw := 0.0
	for y in yaw_hist:
		max_yaw = maxf(max_yaw, absf(y))
	var exit_kmh := absf(car.speed_kmh)
	print("PASS %-12s reached_end %s  %.1f s  entry %.0f km/h  min %.0f km/h  exit %.0f km/h  hits %d  impacts %d (hard %d, max %.2f)  airborne max %.2f s  |yaw rate| max %.2f rad/s  max yaw step at a hit %.3f rad/s" % [
		label, gone, t, entry_kmh, result["min_kmh"], exit_kmh, result["hits"], impacts.size(), result["hard_impacts"],
		impacts.max() if not impacts.is_empty() else 0.0, result["airborne"], max_yaw, result["max_yaw_step"]])
	if soft != null:
		print("  debris live: %s  (peak %d)" % [" ".join(debris_line), result["debris_peak"]])
	result["max_yaw"] = max_yaw
	result["reached_end"] = gone
	ap.queue_free()
	return result


## No rigid collider in a car-wide strip from `dist` metres in front of a board to 2 m short of it.
func _approach_clear(base: Vector3, face: Vector3, yaw: float, dist: float) -> bool:
	var space := map.get_world_3d().direct_space_state
	var q := PhysicsShapeQueryParameters3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2.2, 1.0, 4.0)
	q.shape = box
	q.collision_mask = MapWorld.LAYER_PROPS
	var d := dist
	while d > 2.0:
		var p := base + face * d
		p.y = map.ground_height(p.x, p.z, p.y + 20.0) + 0.8
		q.transform = Transform3D(Basis(Vector3.UP, yaw), p)
		if not space.intersect_shape(q, 1).is_empty():
			return false
		d -= 3.0
	return true


## Mapgen direction boards (along the liaison road): straight into the first one, from 30 m in
## front of it, or nearer when a rigid prop stands in that approach (the board stands off the
## road among the roadside trees; like a row's lane, the run-up must be clear to measure it).
func _sign_pass() -> void:
	var sign_id := -1
	for id in soft.smashable_count():
		if soft.prop_kind(id) == SoftCourse.ROAD_SIGN:
			sign_id = id
			break
	var signs := map.find_child("Signs", false, false)
	if sign_id < 0:
		print("SIGN none on %s (%d sign nodes)" % [map.map_id, signs.get_child_count() if signs != null else 0])
		return
	var sd: Dictionary = map.info["signs"][0]
	var yaw: float = sd["yaw"]
	var base := Vector3(sd["base"][0], sd["base"][1], sd["base"][2])
	var face := Basis(Vector3.UP, yaw).z
	var run_up := 30.0
	while run_up > 10.0 and not _approach_clear(base, face, yaw, run_up):
		run_up -= 5.0
	var start := base + face * run_up
	start.y = map.ground_height(start.x, start.z) + 0.2
	_cut()
	car.reset_to(Transform3D(Basis(Vector3.UP, yaw), start))
	events.clear()
	for i in 4:
		await physics_frame
	car.linear_velocity = -face * 16.0
	var holder := signs.get_node("Sign_0") as Node3D
	var labels := holder.find_children("*", "Label3D", false, false).size()
	var debris0: int = soft.live_debris()
	var yaw_before := 0.0
	var max_yaw_step := 0.0
	var air := 0.0
	var t := 0.0
	var hit_t := -1.0
	while t < 5.0:
		car.input_throttle = 0.6
		car.input_steer = 0.0
		var w0 := absf(car.angular_velocity.y)
		await physics_frame
		t += DT
		air = maxf(air, car.airborne_time)
		if hit_t < 0.0 and soft.is_broken(sign_id):
			hit_t = t
			yaw_before = w0
		if hit_t >= 0.0 and t - hit_t < WINDOW:
			max_yaw_step = maxf(max_yaw_step, absf(car.angular_velocity.y) - yaw_before)
		if hit_t >= 0.0 and t - hit_t > WINDOW:
			break
	car.input_throttle = 0.0
	var ev: Dictionary = {}
	for e in events:
		if e["kind"] == SoftCourse.ROAD_SIGN:
			ev = e
	print("SIGN %s  run-up %.0f m  hit %s  speed %.1f km/h  loss %.1f %%  yaw step %.3f rad/s  airborne max %.2f s  debris pieces %d  sign node visible %s (%d text lines, hidden with it)" % [
		holder.name, run_up, hit_t >= 0.0, float(ev.get("v", 0.0)) * 3.6, float(ev.get("loss", 0.0)) * 100.0,
		max_yaw_step, air, soft.live_debris() - debris0, holder.visible, labels])
	if hit_t < 0.0 or holder.visible:
		failures.append("road sign did not break")
	elif soft.live_debris() - debris0 < 2:
		failures.append("road sign: %d debris pieces" % (soft.live_debris() - debris0))


## Road sign nodes currently hidden (broken).
func _hidden_signs() -> int:
	var n := 0
	var signs := map.find_child("Signs", false, false)
	if signs != null:
		for c in signs.get_children():
			if c is Node3D and c.name.begins_with("Sign_") and not (c as Node3D).visible:
				n += 1
	return n


func _restoration(row: Dictionary) -> void:
	var broken_before: int = soft.broken_count()
	var debris_before: int = soft.live_debris()
	# break a few again so the check starts dirty
	if broken_before == 0:
		await _pass("rebreak", row["s0"] - 90.0, row["s1"] + ROW_RUN_OUT, row["lat"], Callable(), row["s0"] - ROW_MOVE_OUT)
		broken_before = soft.broken_count()
		debris_before = soft.live_debris()
	var signs_before := _hidden_signs()
	_cut()
	car.reset_to(map.spawn)
	for i in 3:
		await physics_frame
	var hidden := _hidden_instances()
	print("RESTORE reset_to(spawn): broken %d -> %d  live debris %d -> %d  hidden MultiMesh instances %d  hidden signs %d -> %d" % [
		broken_before, soft.broken_count(), debris_before, soft.live_debris(), hidden, signs_before, _hidden_signs()])
	if soft.broken_count() != 0 or soft.live_debris() != 0 or hidden != 0 or _hidden_signs() != 0:
		failures.append("restore after reset_to")
	# stage restart: Main frees the car and spawns a new one
	await _pass("rebreak", row["s0"] - 90.0, row["s1"] + ROW_RUN_OUT, row["lat"], Callable(), row["s0"] - ROW_MOVE_OUT)
	var b2: int = soft.broken_count()
	var d2: int = soft.live_debris()
	_cut()
	car.queue_free()
	await physics_frame
	_spawn_car()
	for i in 3:
		await physics_frame
	hidden = _hidden_instances()
	print("RESTORE new car: broken %d -> %d  live debris %d -> %d  hidden MultiMesh instances %d" % [
		b2, soft.broken_count(), d2, soft.live_debris(), hidden])
	if soft.broken_count() != 0 or soft.live_debris() != 0 or hidden != 0:
		failures.append("restore after new car")
	# map reload: a fresh MapWorld is whole
	var count: int = soft.smashable_count()
	_cut()
	map.queue_free()
	await process_frame
	map = MapWorld.new()
	map.name = "Map2"
	map.map_id = opts["map"]
	root.add_child(map)
	await map.build()
	soft = map.soft_course
	for i in 3:
		await physics_frame
	print("RESTORE map reload: smashables %d -> %d  broken %d  hidden MultiMesh instances %d" % [
		count, soft.smashable_count(), soft.broken_count(), _hidden_instances()])
	if soft.smashable_count() != count or soft.broken_count() != 0:
		failures.append("map reload")


## Smashable MultiMesh instances currently collapsed to zero scale.
func _hidden_instances() -> int:
	var n := 0
	for mmi in map.find_children("*", "MultiMeshInstance3D", true, false):
		var mm: MultiMesh = (mmi as MultiMeshInstance3D).multimesh
		for i in mm.instance_count:
			if mm.get_instance_transform(i).basis.get_scale().length_squared() < 1e-8:
				n += 1
	return n
