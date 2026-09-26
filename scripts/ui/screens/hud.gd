extends Control
## Driving HUD. Top-left: map card with stage progress (time trial) or odometer (free roam).
## Top-centre: stage timer with split popups. Bottom-right: tachometer. Centre: notices.
## Reads Game.player_car / Game.session every frame (both may be null).

const UITheme := preload("res://scripts/ui/ui_theme.gd")
const UIMotion := preload("res://scripts/ui/ui_motion.gd")
const UIApi := preload("res://scripts/ui/ui_api.gd")
const PaperCard := preload("res://scripts/ui/widgets/paper_card.gd")
const KineticText := preload("res://scripts/ui/widgets/kinetic_text.gd")
const Tachometer := preload("res://scripts/ui/widgets/tachometer.gd")
const StageProgress := preload("res://scripts/ui/widgets/stage_progress.gd")

const EDGE := Vector2(56, 44)
const SPLIT_HOLD := 2.6
const NOTICE_HOLD := 1.8

var shown := false
var free_roam := false

var _accent := UITheme.SAKURA
var _tl := Control.new()
var _tl_inner := Control.new()
var _map_card: PaperCard
var _map_kanji: Label
var _map_name: Label
var _mode_label: Label
var _progress: StageProgress
var _odo_row := HBoxContainer.new()
var _odo_value: Label

var _tc := Control.new()
var _tc_inner := Control.new()
var _timer_card: PaperCard
var _timer: KineticText
var _best_label: Label
var _timer_pulse := 1.0
var _timer_tint := UITheme.INK

var _split := Control.new()
var _split_card: PaperCard
var _split_cp: Label
var _split_time: Label
var _split_delta: Label
var _split_tween: Tween

var _br := Control.new()
var _br_inner := Control.new()
var _tach: Tachometer

var _notice := Control.new()
var _notice_card: PaperCard
var _notice_label: Label
var _notice_tween: Tween

var _enter_tween: Tween
var _odometer_m := 0.0
var _checkpoint_total := 0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_top_left()
	_build_top_centre()
	_build_tach()
	_build_notice()
	visible = false


func _holder(h: Control, inner: Control, preset: Control.LayoutPreset) -> void:
	h.set_anchors_and_offsets_preset(preset)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(h)
	inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(inner)


func _build_top_left() -> void:
	_holder(_tl, _tl_inner, Control.PRESET_TOP_LEFT)
	_tl.position = EDGE
	_map_card = PaperCard.new()
	_map_card.padding = Vector4(26, 18, 28, 16)
	_map_card.radius = 20.0
	_map_card.paper_alpha = 0.84
	_map_card.set_shadow(0.16, 26.0, Vector2(0, 8))
	_tl_inner.add_child(_map_card)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_map_card.add_child(col)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(head)
	_map_kanji = UITheme.make_label("", UITheme.FONT_BRUSH, 34, _accent)
	_map_kanji.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(_map_kanji)
	_map_name = UITheme.make_label("", UITheme.tracked(UITheme.FONT_TITLE, 2), 24, UITheme.INK)
	_map_name.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(_map_name)
	_mode_label = UITheme.make_label("", UITheme.tracked(UITheme.FONT_UI_BLACK, 3), 12, Color(UITheme.INK, 0.5))
	_mode_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_mode_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mode_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	head.add_child(_mode_label)
	_progress = StageProgress.new()
	col.add_child(_progress)
	_odo_row.add_theme_constant_override("separation", 10)
	_odo_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_odo_row)
	var odo_caption := UITheme.make_label("ODO", UITheme.tracked(UITheme.FONT_UI_BLACK, 3), 13, Color(UITheme.INK, 0.5))
	odo_caption.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_odo_row.add_child(odo_caption)
	_odo_value = UITheme.make_label("0.00 km", UITheme.FONT_TITLE, 26, UITheme.INK)
	_odo_row.add_child(_odo_value)


func _build_top_centre() -> void:
	_holder(_tc, _tc_inner, Control.PRESET_CENTER_TOP)
	_tc.position.y = EDGE.y - 4.0
	_timer_card = PaperCard.new()
	_timer_card.padding = Vector4(40, 10, 40, 12)
	_timer_card.radius = 30.0
	_timer_card.paper_alpha = 0.86
	_timer_card.set_shadow(0.16, 26.0, Vector2(0, 8))
	_tc_inner.add_child(_timer_card)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", -4)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_timer_card.add_child(col)
	_timer = KineticText.new()
	_timer.font = UITheme.FONT_TITLE
	_timer.font_size = 54
	_timer.mono_digits = true
	_timer.tracking = 1.0
	_timer.align = HORIZONTAL_ALIGNMENT_CENTER
	_timer.style = KineticText.Style.NONE
	_timer.text = "0:00.000"
	_timer.custom_minimum_size = Vector2(290, 70)
	col.add_child(_timer)
	_best_label = UITheme.make_label("", UITheme.tracked(UITheme.FONT_UI_BLACK, 2), 14, Color(UITheme.INK, 0.55))
	_best_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_best_label)

	_split.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tc_inner.add_child(_split)
	_split_card = PaperCard.new()
	_split_card.padding = Vector4(22, 10, 14, 10)
	_split_card.radius = 22.0
	_split_card.paper_alpha = 0.9
	_split_card.set_shadow(0.14, 20.0, Vector2(0, 6))
	_split.add_child(_split_card)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_split_card.add_child(row)
	_split_cp = UITheme.make_label("", UITheme.tracked(UITheme.FONT_UI_BLACK, 2), 14, Color(UITheme.INK, 0.55))
	_split_cp.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_split_cp)
	_split_time = UITheme.make_label("", UITheme.FONT_TITLE, 26, UITheme.INK)
	_split_time.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_split_time)
	var chip := PanelContainer.new()
	chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip.name = "DeltaChip"
	row.add_child(chip)
	_split_delta = UITheme.make_label("", UITheme.FONT_TITLE, 22, UITheme.WHITE)
	chip.add_child(_split_delta)
	_split.visible = false


func _build_tach() -> void:
	_holder(_br, _br_inner, Control.PRESET_BOTTOM_RIGHT)
	_tach = Tachometer.new()
	_tach.size = Vector2(380, 380)
	_tach.position = -_tach.size - Vector2(EDGE.x - 10.0, EDGE.y - 18.0)
	_br_inner.add_child(_tach)


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

## Configure for a session (map card, mode, checkpoints). Call before show_hud().
func setup(map_id: String, mode: String) -> void:
	var game := UIApi.game()
	var m: Dictionary = game.get_map(map_id)
	_accent = UITheme.season_accent(str(m.get("season", "spring")))
	free_roam = mode == str(game.MODE_FREE_ROAM)
	_map_kanji.text = str(m.get("name_jp", ""))
	_map_kanji.label_settings.font_color = _accent
	_map_name.text = str(m.get("name", "")).to_upper()
	_mode_label.text = "FREE ROAM" if free_roam else "TIME TRIAL"
	_progress.visible = not free_roam
	_progress.accent = _accent
	_odo_row.visible = free_roam
	_tc.visible = not free_roam
	_odometer_m = 0.0
	_checkpoint_total = int(UIApi.num(game.session, &"checkpoint_total", 0.0))
	_progress.reset(_checkpoint_total)
	var best: float = game.best_time(map_id)
	_best_label.text = "BEST  %s" % game.format_time(best) if not is_inf(best) else "FIRST RUN"
	_timer.text = game.format_time(0.0)
	_timer_tint = UITheme.INK
	_split.visible = false
	_notice.visible = false


func show_hud() -> void:
	if shown:
		return
	shown = true
	visible = true
	modulate.a = 1.0
	UIMotion.kill(_enter_tween)
	_enter_tween = UIMotion.tween(self)
	_enter_tween.set_parallel(true)
	var blocks := [[_tl_inner, Vector2(-60, 0), 0.0], [_tc_inner, Vector2(0, -50), 0.08], [_br_inner, Vector2(70, 40), 0.16]]
	for b: Array in blocks:
		var c: Control = b[0]
		c.position = b[1]
		c.modulate.a = 0.0
		_enter_tween.tween_property(c, "position", Vector2.ZERO, 0.7).set_delay(b[2]).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		_enter_tween.tween_property(c, "modulate:a", 1.0, 0.35).set_delay(b[2])


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
	var blocks := [[_tl_inner, Vector2(-50, 0)], [_tc_inner, Vector2(0, -40)], [_br_inner, Vector2(60, 30)]]
	for b: Array in blocks:
		var c: Control = b[0]
		_enter_tween.tween_property(c, "position", b[1], 0.35).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
		_enter_tween.tween_property(c, "modulate:a", 0.0, 0.3)
	_enter_tween.chain().tween_callback(hide)


# ---------------------------------------------------------------- events

func on_checkpoint(index: int, total: int, split_time: float, delta_to_best: float) -> void:
	var game := UIApi.game()
	_checkpoint_total = total
	if _progress.checkpoint_total != total:
		_progress.reset(total)
	_progress.mark_passed(index, UIApi.num(game.session, &"progress", float(index + 1) / float(total + 1)))
	UIApi.stinger(&"checkpoint")
	_split_cp.text = "CP %d / %d" % [index + 1, total]
	_split_time.text = game.format_time(split_time)
	var chip := _split_delta.get_parent() as PanelContainer
	var has_delta := not is_nan(delta_to_best)
	chip.visible = has_delta
	var tint := UITheme.INK
	if has_delta:
		tint = UITheme.MATCHA if delta_to_best < 0.0 else UITheme.VERMILION
		_split_delta.text = game.format_delta(delta_to_best)
		var sb := UITheme.pill(tint, 0.0)
		sb.content_margin_left = 14
		sb.content_margin_right = 14
		sb.content_margin_top = 2
		sb.content_margin_bottom = 4
		chip.add_theme_stylebox_override("panel", sb)
	_timer_pulse = 0.0
	_timer_tint = tint
	# Popup: drop in under the timer with overshoot, hold, float up and fade.
	UIMotion.kill(_split_tween)
	_split.visible = true
	_split_card.reset_size()
	var w := _split_card.get_combined_minimum_size().x
	var base := Vector2(-w * 0.5, _timer_card.size.y + 14.0)
	_split.position = base + Vector2(0, -26)
	_split.modulate.a = 0.0
	_split_card.scale = Vector2(0.9, 0.9)
	_split_card.pivot_offset = Vector2(w * 0.5, 24)
	_split_tween = UIMotion.tween(self)
	_split_tween.set_parallel(true)
	_split_tween.tween_property(_split, "position", base, 0.5).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_split_tween.tween_property(_split, "modulate:a", 1.0, 0.2)
	_split_tween.tween_property(_split_card, "scale", Vector2.ONE, 0.5).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_split_tween.chain().tween_interval(SPLIT_HOLD)
	_split_tween.chain().tween_property(_split, "position", base + Vector2(0, -10), 0.4).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_split_tween.parallel().tween_property(_split, "modulate:a", 0.0, 0.4)
	_split_tween.chain().tween_callback(_split.hide)


func on_notice(text: String) -> void:
	UIMotion.kill(_notice_tween)
	_notice_label.text = text
	_notice.visible = true
	_notice_card.reset_size()
	var w := _notice_card.get_combined_minimum_size().x
	var base := Vector2(-w * 0.5, 0.0)
	_notice_card.position = base + Vector2(0, 22)
	_notice_card.pivot_offset = Vector2(w * 0.5, 30)
	_notice_card.scale = Vector2(0.94, 0.94)
	_notice.modulate.a = 0.0
	_notice_tween = UIMotion.tween(self)
	_notice_tween.set_parallel(true)
	_notice_tween.tween_property(_notice_card, "position", base, 0.45).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_notice_tween.tween_property(_notice_card, "scale", Vector2.ONE, 0.45).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_notice_tween.tween_property(_notice, "modulate:a", 1.0, 0.2)
	_notice_tween.chain().tween_interval(NOTICE_HOLD)
	_notice_tween.chain().tween_property(_notice, "modulate:a", 0.0, 0.35)
	_notice_tween.parallel().tween_property(_notice_card, "position", base + Vector2(0, -12), 0.35).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_notice_tween.chain().tween_callback(_notice.hide)


# ---------------------------------------------------------------- per frame

func _process(delta: float) -> void:
	if not visible:
		return
	var d := UIMotion.real_delta(delta)
	var game := UIApi.game()
	if game == null:
		return
	var car: Object = game.player_car
	var session: Object = game.session
	var kmh := UIApi.num(car, &"speed_kmh")
	var gear_v: Variant = car.get("gear") if car != null and is_instance_valid(car) else 1
	var shifting_v: Variant = car.get("is_shifting") if car != null and is_instance_valid(car) else false
	_tach.update_values(UIApi.num(car, &"rpm", 900.0), UIApi.num(car, &"max_rpm", 7800.0),
		int(gear_v) if gear_v != null else 1, UIApi.speed_in_units(kmh), UIApi.unit_label(),
		bool(shifting_v) if shifting_v != null else false)

	_timer_card.position.x = -_timer_card.size.x * 0.5
	if free_roam:
		if not game.paused:
			_odometer_m += absf(kmh) / 3.6 * delta
		var mph := str(UIApi.setting("units")) == "mph"
		var dist := _odometer_m / (1609.344 if mph else 1000.0)
		_odo_value.text = "%.2f %s" % [dist, "mi" if mph else "km"]
	else:
		var elapsed := UIApi.num(session, &"elapsed")
		_timer.text = game.format_time(elapsed)
		_progress.progress = UIApi.num(session, &"progress")
		var total := int(UIApi.num(session, &"checkpoint_total", float(_checkpoint_total)))
		if total != _progress.checkpoint_total:
			_progress.reset(total)
			_checkpoint_total = total
		_timer_pulse = minf(_timer_pulse + d * 1.4, 1.0)
		var e := UIMotion.out_spring(_timer_pulse)
		var s := lerpf(1.12, 1.0, e)
		_timer.pivot_offset = _timer.size * 0.5
		_timer.scale = Vector2(s, s)
		_timer.color = _timer_tint.lerp(UITheme.INK, smoothstep(0.35, 1.0, _timer_pulse))
