extends Control
## Livery picker: two-tone paint chips from Game.CAR_COLORS (primary body + diagonal stripe).
## One focus stop; left / right or click choose; the selected chip swells and the name
## slides in beside the row.

signal changed(index: int)

const UITheme := preload("res://scripts/ui/ui_theme.gd")
const UIMotion := preload("res://scripts/ui/ui_motion.gd")
const UIApi := preload("res://scripts/ui/ui_api.gd")

const CHIP_R := 20.0
const GAP := 18.0

var colors: Array = []
var selected := 0

var _sel_scale: PackedFloat32Array = []
var _name_t := 1.0
var _font: Font = UITheme.FONT_UI_BOLD
var _hover := -1


func setup(car_colors: Array, index: int) -> void:
	colors = car_colors
	selected = clampi(index, 0, colors.size() - 1)
	_sel_scale.resize(colors.size())
	for i in colors.size():
		_sel_scale[i] = 1.0
	custom_minimum_size = Vector2(colors.size() * (CHIP_R * 2.0 + GAP) + 170.0, 52.0)


func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	mouse_entered.connect(func() -> void: grab_focus())
	mouse_exited.connect(func() -> void: _hover = -1)
	focus_entered.connect(func() -> void: UIApi.ui_sound(&"hover"))
	set_meta(&"focus_grow", 5.0)


func _chip_centre(i: int) -> Vector2:
	return Vector2(10.0 + CHIP_R + i * (CHIP_R * 2.0 + GAP), size.y * 0.5)


func _choose(i: int) -> void:
	i = clampi(i, 0, colors.size() - 1)
	if i == selected:
		return
	selected = i
	_name_t = 0.0
	UIApi.ui_sound(&"toggle")
	changed.emit(i)


func _gui_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_left", true):
		_choose(selected - 1)
		accept_event()
	elif event.is_action_pressed("ui_right", true):
		_choose(selected + 1)
		accept_event()
	elif event.is_action_pressed("ui_accept"):
		_choose((selected + 1) % colors.size())
		accept_event()
	elif event is InputEventMouseMotion:
		_hover = _index_at((event as InputEventMouseMotion).position)
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			var idx := _index_at(mb.position)
			if idx >= 0:
				_choose(idx)
			accept_event()


func _index_at(p: Vector2) -> int:
	for i in colors.size():
		if p.distance_to(_chip_centre(i)) <= CHIP_R + GAP * 0.5:
			return i
	return -1


func _process(delta: float) -> void:
	var d := UIMotion.real_delta(delta)
	for i in colors.size():
		var target := 1.18 if i == selected else (1.08 if i == _hover else 1.0)
		_sel_scale[i] = lerpf(_sel_scale[i], target, UIMotion.damp(14.0, d))
	_name_t = minf(_name_t + d * 3.0, 1.0)
	queue_redraw()


func _draw() -> void:
	for i in colors.size():
		var c := _chip_centre(i)
		var r := CHIP_R * _sel_scale[i]
		var entry: Dictionary = colors[i]
		var primary: Color = entry["primary"]
		var secondary: Color = entry["secondary"]
		draw_circle(c + Vector2(0, 3), r + 1.5, Color(UITheme.INK, 0.14))
		var circle := PackedVector2Array()
		for k in 40:
			var a := TAU * k / 40.0
			circle.append(c + Vector2(cos(a), sin(a)) * r)
		draw_colored_polygon(circle, primary)
		# Diagonal livery stripe clipped to the chip.
		var dir := Vector2(1, -1).normalized()
		var nrm := Vector2(1, 1).normalized()
		var band := PackedVector2Array([
			c + nrm * r * 0.05 - dir * r * 2.0, c + nrm * r * 0.05 + dir * r * 2.0,
			c + nrm * r * 0.45 + dir * r * 2.0, c + nrm * r * 0.45 - dir * r * 2.0,
		])
		for poly in Geometry2D.intersect_polygons(circle, band):
			draw_colored_polygon(poly, secondary)
		draw_arc(c, r, 0.0, TAU, 40, Color(UITheme.INK, 0.12), 1.5, true)
		if i == selected:
			draw_arc(c, r + 6.0, 0.0, TAU, 48, UITheme.INK, 2.5, true)
	if colors.is_empty():
		return
	var nm := str((colors[selected] as Dictionary)["name"])
	var x0 := _chip_centre(colors.size() - 1).x + CHIP_R + 26.0
	var fs := 21
	var asc := _font.get_ascent(fs)
	var e := UIMotion.out_expo(_name_t)
	draw_string(_font, Vector2(x0 + 14.0 * (1.0 - e), (size.y + asc - _font.get_descent(fs)) * 0.5), nm, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(UITheme.INK, e))
