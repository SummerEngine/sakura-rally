extends Control
## Garage livery picker: a row of washi paint-chip cards (Game.CAR_COLORS), each with an
## ink-edged brush stroke of the body colour over a thinner stroke of the stripe colour, the
## livery's name and kanji. One focus stop: left / right pick (keys, d-pad, stick), a click
## picks directly. The chosen chip lifts, gets a vermilion hanko tick and repaints its strokes;
## while the picker has focus a sakura outline hugs the chosen chip (the global ring skips it).

signal changed(index: int)

const UITheme := preload("res://scripts/ui/ui_theme.gd")
const UIMotion := preload("res://scripts/ui/ui_motion.gd")
const UIApi := preload("res://scripts/ui/ui_api.gd")
const ShaderRect := preload("res://scripts/ui/widgets/shader_rect.gd")
const BRUSH_BAND := preload("res://shaders/ui/brush_band.gdshader")

const CHIP := Vector2(100, 138)
const GAP := 12.0
const LIFT := 10.0
const RADIUS := 14
const FOCUS_GROW := 6.0
const KANJI := {"Sakura": "桜", "Momiji": "紅葉", "Sora": "空", "Matcha": "抹茶", "Sumi": "墨"}

var selected := 0

var _colors: Array = []
var _chips: Array[Control] = []
var _strokes: Array = [] ## per chip: [ink body, body, ink stripe, stripe] ShaderRects
var _lift := PackedFloat32Array()
var _hover := -1
var _time := 0.0
var _focus_t := 0.0
var _outline := Control.new()
var _sb_line := StyleBoxFlat.new()
var _sb_glow := StyleBoxFlat.new()
var _paint_tween: Tween


func setup(car_colors: Array, index: int) -> void:
	_colors = car_colors
	selected = clampi(index, 0, _colors.size() - 1)


func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	set_meta(&"no_focus_ring", true)
	mouse_entered.connect(func() -> void: grab_focus())
	mouse_exited.connect(func() -> void: _hover = -1)
	focus_entered.connect(func() -> void: UIApi.ui_sound(&"hover"))
	custom_minimum_size = Vector2(_colors.size() * (CHIP.x + GAP) - GAP, CHIP.y + LIFT)
	_lift.resize(_colors.size())
	for i in _colors.size():
		_build_chip(i)
		_lift[i] = 1.0 if i == selected else 0.0
	for sb: StyleBoxFlat in [_sb_line, _sb_glow]:
		sb.bg_color = Color(0, 0, 0, 0)
		sb.draw_center = false
		sb.corner_detail = 10
		sb.anti_aliasing_size = 1.0
	_sb_line.set_border_width_all(3)
	_sb_line.set_corner_radius_all(RADIUS + int(FOCUS_GROW))
	_sb_glow.set_border_width_all(7)
	_sb_glow.set_corner_radius_all(RADIUS + int(FOCUS_GROW) + 4)
	_outline.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_outline.draw.connect(_draw_outline)
	add_child(_outline)


func _build_chip(i: int) -> void:
	var c: Dictionary = _colors[i]
	var chip := Panel.new()
	chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip.size = CHIP
	chip.position = Vector2(i * (CHIP.x + GAP), LIFT)
	var sb := StyleBoxFlat.new()
	sb.bg_color = UITheme.PAPER
	sb.set_corner_radius_all(RADIUS)
	sb.corner_detail = 8
	sb.shadow_color = Color(UITheme.INK, 0.16)
	sb.shadow_size = 10
	sb.shadow_offset = Vector2(0, 4)
	sb.border_color = Color(UITheme.INK, 0.1)
	sb.set_border_width_all(1)
	sb.anti_aliasing_size = 1.0
	chip.add_theme_stylebox_override("panel", sb)
	add_child(chip)
	_chips.append(chip)
	# Ink under each stroke, a little larger, so even the white body paint reads on paper.
	var strokes: Array = []
	for spec: Array in [[Vector2(6, 12), Vector2(88, 58), UITheme.INK, 0.25], [Vector2(9, 15), Vector2(82, 52), c["primary"], 0.25],
			[Vector2(12, 66), Vector2(76, 24), UITheme.INK, 0.4], [Vector2(14, 68), Vector2(72, 20), c["secondary"], 0.4]]:
		var s := ShaderRect.new(BRUSH_BAND)
		s.position = spec[0]
		s.size = spec[1]
		s.set_param(&"paint", spec[2])
		s.set_param(&"seed", 1.3 + i * 2.1 + (0.0 if strokes.size() < 2 else 7.0))
		s.set_param(&"taper", spec[3])
		s.set_param(&"progress", 1.0)
		chip.add_child(s)
		strokes.append(s)
	_strokes.append(strokes)
	var name_l := UITheme.make_label(str(c["name"]), UITheme.FONT_UI_BLACK, 15, UITheme.INK)
	name_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_l.position = Vector2(0, 92)
	name_l.size = Vector2(CHIP.x, 20)
	chip.add_child(name_l)
	var jp := UITheme.make_label(str(KANJI.get(str(c["name"]), "")), UITheme.FONT_BRUSH, 17, Color(UITheme.INK, 0.55))
	jp.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	jp.position = Vector2(0, 111)
	jp.size = Vector2(CHIP.x, 20)
	chip.add_child(jp)
	# Hanko tick on the chosen chip.
	var tick := Control.new()
	tick.name = "Tick"
	tick.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tick.position = Vector2(CHIP.x - 26, -8)
	tick.size = Vector2(32, 32)
	tick.pivot_offset = tick.size * 0.5
	tick.draw.connect(func() -> void:
		var ctr := tick.size * 0.5
		tick.draw_circle(ctr, 13.0, UITheme.PAPER)
		tick.draw_circle(ctr, 11.0, UITheme.VERMILION)
		tick.draw_polyline(PackedVector2Array([ctr + Vector2(-5, 0), ctr + Vector2(-1.5, 4), ctr + Vector2(5.5, -4)]), UITheme.PAPER, 2.6, true))
	chip.add_child(tick)


## Picks livery `i` without emitting (sync from settings).
func set_selected(i: int) -> void:
	selected = clampi(i, 0, _colors.size() - 1)


func _choose(i: int) -> void:
	i = clampi(i, 0, _colors.size() - 1)
	if i == selected:
		return
	selected = i
	UIApi.ui_sound(&"toggle")
	_repaint(i)
	changed.emit(i)


## The chosen chip paints its strokes in again: body first, then the stripe.
func _repaint(i: int) -> void:
	UIMotion.kill(_paint_tween)
	var strokes: Array = _strokes[i]
	for s: ShaderRect in strokes:
		s.set_param(&"progress", 0.0)
	_paint_tween = UIMotion.tween(self)
	_paint_tween.set_parallel(true)
	for k in strokes.size():
		var s: ShaderRect = strokes[k]
		_paint_tween.tween_method(s.param_setter(&"progress"), 0.0, 1.0, 0.34).set_delay(0.0 if k < 2 else 0.14) \
				.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func _gui_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_left", true):
		_choose(selected - 1)
		accept_event()
	elif event.is_action_pressed("ui_right", true):
		_choose(selected + 1)
		accept_event()
	elif event is InputEventMouseMotion:
		_hover = _index_at((event as InputEventMouseMotion).position.x)
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			var idx := _index_at(mb.position.x)
			if idx >= 0:
				_choose(idx)
			accept_event()


func _index_at(x: float) -> int:
	var i := int(floor(x / (CHIP.x + GAP)))
	if i < 0 or i >= _colors.size() or x - i * (CHIP.x + GAP) > CHIP.x:
		return -1
	return i


func _process(delta: float) -> void:
	var d := minf(UIMotion.real_delta(delta), 0.05)
	_time += d
	_focus_t = lerpf(_focus_t, 1.0 if has_focus() else 0.0, UIMotion.damp(14.0, d))
	for i in _chips.size():
		var target := 1.0 if i == selected else (0.35 if i == _hover else 0.0)
		_lift[i] = lerpf(_lift[i], target, UIMotion.damp(14.0, d))
		var e := UIMotion.out_cubic(_lift[i])
		var chip := _chips[i]
		chip.position.y = LIFT - LIFT * e
		chip.modulate = Color(1, 1, 1, lerpf(0.8, 1.0, e))
		var tick := chip.get_node(^"Tick") as Control
		var on := 1.0 if i == selected else 0.0
		tick.scale = Vector2.ONE * lerpf(tick.scale.x, on, UIMotion.damp(18.0, d))
		tick.visible = tick.scale.x > 0.02
	var sel := _chips[selected]
	_outline.position = sel.position
	_outline.size = sel.size
	_outline.queue_redraw()


func _draw_outline() -> void:
	var a := UIMotion.out_cubic(_focus_t)
	if a < 0.01:
		return
	var breathe := 0.5 + 0.5 * sin(_time * 3.2)
	var r := Rect2(Vector2.ZERO, _outline.size).grow(FOCUS_GROW)
	_sb_glow.border_color = Color(UITheme.SAKURA, (0.14 + 0.1 * breathe) * a)
	_outline.draw_style_box(_sb_glow, r.grow(4.0))
	_sb_line.border_color = Color(UITheme.SAKURA, 0.95 * a)
	_outline.draw_style_box(_sb_line, r)
