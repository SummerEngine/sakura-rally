extends SceneTree
## Windowed capture of the car on the proving ground for visual review.
## Writes PNG frames to docs/renders/ (physics_*.png) and frame strips to /tmp/sakura_capture/.
##
##   S=/Applications/Summer.app/Contents/MacOS/Summer
##   timeout 300 $S --disable-crash-handler --fixed-fps 120 --path . -s res://tools/physics/capture.gd [-- only=corner,slide]
##
## Shots: corner (autopilot on the tarmac loop, chase cam), slide (gravel handbrake flick, high
## side view), jump (side view sequence over the kicker), wheels (front wheel close-up while
## steering and rolling), bumps (suspension over the bumpy lane), modes (all four camera modes),
## crash (25° guardrail hit at 110 km/h and a quarter-overlap pole hit at 80 km/h on the tarmac
## plaza: an overhead contact sheet of each in /tmp/sakura_capture/ and a chase frame of the scrape).
## Runs offscreen with `--summer-offscreen` (real renderer, no window) as well as windowed.

const DT := 1.0 / 120.0
const OUT_DIR := "res://docs/renders/"
const SEQ_DIR := "/tmp/sakura_capture/"

var ground: Node
var car: Car
var chase: ChaseCamera
var fixed_cam: Camera3D
var options: Dictionary = {}


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=")
		if kv.size() == 2:
			options[kv[0]] = kv[1]
	DirAccess.make_dir_recursive_absolute(SEQ_DIR)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	root.size = Vector2i(1600, 900)
	ground = load("res://scenes/test/physics_test.tscn").instantiate()
	root.add_child(ground)
	car = load("res://scenes/car/car.tscn").instantiate() as Car
	root.add_child(car)
	car.set_livery(Color("f6f1e8"), Color("e8517c"))
	chase = ChaseCamera.new()
	chase.target = car
	chase.player_camera = false
	root.add_child(chase)
	fixed_cam = Camera3D.new()
	fixed_cam.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	root.add_child(fixed_cam)
	await physics_frame
	if _want("corner"):
		await shot_corner()
	if _want("slide"):
		await shot_slide()
	if _want("jump"):
		await shot_jump()
	if _want("wheels"):
		await shot_wheels()
	if _want("bumps"):
		await shot_bumps()
	if _want("modes"):
		await shot_modes()
	if _want("crash") and not occluded:
		await shot_crash()
	root.get_node("Game").request_quit()


func _want(shot: String) -> bool:
	return not options.has("only") or shot in str(options["only"]).split(",")


func _controls(thr: float, brk: float, steer: float, hb: bool = false) -> void:
	car.input_throttle = thr
	car.input_brake = brk
	car.input_steer = steer
	car.input_handbrake = hb


func _ticks(n: int) -> void:
	for i in n:
		await physics_frame


## The last frame counter a capture saw. Offscreen on macOS the window only draws while part of
## it is uncovered; a counter that stops advancing means the frames would be stale.
var _last_drawn := -1
var occluded := false


## The current frame, or null (and `occluded` set) when the renderer has stopped drawing.
func _grab() -> Image:
	await RenderingServer.frame_post_draw
	var drawn := Engine.get_frames_drawn()
	if drawn == _last_drawn:
		occluded = true
		push_warning("capture: no new frame drawn (window occluded?), frames are not verified")
		return null
	_last_drawn = drawn
	return root.get_texture().get_image()


func _save(path: String) -> void:
	var img: Image = await _grab()
	if img == null:
		return
	var abs_path := ProjectSettings.globalize_path(path) if path.begins_with("res://") else path
	img.save_png(abs_path)
	print("saved ", abs_path)


func _use_chase(mode: String = "chase") -> void:
	chase.mode = mode
	chase.make_current()
	chase.snap()


func _lane_steer(lane_x: float) -> float:
	var fwd := -car.global_transform.basis.z
	return clampf(-0.06 * (car.global_position.x - lane_x) - 2.0 * fwd.x, -1.0, 1.0)


func shot_corner() -> void:
	var ap := Autopilot.new()
	ap.path = ground.get("loop_path")
	car.add_child(ap)
	# Start just before the fast right-hander after the long straight.
	car.reset_to(ground.call("loop_transform", 180.0))
	_use_chase()
	var saved := 0
	var cooldown := 3.0
	for i in int(60.0 / DT):
		await physics_frame
		cooldown -= DT
		if cooldown < 0.0 and absf(car.input_steer) > 0.25 and car.speed_kmh > 45.0:
			await _save(OUT_DIR + "physics_corner_%d.png" % saved)
			saved += 1
			cooldown = 4.0
		if saved >= 4:
			break
	ap.queue_free()
	await physics_frame


func shot_slide() -> void:
	# Pass 1: chase view of the flick. Pass 2: the same flick from a fixed high camera (frame strip).
	await _flick(false)
	await _flick(true)
	# High three-quarter view of a sustained power slide.
	fixed_cam.make_current()
	for i in int(2.0 / DT):
		_controls(1.0, 0.0, -0.6)
		await physics_frame
		var p := car.global_position
		fixed_cam.global_position = p + Vector3(9.0, 7.0, 9.0)
		fixed_cam.look_at(p + Vector3.UP * 0.5)
		fixed_cam.fov = 45.0
		if i == 90:
			await _save(OUT_DIR + "physics_slide_gravel_top.png")


## Scandinavian flick on the gravel skidpad: brief right, then full left with handbrake, power out.
func _flick(overhead: bool) -> void:
	var pad: Transform3D = ground.call("spawn", "pad_gravel")
	car.reset_to(Transform3D(Basis.IDENTITY, pad.origin + Vector3(-20.0, 0.0, 52.0)))
	_use_chase()
	await _ticks(60)
	var lane := car.global_position.x
	while car.speed_kmh < 62.0:
		_controls(1.0, 0.0, _lane_steer(lane))
		await physics_frame
	if overhead:
		fixed_cam.make_current()
		fixed_cam.fov = 50.0
		var p0 := car.global_position
		fixed_cam.global_position = p0 + Vector3(12.0, 26.0, -14.0)
		fixed_cam.look_at(p0 + Vector3(-6.0, 0.0, -24.0))
	var frame := 0
	for i in int(2.4 / DT):
		var t := i * DT
		var hb := t < 0.55
		var steer := 0.5 if t < 0.2 else (-1.0 if t < 0.9 else -0.2)
		_controls(0.2 if hb else 1.0, 0.0, steer, hb and t > 0.2)
		await physics_frame
		if overhead and i % 18 == 0:
			await _save(SEQ_DIR + "slide_%02d.png" % frame)
			frame += 1
		if not overhead and i == 100:
			await _save(OUT_DIR + "physics_slide_gravel.png")


func shot_jump() -> void:
	car.reset_to(ground.call("spawn", "jump"))
	await _ticks(30)
	fixed_cam.make_current()
	fixed_cam.global_position = Vector3(-236.0, 2.2, 279.0)
	fixed_cam.look_at(Vector3(-250.0, 1.6, 283.0))
	fixed_cam.fov = 58.0
	var frame := 0
	var landed_frames := 0
	for i in int(14.0 / DT):
		var err := 85.0 / 3.6 - car.linear_velocity.length()
		var thr := clampf(0.3 + err * 0.4, 0.0, 1.0) if car.global_position.z > 294.0 else 0.2
		_controls(thr, 0.0, _lane_steer(-250.0))
		await physics_frame
		var z := car.global_position.z
		if z < 300.0 and z > 255.0 and i % 5 == 0:
			await _save(SEQ_DIR + "jump_%02d.png" % frame)
			frame += 1
		if car.airborne_time > 0.5 and landed_frames == 0 and absf(z - 281.0) < 0.6:
			await _save(OUT_DIR + "physics_jump_air.png")
			landed_frames = 1
		if z < 250.0:
			break
	# Chase view of the same jump.
	car.reset_to(ground.call("spawn", "jump"))
	_use_chase()
	await _ticks(30)
	var shot := false
	for i in int(14.0 / DT):
		var err := 85.0 / 3.6 - car.linear_velocity.length()
		var thr := clampf(0.3 + err * 0.4, 0.0, 1.0) if car.global_position.z > 294.0 else 0.2
		_controls(thr, 0.0, _lane_steer(-250.0))
		await physics_frame
		if not shot and car.airborne_time > 0.45:
			await _save(OUT_DIR + "physics_jump_chase.png")
			shot = true
		if car.global_position.z < 240.0:
			break


func shot_wheels() -> void:
	car.reset_to(ground.call("spawn", "runway_tarmac"))
	await _ticks(60)
	fixed_cam.make_current()
	fixed_cam.fov = 40.0
	var frame := 0
	for i in int(6.0 / DT):
		var t := i * DT
		_controls(0.25 if t > 0.5 else 0.0, 0.0, sin(t * 1.6))
		await physics_frame
		var xf := car.global_transform
		fixed_cam.global_position = xf * Vector3(-3.2, 1.1, -3.4)
		fixed_cam.look_at(xf * Vector3(-0.78, 0.35, -1.27))
		if i % 45 == 0:
			await _save(SEQ_DIR + "wheels_%02d.png" % frame)
			frame += 1
		if i == 150:
			await _save(OUT_DIR + "physics_wheels_steer.png")


func shot_bumps() -> void:
	car.reset_to(ground.call("spawn", "bumps"))
	await _ticks(30)
	fixed_cam.make_current()
	fixed_cam.fov = 50.0
	var frame := 0
	for i in int(7.0 / DT):
		_controls(0.6, 0.0, _lane_steer(-530.0))
		await physics_frame
		var p := car.global_position
		fixed_cam.global_position = p + Vector3(-7.5, 1.2, 0.5)
		fixed_cam.look_at(p + Vector3(0.0, 0.5, 0.0))
		if i % 20 == 0 and p.z < -285.0:
			await _save(SEQ_DIR + "bumps_%02d.png" % frame)
			frame += 1
		if frame == 6:
			await _save(OUT_DIR + "physics_bumps.png")
			frame += 1


func shot_modes() -> void:
	var ap := Autopilot.new()
	ap.path = ground.get("loop_path")
	car.add_child(ap)
	car.reset_to(ground.call("loop_transform", 900.0))
	await _ticks(int(6.0 / DT))
	for m: String in ChaseCamera.MODES:
		_use_chase(m)
		await _ticks(40)
		await _save(OUT_DIR + "physics_cam_%s.png" % m)
	ap.queue_free()
	await physics_frame


func shot_crash() -> void:
	await _crash_scene("wall", 110.0, func(origin: Vector3, fwd: Vector3) -> Node3D:
		# Guardrail 0.25 m thick, 1 m tall, crossing the path 40 m ahead at 25°, running right.
		var dir := fwd.rotated(Vector3.UP, -deg_to_rad(25.0))
		var box := BoxMesh.new()
		box.size = Vector3(0.25, 1.0, 120.0)
		var shape := BoxShape3D.new()
		shape.size = box.size
		return _crash_body(box, shape, Transform3D(Basis.looking_at(dir, Vector3.UP),
				origin + fwd * 40.0 + dir * 55.0 + Vector3.UP * 0.5)))
	if occluded:
		return
	await _crash_scene("pole", 80.0, func(origin: Vector3, fwd: Vector3) -> Node3D:
		# Telephone pole (r 0.16) overlapping the right quarter of the car's width.
		var right := fwd.cross(Vector3.UP)
		var mesh := CylinderMesh.new()
		mesh.top_radius = 0.16
		mesh.bottom_radius = 0.16
		mesh.height = 6.0
		var shape := CylinderShape3D.new()
		shape.radius = 0.16
		shape.height = 6.0
		return _crash_body(mesh, shape, Transform3D(Basis(),
				origin + fwd * 40.0 + right * (0.87 - 0.435 + 0.16) + Vector3.UP * 3.0)))


## A static obstacle on the props layer (like MapWorld's Barriers), with a visible mesh.
func _crash_body(mesh: Mesh, shape: Shape3D, xf: Transform3D) -> Node3D:
	var body := StaticBody3D.new()
	body.collision_layer = 4
	body.collision_mask = 0
	body.transform = xf
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("d8d4cc")
	mi.material_override = mat
	body.add_child(mi)
	root.add_child(body)
	return body


## Runs straight at `kmh` on the tarmac plaza into the obstacle, then holds throttle with the
## wheel centred. Overhead frames every 0.15 s from just before contact go into a 3x2 sheet.
func _crash_scene(tag: String, kmh: float, build: Callable) -> void:
	car.reset_to(ground.call("spawn", "plaza_tarmac"))
	await _ticks(60)
	var lane := car.global_position.x
	while car.speed_kmh < kmh:
		_controls(1.0, 0.0, _lane_steer(lane))
		await physics_frame
	var fwd := -car.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var body: Node3D = build.call(car.global_position * Vector3(1, 0, 1), fwd)
	var contact_at := -1
	var frames: Array[Image] = []
	var chase_saved := false
	for i in int(6.0 / DT):
		var touching := car.get_colliding_bodies().has(body)
		if contact_at < 0 and touching:
			contact_at = i
		var hold := car.speed_kmh < kmh
		_controls(1.0 if contact_at >= 0 or hold else 0.3, 0.0, _lane_steer(lane) if contact_at < 0 else 0.0)
		await physics_frame
		var ahead := contact_at < 0 and (body.global_position - car.global_position).dot(fwd) < 60.0
		if contact_at >= 0 or ahead:
			var p := car.global_position
			fixed_cam.make_current()
			fixed_cam.fov = 50.0
			fixed_cam.global_position = p + Vector3.UP * 30.0 - fwd * 6.0
			fixed_cam.look_at(p + fwd * 4.0)
		var since := i - contact_at if contact_at >= 0 else -1
		if contact_at >= 0 and since % 18 == 0 and frames.size() < 6:
			var img: Image = await _grab()
			if img == null:
				break
			frames.append(img)
		if tag == "wall" and not chase_saved and since == 30:
			_use_chase()
			await _ticks(2)
			await _save(OUT_DIR + "physics_wall_scrape.png")
			chase_saved = true
		if frames.size() >= 6 or occluded:
			break
	_save_sheet(frames, SEQ_DIR + "crash_%s_sheet.png" % tag)
	body.queue_free()
	await physics_frame


func _save_sheet(frames: Array[Image], path: String) -> void:
	if frames.is_empty():
		return
	var w := frames[0].get_width() / 2
	var h := frames[0].get_height() / 2
	var sheet := Image.create(w * 3, h * 2, false, frames[0].get_format())
	for k in frames.size():
		var img := frames[k].duplicate() as Image
		img.resize(w, h, Image.INTERPOLATE_BILINEAR)
		sheet.blit_rect(img, Rect2i(0, 0, w, h), Vector2i((k % 3) * w, (k / 3) * h))
	sheet.save_png(path)
	print("saved ", path)
