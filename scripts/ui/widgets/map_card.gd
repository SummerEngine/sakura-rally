extends Button
## Map card for the Time Attack picker: the map's real top-down render
## (assets/ui/maps/<id>_top.png) with its route drawn over it, names, tagline, best time.
## Focus / hover lifts the card, zooms the map, redraws the route along its length and loops a
## small car around it. The card draws its own sakura focus outline on the lifted card (same
## transform, same corner radius), so the global FocusRing skips it.

const UITheme := preload("res://scripts/ui/ui_theme.gd")
const UIMotion := preload("res://scripts/ui/ui_motion.gd")
const UIApi := preload("res://scripts/ui/ui_api.gd")
const PaperCard := preload("res://scripts/ui/widgets/paper_card.gd")
const RouteOverlay := preload("res://scripts/ui/widgets/route_overlay.gd")
const MAP_IMAGE := preload("res://shaders/ui/map_image.gdshader")

const CARD_SIZE := Vector2(452, 428)
const PREVIEW_SIZE := Vector2(452, 260)
const RADIUS := 26.0
const LIFT := 14.0
const FOCUS_GROW := 7.0
## Route draw-on after focus (seconds, out-expo), then one marker lap takes LAP_TIME.
const DRAW_TIME := 0.9
const LAP_TIME := 7.5
const SEASON_CHIP := {
	"spring": "SPRING  ·  NOON",
	"autumn": "AUTUMN  ·  GOLDEN HOUR",
	"summer": "SUMMER  ·  AFTERNOON",
}

var map: Dictionary = {}
var accent := UITheme.SAKURA

var _lift := Control.new()
var _card: PaperCard
var _image := ColorRect.new()
var _image_mat := ShaderMaterial.new()
var _route: RouteOverlay
var _outline := Control.new()
var _best: Label
var _medal_dot: Control
var _drive: Label
var _watermark: Label
var _focus_t := 0.0
var _press_t := 0.0
var _time := 0.0
var _route_time := -1.0 ## seconds since focus (drives the draw-on and the marker), < 0 = resting
var _sb_line := StyleBoxFlat.new()
var _sb_glow := StyleBoxFlat.new()


func setup(map_data: Dictionary) -> void:
	map = map_data
	accent = UITheme.season_accent(str(map.get("season", "spring")))


func _ready() -> void:
	var empty := StyleBoxEmpty.new()
	for s in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		add_theme_stylebox_override(s, empty)
	focus_mode = Control.FOCUS_ALL
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	custom_minimum_size = CARD_SIZE
	set_meta(&"no_focus_ring", true)
	mouse_entered.connect(func() -> void: grab_focus())
	focus_entered.connect(_on_focus_entered)
	button_down.connect(func() -> void: _press_t = 1.0)

	_lift.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_lift.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_lift)

	_card = PaperCard.new()
	_card.padding = Vector4.ZERO
	_card.radius = RADIUS
	_card.paper_alpha = 0.9
	_card.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_lift.add_child(_card)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_child(col)

	var id := str(map.get("id", ""))
	_image.custom_minimum_size = Vector2(0, PREVIEW_SIZE.y)
	_image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_image.color = Color(accent.lightened(0.7), 1.0)
	var tex_path := "res://assets/ui/maps/%s_top.png" % id
	if ResourceLoader.exists(tex_path):
		_image_mat.shader = MAP_IMAGE
		_image_mat.set_shader_parameter("image", load(tex_path))
		_image_mat.set_shader_parameter("radius", RADIUS)
		_image.material = _image_mat
		_image.resized.connect(func() -> void: _image_mat.set_shader_parameter("rect_size", _image.size))
	col.add_child(_image)

	_route = RouteOverlay.new()
	_route.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if _route.load_route(id):
		_image.add_child(_route)
	else:
		_route.free()
		_route = null

	var chip := _chip(str(SEASON_CHIP.get(str(map.get("season", "spring")), "")), accent.darkened(0.1))
	chip.position = Vector2(18, 16)
	_image.add_child(chip)
	if _route != null:
		_image.add_child(_legend())

	var body := MarginContainer.new()
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_theme_constant_override("margin_left", 28)
	body.add_theme_constant_override("margin_right", 26)
	body.add_theme_constant_override("margin_top", 16)
	body.add_theme_constant_override("margin_bottom", 18)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(body)
	var v := VBoxContainer.new()
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_theme_constant_override("separation", 4)
	body.add_child(v)

	var name_row := HBoxContainer.new()
	name_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_row.add_theme_constant_override("separation", 12)
	v.add_child(name_row)
	var name_l := UITheme.make_label(str(map.get("name", "")), UITheme.FONT_TITLE, 30, UITheme.INK)
	name_row.add_child(name_l)
	var jp := UITheme.make_label(str(map.get("name_jp", "")), UITheme.FONT_BRUSH, 28, accent)
	jp.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	name_row.add_child(jp)

	var tag := UITheme.make_label(str(map.get("tagline", "")), UITheme.FONT_UI_MEDIUM, 17, UITheme.INK_SOFT)
	tag.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tag.custom_minimum_size = Vector2(380, 0)
	v.add_child(tag)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(spacer)

	var foot := HBoxContainer.new()
	foot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	foot.add_theme_constant_override("separation", 8)
	v.add_child(foot)
	_medal_dot = Control.new()
	_medal_dot.custom_minimum_size = Vector2(14, 14)
	_medal_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_medal_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_medal_dot.draw.connect(_draw_medal_dot)
	foot.add_child(_medal_dot)
	_best = UITheme.make_label("", UITheme.FONT_UI_BOLD, 16, UITheme.INK)
	_best.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(_best)
	_drive = UITheme.make_label("Drive  ›", UITheme.FONT_UI_BLACK, 17, accent)
	foot.add_child(_drive)

	_watermark = UITheme.make_label(str(map.get("name_jp", "")).substr(0, 1), UITheme.FONT_BRUSH, 190, Color(accent, 0.1))
	_watermark.position = Vector2(CARD_SIZE.x - 196, PREVIEW_SIZE.y - 6)
	# Inside the card, behind the text: paper < watermark < content.
	var clip := Control.new()
	clip.clip_contents = true
	clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip.add_child(_watermark)
	_card.add_child(clip)
	_card.move_child(clip, 0)

	# Focus outline: a child of the lifted layer, so it moves exactly with the card.
	for sb: StyleBoxFlat in [_sb_line, _sb_glow]:
		sb.bg_color = Color(0, 0, 0, 0)
		sb.draw_center = false
		sb.corner_detail = 12
		sb.anti_aliasing_size = 1.0
	_sb_line.set_border_width_all(3)
	_sb_line.set_corner_radius_all(int(RADIUS + FOCUS_GROW))
	_sb_glow.set_border_width_all(7)
	_sb_glow.set_corner_radius_all(int(RADIUS + FOCUS_GROW + 4.0))
	_outline.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_outline.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_outline.draw.connect(_draw_outline)
	_lift.add_child(_outline)
	refresh()


func _chip(text: String, color: Color) -> PanelContainer:
	var chip := _chip_panel()
	chip.add_child(UITheme.make_label(text, UITheme.tracked(UITheme.FONT_UI_BLACK, 1), 13, color))
	return chip


func _chip_panel() -> PanelContainer:
	var chip := PanelContainer.new()
	var sb := UITheme.pill(Color(UITheme.PAPER, 0.92), 0.12)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 5
	sb.content_margin_bottom = 5
	chip.add_theme_stylebox_override("panel", sb)
	chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return chip


## Bottom-right chip: route length and a swatch per surface the route uses.
func _legend() -> PanelContainer:
	var chip := _chip_panel()
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip.add_child(row)
	var km := "%.1f km" % (_route.length_m / 1000.0)
	row.add_child(UITheme.make_label(km, UITheme.tracked(UITheme.FONT_UI_BLACK, 1), 13, UITheme.INK))
	for s: String in _route.surfaces:
		var sw := Control.new()
		sw.custom_minimum_size = Vector2(18, 16)
		sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		sw.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var c: Color = RouteOverlay.SURFACE_COLORS[s]
		sw.draw.connect(func() -> void:
			var y := sw.size.y * 0.5
			sw.draw_line(Vector2(1, y), Vector2(sw.size.x - 1, y), UITheme.INK, 7.0, true)
			sw.draw_line(Vector2(2, y), Vector2(sw.size.x - 2, y), c, 3.6, true))
		row.add_child(sw)
		row.add_child(UITheme.make_label(s.to_upper(), UITheme.tracked(UITheme.FONT_UI_BLACK, 1), 12, UITheme.INK_SOFT))
	chip.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	chip.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	chip.grow_vertical = Control.GROW_DIRECTION_BEGIN
	chip.offset_right = -14
	chip.offset_bottom = -12
	chip.offset_left = -14
	chip.offset_top = -12
	return chip


func refresh() -> void:
	if _best == null:
		return
	var id := str(map.get("id", ""))
	var best: float = UIApi.game().best_time(id)
	if is_inf(best):
		_best.text = "No time set yet"
		_best.label_settings.font_color = UITheme.INK_SOFT
	else:
		_best.text = "BEST  %s" % UIApi.game().format_time(best)
		_best.label_settings.font_color = UITheme.INK
	_medal_dot.set_meta(&"medal", UIApi.game().medal_for(id, best) if not is_inf(best) else "")
	_medal_dot.queue_redraw()


func _draw_medal_dot() -> void:
	var medal := str(_medal_dot.get_meta(&"medal", ""))
	var c := _medal_dot.size * 0.5
	if medal == "":
		_medal_dot.draw_arc(c, 5.5, 0, TAU, 24, Color(UITheme.INK, 0.3), 2.0, true)
	else:
		_medal_dot.draw_circle(c, 7.0, UITheme.medal_color(medal))
		_medal_dot.draw_circle(c + Vector2(-2, -2), 2.2, Color(1, 1, 1, 0.6))


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


func _on_focus_entered() -> void:
	UIApi.ui_sound(&"hover")
	_route_time = 0.0


func _process(delta: float) -> void:
	var d := UIMotion.real_delta(delta)
	_time += d
	var focused := has_focus()
	var target := 1.0 if focused else 0.0
	_focus_t = lerpf(_focus_t, target, UIMotion.damp(12.0, d))
	_press_t = maxf(_press_t - d * 4.0, 0.0)
	var e := UIMotion.out_cubic(_focus_t)
	_lift.position = Vector2(0, -LIFT * e + 6.0 * UIMotion.out_cubic(_press_t))
	_card.lift = e
	_card.paper_alpha = lerpf(0.86, 0.95, e)
	var zoom := 1.0 + 0.045 * e
	_image_mat.set_shader_parameter("zoom", zoom)
	_image_mat.set_shader_parameter("saturation", lerpf(0.82, 1.0, e))
	_drive.modulate.a = e
	_watermark.modulate.a = 0.7 + 0.3 * e
	if _focus_t > 0.002:
		_outline.queue_redraw()
	if _route == null:
		return
	if absf(_route.emphasis - e) > 0.001:
		_route.zoom = zoom
		_route.emphasis = e
	if focused:
		_route_time += d
		_route.reveal = UIMotion.out_expo(_route_time / DRAW_TIME)
		var lap := (_route_time - DRAW_TIME * 0.7) / LAP_TIME
		_route.marker = fposmod(lap, 1.0) if lap >= 0.0 else -1.0
	elif _route_time >= 0.0:
		_route_time = -1.0
		_route.reveal = 1.0
		_route.marker = -1.0
