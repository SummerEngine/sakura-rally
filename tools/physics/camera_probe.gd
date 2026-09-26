extends SceneTree
## Chase camera downhill check. The autopilot drives one lap of a map with two chase cameras
## on the car: `before` (slope_follow = 0, the level rig of episode 2) and `after` (the slope rig).
## Every frame on a descent (the road 40 m ahead lies more than 4 % below the car) and on flats
## (|grade| < 1.5 % at the car and ahead) the road centreline 10-60 m ahead (every 5 m, 0.3 m up)
## is projected into each camera: a point counts as visible when it is inside the frame and not
## covered by the car's silhouette (the 2D hull of the projected convex hulls of the car's
## meshes). Terrain in the way is reported separately (a crest hides the road from any camera).
## A frame is "blind" when less than half of those points are visible (the car hides the road).
##
##   S=/Applications/Summer.app/Contents/MacOS/Summer
##   for m in hanami momiji liaison; do timeout 900 nice -n 5 $S --headless --disable-crash-handler \
##       --fixed-fps 60 --path . -s res://tools/physics/camera_probe.gd -- map=$m [car=sakura]; done
##
## One route per process: a map built after another in the same process measured differently
## (road points behind "terrain" that is not there: the first map's world state stays around).
## The time is the lap time of RaceSession; the open liaison route has no finish line to cross at
## the arrival (the autopilot stops before it), so its lap runs to `limit`.
##
## Under `--summer-offscreen --audio-driver Dummy` (instead of --headless) it also renders both
## cameras and writes <dir>/<map>_descents.png: the `frames` steepest descents of the lap (at least
## 4 s apart), before on the left, after on the right, each point drawn green (visible), red
## (behind the car) or yellow (behind terrain); plus the single frames <map>_NN_{before,after}.png.
## (The folder option is `dir=`, not `out=`: Summer's offscreen mode reads `out=` itself.)
## Other options: frames=4, limit=300 (s per lap), ap.<property>=<float> (autopilot exports),
## after.<property>=<float> (ChaseCamera exports of the after camera, for tuning).

const MapLapRunner := preload("res://tools/physics/map_lap_runner.gd")
const AHEAD_FROM := 10.0
const AHEAD_TO := 60.0
const AHEAD_STEP := 5.0
const LIFT := 0.3
const DESCENT := -0.04
const FLAT := 0.015
const GRADE_RUN := 40.0
const MIN_SPEED := 8.0
const VIEW := Vector2i(960, 540)
const SHEET_CELL := Vector2i(640, 360)
const CAMS: Array[String] = ["before", "after"]

## Runs after the cameras (process_priority) so it sees the transforms they will render with.
class Meter extends Node:
	var probe: Object

	func _init() -> void:
		process_priority = 1000

	func _process(delta: float) -> void:
		if probe != null:
			probe.measure(delta)


var opts := {"map": "hanami", "car": "sakura", "dir": "/tmp/ep3/camera", "frames": "4", "limit": "300"}
var rendering := false
var map: MapWorld
var car: Car
var cams: Dictionary = {}
var hull_local := PackedVector3Array()
var road_idx := -1
var elapsed := 0.0
var stats: Dictionary = {}
var shots: Array[Dictionary] = []
var next_candidate := 0.0
var pitch_prev: Dictionary = {}
var rate_prev: Dictionary = {}
var pending: Dictionary = {}


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	_run.call_deferred()


func _run() -> void:
	var game := root.get_node("Game")
	rendering = DisplayServer.get_name() != "headless"
	DirAccess.make_dir_recursive_absolute(opts["dir"])
	var map_id := str(opts["map"])
	map = await MapLapRunner.build_map(self, map_id)
	car = (load(str(game.get_car(opts["car"])["scene"])) as PackedScene).instantiate() as Car
	root.add_child(car)
	CarLook.apply(car)
	for c in CAMS:
		for kind in ["descent", "flat"]:
			stats["%s/%s" % [c, kind]] = {"frames": 0, "blind": 0, "points": 0, "in_frame": 0, "covered": 0, "visible": 0, "terrain": 0}
		stats["%s/rate" % c] = []
		stats["%s/peak" % c] = [0.0, 0.0]
		stats["%s/jerk" % c] = []
	if rendering:
		root.size = VIEW
	for c in CAMS:
		var cam := ChaseCamera.new()
		cam.name = "Chase_%s" % c
		cam.player_camera = false
		cam.target = car
		cam.road = map.track
		if c == "before":
			cam.slope_follow = 0.0
		else:
			for key in opts:
				if str(key).begins_with("after."):
					cam.set(str(key).substr(6), float(opts[key]))
		cams[c] = cam
		if c == "after":
			root.add_child(cam)
		else:
			var vp := SubViewport.new()
			vp.size = VIEW
			vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
			root.add_child(vp)
			vp.add_child(cam)
		cam.make_current()
	var meter := Meter.new()
	meter.probe = self
	root.add_child(meter)
	var runner := MapLapRunner.new()
	runner.driver_props["closed"] = map.track.closed
	for key in opts:
		if str(key).begins_with("ap."):
			runner.driver_props[str(key).substr(3)] = float(opts[key])
	await physics_frame
	_build_hull()
	var r: Dictionary = await runner.lap(self, map, car, false, float(opts["limit"]))
	meter.probe = null
	print("CAMERA_PROBE map=%s car=%s lap finished=%s time=%.1f s top=%.0f km/h resets=%d (visible = in frame and not behind the car)" % [
			map_id, opts["car"], r["finished"], r["time"], r["top_kmh"], r["resets"]])
	for kind in ["descent", "flat"]:
		var parts: Array[String] = []
		for c in CAMS:
			var st: Dictionary = stats["%s/%s" % [c, kind]]
			var n := maxf(st["points"], 1.0)
			parts.append("%s visible %.1f%% (in frame %.1f%%, behind car %.1f%%, behind terrain %.1f%%) blind frames %.1f%%" % [
					c, 100.0 * st["visible"] / n, 100.0 * st["in_frame"] / n, 100.0 * st["covered"] / n,
					100.0 * st["terrain"] / n, 100.0 * st["blind"] / maxf(st["frames"], 1.0)])
		print("  %s (%d frames, %.0f s): %s | %s" % [kind, stats["before/%s" % kind]["frames"],
				stats["before/%s" % kind]["frames"] / 60.0, parts[0], parts[1]])
	var motion: Array[String] = []
	for c in CAMS:
		motion.append("%s pitch rate p95 %.1f max %.1f deg/s (t=%.1f s), pitch accel rms %.0f deg/s2" % [c,
				_percentile(stats["%s/rate" % c], 0.95), stats["%s/peak" % c][0], stats["%s/peak" % c][1], _rms(stats["%s/jerk" % c])])
	print("  motion: %s | %s" % motion)
	if rendering and not shots.is_empty():
		print("  frames: %s" % _write_sheet(map_id))
	elif rendering:
		push_warning("camera_probe: no descent frame was drawn (the offscreen window stopped drawing?)")
	game.request_quit()


## Car-local points of the convex hulls of the car's meshes (wheels included).
func _build_hull() -> void:
	hull_local = PackedVector3Array()
	var inv := car.global_transform.affine_inverse()
	for n in car.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null or not mi.is_visible_in_tree():
			continue
		var shape := mi.mesh.create_convex_shape(true, true)
		var to_car := inv * mi.global_transform
		for p in shape.points:
			hull_local.append(to_car * p)


func measure(delta: float) -> void:
	if car == null or not is_instance_valid(car) or hull_local.is_empty():
		return
	if car.launch_hold:
		pitch_prev.clear()
		rate_prev.clear()
		return
	elapsed += delta
	var track := map.track
	var xf := car.get_global_transform_interpolated()
	road_idx = track.nearest(xf.origin, road_idx, 10)
	var s := track.abs_s(road_idx, xf.origin)
	var y0 := track.position_at_abs(s).y
	var grade := (track.position_at_abs(s + GRADE_RUN).y - y0) / GRADE_RUN
	var at_car := (track.position_at_abs(s + 6.0).y - track.position_at_abs(s - 6.0).y) / 12.0
	for c in CAMS:
		_track_motion(c, delta)
	var kind := ""
	if grade < DESCENT:
		kind = "descent"
	elif absf(grade) < FLAT and absf(at_car) < FLAT:
		kind = "flat"
	if kind == "" or car.linear_velocity.length() < MIN_SPEED:
		return
	var marks: Dictionary = {}
	for c in CAMS:
		var cam: ChaseCamera = cams[c]
		var proj := Projection.create_perspective(cam.fov, float(VIEW.x) / VIEW.y, cam.near, cam.far)
		var view := cam.global_transform.affine_inverse()
		var sil := PackedVector2Array()
		for p in hull_local:
			var q := _project(proj, view, xf * p)
			if q.z > 0.0:
				sil.append(Vector2(q.x, q.y))
		sil = Geometry2D.convex_hull(sil) if sil.size() >= 3 else PackedVector2Array()
		var st: Dictionary = stats["%s/%s" % [c, kind]]
		st["frames"] += 1
		var seen := 0
		var total := 0
		var dots: Array = []
		var d := AHEAD_FROM
		while d <= AHEAD_TO + 0.01:
			var w := track.position_at_abs(s + d) + Vector3.UP * LIFT
			var q := _project(proj, view, w)
			var inside := q.z > 0.0 and absf(q.x) <= 1.0 and absf(q.y) <= 1.0
			var covered := inside and sil.size() >= 3 and Geometry2D.is_point_in_polygon(Vector2(q.x, q.y), sil)
			var hidden := inside and not covered and _terrain_between(cam.global_position, w)
			st["points"] += 1
			total += 1
			if inside:
				st["in_frame"] += 1
			if covered:
				st["covered"] += 1
			if inside and not covered:
				st["visible"] += 1
				seen += 1
			if hidden:
				st["terrain"] += 1
			if inside:
				dots.append([Vector2(q.x, q.y), Color.RED if covered else (Color.YELLOW if hidden else Color.GREEN)])
			d += AHEAD_STEP
		if seen * 2 < total:
			st["blind"] += 1
		marks[c] = dots
	if kind == "descent" and rendering and pending.is_empty() and elapsed >= next_candidate:
		next_candidate = elapsed + 0.5
		_consider_shot(grade, marks)


func _project(proj: Projection, view: Transform3D, w: Vector3) -> Vector3:
	var v := view * w
	var clip := proj * Vector4(v.x, v.y, v.z, 1.0)
	if clip.w <= 0.001:
		return Vector3(0.0, 0.0, -1.0)
	return Vector3(clip.x / clip.w, clip.y / clip.w, 1.0)


func _terrain_between(from: Vector3, to: Vector3) -> bool:
	var ray := PhysicsRayQueryParameters3D.create(from, to, 1)
	var hit := root.get_world_3d().direct_space_state.intersect_ray(ray)
	return not hit.is_empty() and (hit["position"] as Vector3).distance_to(to) > 1.5


func _track_motion(c: String, delta: float) -> void:
	var cam: ChaseCamera = cams[c]
	var f := -cam.global_basis.z
	var pitch := rad_to_deg(atan2(f.y, Vector2(f.x, f.z).length()))
	if pitch_prev.has(c) and delta > 0.0:
		var rate := (pitch - float(pitch_prev[c])) / delta
		(stats["%s/rate" % c] as Array).append(absf(rate))
		var peak: Array = stats["%s/peak" % c]
		if absf(rate) > float(peak[0]):
			peak[0] = absf(rate)
			peak[1] = elapsed
		if rate_prev.has(c):
			(stats["%s/jerk" % c] as Array).append((rate - float(rate_prev[c])) / delta)
		rate_prev[c] = rate
	pitch_prev[c] = pitch


## Keeps the `frames` steepest descents at least 4 s apart; renders the candidate this frame.
func _consider_shot(grade: float, marks: Dictionary) -> void:
	var limit := int(opts["frames"])
	var replace := -1
	for k in shots.size():
		if absf(float(shots[k]["t"]) - elapsed) < 4.0:
			if grade >= float(shots[k]["grade"]):
				return
			replace = k
			break
	if replace < 0 and shots.size() >= limit:
		var least := 0
		for k in shots.size():
			if float(shots[k]["grade"]) > float(shots[least]["grade"]):
				least = k
		if grade >= float(shots[least]["grade"]):
			return
		replace = least
	pending = {"t": elapsed, "grade": grade, "marks": marks, "kmh": car.speed_kmh, "replace": replace}
	_grab.call_deferred()


func _grab() -> void:
	await RenderingServer.frame_post_draw
	if pending.is_empty() or cams.is_empty():
		pending = {}
		return
	var shot := pending
	shot["before"] = (cams["before"] as Camera3D).get_viewport().get_texture().get_image()
	shot["after"] = (cams["after"] as Camera3D).get_viewport().get_texture().get_image()
	var replace: int = shot["replace"]
	if replace >= 0:
		shots[replace] = shot
	else:
		shots.append(shot)
	pending = {}


func _write_sheet(map_id: String) -> String:
	shots.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["t"]) < float(b["t"]))
	var sheet := Image.create(SHEET_CELL.x * 2 + 18, (SHEET_CELL.y + 6) * shots.size() + 6, false, Image.FORMAT_RGB8)
	sheet.fill(Color(0.08, 0.08, 0.1))
	var names: Array[String] = []
	for k in shots.size():
		var shot := shots[k]
		for j in CAMS.size():
			var c := CAMS[j]
			var img: Image = shot[c]
			img.convert(Image.FORMAT_RGB8)
			var file := "%s/%s_%02d_%s.png" % [opts["dir"], map_id, k + 1, c]
			img.save_png(file)
			var cell := img.duplicate() as Image
			cell.resize(SHEET_CELL.x, SHEET_CELL.y, Image.INTERPOLATE_BILINEAR)
			for dot in shot["marks"][c]:
				var ndc: Vector2 = dot[0]
				var px := Vector2i(int((ndc.x * 0.5 + 0.5) * SHEET_CELL.x), int((0.5 - ndc.y * 0.5) * SHEET_CELL.y))
				cell.fill_rect(Rect2i(px - Vector2i(3, 3), Vector2i(7, 7)).intersection(Rect2i(Vector2i.ZERO, SHEET_CELL)), Color.BLACK)
				cell.fill_rect(Rect2i(px - Vector2i(2, 2), Vector2i(5, 5)).intersection(Rect2i(Vector2i.ZERO, SHEET_CELL)), dot[1])
			sheet.blit_rect(cell, Rect2i(Vector2i.ZERO, SHEET_CELL), Vector2i(6 + j * (SHEET_CELL.x + 6), 6 + k * (SHEET_CELL.y + 6)))
		names.append("#%d t=%.1f s grade %.1f%% %.0f km/h" % [k + 1, shot["t"], 100.0 * float(shot["grade"]), shot["kmh"]])
	var path := "%s/%s_descents.png" % [opts["dir"], map_id]
	sheet.save_png(path)
	return "%s (%s)" % [path, ", ".join(names)]


func _percentile(values: Array, q: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[clampi(int(q * (sorted.size() - 1)), 0, sorted.size() - 1)]


func _rms(values: Array) -> float:
	var sum := 0.0
	for v in values:
		sum += v * v
	return sqrt(sum / maxf(values.size(), 1.0))
