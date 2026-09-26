extends Button
## Map selection card: painted preview (texture from the map's `preview` path when it exists,
## else a procedural painted landscape in the season's palette), names, tagline, best time.
## Focus / hover lifts the card, zooms the preview and reveals the "Drive" cue.

const UITheme := preload("res://scripts/ui/ui_theme.gd")
const UIMotion := preload("res://scripts/ui/ui_motion.gd")
const UIApi := preload("res://scripts/ui/ui_api.gd")
const PaperCard := preload("res://scripts/ui/widgets/paper_card.gd")
const PAINTED := preload("res://shaders/ui/painted_scene.gdshader")

const CARD_SIZE := Vector2(452, 356)
const PREVIEW_H := 196.0

var map: Dictionary = {}
var accent := UITheme.SAKURA

var _lift := Control.new()
var _card: PaperCard
var _preview := ColorRect.new()
var _preview_mat := ShaderMaterial.new()
var _best: Label
var _medal_dot: Control
var _drive: Label
var _watermark: Label
var _focus_t := 0.0
var _press_t := 0.0
var _time := 0.0


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
	set_meta(&"focus_radius", 32.0)
	set_meta(&"focus_grow", 7.0)
	mouse_entered.connect(func() -> void: grab_focus())
	focus_entered.connect(func() -> void: UIApi.ui_sound(&"hover"))
	button_down.connect(func() -> void: _press_t = 1.0)

	_lift.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_lift.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_lift)

	_card = PaperCard.new()
	_card.padding = Vector4.ZERO
	_card.paper_alpha = 0.9
	_card.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_lift.add_child(_card)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_child(col)

	_preview.custom_minimum_size = Vector2(0, PREVIEW_H)
	_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_preview_mat.shader = PAINTED
	_preview_mat.set_shader_parameter("radius", 26.0)
	_preview_mat.set_shader_parameter("corner_mask", Vector4(1, 1, 0, 0))
	_preview_mat.set_shader_parameter("autumn", 1.0 if map.get("season", "") == "autumn" else 0.0)
	_preview_mat.set_shader_parameter("time_scale", 0.6)
	var tex_path := str(map.get("preview", ""))
	if tex_path != "" and ResourceLoader.exists(tex_path):
		_preview_mat.set_shader_parameter("preview_tex", load(tex_path))
		_preview_mat.set_shader_parameter("use_texture", true)
	_preview.material = _preview_mat
	_preview.resized.connect(func() -> void: _preview_mat.set_shader_parameter("rect_size", _preview.size))
	col.add_child(_preview)

	var chip := PanelContainer.new()
	var chip_sb := UITheme.pill(Color(UITheme.PAPER, 0.92), 0.12)
	chip_sb.content_margin_left = 14
	chip_sb.content_margin_right = 14
	chip_sb.content_margin_top = 5
	chip_sb.content_margin_bottom = 5
	chip.add_theme_stylebox_override("panel", chip_sb)
	chip.position = Vector2(18, 16)
	chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var season_txt := "AUTUMN  ·  GOLDEN HOUR" if map.get("season", "") == "autumn" else "SPRING  ·  NOON"
	var chip_l := UITheme.make_label(season_txt, UITheme.tracked(UITheme.FONT_UI_BLACK, 1), 13, accent.darkened(0.1))
	chip.add_child(chip_l)
	_preview.add_child(chip)

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
	_watermark.position = Vector2(CARD_SIZE.x - 196, PREVIEW_H - 6)
	# Inside the card, behind the text: paper < watermark < content.
	var clip := Control.new()
	clip.clip_contents = true
	clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip.add_child(_watermark)
	_card.add_child(clip)
	_card.move_child(clip, 0)
	refresh()


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


func _process(delta: float) -> void:
	var d := UIMotion.real_delta(delta)
	_time += d
	var target := 1.0 if has_focus() else 0.0
	_focus_t = lerpf(_focus_t, target, UIMotion.damp(12.0, d))
	_press_t = maxf(_press_t - d * 4.0, 0.0)
	var e := UIMotion.out_cubic(_focus_t)
	_lift.position = Vector2(0, -14.0 * e + 6.0 * UIMotion.out_cubic(_press_t))
	_card.lift = e
	_card.paper_alpha = lerpf(0.86, 0.95, e)
	_preview_mat.set_shader_parameter("zoom", 1.0 + 0.06 * e)
	var mouse := get_local_mouse_position() / maxf(size.x, 1.0) - Vector2(0.5, 0.5)
	_preview_mat.set_shader_parameter("parallax", clampf(mouse.x, -0.6, 0.6) * e * 2.0 + sin(_time * 0.3) * 0.3)
	_drive.modulate.a = e
	_watermark.modulate.a = 0.7 + 0.3 * e
