extends Control
## Settings sheet (menu and pause): volumes, quality, transmission, camera, units,
## fullscreen. Every change is written immediately via Game.set_setting.
## Esc / B / Back button or "Done" closes; emits `closed`.

signal closed

const UITheme := preload("res://scripts/ui/ui_theme.gd")
const UIMotion := preload("res://scripts/ui/ui_motion.gd")
const UIApi := preload("res://scripts/ui/ui_api.gd")
const PaperCard := preload("res://scripts/ui/widgets/paper_card.gd")
const Segmented := preload("res://scripts/ui/widgets/segmented.gd")
const PaperSlider := preload("res://scripts/ui/widgets/paper_slider.gd")
const InkButton := preload("res://scripts/ui/widgets/ink_button.gd")

## [setting key, label, option values, option labels]
const CHOICES := [
	["quality", "Quality", ["low", "medium", "high"], ["Low", "Medium", "High"]],
	["transmission", "Gearbox", ["auto", "manual"], ["Automatic", "Manual"]],
	["camera", "Camera", ["chase", "chase_far", "hood", "bumper"], ["Chase", "Far", "Hood", "Bumper"]],
	["units", "Speed", ["kmh", "mph"], ["km/h", "mph"]],
	["fullscreen", "Display", [false, true], ["Window", "Fullscreen"]],
]
const VOLUMES := [["master_volume", "Master"], ["music_volume", "Music"], ["sfx_volume", "Effects"]]

var is_open := false

var _dim := ColorRect.new()
var _card: PaperCard
var _rows: Array[Control] = []
var _controls: Dictionary = {} ## key -> control
var _done: Button
var _return_focus: Control
var _tween: Tween


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_dim.color = Color(UITheme.INK, 0.3)
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	_card = PaperCard.new()
	_card.padding = Vector4(52, 44, 52, 40)
	_card.paper_alpha = 0.94
	center.add_child(_card)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_child(col)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 16)
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(head)
	head.add_child(UITheme.make_label("Settings", UITheme.FONT_TITLE, 40, UITheme.INK))
	var jp := UITheme.make_label("設定", UITheme.FONT_BRUSH, 34, UITheme.SAKURA)
	jp.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(jp)
	col.add_child(_spacer(10))

	col.add_child(_section("SOUND"))
	for v: Array in VOLUMES:
		var slider := PaperSlider.new()
		slider.value = float(UIApi.setting(v[0]))
		slider.value_changed.connect(func(x: float) -> void: UIApi.game().set_setting(v[0], x))
		_controls[v[0]] = slider
		col.add_child(_row(v[1], slider))
	col.add_child(_spacer(8))
	col.add_child(_section("DRIVING  &  DISPLAY"))
	for c: Array in CHOICES:
		var seg := Segmented.new()
		seg.options = PackedStringArray(c[3])
		seg.min_segment_width = 112.0
		seg.font_size = 18
		seg.height = 48.0
		seg.changed.connect(func(i: int) -> void: UIApi.game().set_setting(c[0], (c[2] as Array)[i]))
		_controls[c[0]] = seg
		col.add_child(_row(c[1], seg))
	col.add_child(_spacer(14))
	_done = InkButton.new()
	_done.text = "Done"
	_done.theme_type_variation = &"PrimaryButton"
	_done.custom_minimum_size = Vector2(220, 0)
	_done.size_flags_horizontal = Control.SIZE_SHRINK_END
	_done.press_sound = &"back"
	_done.pressed.connect(close)
	col.add_child(_done)

	# Vertical chain through every row; left/right stays inside the control.
	var chain: Array[Control] = []
	for r in _rows:
		chain.append(r.get_child(1) as Control)
	chain.append(_done)
	for i in chain.size():
		var prev := chain[(i - 1 + chain.size()) % chain.size()]
		var next := chain[(i + 1) % chain.size()]
		chain[i].focus_neighbor_top = prev.get_path()
		chain[i].focus_neighbor_bottom = next.get_path()
		chain[i].focus_neighbor_left = chain[i].get_path()
		chain[i].focus_neighbor_right = chain[i].get_path()
		chain[i].focus_previous = prev.get_path()
		chain[i].focus_next = next.get_path()
	visible = false


func _spacer(h: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


func _section(text: String) -> Control:
	var l := UITheme.make_label(text, UITheme.tracked(UITheme.FONT_UI_BLACK, 3), 13, Color(UITheme.INK, 0.5))
	return l


func _row(label_text: String, control: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 24)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := UITheme.make_label(label_text, UITheme.FONT_UI_BOLD, 21, UITheme.INK)
	l.custom_minimum_size = Vector2(150, 0)
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(l)
	row.add_child(control)
	_rows.append(row)
	return row


func _sync() -> void:
	for v: Array in VOLUMES:
		(_controls[v[0]] as PaperSlider).value = float(UIApi.setting(v[0]))
	for c: Array in CHOICES:
		var idx := (c[2] as Array).find(UIApi.setting(c[0]))
		(_controls[c[0]] as Segmented).selected = maxi(idx, 0)


func open() -> void:
	if is_open:
		return
	is_open = true
	_return_focus = get_viewport().gui_get_focus_owner()
	_sync()
	visible = true
	UIMotion.kill(_tween)
	_dim.modulate.a = 0.0
	_tween = UIMotion.tween(self)
	_tween.tween_property(_dim, "modulate:a", 1.0, 0.25)
	_card.reveal = 0.0
	_tween.parallel().tween_property(_card, "reveal", 1.0, 0.55).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	for r in _rows:
		r.modulate.a = 0.0
	_done.modulate.a = 0.0
	(_rows[0].get_child(1) as Control).grab_focus()
	# Rows live in a VBox: wait for its first sort so rise_in captures the laid-out positions.
	await get_tree().process_frame
	if not is_open:
		return
	var d := 0.12
	for r in _rows:
		UIMotion.rise_in(r, d, 14.0, 0.4)
		d += 0.035
	UIMotion.rise_in(_done, d + 0.05, 14.0, 0.4)


func close() -> void:
	if not is_open:
		return
	is_open = false
	UIMotion.kill(_tween)
	_tween = UIMotion.tween(self)
	_tween.tween_property(_card, "reveal", 0.0, 0.3).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_tween.parallel().tween_property(_dim, "modulate:a", 0.0, 0.3)
	_tween.tween_callback(hide)
	if _return_focus != null and is_instance_valid(_return_focus) and _return_focus.is_visible_in_tree():
		_return_focus.grab_focus()
	else:
		get_viewport().gui_release_focus()
	closed.emit()


func _unhandled_input(event: InputEvent) -> void:
	if not is_open:
		return
	if event.is_action_pressed("ui_cancel") or event.is_action_pressed("pause"):
		UIApi.ui_sound(&"back")
		close()
		get_viewport().set_input_as_handled()
