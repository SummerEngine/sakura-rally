extends SceneTree
## Windowed tour capture of a built map: chase-height views every 1/N of the lap,
## plus two aerial views. Used to judge the look without playing.
##
##   $S --disable-crash-handler --path . -s res://tools/build/capture_map.gd -- hanami /tmp/tour 12
##
## Optional 4th argument "low" renders the low-height hero angle instead.

const PostFXScript := preload("res://scripts/fx/post_fx.gd")

var map: MapWorld
var cam: Camera3D
var post: Node3D


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var map_id := args[0] if args.size() > 0 else "hanami"
	var out_dir := args[1] if args.size() > 1 else "/tmp/tour"
	var shots := int(args[2]) if args.size() > 2 else 12
	var style := args[3] if args.size() > 3 else "chase"
	DirAccess.make_dir_recursive_absolute(out_dir)
	root.size = Vector2i(1920, 1080)
	DisplayServer.window_set_size(Vector2i(1600, 900))
	_run.call_deferred(map_id, out_dir, shots, style)


func _run(map_id: String, out_dir: String, shots: int, style: String) -> void:
	map = MapWorld.new()
	map.map_id = map_id
	root.add_child(map)
	var t0 := Time.get_ticks_msec()
	map.build()
	print("BUILD %s %d ms stats=%s" % [map_id, Time.get_ticks_msec() - t0, map.stats])
	cam = Camera3D.new()
	cam.fov = 62.0
	cam.near = 0.1
	cam.far = 12000.0
	root.add_child(cam)
	cam.make_current()
	post = PostFXScript.new()
	root.add_child(post)
	post.apply_preset(map.atmosphere.preset, map.sun_dir)
	for f in 20:
		await process_frame
	for k in shots:
		var p := float(k) / shots * map.track.length
		var xf := map.track.transform_at_progress(p)
		var fwd := -xf.basis.z
		var up := Vector3.UP
		var at := xf.origin
		if style == "low":
			cam.global_position = at - fwd * 4.5 + xf.basis.x * 2.2 + up * 0.9
			cam.look_at(at + fwd * 25.0 + up * 1.6, up)
		else:
			cam.global_position = at - fwd * 7.5 + up * 2.8
			cam.look_at(at + fwd * 14.0 + up * 0.8, up)
		await _settle(14)
		_save("%s/%s_%02d.png" % [out_dir, map_id, k])
	# aerials: over the start looking across the map, and a high overview
	var c := map.track.transform_at_progress(0.0).origin
	cam.global_position = c + Vector3(0.0, 160.0, 260.0)
	cam.look_at(Vector3(0.0, 40.0, 0.0), Vector3.UP)
	await _settle(20)
	_save("%s/%s_aerial_a.png" % [out_dir, map_id])
	cam.global_position = Vector3(520.0, 420.0, 520.0)
	cam.look_at(Vector3(0.0, 30.0, 0.0), Vector3.UP)
	await _settle(20)
	_save("%s/%s_aerial_b.png" % [out_dir, map_id])
	print("CAPTURE DONE fps=%d" % Engine.get_frames_per_second())
	quit()


func _settle(frames: int) -> void:
	for f in frames:
		await process_frame
	await RenderingServer.frame_post_draw


func _save(path: String) -> void:
	var img := root.get_texture().get_image()
	img.save_png(path)
	print("SHOT ", path)
