extends Control
## Garage car selector (Game.CARS): name, brush kanji, tagline, spec line and four stat bars
## (speed, acceleration, grip, drift). One focus stop: left / right switch cars (keys, d-pad,
## stick), the ‹ › arrows take clicks. A switch slides the old name out and the new one in,
## the bars run to the new values. While focused a sakura outline hugs the selector.

signal changed(index: int)

const UITheme := preload("res://scripts/ui/ui_theme.gd")
const UIMotion := preload("res://scripts/ui/ui_motion.gd")
const UIApi := preload("res://scripts/ui/ui_api.gd")

const WIDTH := 548.0
const STATS := [["speed", "SPEED"], ["acceleration", "ACCELERATION"], ["grip", "GRIP"], ["drift", "DRIFT"]]
const BAR_W := 300.0
const BAR_H := 10.0
const FOCUS_GROW := 12.0

var selected := 0

var _cars: Array = []
var _info := VBoxContainer.new()
var _name: Label
var _kanji: Label
var _count: Label
var _tagline: Label
var _spec: Label
var _bars := Control.new()
var _left := Control.new()
var _right := Control.new()
var _values := PackedFloat32Array([0, 0, 0, 0])
var _targets := PackedFloat32Array([0, 0, 0, 0])
var _starts := PackedFloat32Array([0, 0, 0, 0])
var _bar_t := 1.0
var _swap_t := 1.0
var _swap_dir := 1.0
var _kick := Vector2.ZERO ## left / right arrow kick
var _focus_t := 0.0
var _time := 0.0
var _sb_line := StyleBoxFlat.new()
var _sb_glow := StyleBoxFlat.new()
var _label_font: Font = UITheme.tracked(UITheme.FONT_UI_BLACK, 2)


func setup(cars: Array, index: int) -> void:
	_cars = cars
	selected = clampi(index, 0, _cars.size() - 1)


func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	set_meta(&"no_focus_ring", true)
	mouse_entered.connect(func() -> void: grab_focus())
	focus_entered.connect(func() -> void: UIApi.ui_sound(&"hover"))
	for sb: StyleBoxFlat in [_sb_line, _sb_glow]:
		sb.bg_color = Color(0, 0, 0, 0)
		sb.draw_center = false
		sb.corner_detail = 10
		sb.anti_aliasing_size = 1.0
	_sb_line.set_border_width_all(3)
	_sb_line.set_corner_radius_all(22)
	_sb_glow.set_border_width_all(7)
	_sb_glow.set_corner_radius_all(26)

	_info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_info.add_theme_constant_override("separation", 6)
	_info.position = Vector2(0, 0)
	add_child(_info)
	var name_row := HBoxContainer.new()
	name_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_row.add_theme_constant_override("separation", 14)
	_info.add_child(name_row)
	_left.custom_minimum_size = Vector2(26, 56)
	_right.custom_minimum_size = Vector2(26, 56)
	for arrow: Control in [_left, _right]:
		arrow.mouse_filter = Control.MOUSE_FILTER_STOP
		arrow.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		arrow.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_left.draw.connect(_draw_arrow.bind(_left, -1.0))
	_right.draw.connect(_draw_arrow.bind(_right, 1.0))
	_left.gui_input.connect(_arrow_input.bind(-1))
	_right.gui_input.connect(_arrow_input.bind(1))
	name_row.add_child(_left)
	_name = UITheme.make_label("", UITheme.FONT_TITLE, 50, UITheme.INK)
	name_row.add_child(_name)
	_kanji = UITheme.make_label("", UITheme.FONT_BRUSH, 44, UITheme.VERMILION)
	_kanji.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	name_row.add_child(_kanji)
	name_row.add_child(_right)
	var push := Control.new()
	push.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	push.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_row.add_child(push)
	_count = UITheme.make_label("", UITheme.tracked(UITheme.FONT_UI_BLACK, 2), 14, UITheme.INK_SOFT)
	_count.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	name_row.add_child(_count)
	_tagline = UITheme.make_label("", UITheme.FONT_UI_MEDIUM, 18, UITheme.INK_SOFT)
	_tagline.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tagline.custom_minimum_size = Vector2(WIDTH, 0)
	_info.add_child(_tagline)
	_spec = UITheme.make_label("", UITheme.tracked(UITheme.FONT_UI_BLACK, 2), 13, Color(UITheme.INK, 0.72))
	_info.add_child(_spec)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 8)
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_info.add_child(gap)
	_bars.custom_minimum_size = Vector2(WIDTH, STATS.size() * 28.0)
	_bars.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bars.draw.connect(_draw_bars)
	_info.add_child(_bars)
	_info.minimum_size_changed.connect(func() -> void:
		custom_minimum_size = Vector2(WIDTH, _info.get_combined_minimum_size().y))
	_show_car(false)


## Shows car `i` without emitting (sync from settings).
func set_selected(i: int) -> void:
	selected = clampi(i, 0, _cars.size() - 1)
	_show_car(false)


func _choose(i: int) -> void:
	var n := _cars.size()
	if n < 2:
		return
	var dir := signf(float(i - selected))
	i = wrapi(i, 0, n)
	if i == selected:
		return
	selected = i
	_swap_dir = dir
	_kick = Vector2(-1.0 if dir < 0.0 else 0.0, 1.0 if dir > 0.0 else 0.0)
	UIApi.ui_sound(&"toggle")
	_show_car(true)
	changed.emit(i)


func _show_car(animate: bool) -> void:
	if _name == null or _cars.is_empty():
		return
	var car: Dictionary = _cars[selected]
	_name.text = str(car.get("name", ""))
	_kanji.text = str(car.get("name_jp", ""))
	_tagline.text = str(car.get("tagline", ""))
	_spec.text = str(car.get("spec", "")).to_upper()
	_count.text = "%d / %d" % [selected + 1, _cars.size()]
	# One car: nothing to switch to, so no arrows and no count.
	var many := _cars.size() > 1
	_count.visible = many
	_left.modulate.a = 1.0 if many else 0.0
	_right.modulate.a = 1.0 if many else 0.0
	_left.mouse_filter = Control.MOUSE_FILTER_STOP if many else Control.MOUSE_FILTER_IGNORE
	_right.mouse_filter = _left.mouse_filter
	var stats: Dictionary = car.get("stats", {})
	for k in STATS.size():
		_starts[k] = _values[k]
		_targets[k] = float(stats.get(STATS[k][0], 0.0))
	_bar_t = 0.0 if animate else 1.0
	_swap_t = 0.0 if animate else 1.0
	if not animate:
		_values = _targets.duplicate()
	_bars.queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_left", true):
		_choose(selected - 1)
		accept_event()
	elif event.is_action_pressed("ui_right", true):
		_choose(selected + 1)
		accept_event()


func _arrow_input(event: InputEvent, dir: int) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		grab_focus()
		_choose(selected + dir)


func _process(delta: float) -> void:
	var d := minf(UIMotion.real_delta(delta), 0.05)
	_time += d
	_focus_t = lerpf(_focus_t, 1.0 if has_focus() else 0.0, UIMotion.damp(14.0, d))
	_kick = _kick.lerp(Vector2.ZERO, UIMotion.damp(10.0, d))
	_left.position.x = -6.0 * _kick.x
	_right.queue_redraw()
	_left.queue_redraw()
	if _swap_t < 1.0:
		# Name block: out-expo slide in from the side the switch came from.
		_swap_t = minf(_swap_t + d / 0.42, 1.0)
		var e := UIMotion.out_expo(_swap_t)
		for l: Control in [_name, _kanji, _tagline, _spec]:
			l.modulate.a = e
		_name.position.x = _left.size.x + 14.0 + 40.0 * _swap_dir * (1.0 - e)
	if _bar_t < 1.0:
		_bar_t = minf(_bar_t + d, 1.0)
		for k in STATS.size():
			var t := UIMotion.out_expo(clampf((_bar_t - k * 0.06) / 0.7, 0.0, 1.0))
			_values[k] = lerpf(_starts[k], _targets[k], t)
		_bars.queue_redraw()
	queue_redraw()


func _draw() -> void:
	var a := UIMotion.out_cubic(_focus_t)
	if a < 0.01:
		return
	var breathe := 0.5 + 0.5 * sin(_time * 3.2)
	var r := Rect2(Vector2.ZERO, size).grow(FOCUS_GROW)
	_sb_glow.border_color = Color(UITheme.SAKURA, (0.14 + 0.1 * breathe) * a)
	draw_style_box(_sb_glow, r.grow(4.0))
	_sb_line.border_color = Color(UITheme.SAKURA, 0.95 * a)
	draw_style_box(_sb_line, r)


func _draw_arrow(arrow: Control, dir: float) -> void:
	var c := arrow.size * 0.5
	var kick := _kick.y if dir > 0.0 else _kick.x
	c.x += dir * 5.0 * absf(kick)
	var col := Color(UITheme.INK, 0.45 + 0.4 * _focus_t)
	var tip := c + Vector2(6 * dir, 0)
	arrow.draw_line(c + Vector2(-5 * dir, -11), tip, col, 3.4, true)
	arrow.draw_line(tip, c + Vector2(-5 * dir, 11), col, 3.4, true)
	arrow.draw_circle(tip, 1.7, col)


func _draw_bars() -> void:
	var f := _label_font
	var label_w := WIDTH - BAR_W
	for k in STATS.size():
		var y := k * 28.0 + 14.0
		_bars.draw_string(f, Vector2(0, y + 5), STATS[k][1], HORIZONTAL_ALIGNMENT_LEFT, -1, 13, UITheme.INK_SOFT)
		var track := Rect2(label_w, y - BAR_H * 0.5, BAR_W, BAR_H)
		_bars.draw_rect(track, Color(UITheme.INK, 0.1))
		var fill := Rect2(track.position, Vector2(BAR_W * clampf(_values[k], 0.0, 1.0), BAR_H))
		_bars.draw_rect(fill, UITheme.VERMILION.lerp(UITheme.SAKURA, float(k) / 3.0 * 0.5))
		# Gauge notches every 10 %, cut in paper.
		for n in range(1, 10):
			var x := label_w + BAR_W * n * 0.1
			_bars.draw_line(Vector2(x, track.position.y), Vector2(x, track.end.y), UITheme.PAPER, 2.0)
