extends SceneTree
## Films a replay recorded by tools/rl_pixels/pixel_env.gd (eval mode, option replays): the chase
## camera stored in its frames, the game's look (ReplayView: atmosphere, grade, ink lines, the
## season at the camera) at the high preset, as PNG frames. The frames come from a SubViewport
## drawn on demand (render loop off, one RenderingServer.force_draw() per frame), so a sleeping
## or covered screen cannot hand back a stale frame (tools/replay/review.gd reads the window).
## --fixed-fps equal to fps advances the eased screen passes one frame per frame. Offscreen on
## the agents' dev build (train_pixels.py film runs it):
##
##   D=~/opt/summer-dev/SummerDev.app/Contents/MacOS/Summer
##   $D --summer-offscreen --audio-driver Dummy --disable-crash-handler --fixed-fps 30 --path . \
##       -s res://tools/rl_pixels/film_render.gd -- replay=/tmp/px/replays/hanami_0.srr dest=/tmp/px/hanami
##
## Options: replay, dest (frame_NNNN.png), fps, size, t0, t1 (replay seconds; default: all of it).

const WARMUP_FRAMES := 20

var opts := {"replay": "", "dest": "", "fps": "30", "size": "1280x720", "t0": "0", "t1": ""}


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	_run.call_deferred()


func _run() -> void:
	var game := root.get_node("Game")
	var data := ReplayData.load_file(str(opts["replay"]))
	if data.error != "":
		printerr("film_render: %s: %s" % [opts["replay"], data.error])
		game.request_quit(1)
		return
	RenderingServer.render_loop_enabled = false
	root.disable_3d = true
	var wh: PackedStringArray = str(opts["size"]).split("x")
	var vp := SubViewport.new()
	vp.size = Vector2i(int(wh[0]), int(wh[1]))
	vp.msaa_3d = Viewport.MSAA_4X
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	root.add_child(vp)
	var view := ReplayView.new()
	view.name = "ReplayView"
	vp.add_child(view)
	await view.setup(data)
	var fps := float(opts["fps"])
	var t0 := float(opts["t0"])
	var t1 := float(opts["t1"]) if str(opts["t1"]) != "" else data.duration()
	var dest := str(opts["dest"])
	DirAccess.make_dir_recursive_absolute(dest)
	for i in WARMUP_FRAMES:
		view.show_at(t0)
		await process_frame
	var n := maxi(1, int(floor((t1 - t0) * fps)) + 1)
	for k in n:
		view.show_at(t0 + k / fps)
		# the rest of this iteration flushes the poses to the renderer and eases the screen passes
		await process_frame
		RenderingServer.viewport_set_update_mode(vp.get_viewport_rid(), RenderingServer.VIEWPORT_UPDATE_ONCE)
		RenderingServer.force_draw(false, 1.0 / fps)
		vp.get_texture().get_image().save_png(dest.path_join("frame_%04d.png" % k))
	print("FILMED %d frames %.2f..%.2f s -> %s" % [n, t0, t1, dest])
	game.request_quit(0)
