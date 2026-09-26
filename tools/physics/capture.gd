extends SceneTree
## Windowed capture of the car on the proving ground for visual review.
## Writes PNG frames to docs/renders/ (physics_*.png) and frame strips to /tmp/sakura_capture/.
##
##   S=/Applications/Summer.app/Contents/MacOS/Summer
##   timeout 300 $S --disable-crash-handler --fixed-fps 120 --path . -s res://tools/physics/capture.gd [-- only=corner,slide]
##
## Shots: corner (autopilot on the tarmac loop, chase cam), slide (gravel handbrake flick, high
## side view), jump (side view sequence over the kicker), wheels (front wheel close-up while
## steering and rolling), bumps (suspension over the bumpy lane), modes (all four camera modes).

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


func _save(path: String) -> void:
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
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
