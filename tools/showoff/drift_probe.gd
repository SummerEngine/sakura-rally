extends SceneTree
## Headless measurement of the menu flyover driving: the menu car laps the real maps under the
## Autopilot the way MenuStage drives it, and every lap prints its time, speed, sliding, braking,
## line and contact numbers.
##
##   S=/Applications/Summer.app/Contents/MacOS/Summer
##   timeout 900 $S --headless --disable-crash-handler --fixed-fps 120 --path . \
##       -s res://tools/showoff/drift_probe.gd [-- maps=hanami,momiji cars=sakura,hayate \
##       styles=tidy,showoff laps=1 trace=/tmp/showoff/trace]
##
## styles: tidy = the pre-showoff flyover (tidy style, speed scale 0.82, 150 km/h), showoff = the
## flyover as MenuStage runs it now (MenuStage.FLYOVER_*), demo = the demo reel's race pace
## (showoff style, full scale, 195 km/h). laps: flying laps after the out-lap from the spawn.
## trace: writes <trace>_<map>_<car>_<style>.csv (one row per 0.05 s) for tuning.
##
## Columns: lap time; mean / max km/h; slide% = time with body slip > 12° (above 5 m/s), of the
## whole lap and of the time in corners (road heading change over the 30 m around the car
## > 12°); slides = separate excursions past 20° (each ends below 12°); max slip; brake time and
## brake applications (input_brake > 0.05, rising edges); lat = the largest |distance from the
## road centreline| / road half width (> 1.0 = the car's centre left the tarmac); rigid = chassis
## contacts with a static body on the props layer (trees, poles, walls, barriers) or a wall-like
## (|normal.y| < 0.5) contact with the world; soft = soft dressing smashed and soft uprights (gate
## posts, arch legs) brushed, listed with their lap progress on a SOFT line; resets = ticks where
## the car jumped > 5 m.

const DT := 1.0 / 120.0
const SLIDE_ON := 20.0
const SLIDE_OFF := 12.0
const CORNER_TURN := 12.0

var opts := {"maps": "hanami,momiji", "cars": "sakura,hayate", "styles": "tidy,showoff", "laps": "1", "trace": ""}
var game: Node
var rows: Array[String] = []


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	_run.call_deferred()


func _run() -> void:
	game = root.get_node("Game")
	for map_id in str(opts["maps"]).split(","):
		var map := MapWorld.new()
		map.name = "Map"
		map.map_id = map_id
		root.add_child(map)
		await map.build()
		for car_id in str(opts["cars"]).split(","):
			for style in str(opts["styles"]).split(","):
				await _probe(map, car_id, style)
		map.queue_free()
		await physics_frame
	print("")
	print("| map | car | style | lap | time s | mean km/h | max km/h | slide>12° % | in corners % | slides>20° | max slip° | brake s | brake apps | lat/hw | rigid | soft | resets |")
	print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
	for r in rows:
		print(r)
	game.request_quit()


## Autopilot settings per style name: [style, speed_scale, max_kmh].
func _config(style: String) -> Array:
	match style:
		"tidy":
			return [&"tidy", 0.82, 150.0]
		"showoff":
			# Loaded at run time: menu_stage.gd names the Game autoload, which a -s script's
			# compile step does not know yet.
			var k: Dictionary = (load("res://scripts/game/menu_stage.gd") as GDScript).get_script_constant_map()
			return [k["FLYOVER_STYLE"], k["FLYOVER_SCALE"], k["FLYOVER_KMH"]]
		"demo":
			return [&"showoff", 1.0, 195.0]
	push_error("unknown style " + style)
	return [&"tidy", 1.0, 195.0]


func _probe(map: MapWorld, car_id: String, style: String) -> void:
	var track := map.track
	var car := (load(str(game.get_car(car_id)["scene"])) as PackedScene).instantiate() as Car
	car.controlled_by_player = false
	root.add_child(car)
	car.reset_to(map.spawn)
	var cfg := _config(style)
	var ap := Autopilot.new()
	ap.curve = track.to_curve()
	ap.closed = track.closed
	ap.style = cfg[0]
	ap.speed_scale = cfg[1]
	ap.max_speed_kmh = cfg[2]
	car.add_child(ap)
	var hard := [0]
	car.impact.connect(func(s: float, _p: Vector3) -> void:
		if s > 0.25:
			hard[0] += 1)
	# Soft dressing hits (no physics contact: SoftCourse tests the car's box itself).
	var soft: Array[String] = []
	var on_smash := func(prop: String, point: Vector3, _v: float, _loss: float) -> void:
		soft.append("%s@%.0f" % [prop, track.progress_of(track.nearest(point), point)])
	var on_upright := func(point: Vector3, _v: float, _loss: float) -> void:
		soft.append("upright@%.0f" % track.progress_of(track.nearest(point), point))
	map.soft_course.smashed.connect(on_smash)
	map.soft_course.upright_hit.connect(on_upright)

	var want := int(opts["laps"])
	var trace: FileAccess = null
	if str(opts["trace"]) != "":
		var path := "%s_%s_%s_%s.csv" % [opts["trace"], map.map_id, car_id, style]
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		trace = FileAccess.open(path, FileAccess.WRITE)
		trace.store_line("t,progress,kmh,slip,steer,thr,brk,hb,intent,lat,hw,phase,target_kmh,surface,x,z")
	var laps_done := -1 # the out-lap from the spawn ends at the first line crossing
	var m := _fresh()
	var hint := -1
	var prev_pos := car.global_position
	var sliding := false
	var braking := false
	var touching := {}
	var t := 0.0
	var limit := 400.0 * (want + 1)
	var listed := str(opts.get("corners", "")) != "1"
	while laps_done < want and t < limit:
		await physics_frame
		t += DT
		var pos := car.global_position
		if not listed and ap._built:
			listed = true
			_list_corners(ap)
		if ap.laps > laps_done + 1:
			if laps_done >= 0:
				m["time"] = ap.last_lap_time
				m["hard"] = hard[0]
				m["soft"] = soft.duplicate()
				rows.append(_row(map.map_id, car_id, style, laps_done + 1, m))
			laps_done += 1
			m = _fresh()
			hard[0] = 0
			soft.clear()
		if pos.distance_to(prev_pos) > 5.0:
			m["resets"] += 1
		prev_pos = pos
		hint = track.nearest(pos, hint, 10 if hint >= 0 else 40)
		var speed := car.linear_velocity.length()
		var lv := car.local_velocity
		var slip := rad_to_deg(absf(atan2(lv.x, maxf(-lv.z, 0.5)))) if speed > 5.0 else 0.0
		var s := track.abs_s(hint, pos)
		var a := track.forward_at_abs(s - 15.0)
		var b := track.forward_at_abs(s + 15.0)
		var corner := rad_to_deg(absf(atan2(a.cross(b).y, a.dot(b)))) > CORNER_TURN
		m["n"] += 1
		m["kmh_sum"] += speed * 3.6
		m["kmh_max"] = maxf(m["kmh_max"], speed * 3.6)
		m["slip_max"] = maxf(m["slip_max"], slip)
		if slip > SLIDE_OFF:
			m["slide_n"] += 1
		if corner:
			m["corner_n"] += 1
			if slip > SLIDE_OFF:
				m["corner_slide_n"] += 1
		if not sliding and slip > SLIDE_ON:
			sliding = true
			m["slides"] += 1
		elif sliding and slip < SLIDE_OFF:
			sliding = false
		var brk := car.input_brake > 0.05
		if brk:
			m["brake_n"] += 1
			if not braking:
				m["brake_apps"] += 1
		braking = brk
		var hw := track.half_width(hint)
		m["lat"] = maxf(m["lat"], absf(track.lateral(hint, pos)) / hw)
		_contacts(car, m, touching)
		if trace != null and int(round(t / DT)) % 6 == 0:
			trace.store_line("%.2f,%.1f,%.1f,%.1f,%.2f,%.2f,%.2f,%d,%.2f,%.2f,%.2f,%d,%.1f,%s,%.0f,%.0f" % [t, ap.progress, speed * 3.6,
					rad_to_deg(atan2(lv.x, maxf(-lv.z, 0.5))), car.input_steer, car.input_throttle, car.input_brake,
					1 if car.input_handbrake else 0, car.drift_intent, track.lateral(hint, pos), hw, ap._phase,
					ap.target_speed * 3.6, track.surface(hint), pos.x, pos.z])
	if laps_done < want:
		rows.append("| %s | %s | %s | - | DNF after %.0f s | | | | | | | | | | | | %d |" % [map.map_id, car_id, style, t, m["resets"]])
	map.soft_course.smashed.disconnect(on_smash)
	map.soft_course.upright_hit.disconnect(on_upright)
	if trace != null:
		trace.close()
	car.queue_free()
	await physics_frame


func _fresh() -> Dictionary:
	return {"time": 0.0, "n": 0, "kmh_sum": 0.0, "kmh_max": 0.0, "slide_n": 0, "corner_n": 0,
			"corner_slide_n": 0, "slides": 0, "slip_max": 0.0, "brake_n": 0, "brake_apps": 0,
			"lat": 0.0, "rigid": 0, "resets": 0, "hard": 0, "rigid_at": [], "soft": []}


## Counts new chassis contacts with rigid things (each body/shape pair once per touch).
func _contacts(car: Car, m: Dictionary, touching: Dictionary) -> void:
	var state := PhysicsServer3D.body_get_direct_state(car.get_rid())
	var now := {}
	for i in state.get_contact_count():
		var obj := state.get_contact_collider_object(i) as CollisionObject3D
		if obj == null:
			continue
		var rigid := (obj.collision_layer & MapWorld.LAYER_PROPS) != 0
		if not rigid and (obj.collision_layer & MapWorld.LAYER_WORLD) != 0:
			rigid = absf(state.get_contact_local_normal(i).y) < 0.5 and obj.name != &"TerrainBody"
		if not rigid:
			continue
		var key := "%d/%d" % [obj.get_instance_id(), state.get_contact_collider_shape(i)]
		now[key] = true
		if not touching.has(key):
			m["rigid"] += 1
			var p := state.get_contact_collider_position(i)
			(m["rigid_at"] as Array).append("%s@(%.0f,%.0f,%.0f)" % [obj.name, p.x, p.y, p.z])
	touching.clear()
	touching.merge(now)


func _row(map_id: String, car_id: String, style: String, lap: int, m: Dictionary) -> String:
	var n := maxf(m["n"], 1)
	var cn := maxf(m["corner_n"], 1)
	var r := "| %s | %s | %s | %d | %.2f | %.1f | %.1f | %.1f | %.1f | %d | %.1f | %.1f | %d | %.2f | %d | %d | %d |" % [
			map_id, car_id, style, lap, m["time"], m["kmh_sum"] / n, m["kmh_max"],
			100.0 * m["slide_n"] / n, 100.0 * m["corner_slide_n"] / cn, m["slides"], m["slip_max"],
			m["brake_n"] * DT, m["brake_apps"], m["lat"], m["rigid"], (m["soft"] as Array).size(), m["resets"]]
	var at: Array = m["rigid_at"]
	if not at.is_empty() or m["hard"] > 0:
		print("CONTACTS %s/%s/%s lap %d: hard impacts %d, %s" % [map_id, car_id, style, lap, m["hard"], ", ".join(at)])
	if not (m["soft"] as Array).is_empty():
		print("SOFT %s/%s/%s lap %d: %s" % [map_id, car_id, style, lap, ", ".join(m["soft"])])
	print("LAP " + r)
	return r


## corners=1: the slid corners of the showoff table with their planned speeds.
func _list_corners(ap: Autopilot) -> void:
	for c: Dictionary in ap._corners:
		var vmin := INF
		for i in range(int(c["start"]), int(c["end"]) + 1):
			vmin = minf(vmin, ap._speeds[ap._wrap_index(i)])
		print("CORNER %6.0f-%6.0f m %s %s turn %3.0f° r %4.0f m vmin %3.0f km/h" % [c["start"] * ap._spacing,
				c["end"] * ap._spacing, "R" if c["dir"] > 0.0 else "L", "loose" if c["loose"] else "tarmac",
				rad_to_deg(c["turn"]), c["radius"], vmin * 3.6])
