extends Control
## Garage car strip: every car (Game.CARS entries with a scene) as a washi card in one row at the
## bottom of the screen - thumbnail (assets/ui/cars/<id>.png, tools/build/car_thumbs.gd), name and
## kanji. Fixed layout: the cards never move with the names. One focus stop: left / right pick
## (keys, d-pad, stick), a click picks directly, the pointer lifts the card under it. The chosen
## card lifts and gets a vermilion hanko tick; while the strip has focus a sakura outline hugs the
## chosen card (the global focus ring skips it), like the livery picker.

signal changed(index: int)

const UITheme := preload("res://scripts/ui/ui_theme.gd")
const UIMotion := preload("res://scripts/ui/ui_motion.gd")
const UIApi := preload("res://scripts/ui/ui_api.gd")

const THUMB_DIR := "res://assets/ui/cars/"
const CARD := Vector2(260, 178)
const THUMB := Vector2(232, 112)
const GAP := 18.0
const LIFT := 12.0
const RADIUS := 18
const FOCUS_GROW := 6.0

var selected := 0

var _cars: Array = []
var _cards: Array[Control] = []
var _lift := PackedFloat32Array()
var _hover := -1
var _time := 0.0
var _focus_t := 0.0
var _outline := Control.new()
var _sb_line := StyleBoxFlat.new()
var _sb_glow := StyleBoxFlat.new()


func setup(cars: Array, index: int) -> void:
	_cars = cars
	selected = clampi(index, 0, maxi(_cars.size() - 1, 0))


func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	set_meta(&"no_focus_ring", true)
	mouse_entered.connect(func() -> void: grab_focus())
	mouse_exited.connect(func() -> void: _hover = -1)
	focus_entered.connect(func() -> void: UIApi.ui_sound(&"hover"))
	custom_minimum_size = Vector2(maxf(_cars.size() * (CARD.x + GAP) - GAP, CARD.x), CARD.y + LIFT)
	size = custom_minimum_size
	_lift.resize(_cars.size())
	for i in _cars.size():
		_build_card(i)
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


func _build_card(i: int) -> void:
	var car: Dictionary = _cars[i]
	var card := Panel.new()
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.size = CARD
	card.position = Vector2(i * (CARD.x + GAP), LIFT)
	card.pivot_offset = CARD * 0.5
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(UITheme.PAPER, 0.94)
	sb.set_corner_radius_all(RADIUS)
	sb.corner_detail = 8
	sb.shadow_color = Color(UITheme.INK, 0.2)
	sb.shadow_size = 12
	sb.shadow_offset = Vector2(0, 5)
	sb.border_color = Color(UITheme.INK, 0.1)
	sb.set_border_width_all(1)
	sb.anti_aliasing_size = 1.0
	card.add_theme_stylebox_override("panel", sb)
	add_child(card)
	_cards.append(card)
	# A soft sakura wash behind the car, so the white bodies read on the paper.
	var wash := Panel.new()
	wash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wash.position = Vector2(10, 10)
	wash.size = Vector2(CARD.x - 20, THUMB.y + 8)
	var wsb := StyleBoxFlat.new()
	wsb.bg_color = Color(UITheme.SAKURA_PALE, 0.55)
	wsb.set_corner_radius_all(RADIUS - 6)
	wsb.corner_detail = 8
	wash.add_theme_stylebox_override("panel", wsb)
	card.add_child(wash)
	var path := "%s%s.png" % [THUMB_DIR, car.get("id", "")]
	if ResourceLoader.exists(path):
		var tex := TextureRect.new()
		tex.texture = load(path) as Texture2D
		tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex.position = Vector2((CARD.x - THUMB.x) * 0.5, 12)
		tex.size = THUMB
		card.add_child(tex)
	else:
		# No thumbnail rendered yet: the car's kanji stands in.
		var big := UITheme.make_label(str(car.get("name_jp", "")), UITheme.FONT_BRUSH, 64, Color(UITheme.INK, 0.35))
		big.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		big.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		big.position = wash.position
		big.size = wash.size
		card.add_child(big)
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 10)
	row.position = Vector2(0, THUMB.y + 22)
	row.size = Vector2(CARD.x, 40)
	card.add_child(row)
	var name_l := UITheme.make_label(str(car.get("name", "")), UITheme.FONT_TITLE, 26, UITheme.INK)
	name_l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(name_l)
	var jp := UITheme.make_label(str(car.get("name_jp", "")), UITheme.FONT_BRUSH, 26, UITheme.VERMILION)
	jp.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(jp)
	# Hanko tick on the chosen card.
	var tick := Control.new()
	tick.name = "Tick"
	tick.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tick.position = Vector2(CARD.x - 28, -10)
	tick.size = Vector2(34, 34)
	tick.pivot_offset = tick.size * 0.5
	tick.draw.connect(func() -> void:
		var ctr := tick.size * 0.5
		tick.draw_circle(ctr, 14.0, UITheme.PAPER)
		tick.draw_circle(ctr, 12.0, UITheme.VERMILION)
		tick.draw_polyline(PackedVector2Array([ctr + Vector2(-5.5, 0), ctr + Vector2(-1.5, 4.5), ctr + Vector2(6, -4.5)]), UITheme.PAPER, 2.8, true))
	card.add_child(tick)


## Shows car `i` as chosen without emitting (sync from settings).
func set_selected(i: int) -> void:
	selected = clampi(i, 0, maxi(_cars.size() - 1, 0))


func _choose(i: int) -> void:
	i = clampi(i, 0, _cars.size() - 1)
	if i == selected:
		return
	selected = i
	UIApi.ui_sound(&"toggle")
	changed.emit(i)


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
	var i := int(floor(x / (CARD.x + GAP)))
	if i < 0 or i >= _cars.size() or x - i * (CARD.x + GAP) > CARD.x:
		return -1
	return i


func _process(delta: float) -> void:
	if _cards.is_empty():
		return
	var d := minf(UIMotion.real_delta(delta), 0.05)
	_time += d
	_focus_t = lerpf(_focus_t, 1.0 if has_focus() else 0.0, UIMotion.damp(14.0, d))
	for i in _cards.size():
		var target := 1.0 if i == selected else (0.35 if i == _hover else 0.0)
		_lift[i] = lerpf(_lift[i], target, UIMotion.damp(14.0, d))
		var e := UIMotion.out_cubic(_lift[i])
		var card := _cards[i]
		card.position.y = LIFT - LIFT * e
		card.modulate = Color(1, 1, 1, lerpf(0.78, 1.0, e))
		var tick := card.get_node(^"Tick") as Control
		var on := 1.0 if i == selected else 0.0
		tick.scale = Vector2.ONE * lerpf(tick.scale.x, on, UIMotion.damp(18.0, d))
		tick.visible = tick.scale.x > 0.02
	var sel := _cards[selected]
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
