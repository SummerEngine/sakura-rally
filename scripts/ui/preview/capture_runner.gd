extends Node
## Automated tour of every UI screen for the preview harness (`-- --capture=16x9`).
## Navigates with the same input actions a player uses (ui_* keyboard / gamepad actions and
## `pause`), saves full-frame PNGs as docs/renders/ui_<shot>_<aspect>.png and animation
## contact sheets (frames left-to-right, top-to-bottom) as docs/renders/ui_anim_<name>_<aspect>.png,
## then quits.

const OUT_DIR := "res://docs/renders/"
const SHEET_W := 640 ## width of one frame in a contact sheet
const SHEET_COLS := 4

var driver: Node
var aspect := "16x9"
var sheets := true
var _shots: PackedStringArray = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func run(p_driver: Node, p_aspect: String) -> void:
	driver = p_driver
	aspect = p_aspect
	sheets = aspect != "16x10"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	await _wait(0.6)
	var game: Node = driver.game
	var ui: Node = driver.ui

	# Title: intro animation, settled menu, focus moved to the second card, livery row.
	await _sheet("title_intro", 12, 0.2)
	await _wait(0.8)
	await _shot("title")
	await _press("ui_right")
	await _wait(0.6)
	await _shot("title_focus")
	await _press("ui_up")
	await _press("ui_right")
	await _wait(0.5)
	await _shot("title_livery")
	await _press("ui_left")
	await _press("ui_down")
	await _press("ui_left")
	await _wait(0.3)

	# Settings from the title (keyboard: move to the Settings button and accept).
	ui.title.focus_settings_button()
	await _wait(0.3)
	await _press("ui_accept")
	await _sheet("settings_open", 4, 0.12)
	await _wait(0.5)
	await _shot("settings")
	await _press("ui_cancel")
	await _wait(0.6)

	# Start Hanami Pass (time trial) from the focused first card.
	(ui.title._cards[0] as Control).grab_focus()
	await _wait(0.3)
	await _press("ui_accept")
	await _sheet("transition_cover", 8, 0.12)
	await _shot("loading")
	await _until(func() -> bool: return int(game.state) == int(game.State.INTRO))
	await _sheet("intro_card", 12, 0.16)
	await _wait(0.2)
	await _shot("intro_card")
	await _until(func() -> bool: return int(game.state) == int(game.State.COUNTDOWN))
	await _wait(0.12)
	await _shot("countdown_3")
	await _sheet("countdown_tick", 8, 0.1)
	await _until(func() -> bool: return int(game.state) == int(game.State.RACING))
	await _sheet("countdown_go", 8, 0.09)
	await _wait(2.5)
	await _shot("hud")
	driver.next_checkpoint()
	await _sheet("hud_split", 6, 0.1)
	await _wait(0.2)
	await _shot("hud_split")
	await _wait(1.0)
	game.post_notice("Car reset")
	await _wait(0.5)
	await _shot("hud_notice")
	await _wait(2.5)

	# Pause via the `pause` action, open Settings from it, back, resume.
	await _press("pause")
	await _sheet("pause_open", 4, 0.1)
	await _wait(0.5)
	await _shot("pause")
	await _press("ui_down")
	await _press("ui_down")
	await _press("ui_accept")
	await _wait(0.8)
	await _shot("pause_settings")
	await _press("ui_cancel")
	await _wait(0.4)
	await _press("pause")
	await _wait(0.8)

	# Finish with a gold record: banner, count-up, results card, stamp.
	driver.finish_now(148.4)
	await _until(func() -> bool: return int(game.state) == int(game.State.FINISHED))
	await _sheet("finish", 16, 0.12)
	await _wait(0.1)
	await _shot("finish_banner_late")
	await _wait(1.6)
	await _sheet("results_stamp", 8, 0.1)
	await _wait(1.5)
	await _shot("results_record")

	# Retry (keyboard accept on the focused Retry) and finish slower: no record, bronze.
	await _press("ui_accept")
	await _until(func() -> bool: return int(game.state) == int(game.State.RACING))
	await _wait(1.5)
	driver.next_checkpoint()
	await _wait(0.4)
	await _shot("hud_split_slower")
	driver.finish_now(176.25)
	await _until(func() -> bool: return int(game.state) == int(game.State.FINISHED))
	await _wait(1.2)
	await _shot("finish_banner")
	await _wait(3.6)
	await _shot("results_bronze")

	# Next map -> Momiji Valley.
	await _press("ui_right")
	await _press("ui_accept")
	await _until(func() -> bool: return int(game.state) == int(game.State.INTRO))
	await _wait(1.8)
	await _shot("intro_autumn")
	await _until(func() -> bool: return int(game.state) == int(game.State.RACING))
	await _wait(2.0)
	await _shot("hud_autumn")

	# Pause -> Main menu -> Free roam on Momiji.
	await _press("pause")
	await _wait(0.5)
	for i in 3:
		await _press("ui_down")
	await _press("ui_accept")
	await _until(func() -> bool: return int(game.state) == int(game.State.MENU))
	await _wait(3.0)
	await _shot("title_return")
	ui.title._mode.selected = 1
	(ui.title._cards[1] as Control).grab_focus()
	await _wait(0.2)
	await _press("ui_accept")
	await _until(func() -> bool: return int(game.state) == int(game.State.FREE_ROAM))
	await _wait(2.5)
	game.post_notice("Free roam: drive anywhere")
	await _wait(0.6)
	await _shot("hud_free_roam")
	await _wait(0.4)

	print("UI_CAPTURE done %s: %s" % [aspect, ", ".join(_shots)])
	get_tree().quit()


# ---------------------------------------------------------------- helpers

func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds, true, false, true).timeout


func _until(cond: Callable, timeout: float = 20.0) -> void:
	var t := 0.0
	while not cond.call():
		await get_tree().process_frame
		t += get_process_delta_time()
		if t > timeout:
			push_error("UI_CAPTURE timed out waiting for state")
			return


func _press(action: StringName) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	Input.parse_input_event(ev)
	await get_tree().process_frame
	var up := InputEventAction.new()
	up.action = action
	up.pressed = false
	Input.parse_input_event(up)
	await get_tree().process_frame
	await get_tree().process_frame


func _grab() -> Image:
	await RenderingServer.frame_post_draw
	return get_viewport().get_texture().get_image()


func _shot(shot_name: String) -> void:
	var img := await _grab()
	var path := "%sui_%s_%s.png" % [OUT_DIR, shot_name, aspect]
	img.save_png(ProjectSettings.globalize_path(path))
	_shots.append(shot_name)


func _sheet(sheet_name: String, frames: int, interval: float) -> void:
	if not sheets:
		await _wait(interval * frames)
		return
	var tiles: Array[Image] = []
	for i in frames:
		var img := await _grab()
		var h := int(round(float(img.get_height()) * SHEET_W / float(img.get_width())))
		img.resize(SHEET_W, h, Image.INTERPOLATE_BILINEAR)
		tiles.append(img)
		await _wait(interval)
	var th := tiles[0].get_height()
	var rows := int(ceil(float(frames) / SHEET_COLS))
	var cols := mini(frames, SHEET_COLS)
	var gap := 6
	var sheet := Image.create(cols * SHEET_W + (cols + 1) * gap, rows * th + (rows + 1) * gap, false, tiles[0].get_format())
	sheet.fill(Color("2a2235"))
	for i in frames:
		var x := gap + (i % SHEET_COLS) * (SHEET_W + gap)
		var y := gap + (i / SHEET_COLS) * (th + gap)
		sheet.blit_rect(tiles[i], Rect2i(0, 0, SHEET_W, th), Vector2i(x, y))
	sheet.save_png(ProjectSettings.globalize_path("%sui_anim_%s_%s.png" % [OUT_DIR, sheet_name, aspect]))
	_shots.append("anim_" + sheet_name)
