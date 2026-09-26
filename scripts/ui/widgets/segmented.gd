extends Control
## Segmented pill selector (e.g. Time Trial | Free Roam, Low | Medium | High).
## One focus stop: left / right (keys, d-pad, stick) change the value, mouse clicks pick
## directly. The white selection pill slides with a spring.

signal changed(index: int)

const UITheme := preload("res://scripts/ui/ui_theme.gd")
const UIMotion := preload("res://scripts/ui/ui_motion.gd")
const UIApi := preload("res://scripts/ui/ui_api.gd")

@export var options: PackedStringArray = []:
	set(v):
		options = v
		_layout()
@export var selected := 0
@export var font_size := 20
@export var accent := UITheme.VERMILION
@export var min_segment_width := 120.0
@export var height := 52.0

var _pill_x := 0.0
var _pill_w := 0.0
var _pill_vel := 0.0
var _hover := -1
var _seg_x: PackedFloat32Array = []
var _seg_w: PackedFloat32Array = []
var _font: Font = UITheme.FONT_UI_BOLD
var _placed := false
var _track := StyleBoxFlat.new()
var _pill := StyleBoxFlat.new()


func _init() -> void:
	_track.bg_color = Color(UITheme.INK, 0.07)
	_track.corner_detail = 12
	_pill.bg_color = Color(1, 1, 1, 0.98)
	_pill.corner_detail = 12
	_pill.shadow_color = Color(UITheme.INK, 0.14)
	_pill.shadow_size = 8
	_pill.shadow_offset = Vector2(0, 2)


func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	mouse_entered.connect(func() -> void: grab_focus())
	mouse_exited.connect(func() -> void: _hover = -1)
	focus_entered.connect(func() -> void: UIApi.ui_sound(&"hover"))
	_layout()


func set_selected(i: int, emit: bool = false) -> void:
	i = clampi(i, 0, maxi(options.size() - 1, 0))
	if i == selected:
		return
	selected = i
	if emit:
		UIApi.ui_sound(&"toggle")
		changed.emit(i)


func _layout() -> void:
	_seg_x.clear()
	_seg_w.clear()
	var pad := 6.0
	var x := pad
	for o in options:
		var w := maxf(min_segment_width, _font.get_string_size(o, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x + 44.0)
		_seg_x.append(x)
		_seg_w.append(w)
		x += w
	custom_minimum_size = Vector2(x + pad, height)
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_left", true):
		set_selected(selected - 1, true)
		accept_event()
	elif event.is_action_pressed("ui_right", true):
		set_selected(selected + 1, true)
		accept_event()
	elif event.is_action_pressed("ui_accept"):
		set_selected((selected + 1) % maxi(options.size(), 1), true)
		accept_event()
	elif event is InputEventMouseMotion:
		_hover = _index_at((event as InputEventMouseMotion).position.x)
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			var idx := _index_at(mb.position.x)
			if idx >= 0:
				set_selected(idx, true)
			accept_event()


func _index_at(x: float) -> int:
	for i in _seg_x.size():
		if x >= _seg_x[i] and x < _seg_x[i] + _seg_w[i]:
			return i
	return -1


func _process(delta: float) -> void:
	if _seg_x.is_empty():
		return
	var d := minf(UIMotion.real_delta(delta), 0.05)
	var tx: float = _seg_x[selected]
	var tw: float = _seg_w[selected]
	if not _placed:
		_pill_x = tx
		_pill_w = tw
		_placed = true
	var k := 380.0
	var c := 30.0
	_pill_vel += ((tx - _pill_x) * k - _pill_vel * c) * d
	_pill_x += _pill_vel * d
	_pill_w = lerpf(_pill_w, tw, UIMotion.damp(18.0, d))
	queue_redraw()


func _draw() -> void:
	var r := size.y * 0.5
	_track.set_corner_radius_all(int(r))
	draw_style_box(_track, Rect2(Vector2.ZERO, size))
	if _seg_x.is_empty():
		return
	_pill.set_corner_radius_all(int(r - 5))
	draw_style_box(_pill, Rect2(Vector2(_pill_x, 5), Vector2(_pill_w, size.y - 10)))
	var asc := _font.get_ascent(font_size)
	var desc := _font.get_descent(font_size)
	for i in options.size():
		var o: String = options[i]
		var w := _font.get_string_size(o, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		var centre: float = _seg_x[i] + _seg_w[i] * 0.5
		# Colour follows the sliding pill, so the label tints as the pill arrives.
		var cover := clampf(1.0 - absf(centre - (_pill_x + _pill_w * 0.5)) / maxf(_seg_w[i] * 0.6, 1.0), 0.0, 1.0)
		var col := Color(UITheme.INK, 0.55 if i != _hover else 0.8).lerp(accent, cover)
		draw_string(_font, Vector2(centre - w * 0.5, (size.y + asc - desc) * 0.5), o, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, col)
