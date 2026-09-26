extends SceneTree
## Top-down card art for the Time Attack map cards: builds the world once and renders each stage
## route straight down with an orthographic camera framed on it (plus a margin, at the card's
## aspect), in the game's own look (toon shading, ink lines, colour grade, the season of that
## stage: the world's look follows the camera) with the fog, clouds and petals off so the ground
## reads. Renders at RENDER_SCALE x the output size and downsamples for crisp edges.
##
## Writes assets/ui/maps/<id>_top.png and assets/ui/maps/<id>_route.json:
##   {"image_size": [w, h], "world_rect": [x0, z0, width, height], "closed": bool,
##    "points": [[u, v] ...], "surface": [...], "start": [u, v], "finish": [u, v],
##    "checkpoints": [[u, v] ...]}   u, v in 0..1 image space (u = +X, v = +Z, north up)
##
##   S=/Applications/Summer.app/Contents/MacOS/Summer
##   timeout 300 $S --summer-offscreen --audio-driver Dummy --disable-crash-handler --path . \
##       -s res://tools/build/capture_topdown.gd -- hanami momiji
##
## Needs pixels (offscreen or a window; headless has none). With no route ids it renders every
## stage in Game.MAPS.

const PostFXScript := preload("res://scripts/fx/post_fx.gd")

const OUT_DIR := "res://assets/ui/maps/"
## Output image size: 2x the card's preview area (MapCard.PREVIEW_SIZE, 452 x 260).
const OUT_SIZE := Vector2i(904, 520)
const RENDER_SCALE := 3
## Route sample spacing in metres (contract: every 6-10 m).
const STEP := 8.0
## Free space around the route bounds (room for the start / finish marks): a fraction of the
## larger side plus a fixed border.
const MARGIN_FRAC := 0.03
const MARGIN_M := 28.0
## Camera height above the highest ground in the frame. Close enough that the depth-based ink
## still finds tree and building silhouettes, clear of every canopy.
const CAM_CLEARANCE := 90.0


func _initialize() -> void:
	var ids: Array = OS.get_cmdline_user_args()
	if ids.is_empty():
		for m: Dictionary in root.get_node("Game").MAPS:
			ids.append(m["id"])
	DisplayServer.window_set_size(Vector2i(1280, 720))
	_run.call_deferred(ids)


func _run(ids: Array) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var vp := SubViewport.new()
	vp.size = OUT_SIZE * RENDER_SCALE
	vp.msaa_3d = Viewport.MSAA_4X
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	var map := MapWorld.new()
	vp.add_child(map)
	map.build()
	var failed := 0
	for id: String in ids:
		if not map.routes.has(id):
			push_error("capture_topdown: the world has no route %s" % id)
			failed += 1
			continue
		await _capture(vp, map, id)
	root.get_node("Game").request_quit(1 if failed > 0 else 0)


func _capture(vp: SubViewport, map: MapWorld, id: String) -> void:
	var t0 := Time.get_ticks_msec()
	map.select_route(id)
	var track := map.track
	var closed := map.closed
	var n := maxi(int(ceil(track.length / STEP)), 8)
	var world: Array[Vector3] = []
	var surfaces: Array[String] = []
	# A closed lap returns to its first sample, which the card joins itself.
	for k in (n if closed else n + 1):
		var s := track.start_s + track.length * float(k) / float(n)
		world.append(track.position_at_abs(s))
		surfaces.append(String(track.surface(track.index_at_abs(s))))
	var start := map.start_line.origin
	var finish := start if closed else map.arrival.origin

	# Frame: route bounds plus margin, widened to the output aspect, north up.
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in world:
		lo = lo.min(Vector2(p.x, p.z))
		hi = hi.max(Vector2(p.x, p.z))
	var size := hi - lo
	var pad := maxf(size.x, size.y) * MARGIN_FRAC + MARGIN_M
	size += Vector2(pad, pad) * 2.0
	var aspect := float(OUT_SIZE.x) / float(OUT_SIZE.y)
	if size.x / size.y < aspect:
		size.x = size.y * aspect
	else:
		size.y = size.x / aspect
	var centre := (lo + hi) * 0.5
	# Keep the frame on the terrain (the map pack is `size` metres square around the origin):
	# slide it inwards where the widened side would show the world's edge.
	var half := float(map.info.get("size", 1600.0)) * 0.5
	for axis in 2:
		var room := half - size[axis] * 0.5
		centre[axis] = clampf(centre[axis], -room, room) if room > 0.0 else 0.0
	var origin := centre - size * 0.5

	# Clean ground: no fog or glow haze, no clouds or petals, shadows reach the whole frame.
	var env := map.atmosphere.environment
	env.fog_enabled = false
	env.glow_enabled = false
	map.sky_rig.visible = false
	var sun := map.atmosphere.sun
	sun.directional_shadow_max_distance = maxf(size.x, size.y) * 1.2 + CAM_CLEARANCE * 4.0
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS

	var top := -INF
	for gx in 9:
		for gz in 9:
			var x := origin.x + size.x * gx / 8.0
			var z := origin.y + size.y * gz / 8.0
			top = maxf(top, map.ground_height(x, z, 2000.0))
	var cam := vp.get_camera_3d()
	if cam == null:
		cam = Camera3D.new()
		vp.add_child(cam)
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	cam.size = size.y
	cam.near = 1.0
	cam.far = CAM_CLEARANCE + 800.0
	cam.global_position = Vector3(centre.x, top + CAM_CLEARANCE, centre.y)
	cam.look_at(Vector3(centre.x, top - 100.0, centre.y), Vector3.FORWARD)
	cam.make_current()

	var post: PostFX = vp.get_node_or_null(^"PostFX")
	if post == null:
		post = PostFXScript.new()
		post.name = "PostFX"
		vp.add_child(post)
	# Let the world's look settle on this stage's season (the camera moved: a cut) first.
	await process_frame
	await process_frame
	post.apply_preset(map.atmosphere.preset, map.sun_dir)
	post.ink_material.set_shader_parameter("fade_start", CAM_CLEARANCE + 600.0)
	post.ink_material.set_shader_parameter("fade_end", CAM_CLEARANCE + 800.0)
	post.ink_material.set_shader_parameter("thickness", 1.1)
	post.grade_material.set_shader_parameter("vignette", 0.0)
	post.grade_material.set_shader_parameter("grain_amount", 0.0)

	for f in 30:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	img.resize(OUT_SIZE.x, OUT_SIZE.y, Image.INTERPOLATE_LANCZOS)
	var png := "%s%s_top.png" % [OUT_DIR, id]
	img.save_png(ProjectSettings.globalize_path(png))

	var uv := func(p: Vector3) -> Array:
		return [snappedf((p.x - origin.x) / size.x, 0.0001), snappedf((p.z - origin.y) / size.y, 0.0001)]
	var pts: Array = []
	for p in world:
		pts.append(uv.call(p))
	var cps: Array = []
	for c: Dictionary in map.checkpoints:
		cps.append(uv.call(c["position"]))
	var route := {
		"image_size": [OUT_SIZE.x, OUT_SIZE.y],
		"world_rect": [snappedf(origin.x, 0.01), snappedf(origin.y, 0.01), snappedf(size.x, 0.01), snappedf(size.y, 0.01)],
		"closed": closed,
		"points": pts,
		"surface": surfaces,
		"start": uv.call(start),
		"finish": uv.call(finish),
		"checkpoints": cps,
	}
	var json := "%s%s_route.json" % [OUT_DIR, id]
	var f := FileAccess.open(ProjectSettings.globalize_path(json), FileAccess.WRITE)
	f.store_string(JSON.stringify(route))
	f.close()
	print("TOPDOWN %s %d points, %d checkpoints, %.0f x %.0f m, %d ms -> %s" % [id, pts.size(), cps.size(), size.x, size.y, Time.get_ticks_msec() - t0, png])
	await process_frame
