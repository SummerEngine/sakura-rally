extends Control
## Volume slider: soft track, sakura fill, paper knob, value readout. Left / right step it
## (hold to repeat), mouse drag or click sets it directly.

signal value_changed(value: float)

const UITheme := preload("res://scripts/ui/ui_theme.gd")
const UIMotion := preload("res://scripts/ui/ui_motion.gd")
const UIApi := preload("res://scripts/ui/ui_api.gd")

@export var value := 0.8
@export var step := 0.05
@export var track_width := 300.0

var _shown := 0.8
var _dragging := false
var _knob_pop := 0.0
var _font: Font = UITheme.FONT_UI_BLACK
var _sb_track := StyleBoxFlat.new()
var _sb_fill := StyleBoxFlat.new()


func _init() -> void:
	for sb: StyleBoxFlat in [_sb_track, _sb_fill]:
		sb.set_corner_radius_all(4)
		sb.corner_detail = 6
	_sb_track.bg_color = Color(UITheme.INK, 0.1)
	_sb_fill.bg_color = UITheme.SAKURA


func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	custom_minimum_size = Vector2(track_width + 88.0, 52.0)
	mouse_entered.connect(func() -> void: grab_focus())
	focus_entered.connect(func() -> void: UIApi.ui_sound(&"hover"))
	_shown = value
	set_meta(&"focus_grow", 4.0)


func set_value(v: float, emit: bool = false) -> void:
	v = clampf(snappedf(v, step * 0.5) if _dragging else snappedf(v, step), 0.0, 1.0)
	if is_equal_approx(v, value):
		return
	value = v
	_knob_pop = 1.0
	if emit:
		value_changed.emit(v)


func _track_rect() -> Rect2:
	return Rect2(Vector2(18.0, size.y * 0.5 - 4.0), Vector2(track_width, 8.0))


func _gui_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_left", true):
		set_value(value - step, true)
		UIApi.ui_sound(&"toggle")
		accept_event()
	elif event.is_action_pressed("ui_right", true):
		set_value(value + step, true)
		UIApi.ui_sound(&"toggle")
		accept_event()
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_dragging = mb.pressed
			if mb.pressed:
				_set_from_x(mb.position.x)
			else:
				UIApi.ui_sound(&"toggle")
			accept_event()
	elif event is InputEventMouseMotion and _dragging:
		_set_from_x((event as InputEventMouseMotion).position.x)
		accept_event()


func _set_from_x(x: float) -> void:
	var tr := _track_rect()
	set_value((x - tr.position.x) / tr.size.x, true)


func _process(delta: float) -> void:
	var d := UIMotion.real_delta(delta)
	_shown = lerpf(_shown, value, UIMotion.damp(22.0, d))
	_knob_pop = maxf(_knob_pop - d * 5.0, 0.0)
	queue_redraw()


func _draw() -> void:
	var tr := _track_rect()
	draw_style_box(_sb_track, tr)
	var fill := Rect2(tr.position, Vector2(maxf(tr.size.x * _shown, 8.0), tr.size.y))
	draw_style_box(_sb_fill, fill)
	# Tick marks every 25 %.
	for i in range(1, 4):
		var x := tr.position.x + tr.size.x * i * 0.25
		draw_circle(Vector2(x, tr.get_center().y), 2.0, Color(1, 1, 1, 0.8) if _shown * 4.0 >= i else Color(UITheme.INK, 0.2))
	var kx := tr.position.x + tr.size.x * _shown
	var kc := Vector2(kx, tr.get_center().y)
	var kr := 13.0 + 3.0 * UIMotion.out_cubic(_knob_pop) + (2.0 if has_focus() else 0.0)
	draw_circle(kc + Vector2(0, 3), kr + 2.0, Color(UITheme.INK, 0.12))
	draw_circle(kc, kr, Color(1, 1, 1))
	draw_circle(kc, kr * 0.38, UITheme.SAKURA)
	var txt := "%d" % roundi(value * 100.0)
	var fs := 20
	var w := _font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var asc := _font.get_ascent(fs)
	draw_string(_font, Vector2(size.x - 14.0 - w, (size.y + asc - _font.get_descent(fs)) * 0.5), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, UITheme.INK)
