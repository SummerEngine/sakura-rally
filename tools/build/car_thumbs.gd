extends SceneTree
## Car strip thumbnails for the garage (scripts/ui/widgets/car_selector.gd): renders every car
## scene in Game.CARS on a transparent background, front three-quarter view from a little above,
## in the game's cel look (the car's toon materials and inked hulls from CarLook, a warm key
## light, the default shade tint) with the first livery (Game.CAR_COLORS[0]) so the cards compare
## the cars' shapes. Renders at RENDER_SCALE x the output size and downsamples for clean edges.
##
## Writes assets/ui/cars/<id>.png (OUT_SIZE, RGBA). Offscreen (headless has no pixels):
##   S=/Applications/Summer.app/Contents/MacOS/Summer
##   timeout 300 nice -n 5 $S --summer-offscreen --audio-driver Dummy --disable-crash-handler \
##       --path . -s res://tools/build/car_thumbs.gd [-- sakura hayate]
## then re-import (`--import`). With no ids it renders every car whose scene exists.

const OUT_DIR := "res://assets/ui/cars/"
## Output size: 2x the strip card's thumbnail (CarSelector.THUMB, 232 x 112).
const OUT_SIZE := Vector2i(464, 224)
const RENDER_SCALE := 2
## Camera: yaw of the view around the car (0 = straight ahead of its nose, + = its left side),
## elevation, lens; the car's bounds are fitted with FIT_MARGIN of air.
const VIEW_YAW := 38.0
const VIEW_PITCH := 11.0
const FOV := 24.0
const FIT_MARGIN := 1.06


func _initialize() -> void:
	var ids: Array = OS.get_cmdline_user_args()
	var game: Node = root.get_node("Game")
	if ids.is_empty():
		for c: Dictionary in game.CARS:
			if ResourceLoader.exists(str(c["scene"])):
				ids.append(c["id"])
	_run.call_deferred(ids)


func _run(ids: Array) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var game: Node = root.get_node("Game")
	var failed := 0
	for id: String in ids:
		var car: Dictionary = game.get_car(id)
		if car.is_empty() or str(car.get("id", "")) != id or not ResourceLoader.exists(str(car["scene"])):
			push_error("car_thumbs: no car scene for %s" % id)
			failed += 1
			continue
		await _render(id, str(car["scene"]), game.CAR_COLORS[0])
	game.request_quit(1 if failed > 0 else 0)


func _render(id: String, scene_path: String, livery: Dictionary) -> void:
	var vp := SubViewport.new()
	vp.size = OUT_SIZE * RENDER_SCALE
	vp.transparent_bg = true
	vp.msaa_3d = Viewport.MSAA_8X
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)

	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("f2e6f0")
	env.ambient_light_energy = 0.55
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.light_color = Color("fff1dc")
	sun.light_energy = 1.25
	sun.shadow_enabled = true
	sun.rotation_degrees = Vector3(-48.0, 150.0, 0.0)
	vp.add_child(sun)

	# Frozen and out of the physics space: the car only needs to look parked.
	var car := (load(scene_path) as PackedScene).instantiate() as Car
	car.process_mode = Node.PROCESS_MODE_DISABLED
	car.freeze = true
	vp.add_child(car)
	car.set_livery(livery["primary"], livery["secondary"])
	CarLook.apply(car)

	var box := _bounds(car)
	var centre := box.get_center()
	var radius := box.size.length() * 0.5
	# From the car towards the camera: ahead of the nose (-Z), turned to its left, raised.
	var dir := Basis(Vector3.UP, deg_to_rad(VIEW_YAW)) * Basis(Vector3.RIGHT, deg_to_rad(VIEW_PITCH)) * Vector3.FORWARD
	var cam := Camera3D.new()
	cam.fov = FOV
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	vp.add_child(cam)
	# Fit the bounding sphere to the frame height (the frame is wider than tall).
	var dist := radius * FIT_MARGIN / sin(deg_to_rad(FOV) * 0.5) * 0.62
	cam.global_position = centre + dir * dist
	cam.look_at(centre, Vector3.UP)
	cam.make_current()

	for f in 12:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	img.convert(Image.FORMAT_RGBA8)
	img = _crop_fit(img)
	var png := "%s%s.png" % [OUT_DIR, id]
	img.save_png(ProjectSettings.globalize_path(png))
	print("CAR_THUMB %s %dx%d -> %s" % [id, img.get_width(), img.get_height(), png])
	vp.queue_free()
	await process_frame


## World bounds of the car's visible meshes.
func _bounds(car: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for n in car.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if not mi.is_visible_in_tree() or mi.mesh == null:
			continue
		var b := mi.global_transform * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box


## Crops the render to the car's pixels, centred, and scales it to fill OUT_SIZE with a few
## pixels of air (the same framing for every car whatever its proportions).
func _crop_fit(img: Image) -> Image:
	var used := img.get_used_rect()
	if used.size.x <= 0 or used.size.y <= 0:
		img.resize(OUT_SIZE.x, OUT_SIZE.y, Image.INTERPOLATE_LANCZOS)
		return img
	var pad := 6 * RENDER_SCALE
	var avail := Vector2(OUT_SIZE * RENDER_SCALE) - Vector2(pad, pad) * 2.0
	var k := minf(avail.x / used.size.x, avail.y / used.size.y)
	var part := img.get_region(used)
	part.resize(maxi(int(used.size.x * k), 1), maxi(int(used.size.y * k), 1), Image.INTERPOLATE_LANCZOS)
	var out := Image.create_empty(OUT_SIZE.x * RENDER_SCALE, OUT_SIZE.y * RENDER_SCALE, false, Image.FORMAT_RGBA8)
	var at := (Vector2i(out.get_size()) - part.get_size()) / 2
	# Stand the car on the bottom margin so every card's cars share a ground line.
	at.y = out.get_height() - pad - part.get_height()
	out.blit_rect(part, Rect2i(Vector2i.ZERO, part.get_size()), at)
	out.resize(OUT_SIZE.x, OUT_SIZE.y, Image.INTERPOLATE_LANCZOS)
	return out
