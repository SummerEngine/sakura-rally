extends SceneTree
## Replay review (docs/REPLAYS.md). Lists and summarises the player's replays and renders what
## he saw at chosen moments. `list` and `summary` run headless; `render` needs a renderer and
## runs offscreen.
##
##   S=/Applications/Summer.app/Contents/MacOS/Summer
##   R="--disable-crash-handler --path . -s res://tools/replay/review.gd --"
##   timeout 60 $S --headless $R list [<folder>]
##   timeout 120 $S --headless $R summary <file> [--json]
##   timeout 900 nice -n 5 $S --summer-offscreen --audio-driver Dummy $R render <file> <t0> <t1> [fps]
##   timeout 1800 nice -n 5 $S --summer-offscreen --audio-driver Dummy $R render <file> --events [fps]
##   timeout 900 nice -n 5 $S --summer-offscreen --audio-driver Dummy $R compare <folder>
##
## list: the default folder is the player's (`user://replays`, i.e. ~/Library/Application
##   Support/Godot/app_userdata/Sakura Rally/replays), newest first. A bare file name given to
##   summary / render is looked up there.
## summary: the timeline (splits, crashes, resets, off-road excursions, jumps, wrong way,
##   pauses, and hesitations: sudden lifts, heavy or unexpected braking, crawling, zig-zag
##   steering) with replay time, route distance and the nearest corner, then the worst sectors.
## render <t0> <t1>: frames from replay second t0 to t1 (fps, default 30) into
##   dest=<folder> (default /tmp/sakura_replays/<replay name>/), a contact sheet (sheet.png) and,
##   with ffmpeg on the PATH, clip.mp4.
## render --events: a clip around every notable moment (2.5 s before to 2 s after, fps default
##   15), each in its own subfolder with an mp4, plus moments.png (the frame of each moment) and
##   moments.txt (what each one is).
## compare <folder>: live frames captured by tools/replay/capture_flow.gd (<folder>/captures.json)
##   against the replay rendered at the same times: replay_NN.png, pair_NN.png (live left),
##   pairs.png, and the pixel difference of each pair.
## Options: dest=<folder>, size=<w>x<h> (default 1600x900).
## (Not `out=`: Summer's offscreen mode takes that one for itself.)

const Analysis := preload("res://tools/replay/analysis.gd")
const Pairs := preload("res://tools/replay/pairs.gd")
const PLAYER_FOLDER := "user://replays"
const WARMUP := 0.7

var args: PackedStringArray = []
var opts := {"dest": "", "size": "1600x900"}


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		if kv.size() == 2 and opts.has(kv[0]):
			opts[kv[0]] = kv[1]
		else:
			args.append(arg)
	_run.call_deferred()


func _run() -> void:
	var cmd := args[0] if args.size() > 0 else "list"
	var code := 0
	match cmd:
		"list":
			_list(args[1] if args.size() > 1 else PLAYER_FOLDER)
		"summary":
			code = await _summary()
		"render":
			code = await _render()
		"compare":
			code = await _compare()
		_:
			print("usage: list [folder] | summary <file> [--json] | render <file> <t0> <t1> [fps] | render <file> --events [fps] | compare <folder>")
			code = 2
	root.get_node("Game").request_quit(code)


static func _resolve(file: String) -> String:
	if FileAccess.file_exists(file):
		return file
	var p := ProjectSettings.globalize_path(PLAYER_FOLDER).path_join(file)
	return p if FileAccess.file_exists(p) else file


func _list(folder: String) -> void:
	var dir := ProjectSettings.globalize_path(folder)
	if not DirAccess.dir_exists_absolute(dir):
		print("0 replays: %s does not exist (nothing recorded there yet)" % dir)
		return
	var names := Array(DirAccess.get_files_at(dir)).filter(
			func(n: String) -> bool: return n.get_extension() == ReplayFormat.EXTENSION)
	names.sort()
	names.reverse()
	print("%d replays in %s" % [names.size(), dir])
	for n: String in names:
		var p := ReplayData.peek(dir.path_join(n))
		if p["error"] != "":
			print("  %s  (%s)" % [n, p["error"]])
			continue
		var h: Dictionary = p["header"]
		var seconds := -1.0
		var ending := "cut short"
		var result := ""
		for e: Dictionary in p["events"]:
			match str(e.get("type", "")):
				"end":
					seconds = float(e.get("seconds", -1.0))
					ending = str(e.get("reason", ""))
					if e.has("finished"):
						result = "finished %s %s" % [Analysis._clock(float(e["finished"])), e.get("medal", "")]
					elif e.get("arrived", false):
						result = "arrived"
		print("  %s  %-8s %-10s %-7s %6s  %5.0f KB  %-22s %s" % [str(h.get("date", "")).replace("T", " "), h.get("route", ""),
				h.get("mode", ""), h.get("car", ""), Analysis._clock(seconds) if seconds >= 0.0 else "?",
				float(p["bytes"]) / 1024.0, result if result != "" else ending, n])


func _load(file: String) -> ReplayData:
	var data := ReplayData.load_file(_resolve(file))
	if data.error != "":
		print("ERROR %s: %s" % [file, data.error])
		return null
	return data


func _build_map(route: String) -> MapWorld:
	var map := MapWorld.new()
	map.name = "Map"
	map.map_id = route
	root.add_child(map)
	await map.build()
	return map


func _summary() -> int:
	if args.size() < 2:
		print("usage: summary <file> [--json]")
		return 2
	var data := _load(args[1])
	if data == null:
		return 1
	var map: MapWorld = await _build_map(str(data.header.get("route", "hanami")))
	var summary := Analysis.analyze(data, map.track)
	if "--json" in args:
		print(JSON.stringify(ReplayFormat.json_safe(summary), "  "))
	else:
		print(data.path)
		print(Analysis.report(summary))
	return 0


func _render() -> int:
	if DisplayServer.get_name() == "headless":
		print("render needs a renderer: run with --summer-offscreen --audio-driver Dummy instead of --headless")
		return 2
	if args.size() < 3:
		print("usage: render <file> <t0> <t1> [fps] | render <file> --events [fps]")
		return 2
	var data := _load(args[1])
	if data == null:
		return 1
	var size := str(opts["size"]).split("x")
	root.size = Vector2i(int(size[0]), int(size[1]))
	var dest := str(opts["dest"])
	if dest == "":
		dest = "/tmp/sakura_replays".path_join(data.path.get_file().get_basename())
	DirAccess.make_dir_recursive_absolute(dest)
	var view := ReplayView.new()
	view.name = "ReplayView"
	root.add_child(view)
	await view.setup(data)
	if args[2] == "--events":
		var fps := float(args[3]) if args.size() > 3 else 15.0
		var summary := Analysis.analyze(data, view.map.track)
		var moments := Analysis.notable(summary)
		var stills: Array[Image] = []
		var text: PackedStringArray = []
		for k in moments.size():
			var m: Dictionary = moments[k]
			var t: float = m["t"]
			var sub := dest.path_join("%02d_%s_t%06.1f" % [k, m["kind"], t])
			var line := "%02d  t=%7.2fs  s=%5dm  %s  %s" % [k, t, roundi(float(m["s"])), m["where"], m["text"]]
			print("MOMENT ", line)
			text.append(line)
			var frames := await _clip(view, data, maxf(t - 2.5, 0.0), minf(t + 2.0, data.duration()), fps, sub, t)
			stills.append(frames)
			_mp4(sub, fps)
		FileAccess.open(dest.path_join("moments.txt"), FileAccess.WRITE).store_string("\n".join(text) + "\n")
		if not stills.is_empty():
			_sheet(stills, 3).save_png(dest.path_join("moments.png"))
		print("RENDERED %d moments into %s (moments.png, moments.txt)" % [moments.size(), dest])
	else:
		var t0 := float(args[2])
		var t1 := float(args[3]) if args.size() > 3 else t0
		var fps := float(args[4]) if args.size() > 4 else 30.0
		await _clip(view, data, t0, t1, fps, dest, NAN)
		var names := Array(DirAccess.get_files_at(dest)).filter(func(n: String) -> bool: return n.begins_with("frame_"))
		names.sort()
		var pick: Array[Image] = []
		var step := maxi(1, ceili(names.size() / 12.0))
		for k in range(0, names.size(), step):
			pick.append(Image.load_from_file(dest.path_join(names[k])))
		_sheet(pick, 4).save_png(dest.path_join("sheet.png"))
		_mp4(dest, fps)
		print("RENDERED %d frames t=%.2f..%.2f into %s (sheet.png%s)" % [names.size(), t0, t1, dest,
				", clip.mp4" if FileAccess.file_exists(dest.path_join("clip.mp4")) else ""])
	return 0


func _compare() -> int:
	if args.size() < 2:
		print("usage: compare <folder>")
		return 2
	var folder := args[1]
	var list: Variant = JSON.parse_string(FileAccess.get_file_as_string(folder.path_join("captures.json")))
	if not list is Array or (list as Array).is_empty():
		print("ERROR no captures in %s" % folder.path_join("captures.json"))
		return 1
	var rows: Array[Image] = []
	var worst := 0.0
	var view: ReplayView = null
	var shown := ""
	for k in (list as Array).size():
		var cap: Dictionary = list[k]
		var live := Image.load_from_file(folder.path_join(str(cap["image"])))
		if str(cap["replay"]) != shown:
			if view != null:
				view.queue_free()
				await process_frame
			var data := _load(str(cap["replay"]))
			if data == null:
				return 1
			root.size = live.get_size()
			view = ReplayView.new()
			view.name = "ReplayView"
			root.add_child(view)
			await view.setup(data)
			shown = str(cap["replay"])
		var t := float(cap["t"])
		# the same warm-up as the live drive had: the body lean and screen passes settle
		for w in 40:
			await process_frame
			view.show_at(t - (40 - w) / 60.0)
		await process_frame
		view.show_at(t)
		await RenderingServer.frame_post_draw
		var img := root.get_texture().get_image()
		img.save_png(folder.path_join("replay_%02d.png" % k))
		var d := Pairs.diff(live, img)
		var pair := Pairs.pair(live, img)
		pair.save_png(folder.path_join("pair_%02d.png" % k))
		rows.append(pair)
		worst = maxf(worst, d.x)
		print("PAIR %02d t=%.3f s of %s  mean abs diff %.1f/255  pixels off by >32: %.1f%%" % [k, t,
				shown.get_file(), d.x, d.y * 100.0])
	Pairs.stack(rows).save_png(folder.path_join("pairs.png"))
	print("COMPARED %d pairs into %s (pairs.png), worst mean abs diff %.1f/255" % [rows.size(), folder, worst])
	return 0


## Renders replay time t0..t1 at fps into dest/frame_NNNN.png (after a short warm-up so the
## body lean, the pop-ups and the screen passes have settled). Returns the frame nearest to
## `mark` (or the middle one).
func _clip(view: ReplayView, data: ReplayData, t0: float, t1: float, fps: float, dest: String, mark: float) -> Image:
	DirAccess.make_dir_recursive_absolute(dest)
	var w := t0 - WARMUP
	while w < t0:
		await process_frame
		view.show_at(maxf(w, 0.0))
		w += 1.0 / 60.0
	var n := maxi(1, int(floor((t1 - t0) * fps)) + 1)
	var target := mark if is_finite(mark) else (t0 + t1) * 0.5
	var best: Image = null
	var best_d := INF
	for k in n:
		var t := t0 + k / fps
		await process_frame
		view.show_at(t)
		await RenderingServer.frame_post_draw
		var img := root.get_texture().get_image()
		img.save_png(dest.path_join("frame_%04d.png" % k))
		if absf(t - target) < best_d:
			best_d = absf(t - target)
			best = img
	print("  %d frames %.2f..%.2f s -> %s" % [n, t0, t1, dest])
	return best


static func _mp4(dir: String, fps: float) -> void:
	var out: Array = []
	var code := OS.execute("ffmpeg", ["-y", "-loglevel", "error", "-framerate", str(fps), "-i", dir.path_join("frame_%04d.png"),
			"-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "20", dir.path_join("clip.mp4")], out, true)
	if code != 0:
		print("  (no mp4: ffmpeg exit %d %s)" % [code, "".join(out).strip_edges()])


## Tiles images (scaled to 480 wide) in `cols` columns.
static func _sheet(images: Array[Image], cols: int) -> Image:
	var w := 480
	var h := int(480.0 * images[0].get_height() / images[0].get_width())
	var rows := ceili(images.size() / float(cols))
	var out := Image.create(cols * (w + 4), rows * (h + 4), false, Image.FORMAT_RGB8)
	out.fill(Color.WHITE)
	for k in images.size():
		var src := images[k].duplicate() as Image
		src.convert(Image.FORMAT_RGB8)
		src.resize(w, h, Image.INTERPOLATE_BILINEAR)
		out.blit_rect(src, Rect2i(0, 0, w, h), Vector2i((k % cols) * (w + 4), (k / cols) * (h + 4)))
	return out
