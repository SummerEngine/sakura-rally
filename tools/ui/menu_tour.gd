extends SceneTree
## Offscreen tour of the title hub in the real game (live 3D flyover, the real menu car): hub,
## Time Attack, the garage with every livery painted onto the parked car (one frame caught
## mid-sweep), a car switch on the car strip (old car driving off, new one parking), and back to the flyover with the chosen car. Navigates with the
## player's ui_* actions; saves <out>/menu_<shot>_<aspect>.png and prints MENU_TOUR lines.
##
##   timeout 300 $S --summer-offscreen --audio-driver Dummy --disable-crash-handler --path . \
##       -s res://tools/ui/menu_tour.gd -- aspect=16x9 out=/tmp/menu_tour

const ASPECTS := {"16x9": Vector2i(1600, 900), "16x10": Vector2i(1440, 900), "21x9": Vector2i(2100, 900)}

var opts := {"aspect": "16x9", "out": "/tmp/menu_tour"}
var main: Node
var game: Node
var ui: Node
var failures: Array[String] = []


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	DirAccess.make_dir_recursive_absolute(opts["out"])
	game = root.get_node("Game")
	game.set_setting("quality", "high")
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred()


func _run() -> void:
	var win: Vector2i = ASPECTS[opts["aspect"]]
	DisplayServer.window_set_size(win)
	root.size = win
	ui = main.ui
	await _until(func() -> bool: return int(game.state) == int(game.State.MENU), 90.0)
	# The UI clock (unscaled, like every UI tween): the intro is 1.8 s long on it.
	await _seconds(3.5)
	var wm: Control = ui.title._wordmark
	_check(wm.is_visible_in_tree() and not wm.leaving and wm.t_in >= wm.total_in_time(),
		"wordmark settled (t_in %.2f, leaving %s)" % [wm.t_in, wm.leaving])
	var img := await _shot("title")
	var ink := _ink_pixels(img, wm.get_global_rect())
	_check(ink > 800, "wordmark drawn on the title frame (%d ink pixels)" % ink)

	# Time Attack: the page over the flyover, then back.
	ui.title._time_attack_item.grab_focus()
	await _press(&"ui_accept")
	await _seconds(1.6)
	await _shot("time_attack")
	await _press(&"ui_cancel")
	await _seconds(1.0)

	# Garage: the menu car stands on the workshop's display spot under the showroom orbit.
	ui.title._garage_item.grab_focus()
	await _press(&"ui_accept")
	await _until(func() -> bool: return str(game.menu_view) == "garage", 5.0)
	await _seconds(2.2)
	_check(main.autopilot == null, "garage stops the autopilot")
	_check(main.car.launch_hold, "garage parks the car")
	var spot: Vector3 = main.menu_stage.display_spot().origin
	_check(main.car.global_position.distance_to(spot) < 0.5, "car on the display spot (%.2f m)" % main.car.global_position.distance_to(spot))
	await _shot("garage")
	var panel: Node = ui.title._garage
	panel.livery_picker.grab_focus()
	await _seconds(0.3)
	var colors: Array = game.CAR_COLORS
	for i in range(1, colors.size()):
		await _press(&"ui_right")
		if i == 1:
			await _seconds(0.36)
			await _shot("garage_sweep")
			await _seconds(1.0)
		else:
			await _seconds(1.3)
		_check(int(game.get_setting("car_color")) == i, "livery %d saved" % i)
		_check(_paint_color(main.car).is_equal_approx(colors[i]["primary"]), "livery %d on the car" % i)
		await _shot("garage_livery_%d" % i)
	# Car switch (when a second car scene is in the project).
	if panel._cars.size() > 1:
		panel.car_selector.grab_focus()
		await _seconds(0.3)
		var before: Node = main.car
		await _press(&"ui_right")
		await _seconds(1.5)
		await _shot("garage_switch_leave")
		await _seconds(3.0)
		await _shot("garage_switch_arrive")
		await _until(func() -> bool: return not main.menu_stage.arriving(), 15.0)
		await _seconds(0.5)
		_check(main.car != before and is_instance_valid(main.car), "car switch brings in another car")
		_check(main.car.global_position.distance_to(spot) < 0.3, "new car parked on the display spot (%.2f m)" % main.car.global_position.distance_to(spot))
		_check(str(game.get_setting("car_id")) == str(panel._cars[1]["id"]), "car choice saved")
		_check(main.car.scene_file_path == str(panel._cars[1]["scene"]), "switched car runs the chosen scene")
		_check(_paint_color(main.car).is_equal_approx(colors[colors.size() - 1]["primary"]), "switched car wears the livery")
		await _shot("garage_car2")
	await _press(&"ui_cancel")
	await _until(func() -> bool: return str(game.menu_view) == "title", 5.0)
	await _seconds(3.0)
	_check(main.autopilot != null, "flyover resumes after the garage")
	_check(main.car.scene_file_path == str(game.current_car()["scene"]), "flyover shows the selected car")
	await _shot("title_after_garage")
	print("MENU_TOUR fps=%d failures=%d %s" % [Engine.get_frames_per_second(), failures.size(), failures])
	game.request_quit(1 if failures.size() > 0 else 0)


## Body paint colour on the car's converted toon material (what the player sees).
func _paint_color(car: Node) -> Color:
	var visuals: Node = car.get_node_or_null(^"Visuals")
	for node in visuals.model.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		for s in mi.get_surface_override_material_count():
			var m := mi.get_surface_override_material(s) as ShaderMaterial
			if m != null and m.resource_name.to_lower().contains("paint") and not m.resource_name.to_lower().contains("paint2"):
				return m.get_shader_parameter("albedo")
	return Color(0, 0, 0, 0)


func _check(ok: bool, what: String) -> void:
	print("MENU_TOUR CHECK %s %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		failures.append(what)


func _shot(shot: String) -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	var path := "%s/menu_%s_%s.png" % [opts["out"], shot, opts["aspect"]]
	var img := root.get_texture().get_image()
	img.save_png(path)
	print("MENU_TOUR SHOT ", path)
	return img


## Dark ink pixels inside `rect` (the wordmark's ink over the bright sky and hills), every 2nd.
func _ink_pixels(img: Image, rect: Rect2) -> int:
	var r := Rect2i(rect).intersection(Rect2i(Vector2i.ZERO, img.get_size()))
	var n := 0
	for y in range(r.position.y, r.end.y, 2):
		for x in range(r.position.x, r.end.x, 2):
			if img.get_pixel(x, y).get_luminance() < 0.3:
				n += 1
	return n


func _press(action: StringName) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	Input.parse_input_event(ev)
	await process_frame
	var up := InputEventAction.new()
	up.action = action
	up.pressed = false
	Input.parse_input_event(up)
	await process_frame
	await process_frame


func _seconds(s: float) -> void:
	await create_timer(s, true, false, true).timeout



func _until(cond: Callable, timeout: float) -> void:
	var start := Time.get_ticks_msec()
	while not cond.call():
		if (Time.get_ticks_msec() - start) / 1000.0 > timeout:
			_check(false, "timed out")
			return
		await process_frame
