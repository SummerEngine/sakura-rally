extends Control
## Control hints as small paper keycaps followed by a label: [W][A][S][D] Drive  [Space] Handbrake.
## Switches to gamepad glyph names after the last input came from a joypad.

const UITheme := preload("res://scripts/ui/ui_theme.gd")

## Each entry: [keyboard keys (Array[String]), gamepad keys (Array[String]), label]
@export var entries: Array = []
@export var font_size := 15
@export var cap_color := Color(UITheme.PAPER, 0.9)
@export var text_color := Color(UITheme.INK, 0.8)
@export var backing := Color(UITheme.PAPER, 0.62) ## soft pill behind the strip (alpha 0 = none)

const PAD_X := 16.0

var _gamepad := false
var _cap := StyleBoxFlat.new()
var _back := StyleBoxFlat.new()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cap.corner_detail = 6
	_cap.set_corner_radius_all(7)
	_cap.shadow_color = Color(UITheme.INK, 0.16)
	_cap.shadow_size = 3
	_cap.shadow_offset = Vector2(0, 2)
	_cap.border_color = Color(UITheme.INK, 0.12)
	_cap.border_width_bottom = 2
	_back.set_corner_radius_all(24)
	_back.corner_detail = 10
	_back.shadow_color = Color(UITheme.INK, 0.08)
	_back.shadow_size = 12
	_back.shadow_offset = Vector2(0, 3)


func _ready() -> void:
	_relayout()


func _input(event: InputEvent) -> void:
	var pad := event is InputEventJoypadButton or (event is InputEventJoypadMotion and absf((event as InputEventJoypadMotion).axis_value) > 0.5)
	var kb := event is InputEventKey or event is InputEventMouseButton
	if (pad and not _gamepad) or (kb and _gamepad):
		_gamepad = pad
		_relayout()


func _measure() -> float:
	var f: Font = UITheme.FONT_UI_BLACK
	var lf: Font = UITheme.FONT_UI_BOLD
	var x := 0.0
	for e: Array in entries:
		var keys: Array = e[1] if _gamepad else e[0]
		for k: String in keys:
			x += maxf(f.get_string_size(k, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size - 2).x + 16.0, 28.0) + 4.0
		x += 6.0 + lf.get_string_size(str(e[2]), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x + 26.0
	return x - 26.0 + PAD_X * 2.0


func _relayout() -> void:
	custom_minimum_size = Vector2(_measure(), 44.0)
	queue_redraw()


func _draw() -> void:
	var f: Font = UITheme.FONT_UI_BLACK
	var lf: Font = UITheme.FONT_UI_BOLD
	var total := _measure()
	var x := size.x - total
	if backing.a > 0.0:
		_back.bg_color = backing
		draw_style_box(_back, Rect2(x, 0.0, total, size.y))
	x += PAD_X
	var h := 28.0
	var y := (size.y - h) * 0.5
	var ks := font_size - 2
	_cap.bg_color = cap_color
	for e: Array in entries:
		var keys: Array = e[1] if _gamepad else e[0]
		for k: String in keys:
			var w := maxf(f.get_string_size(k, HORIZONTAL_ALIGNMENT_LEFT, -1, ks).x + 16.0, 28.0)
			draw_style_box(_cap, Rect2(x, y, w, h))
			var tw := f.get_string_size(k, HORIZONTAL_ALIGNMENT_LEFT, -1, ks).x
			draw_string(f, Vector2(x + (w - tw) * 0.5, y + h * 0.5 + (f.get_ascent(ks) - f.get_descent(ks)) * 0.5 - 1.0), k, HORIZONTAL_ALIGNMENT_LEFT, -1, ks, UITheme.INK)
			x += w + 4.0
		x += 6.0
		var label := str(e[2])
		draw_string(lf, Vector2(x, y + h * 0.5 + (lf.get_ascent(font_size) - lf.get_descent(font_size)) * 0.5), label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, text_color)
		x += lf.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x + 26.0
