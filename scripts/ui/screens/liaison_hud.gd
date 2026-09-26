extends Control
## Calm HUD of a campaign liaison (Game.State.LIAISON): no timer. Top-left, a blue Japanese
## road direction sign to the next stage with the distance left and a strip map of the road;
## bottom-right, a small paper speed readout; centre, the same notice pill as the race HUD.
## Reads Game.player_car / Game.session (distance_left, progress) every frame.

const UITheme := preload("res://scripts/ui/ui_theme.gd")
const UIMotion := preload("res://scripts/ui/ui_motion.gd")
const UIApi := preload("res://scripts/ui/ui_api.gd")
const PaperCard := preload("res://scripts/ui/widgets/paper_card.gd")
const KineticText := preload("res://scripts/ui/widgets/kinetic_text.gd")

const EDGE := Vector2(56, 44)
const SIGN_BLUE := Color("1f5ea6")
const NOTICE_HOLD := 1.8

var shown := false

var _tl := Control.new()
var _sign := PanelContainer.new()
var _code: Label
var _dest_jp: Label
var _dest: Label
var _dist: KineticText
var _dist_unit: Label
var _strip := Control.new()
var _progress := 0.0

var _br := Control.new()
var _speed_card: PaperCard
var _speed: KineticText
var _unit: Label
var _gear: Label

var _notice := Control.new()
var _notice_card: PaperCard
var _notice_label: Label
var _notice_tween: Tween
var _enter_tween: Tween
var _last_dist_text := ""
var _last_speed := -1
var _last_gear := -99


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_sign()
	_build_speed()
	_build_notice()
	visible = false


func _build_sign() -> void:
	_tl.position = EDGE
	_tl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_tl)
	var sb := StyleBoxFlat.new()
	sb.bg_color = SIGN_BLUE
	sb.set_corner_radius_all(16)
	sb.corner_detail = 8
	sb.border_color = Color(1, 1, 1, 0.95)
	sb.set_border_width_all(4)
	sb.expand_margin_left = 6
	sb.expand_margin_right = 6
	sb.expand_margin_top = 6
	sb.expand_margin_bottom = 6
	sb.content_margin_left = 28
	sb.content_margin_right = 30
	sb.content_margin_top = 16
	sb.content_margin_bottom = 18
	sb.shadow_color = Color(UITheme.INK, 0.22)
	sb.shadow_size = 18
	sb.shadow_offset = Vector2(0, 8)
	sb.anti_aliasing_size = 1.2
	_sign.add_theme_stylebox_override("panel", sb)
	_sign.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tl.add_child(_sign)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sign.add_child(col)
	_code = UITheme.make_label("", UITheme.tracked(UITheme.FONT_UI_BLACK, 3), 13, Color(1, 1, 1, 0.75))
	col.add_child(_code)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(row)
	var arrow := Control.new()
	arrow.custom_minimum_size = Vector2(34, 52)
	arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	arrow.draw.connect(func() -> void:
		var c := arrow.size * 0.5
		arrow.draw_colored_polygon(PackedVector2Array([c + Vector2(0, -24), c + Vector2(16, -6), c + Vector2(5, -6),
				c + Vector2(5, 24), c + Vector2(-5, 24), c + Vector2(-5, -6), c + Vector2(-16, -6)]), UITheme.WHITE))
	row.add_child(arrow)
	var names := VBoxContainer.new()
	names.add_theme_constant_override("separation", -6)
	names.mouse_filter = Control.MOUSE_FILTER_IGNORE
	names.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(names)
	_dest_jp = UITheme.make_label("", UITheme.FONT_UI_BLACK, 34, UITheme.WHITE)
	names.add_child(_dest_jp)
	_dest = UITheme.make_label("", UITheme.tracked(UITheme.FONT_UI_BOLD, 1), 18, Color(1, 1, 1, 0.9))
	names.add_child(_dest)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(26, 0)
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(gap)
	var drow := HBoxContainer.new()
	drow.add_theme_constant_override("separation", 6)
	drow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	drow.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(drow)
	_dist = KineticText.new()
	_dist.font = UITheme.FONT_TITLE
	_dist.font_size = 40
	_dist.mono_digits = true
	_dist.color = UITheme.WHITE
	_dist.style = KineticText.Style.NONE
	_dist.align = HORIZONTAL_ALIGNMENT_RIGHT
	_dist.custom_minimum_size = Vector2(96, 52)
	drow.add_child(_dist)
	_dist_unit = UITheme.make_label("km", UITheme.FONT_UI_BLACK, 18, Color(1, 1, 1, 0.85))
	_dist_unit.size_flags_vertical = Control.SIZE_SHRINK_END
	drow.add_child(_dist_unit)
	# Strip map: the road from start to arrival with the car on it.
	_strip.custom_minimum_size = Vector2(0, 26)
	_strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_strip.draw.connect(_draw_strip)
	col.add_child(_strip)


func _build_speed() -> void:
	_br.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_br.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_br)
	_speed_card = PaperCard.new()
	_speed_card.padding = Vector4(30, 10, 28, 12)
	_speed_card.radius = 30.0
	_speed_card.paper_alpha = 0.86
	_speed_card.set_shadow(0.16, 26.0, Vector2(0, 8))
	_br.add_child(_speed_card)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_speed_card.add_child(row)
	# A plain Control of fixed size: KineticText resizes its minimum to the text, which would
	# grow the card past the screen edge as the digits change.
	var box := Control.new()
	box.custom_minimum_size = Vector2(124, 74)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(box)
	_speed = KineticText.new()
	_speed.font = UITheme.FONT_TITLE
	_speed.font_size = 58
	_speed.mono_digits = true
	_speed.align = HORIZONTAL_ALIGNMENT_RIGHT
	_speed.style = KineticText.Style.NONE
	_speed.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_speed.text = "0"
	box.add_child(_speed)
	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", -2)
	right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	right.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(right)
	_unit = UITheme.make_label("km/h", UITheme.tracked(UITheme.FONT_UI_BLACK, 2), 15, Color(UITheme.INK, 0.6))
	right.add_child(_unit)
	_gear = UITheme.make_label("1", UITheme.FONT_TITLE, 24, UITheme.VERMILION)
	right.add_child(_gear)


func _build_notice() -> void:
	_notice.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_notice.position.y = 290.0
	_notice.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_notice)
	_notice_card = PaperCard.new()
	_notice_card.padding = Vector4(34, 12, 34, 14)
	_notice_card.radius = 26.0
	_notice_card.paper_alpha = 0.9
	_notice.add_child(_notice_card)
	_notice_label = UITheme.make_label("", UITheme.FONT_UI_BLACK, 26, UITheme.INK)
	_notice_card.add_child(_notice_label)
	_notice.visible = false


# ---------------------------------------------------------------- lifecycle

## Configure for the liaison leg (Game.campaign_current_leg()) heading to the leg after it.
func setup() -> void:
	var game := UIApi.game()
	var legs: Array = game.CAMPAIGN
	var i: int = game.campaign_leg
	var leg: Dictionary = legs[clampi(i, 0, legs.size() - 1)]
	var dest: Dictionary = legs[mini(i + 1, legs.size() - 1)]
	_code.text = "%s  ·  %s  ·  NEXT %s" % [leg["code"], str(leg["title"]).to_upper(), dest["code"]]
	_dest_jp.text = str(dest["title_jp"])
	_dest.text = str(dest["title"])
	_last_dist_text = ""
	_last_speed = -1
	_progress = 0.0
	_notice.visible = false
	_sign.reset_size()


func show_hud() -> void:
	if shown:
		return
	shown = true
	visible = true
	modulate.a = 1.0
	UIMotion.kill(_enter_tween)
	_enter_tween = UIMotion.tween(self)
	_enter_tween.set_parallel(true)
	# The sign swings in from its top edge like a board on a post; the speed card rises.
	_sign.pivot_offset = Vector2(_sign.size.x * 0.5, 0.0)
	_sign.rotation = -0.18
	_sign.scale = Vector2(0.92, 0.92)
	_tl.modulate.a = 0.0
	_enter_tween.tween_property(_tl, "modulate:a", 1.0, 0.3)
	_enter_tween.tween_property(_sign, "rotation", 0.0, 0.9).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	_enter_tween.tween_property(_sign, "scale", Vector2.ONE, 0.5).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_speed_card.reset_size()
	var base := -_speed_card.get_combined_minimum_size() - Vector2(EDGE.x, EDGE.y)
	_speed_card.position = base + Vector2(0, 50)
	_speed_card.modulate.a = 0.0
	_enter_tween.tween_property(_speed_card, "position", base, 0.7).set_delay(0.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_enter_tween.tween_property(_speed_card, "modulate:a", 1.0, 0.35).set_delay(0.12)


func hide_hud(instant: bool = false) -> void:
	if not shown:
		return
	shown = false
	UIMotion.kill(_enter_tween)
	if instant:
		visible = false
		return
	_enter_tween = UIMotion.tween(self)
	_enter_tween.set_parallel(true)
	_enter_tween.tween_property(_tl, "modulate:a", 0.0, 0.3)
	_enter_tween.tween_property(_sign, "rotation", -0.12, 0.35).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_enter_tween.tween_property(_speed_card, "modulate:a", 0.0, 0.3)
	_enter_tween.tween_property(_speed_card, "position:y", _speed_card.position.y + 40.0, 0.35).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_enter_tween.chain().tween_callback(hide)


func on_notice(text: String) -> void:
	UIMotion.kill(_notice_tween)
	_notice_label.text = text
	_notice.visible = true
	_notice_card.reset_size()
	var w := _notice_card.get_combined_minimum_size().x
	var base := Vector2(-w * 0.5, 0.0)
	_notice_card.position = base + Vector2(0, 22)
	_notice.modulate.a = 0.0
	_notice_tween = UIMotion.tween(self)
	_notice_tween.set_parallel(true)
	_notice_tween.tween_property(_notice_card, "position", base, 0.45).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_notice_tween.tween_property(_notice, "modulate:a", 1.0, 0.2)
	_notice_tween.chain().tween_interval(NOTICE_HOLD)
	_notice_tween.chain().tween_property(_notice, "modulate:a", 0.0, 0.35)
	_notice_tween.chain().tween_callback(_notice.hide)


# ---------------------------------------------------------------- per frame

func _process(_delta: float) -> void:
	if not visible:
		return
	var game := UIApi.game()
	var car: Object = game.player_car
	var session: Object = game.session
	var kmh := absf(UIApi.num(car, &"speed_kmh"))
	var speed := roundi(UIApi.speed_in_units(kmh))
	var gear := int(UIApi.num(car, &"gear", 1.0))
	if speed != _last_speed or gear != _last_gear:
		_last_speed = speed
		_last_gear = gear
		_speed.text = str(speed)
		_unit.text = UIApi.unit_label()
		_gear.text = "R" if gear < 0 else ("N" if gear == 0 else str(gear))
	var left := maxf(UIApi.num(session, &"distance_left"), 0.0)
	var mph := str(UIApi.setting("units")) == "mph"
	var dist := left / (1609.344 if mph else 1000.0)
	var txt := "%.1f" % dist
	if txt != _last_dist_text:
		_last_dist_text = txt
		_dist.text = txt
		_dist_unit.text = "mi" if mph else "km"
	var p := UIApi.num(session, &"progress")
	if absf(p - _progress) > 0.0005:
		_progress = p
		_strip.queue_redraw()


func _draw_strip() -> void:
	var w := _strip.size.x
	var y := _strip.size.y * 0.55
	var white := Color(1, 1, 1, 0.9)
	var x0 := 6.0
	var x1 := w - 14.0
	var x := lerpf(x0, x1, _progress)
	# Faint road ahead, solid behind the car.
	_strip.draw_line(Vector2(x0, y), Vector2(x1, y), Color(1, 1, 1, 0.35), 3.0, true)
	_strip.draw_line(Vector2(x0, y), Vector2(x, y), white, 4.0, true)
	_strip.draw_circle(Vector2(x0, y), 4.0, white)
	# Time-control flag at the end.
	_strip.draw_line(Vector2(x1, y), Vector2(x1, y - 16.0), white, 2.0, true)
	_strip.draw_colored_polygon(PackedVector2Array([Vector2(x1, y - 16.0), Vector2(x1 + 11.0, y - 12.0), Vector2(x1, y - 8.0)]), UITheme.GOLD)
	_strip.draw_circle(Vector2(x, y), 7.0, UITheme.GOLD)
	_strip.draw_circle(Vector2(x, y), 7.0, SIGN_BLUE.darkened(0.3), false, 2.0, true)
