extends "res://tools/game/flows.gd"
## A game flow (tools/game/flows.gd, same options) recorded by the Replays autoload, with live
## frames saved from the screen at chosen replay times of every recording on one route. Pair
## them with the replay rendered at those times with `review.gd compare <dest>`
## (docs/REPLAYS.md). Needs a renderer: runs offscreen.
##
##   S=/Applications/Summer.app/Contents/MacOS/Summer
##   timeout 1500 nice -n 5 $S --summer-offscreen --audio-driver Dummy --disable-crash-handler \
##       --path . -s res://tools/replay/capture_flow.gd -- flow=campaign speed=3 \
##       replays=/tmp/ep3/replays/campaign capture=liaison:10,30,50 dest=/tmp/ep3/replays/campaign_live
##
## capture=<route>:<t,t,...>: replay seconds to capture in each recording of that route.
## dest=<folder>: live_NN.png and captures.json ([{replay, t, image}]), rewritten after each
## capture so a flow that quits leaves a complete list.
## (Not `out=`: Summer's offscreen mode takes that one for itself.)

var _cap_route := "liaison"
var _cap_times: Array[float] = []
var _cap_dest := "/tmp/ep3/replays/capture"
var _cap_path := ""
var _cap_left: Array[float] = []
var _cap_list: Array[Dictionary] = []
var _cap_busy := false


func _initialize() -> void:
	super()
	var spec := str(opts.get("capture", "liaison:10,30,50")).split(":", true, 1)
	_cap_route = spec[0]
	for x in (spec[1] if spec.size() > 1 else "").split(",", false):
		_cap_times.append(float(x))
	_cap_times.sort()
	_cap_dest = str(opts.get("dest", _cap_dest))
	DirAccess.make_dir_recursive_absolute(_cap_dest)
	for f in DirAccess.get_files_at(_cap_dest):
		if f.begins_with("live_") or f == "captures.json":
			DirAccess.remove_absolute(_cap_dest.path_join(f))
	process_frame.connect(_capture_tick)


func _capture_tick() -> void:
	var replays := root.get_node_or_null("Replays")
	if _cap_busy or replays == null or not replays.is_recording():
		return
	var path: String = replays.current_path
	if path != _cap_path:
		_cap_path = path
		_cap_left.clear()
		if str(replays.header.get("route", "")) == _cap_route:
			_cap_left.assign(_cap_times)
	if _cap_left.is_empty() or float(replays.frame_time()) < _cap_left[0]:
		return
	_cap_left.pop_front()
	_cap_busy = true
	await RenderingServer.frame_post_draw
	_cap_busy = false
	if replays.current_path != path:
		return
	var t := float(replays.frame_time())
	# a draw that came late (offscreen can stall) covers every wanted time it overtook
	while not _cap_left.is_empty() and _cap_left[0] <= t:
		_cap_left.pop_front()
	var name := "live_%02d.png" % _cap_list.size()
	root.get_texture().get_image().save_png(_cap_dest.path_join(name))
	_cap_list.append({"replay": path, "t": t, "image": name})
	FileAccess.open(_cap_dest.path_join("captures.json"), FileAccess.WRITE).store_string(JSON.stringify(_cap_list, "  "))
	print("LIVE capture %s at t=%.3f s of %s" % [name, t, path.get_file()])
