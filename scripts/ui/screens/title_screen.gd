extends Control
## Title hub over the live 3D flyover: brush-painted 桜 logo, kinetic wordmark, hanko stamp,
## drifting petals and the hub menu (Campaign, Time Attack, Garage, Settings, Quit).
## Time Attack and Garage are pages of the hub (time_attack_panel.gd, garage_panel.gd). The page
## showing is mirrored to Game.set_menu_view, so Main parks the car for the garage; the switch
## to and from the garage hides the camera cut under a quick ink wipe. Esc / B steps back from
## a page to the hub.

signal settings_requested
signal shake_requested(strength: float)

const UITheme := preload("res://scripts/ui/ui_theme.gd")
const UIMotion := preload("res://scripts/ui/ui_motion.gd")
const UIApi := preload("res://scripts/ui/ui_api.gd")
const BrushKanji := preload("res://scripts/ui/widgets/brush_kanji.gd")
const KineticText := preload("res://scripts/ui/widgets/kinetic_text.gd")
const Hanko := preload("res://scripts/ui/widgets/hanko.gd")
const HubItem := preload("res://scripts/ui/widgets/hub_item.gd")
const JourneyStrip := preload("res://scripts/ui/widgets/journey_strip.gd")
const ConfirmDialog := preload("res://scripts/ui/widgets/confirm_dialog.gd")
const PetalField := preload("res://scripts/ui/widgets/petal_field.gd")
const KeyHints := preload("res://scripts/ui/widgets/key_hints.gd")
const ShaderRect := preload("res://scripts/ui/widgets/shader_rect.gd")
const TimeAttackPanel := preload("res://scripts/ui/screens/time_attack_panel.gd")
const GaragePanel := preload("res://scripts/ui/screens/garage_panel.gd")
const INK_WIPE := preload("res://shaders/ui/ink_wipe.gdshader")

const MARGIN := Vector2(96, 64)
const LOGO_POS := MARGIN - Vector2(26, 28)
## Garage switch: the ink wipe's cover and lift times (the loading wipe takes ~1 s each way).
const WIPE_COVER := 0.55
const WIPE_LIFT := 0.65

var active := false
## "title" (the hub), "time_attack" or "garage"; mirrored to Game.menu_view.
var view := "title"

var _scrim := TextureRect.new()
var _petals: PetalField
var _logo := Control.new()
var _kanji: BrushKanji
var _wordmark: KineticText
var _subline := HBoxContainer.new()
var _hanko: Hanko
var _hub := VBoxContainer.new()
var _campaign_item: HubItem
var _journey: JourneyStrip
var _new_journey_item: HubItem
var _time_attack_item: HubItem
var _garage_item: HubItem
var _small_row := HBoxContainer.new()
var _settings_item: HubItem
var _quit_item: HubItem
var _time_attack: TimeAttackPanel
var _garage: GaragePanel
var _wipe: ShaderRect
var _confirm: ConfirmDialog
var _hint: Control
var _time := 0.0
## Full-rect layers that carry only the parallax offset, so the anchored layout inside
## them is never overwritten.
var _logo_layer := Control.new()
var _menu_layer := Control.new()
var _parallax := Vector2.ZERO
var _intro_tween: Tween
var _wipe_tween: Tween
## Hub item to focus when coming back from a page.
var _last_hub: Control
## A garage switch is under way (ink wipe running); input waits for it.
var _switching := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_scrim()
	_petals = PetalField.new()
	add_child(_petals)
	for layer: Control in [_logo_layer, _menu_layer]:
		layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(layer)
	_build_logo()
	_build_hub()
	_time_attack = TimeAttackPanel.new()
	_time_attack.back_requested.connect(_back_to_hub)
	_menu_layer.add_child(_time_attack)
	_garage = GaragePanel.new()
	_garage.back_requested.connect(_back_to_hub)
	_menu_layer.add_child(_garage)
	_hint = KeyHints.new()
	_hint.entries = [
		[["W", "A", "S", "D"], ["RT", "LT", "L"], "Drive"],
		[["Space"], ["A"], "Handbrake"],
		[["Q", "E"], ["LB", "RB"], "Shift"],
		[["C"], ["Y"], "Camera"],
		[["R"], ["Back"], "Reset"],
		[["Esc"], ["Start"], "Pause"],
	]
	_hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_hint.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_hint.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_hint.offset_left = -MARGIN.x * 0.6
	_hint.offset_right = -MARGIN.x * 0.6
	_hint.offset_top = -MARGIN.y * 0.9
	_hint.offset_bottom = -MARGIN.y * 0.9
	add_child(_hint)
	_wipe = ShaderRect.new(INK_WIPE)
	_wipe.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_wipe.set_param(&"ink", UITheme.INK)
	_wipe.set_param(&"accent", UITheme.SAKURA)
	_wipe.visible = false
	add_child(_wipe)
	_confirm = ConfirmDialog.new()
	add_child(_confirm)
	UIApi.game().settings_changed.connect(_refresh_garage_item)
	visible = false


func _build_scrim() -> void:
	# Soft paper wash from the left so the menu column reads over a bright painted scene.
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.28, 0.5, 0.72])
	g.colors = PackedColorArray([Color(UITheme.PAPER, 0.62), Color(UITheme.PAPER, 0.42), Color(UITheme.PAPER, 0.14), Color(UITheme.PAPER, 0.0)])
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.width = 512
	gt.height = 8
	gt.fill_from = Vector2(0, 0)
	gt.fill_to = Vector2(1, 0)
	_scrim.texture = gt
	_scrim.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_scrim.stretch_mode = TextureRect.STRETCH_SCALE
	_scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_scrim)


func _build_logo() -> void:
	_logo.position = LOGO_POS
	_logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_logo_layer.add_child(_logo)
	_kanji = BrushKanji.new()
	_kanji.text = "桜"
	_kanji.size = Vector2(250, 250)
	_kanji.color = UITheme.INK
	_kanji.halo = Color(1, 1, 1, 0.45)
	_kanji.halo_size = 26
	_logo.add_child(_kanji)

	var col := VBoxContainer.new()
	col.position = Vector2(262, 62)
	col.add_theme_constant_override("separation", 10)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_logo.add_child(col)
	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 18)
	title_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(title_row)
	_wordmark = KineticText.new()
	_wordmark.text = "SAKURA RALLY"
	_wordmark.font = UITheme.FONT_TITLE
	_wordmark.font_size = 66
	_wordmark.tracking = 14.0
	_wordmark.color = UITheme.INK
	_wordmark.halo = Color(1, 1, 1, 0.5)
	_wordmark.halo_size = 16
	_wordmark.style = KineticText.Style.DROP
	_wordmark.stepped_fps = 12.0
	_wordmark.stagger = 0.05
	_wordmark.char_duration = 0.55
	_wordmark.distance = 56.0
	title_row.add_child(_wordmark)
	_hanko = Hanko.new()
	_hanko.text = "山道"
	_hanko.custom_minimum_size = Vector2(52, 86)
	_hanko.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_hanko.rest_rotation = 0.08
	_hanko.landed.connect(func() -> void: shake_requested.emit(0.35))
	title_row.add_child(_hanko)

	_subline.add_theme_constant_override("separation", 16)
	_subline.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_subline)
	var jp := UITheme.make_label("桜ラリー", UITheme.FONT_BRUSH, 30, UITheme.SAKURA)
	jp.label_settings.outline_size = 12
	jp.label_settings.outline_color = Color(1, 1, 1, 0.5)
	_subline.add_child(jp)
	var bar := ColorRect.new()
	bar.color = Color(UITheme.INK, 0.25)
	bar.custom_minimum_size = Vector2(36, 2)
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_subline.add_child(bar)
	var tag := UITheme.make_label("A quiet rally through Japan's mountain roads", UITheme.FONT_UI_BOLD, 20, Color(UITheme.INK, 0.78))
	tag.label_settings.outline_size = 10
	tag.label_settings.outline_color = Color(1, 1, 1, 0.45)
	tag.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_subline.add_child(tag)


func _build_hub() -> void:
	_hub.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_hub.grow_vertical = Control.GROW_DIRECTION_BEGIN
	# Items carry their own padding (room for the focus swash); align their text to the margin.
	_hub.offset_left = MARGIN.x - 22.0
	_hub.offset_right = MARGIN.x - 22.0
	_hub.offset_top = -MARGIN.y + 8.0
	_hub.offset_bottom = -MARGIN.y + 8.0
	_hub.add_theme_constant_override("separation", 2)
	_hub.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_menu_layer.add_child(_hub)

	_journey = JourneyStrip.new()
	var detail := MarginContainer.new()
	detail.add_theme_constant_override("margin_top", 8)
	detail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	detail.add_child(_journey)
	_campaign_item = _item(HubItem.Kind.PRIMARY, "旅", "CAMPAIGN", "New journey", detail)
	_campaign_item.press_sound = &"start"
	_campaign_item.pressed.connect(_on_campaign_pressed)
	_new_journey_item = _item(HubItem.Kind.SMALL, "", "", "Start a new journey")
	_new_journey_item.pressed.connect(_on_new_journey_pressed)
	_hub.add_child(_gap(10))
	_time_attack_item = _item(HubItem.Kind.NORMAL, "時", "TIME TRIAL · FREE ROAM", "Time Attack")
	_time_attack_item.pressed.connect(_open_time_attack)
	_garage_item = _item(HubItem.Kind.NORMAL, "車", "", "Garage")
	_garage_item.pressed.connect(_open_garage)
	_hub.add_child(_gap(10))

	_small_row.add_theme_constant_override("separation", 4)
	_small_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hub.add_child(_small_row)
	_settings_item = _item(HubItem.Kind.SMALL, "", "", "Settings", null, _small_row)
	_settings_item.pressed.connect(func() -> void: settings_requested.emit())
	_quit_item = _item(HubItem.Kind.SMALL, "", "", "Quit", null, _small_row)
	_quit_item.press_sound = &"back"
	_quit_item.pressed.connect(func() -> void: UIApi.game().request_quit())


func _item(kind: int, kanji: String, overline: String, title: String, detail: Control = null, parent: Control = null) -> HubItem:
	var item := HubItem.new()
	item.setup(kind, kanji, overline, title, detail)
	item.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	(parent if parent != null else _hub).add_child(item)
	return item


func _gap(h: float) -> Control:
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, h)
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return gap


## Campaign label and journey strip from Game.campaign_status(), garage label from the car
## settings, and the focus chain over whichever items show.
func _refresh_hub() -> void:
	var game := UIApi.game()
	var st: Dictionary = game.campaign_status()
	var legs := int(st["legs"])
	var leg := int(st["leg"])
	if bool(st["finished"]):
		_campaign_item.set_overline("CAMPAIGN · JOURNEY COMPLETE")
		_campaign_item.set_title("Replay journey")
	elif bool(st["started"]):
		var next: Dictionary = st["next"]
		_campaign_item.set_overline("CAMPAIGN · LEG %d OF %d" % [mini(leg + 1, legs), legs])
		_campaign_item.set_title("Continue · %s" % str(next.get("title", "")))
	else:
		_campaign_item.set_overline("CAMPAIGN · %d LEGS" % legs)
		_campaign_item.set_title("New journey")
	_journey.setup(game.CAMPAIGN, legs if bool(st["finished"]) else leg)
	_new_journey_item.visible = _in_progress()
	_refresh_garage_item()
	_link_hub_focus()


func _in_progress() -> bool:
	var st: Dictionary = UIApi.game().campaign_status()
	return bool(st["started"]) and not bool(st["finished"])


func _refresh_garage_item() -> void:
	var game := UIApi.game()
	var car: Dictionary = game.current_car()
	var livery: Dictionary = game.car_colors()
	_garage_item.set_overline("%s · %s LIVERY" % [str(car.get("name", "")).to_upper(), str(livery.get("name", "")).to_upper()])


func _link_hub_focus() -> void:
	var column: Array[Control] = [_campaign_item]
	if _new_journey_item.visible:
		column.append(_new_journey_item)
	column.append_array([_time_attack_item, _garage_item, _settings_item])
	for i in column.size():
		var c := column[i]
		c.focus_neighbor_top = column[i - 1].get_path() if i > 0 else c.get_path()
		c.focus_neighbor_bottom = column[i + 1].get_path() if i < column.size() - 1 else c.get_path()
		c.focus_neighbor_left = c.get_path()
		c.focus_neighbor_right = c.get_path()
	_settings_item.focus_neighbor_right = _quit_item.get_path()
	_quit_item.focus_neighbor_left = _settings_item.get_path()
	_quit_item.focus_neighbor_right = _quit_item.get_path()
	_quit_item.focus_neighbor_top = _garage_item.get_path()
	_quit_item.focus_neighbor_bottom = _quit_item.get_path()


func _hub_rows() -> Array[Control]:
	var rows: Array[Control] = [_campaign_item]
	if _new_journey_item.visible:
		rows.append(_new_journey_item)
	rows.append_array([_time_attack_item, _garage_item, _small_row])
	return rows


# ---------------------------------------------------------------- show / hide

func enter() -> void:
	active = true
	visible = true
	modulate.a = 1.0
	_switching = false
	_end_wipe()
	var game := UIApi.game()
	# Back from a Time Attack drive: land on its page again (the garage never starts a drive).
	view = "time_attack" if str(game.menu_view) == "time_attack" else "title"
	game.set_menu_view(view)
	_refresh_hub()
	_hub.visible = view == "title"
	_garage.visible = false
	_time_attack.visible = false
	_hint.modulate.a = 0.0
	# Entrance tweens read the laid-out positions.
	UIMotion.layout_now(self)
	_play_intro()
	if view == "time_attack":
		_time_attack.enter(0.9)
	else:
		_last_hub = _campaign_item
		_campaign_item.grab_focus()


func leave(instant: bool = false) -> void:
	if not active:
		return
	active = false
	UIMotion.kill(_intro_tween)
	if instant:
		visible = false
		return
	var tw := UIMotion.tween(self)
	tw.tween_property(self, "modulate:a", 0.0, 0.45).set_delay(0.15)
	tw.tween_callback(hide)
	UIMotion.slide_out(_logo, Vector2(0, -36))
	_wordmark.play_out()
	UIMotion.slide_out(_hint, Vector2(0, 20))
	match view:
		"time_attack":
			_time_attack.leave_for_race()
		"garage":
			_garage.leave()
		_:
			_slide_hub_out(Vector2(-40, 0))


func _play_intro() -> void:
	UIMotion.kill(_intro_tween)
	_logo.modulate.a = 1.0
	_logo.position = LOGO_POS
	_scrim.modulate.a = 0.0
	_intro_tween = UIMotion.tween(self)
	_intro_tween.tween_property(_scrim, "modulate:a", 1.0, 0.8)
	_kanji.play(1.8, 0.1)
	_wordmark.play(0.55)
	_hanko.modulate.a = 0.0
	_hanko.stamp(1.75)
	_subline.modulate.a = 0.0
	UIMotion.rise_in(_subline, 1.1, 16.0, 0.6)
	if view == "title":
		_rise_hub(0.95)
	_hint.position.y = _hint_rest_y()
	UIMotion.tween(_hint).tween_property(_hint, "modulate:a", 1.0, 0.6).set_delay(1.6)


func _rise_hub(delay: float) -> void:
	var d := delay
	for r in _hub_rows():
		UIMotion.rise_in(r, d, 34.0 if r == _campaign_item else 26.0, 0.6)
		d += 0.08


func _slide_hub_out(offset: Vector2) -> void:
	var i := 0
	for r in _hub_rows():
		UIMotion.slide_out(r, offset, 0.03 * i, 0.24)
		i += 1


func _hint_rest_y() -> float:
	return size.y - MARGIN.y * 0.9 - _hint.size.y


func focus_settings_button() -> void:
	_settings_item.grab_focus()


# ---------------------------------------------------------------- pages

func _open_time_attack() -> void:
	if _switching or view != "title":
		return
	_last_hub = _time_attack_item
	view = "time_attack"
	UIApi.game().set_menu_view(view)
	_slide_hub_out(Vector2(-60, 0))
	_hide_hub_later()
	_time_attack.enter(0.14)


func _open_garage() -> void:
	if _switching or view != "title":
		return
	_switching = true
	_last_hub = _garage_item
	view = "garage"
	get_viewport().gui_release_focus()
	_slide_hub_out(Vector2(-60, 0))
	_hide_hub_later()
	UIMotion.slide_out(_logo, Vector2(0, -36))
	_wordmark.play_out()
	UIMotion.kill(_intro_tween)
	UIMotion.tween(_hint).tween_property(_hint, "modulate:a", 0.0, 0.2)
	await _cover()
	if not active or view != "garage":
		return
	# The camera cut and the car parking happen under the ink.
	UIApi.game().set_menu_view("garage")
	await get_tree().process_frame
	if not active or view != "garage":
		return
	_lift()
	_garage.enter(0.2)
	_switching = false


func _back_to_hub() -> void:
	if _switching:
		return
	match view:
		"time_attack":
			view = "title"
			UIApi.game().set_menu_view(view)
			_time_attack.leave()
			_show_hub(0.12)
		"garage":
			_switching = true
			get_viewport().gui_release_focus()
			_garage.leave()
			await _cover()
			if not active or view != "garage":
				return
			view = "title"
			UIApi.game().set_menu_view(view)
			await get_tree().process_frame
			if not active or view != "title":
				return
			_lift()
			_logo.position = LOGO_POS + Vector2(0, -30)
			_logo.modulate.a = 0.0
			var lt := UIMotion.tween(_logo)
			lt.set_parallel(true)
			lt.tween_property(_logo, "modulate:a", 1.0, 0.4).set_delay(0.15)
			lt.tween_property(_logo, "position", LOGO_POS, 0.6).set_delay(0.15).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
			_wordmark.play(0.2)
			UIMotion.tween(_hint).tween_property(_hint, "modulate:a", 1.0, 0.4).set_delay(0.5)
			_show_hub(0.3)
			_switching = false


func _show_hub(delay: float) -> void:
	_refresh_hub()
	_hub.visible = true
	UIMotion.layout_now(_hub)
	UIMotion.layout_now(_small_row)
	_rise_hub(delay)
	var target: Control = _last_hub if _last_hub != null and _last_hub.visible else _campaign_item
	target.grab_focus()


## Hides the hub column once its exit slide is over (the pages take its input from here).
func _hide_hub_later() -> void:
	var tw := UIMotion.tween(_hub)
	tw.tween_interval(0.4)
	tw.tween_callback(func() -> void:
		if view != "title":
			_hub.visible = false)


func _cover() -> Signal:
	UIMotion.kill(_wipe_tween)
	_wipe.visible = true
	_wipe.mouse_filter = Control.MOUSE_FILTER_STOP
	_wipe.set_param(&"seed", randf() * 10.0)
	_wipe_tween = UIMotion.tween(_wipe)
	_wipe_tween.tween_method(_wipe.param_setter(&"progress"), 0.0, 1.0, WIPE_COVER)
	return _wipe_tween.finished


func _lift() -> void:
	UIMotion.kill(_wipe_tween)
	_wipe_tween = UIMotion.tween(_wipe)
	_wipe_tween.tween_method(_wipe.param_setter(&"progress"), 1.0, 2.0, WIPE_LIFT)
	_wipe_tween.tween_callback(_end_wipe)


func _end_wipe() -> void:
	UIMotion.kill(_wipe_tween)
	_wipe.visible = false
	_wipe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_wipe.set_param(&"progress", 0.0)


# ---------------------------------------------------------------- campaign

func _on_campaign_pressed() -> void:
	if _switching or view != "title":
		return
	_last_hub = _campaign_item
	# Continue an unfinished journey; otherwise (first time, or all legs driven) start afresh.
	UIApi.game().request_campaign(not _in_progress())


func _on_new_journey_pressed() -> void:
	if _switching or view != "title" or _confirm.is_open:
		return
	var st: Dictionary = UIApi.game().campaign_status()
	var next: Dictionary = st["next"]
	var first: Dictionary = UIApi.game().CAMPAIGN[0]
	var yes := await _confirm.ask(
		"Start a new journey?",
		"You are on leg %d of %d, %s. Starting over clears this journey and sets off again from %s."
				% [int(st["leg"]) + 1, int(st["legs"]), str(next.get("title", "")), str(first.get("title", ""))],
		"Keep going", "Start over")
	if yes and active and view == "title":
		UIApi.game().request_campaign(true)


# ---------------------------------------------------------------- input / frame

func _unhandled_input(event: InputEvent) -> void:
	if not active or view == "title" or _switching or _confirm.is_open:
		return
	if event.is_action_pressed("ui_cancel"):
		UIApi.ui_sound(&"back")
		_back_to_hub()
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if not visible:
		return
	var d := UIMotion.real_delta(delta)
	_time += d
	var vp := get_viewport_rect().size
	var m := (get_viewport().get_mouse_position() / vp - Vector2(0.5, 0.5)).clamp(Vector2(-0.5, -0.5), Vector2(0.5, 0.5))
	var target := Vector2(-m.x * 14.0, -m.y * 8.0) + Vector2(sin(_time * 0.21) * 4.0, sin(_time * 0.17) * 3.0)
	_parallax = _parallax.lerp(target, UIMotion.damp(3.0, d))
	_logo_layer.position = _parallax
	_menu_layer.position = _parallax * 0.4
