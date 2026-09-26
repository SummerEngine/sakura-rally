extends Control
## Finish sequence + results. `show_result(result, split_deltas)` plays:
##  1. "FINISH" slammed over a vermilion brush swash, 完走 painted beneath, the time counting
##     up to the final value with a soft flash;
##  2. the banner lifts away and the results card slides in from the right with staggered rows
##     (time, best, delta, top speed, splits), a hanko medal STAMP (screen shake + petal burst)
##     and a "NEW RECORD 新記録" ribbon; buttons Retry / Next map / Menu. A campaign stage
##     adds the rally standing and swaps the buttons for Continue / Retry stage / Quit to title.

signal shake_requested(strength: float)

const UITheme := preload("res://scripts/ui/ui_theme.gd")
const UIMotion := preload("res://scripts/ui/ui_motion.gd")
const UIApi := preload("res://scripts/ui/ui_api.gd")
const PaperCard := preload("res://scripts/ui/widgets/paper_card.gd")
const KineticText := preload("res://scripts/ui/widgets/kinetic_text.gd")
const BrushKanji := preload("res://scripts/ui/widgets/brush_kanji.gd")
const Hanko := preload("res://scripts/ui/widgets/hanko.gd")
const InkButton := preload("res://scripts/ui/widgets/ink_button.gd")
const PetalField := preload("res://scripts/ui/widgets/petal_field.gd")
const ShaderRect := preload("res://scripts/ui/widgets/shader_rect.gd")
const BRUSH_BAND := preload("res://shaders/ui/brush_band.gdshader")

const CARD_W := 640.0
const COUNT_UP := 1.1

var shown := false
var result: Dictionary = {}

var _banner := Control.new()
var _swash: ShaderRect
var _finish: KineticText
var _finish_kanji: BrushKanji
var _count_label: KineticText
var _flash := ColorRect.new()

var _card_holder := Control.new()
var _card: PaperCard
var _rows: Array[Control] = []
var _map_kanji: Label
var _map_name: Label
var _kind_label: Label
var _time_big: KineticText
var _best_value: Label
var _delta_value: Label
var _speed_value: Label
var _standing_value: Label
var _splits_head: Label
var _splits_box := GridContainer.new()
var _split_deltas: Array = []
var _medal_hint: Label
var _record := PanelContainer.new()
var _hanko: Hanko
var _buttons := HBoxContainer.new()
var _continue: Button
var _retry: Button
var _next: Button
var _menu: Button
var _petals: PetalField

var _tween: Tween
var _count_t := -1.0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_banner()
	_build_card()
	_petals = PetalField.new()
	_petals.ambient_count = 0
	add_child(_petals)
	_flash.color = Color(1, 0.98, 0.95, 0.0)
	_flash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_flash)
	visible = false


# ---------------------------------------------------------------- build

func _build_banner() -> void:
	_banner.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_banner)
	_swash = ShaderRect.new(BRUSH_BAND)
	_swash.size = Vector2(1180, 230)
	_swash.set_param("paint", UITheme.VERMILION)
	_banner.add_child(_swash)
	_finish = KineticText.new()
	_finish.font = UITheme.FONT_TITLE
	_finish.font_size = 150
	_finish.tracking = 14.0
	_finish.color = UITheme.WHITE
	_finish.shadow = Color(UITheme.INK, 0.3)
	_finish.shadow_offset = Vector2(0, 7)
	_finish.style = KineticText.Style.SLAM
	_finish.stagger = 0.05
	_finish.char_duration = 0.34
	_finish.stepped_fps = 24.0
	_finish.distance = 70.0
	_finish.align = HORIZONTAL_ALIGNMENT_CENTER
	_finish.text = "FINISH"
	_finish.size = Vector2(1200, 200)
	_banner.add_child(_finish)
	_finish_kanji = BrushKanji.new()
	_finish_kanji.text = "完走"
	_finish_kanji.font_size = 118
	_finish_kanji.color = UITheme.INK
	_finish_kanji.halo = Color(UITheme.PAPER, 0.75)
	_finish_kanji.use_strokes = false
	_banner.add_child(_finish_kanji)
	_count_label = KineticText.new()
	_count_label.font = UITheme.FONT_TITLE
	_count_label.font_size = 76
	_count_label.mono_digits = true
	_count_label.tracking = 2.0
	_count_label.color = UITheme.INK
	_count_label.halo = Color(UITheme.PAPER, 0.85)
	_count_label.halo_size = 16
	_count_label.style = KineticText.Style.NONE
	_count_label.align = HORIZONTAL_ALIGNMENT_CENTER
	_count_label.size = Vector2(700, 110)
	_banner.add_child(_count_label)


func _build_card() -> void:
	_card_holder.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	_card_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_card_holder)
	_card = PaperCard.new()
	_card.padding = Vector4(48, 40, 48, 36)
	_card.paper_alpha = 0.93
	_card.custom_minimum_size = Vector2(CARD_W, 0)
	_card_holder.add_child(_card)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_child(col)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 14)
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_map_kanji = UITheme.make_label("", UITheme.FONT_BRUSH, 40, UITheme.SAKURA)
	_map_kanji.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(_map_kanji)
	var hv := VBoxContainer.new()
	hv.add_theme_constant_override("separation", -2)
	hv.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_map_name = UITheme.make_label("", UITheme.tracked(UITheme.FONT_TITLE, 2), 28, UITheme.INK)
	hv.add_child(_map_name)
	_kind_label = UITheme.make_label("", UITheme.tracked(UITheme.FONT_UI_BLACK, 3), 13, Color(UITheme.INK, 0.5))
	hv.add_child(_kind_label)
	head.add_child(hv)
	_add_row(col, head)

	_time_big = KineticText.new()
	_time_big.font = UITheme.FONT_TITLE
	_time_big.font_size = 88
	_time_big.mono_digits = true
	_time_big.tracking = 2.0
	_time_big.style = KineticText.Style.RISE
	_time_big.stagger = 0.035
	_time_big.distance = 30.0
	_time_big.custom_minimum_size = Vector2(0, 108)
	_add_row(col, _time_big)

	_record.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_record.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	var rsb := UITheme.pill(UITheme.GOLD, 0.2)
	rsb.content_margin_top = 7
	rsb.content_margin_bottom = 8
	rsb.content_margin_left = 20
	rsb.content_margin_right = 22
	_record.add_theme_stylebox_override("panel", rsb)
	var rrow := HBoxContainer.new()
	rrow.add_theme_constant_override("separation", 12)
	rrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rrow.add_child(UITheme.make_label("NEW RECORD", UITheme.tracked(UITheme.FONT_UI_BLACK, 3), 17, UITheme.INK))
	var rj := UITheme.make_label("新記録", UITheme.FONT_BRUSH, 22, UITheme.VERMILION)
	rj.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	rrow.add_child(rj)
	_record.add_child(rrow)
	_add_row(col, _record)

	col.add_child(_divider())
	_best_value = _stat_row(col, "Best")
	_delta_value = _stat_row(col, "Versus best")
	_speed_value = _stat_row(col, "Top speed")
	_standing_value = _stat_row(col, "Rally standing")
	col.add_child(_divider())

	_splits_head = UITheme.make_label("SPLITS", UITheme.tracked(UITheme.FONT_UI_BLACK, 3), 13, Color(UITheme.INK, 0.5))
	_add_row(col, _splits_head)
	_splits_box.columns = 3
	_splits_box.add_theme_constant_override("h_separation", 22)
	_splits_box.add_theme_constant_override("v_separation", 4)
	_splits_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_add_row(col, _splits_box)
	_medal_hint = UITheme.make_label("", UITheme.FONT_UI_BOLD, 18, Color(UITheme.INK, 0.6))
	_add_row(col, _medal_hint)

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 10)
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(gap)
	_buttons.add_theme_constant_override("separation", 12)
	_buttons.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_continue = InkButton.new()
	_continue.text = "Continue"
	_continue.theme_type_variation = &"PrimaryButton"
	_continue.custom_minimum_size = Vector2(180, 0)
	_continue.press_sound = &"start"
	_continue.pressed.connect(func() -> void: UIApi.game().request_campaign_continue())
	_buttons.add_child(_continue)
	_retry = InkButton.new()
	_retry.text = "Retry"
	_retry.custom_minimum_size = Vector2(180, 0)
	_retry.press_sound = &"start"
	_retry.pressed.connect(_on_retry)
	_buttons.add_child(_retry)
	_next = InkButton.new()
	_next.text = "Next map"
	_next.press_sound = &"start"
	_next.pressed.connect(_on_next)
	_buttons.add_child(_next)
	_menu = InkButton.new()
	_menu.text = "Menu"
	_menu.theme_type_variation = &"QuietButton"
	_menu.press_sound = &"back"
	_menu.pressed.connect(_on_menu)
	_buttons.add_child(_menu)
	_add_row(col, _buttons)

	_hanko = Hanko.new()
	_hanko.size = Vector2(150, 150)
	_hanko.caption = "GOLD"
	_hanko.landed.connect(_on_stamp_landed)
	_card.add_child(_hanko)
	# PaperCard is a container: keep the seal out of its layout by re-positioning after sort.
	_card.sort_children.connect(_place_hanko)


func _add_row(col: VBoxContainer, c: Control) -> void:
	col.add_child(c)
	_rows.append(c)


func _divider() -> Control:
	var d := ColorRect.new()
	d.color = Color(UITheme.INK, 0.1)
	d.custom_minimum_size = Vector2(0, 2)
	d.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rows.append(d)
	return d


func _stat_row(col: VBoxContainer, caption: String) -> Label:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := UITheme.make_label(caption, UITheme.FONT_UI_BOLD, 21, Color(UITheme.INK, 0.7))
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(l)
	var v := UITheme.make_label("", UITheme.FONT_TITLE, 26, UITheme.INK)
	row.add_child(v)
	_add_row(col, row)
	return v


## The seal sits over the card's top-right corner, half off the paper.
func _place_hanko() -> void:
	_hanko.size = Vector2(150, 150)
	_hanko.position = Vector2(_card.size.x - 104.0, -52.0)
	_hanko.pivot_offset = _hanko.size * 0.5


# ---------------------------------------------------------------- show

## `split_deltas`: the delta_to_best of each checkpoint_passed seen this run (NAN = none).
func show_result(res: Dictionary, split_deltas: Array = []) -> void:
	result = res
	_split_deltas = split_deltas
	shown = true
	visible = true
	modulate.a = 1.0
	var game := UIApi.game()
	var map_id := str(res.get("map_id", game.map_id))
	var m: Dictionary = game.get_map(map_id)
	var accent := UITheme.season_accent(str(m.get("season", "spring")))
	var t := float(res.get("time", 0.0))
	_petals.autumn = str(m.get("season", "")) == "autumn"
	_fill_card(res, m, accent)

	var vp := get_viewport_rect().size
	var c := vp * Vector2(0.5, 0.4)
	_swash.position = c - _swash.size * 0.5
	_swash.set_param("seed", randf() * 10.0)
	_swash.set_param("progress", 0.0)
	_swash.set_param("fade_out", 0.0)
	_finish.position = c - _finish.size * 0.5 - Vector2(0, 8)
	_finish_kanji.size = _finish_kanji.custom_minimum_size
	_finish_kanji.position = c + Vector2(-_finish_kanji.size.x * 0.5, 104)
	_finish_kanji.progress = 0.0
	_count_label.position = c + Vector2(-_count_label.size.x * 0.5, 262)
	_count_label.text = game.format_time(0.0)
	_count_label.modulate.a = 0.0
	_banner.visible = true
	_banner.modulate.a = 1.0
	_banner.position = Vector2.ZERO
	_card_holder.visible = false
	_hanko.modulate.a = 0.0
	_record.modulate.a = 0.0

	UIApi.stinger(&"finish")
	UIMotion.kill(_tween)
	_tween = UIMotion.tween(self)
	_tween.tween_method(_swash.param_setter(&"progress"), 0.0, 1.0, 0.42).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.parallel().tween_callback(_finish.play.bind(0.08))
	_flash.color.a = 0.5
	_tween.parallel().tween_property(_flash, "color:a", 0.0, 0.5).set_delay(0.3)
	_tween.parallel().tween_callback(shake_requested.emit.bind(0.5)).set_delay(0.36)
	_tween.parallel().tween_property(_finish_kanji, "progress", 1.0, 0.7).set_delay(0.45).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_count_t = -0.75
	_tween.tween_interval(COUNT_UP + 0.9)
	# Banner lifts away; card enters.
	_tween.tween_property(_banner, "position", Vector2(-vp.x * 0.16, -60.0), 0.55).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_tween.parallel().tween_property(_banner, "modulate:a", 0.0, 0.45).set_delay(0.1)
	_tween.parallel().tween_method(_swash.param_setter(&"fade_out"), 0.0, 1.0, 0.5)
	_tween.parallel().tween_callback(_enter_card.bind(t)).set_delay(0.15)


func _fill_card(res: Dictionary, m: Dictionary, accent: Color) -> void:
	var game := UIApi.game()
	var t := float(res.get("time", 0.0))
	var prev := float(res.get("previous_best", INF))
	var best := float(res.get("best_time", t))
	_map_kanji.text = str(m.get("name_jp", ""))
	_map_kanji.label_settings.font_color = accent
	_map_name.text = str(m.get("name", "")).to_upper()
	_time_big.text = game.format_time(t)
	_best_value.text = game.format_time(best)
	if is_inf(prev):
		_delta_value.text = "First run"
		_delta_value.label_settings.font = UITheme.FONT_UI_BOLD
		_delta_value.label_settings.font_size = 22
		_delta_value.label_settings.font_color = Color(UITheme.INK, 0.55)
	else:
		_delta_value.label_settings.font = UITheme.FONT_TITLE
		_delta_value.label_settings.font_size = 26
		var dlt := t - prev
		_delta_value.text = game.format_delta(dlt)
		_delta_value.label_settings.font_color = UITheme.MATCHA if dlt < 0.0 else UITheme.VERMILION
	var top := float(res.get("top_speed_kmh", 0.0))
	_speed_value.text = "%d %s" % [roundi(UIApi.speed_in_units(top)), UIApi.unit_label()]
	for ch in _splits_box.get_children():
		ch.queue_free()
	var splits: Array = res.get("splits", [])
	for i in splits.size():
		_splits_box.add_child(UITheme.make_label("CP %d" % (i + 1), UITheme.tracked(UITheme.FONT_UI_BLACK, 2), 15, Color(UITheme.INK, 0.5)))
		_splits_box.add_child(UITheme.make_label(game.format_time(float(splits[i])), UITheme.FONT_TITLE, 20, UITheme.INK))
		var dtxt := ""
		var dcol := Color(UITheme.INK, 0.4)
		var dd := float(_split_deltas[i]) if i < _split_deltas.size() else NAN
		if not is_nan(dd):
			dtxt = game.format_delta(dd)
			dcol = UITheme.MATCHA if dd < 0.0 else UITheme.VERMILION
		_splits_box.add_child(UITheme.make_label(dtxt, UITheme.FONT_TITLE, 18, dcol))
	_splits_head.visible = not splits.is_empty()
	_splits_box.visible = not splits.is_empty()
	var medal := str(res.get("medal", ""))
	_hanko.visible = medal != ""
	_hanko.text = UITheme.medal_kanji(medal)
	_hanko.caption = medal.to_upper()
	_record.visible = bool(res.get("is_record", false))
	var medals: Dictionary = m.get("medals", {})
	var next_medal := ""
	for k in ["bronze", "silver", "gold"]:
		if medals.has(k) and t > float(medals[k]):
			next_medal = k
			break
	if medal == "gold":
		_medal_hint.text = "Gold seal. The pass is yours."
	elif next_medal != "":
		_medal_hint.text = "%s at %s" % [next_medal.capitalize(), game.format_time(float(medals[next_medal]))]
	else:
		_medal_hint.text = ""
	_medal_hint.visible = _medal_hint.text != ""
	var campaign := bool(res.get("campaign", false))
	_standing_value.get_parent().visible = campaign
	if campaign:
		var leg: Dictionary = game.CAMPAIGN[int(res.get("leg", 0))]
		_kind_label.text = "%s  ·  CAMPAIGN RESULT" % leg["code"]
		_standing_value.text = "P%d of %d" % [int(res.get("standing", 0)), int(res.get("field", 0))]
	else:
		_kind_label.text = "TIME TRIAL  ·  RESULT"
	_continue.visible = campaign
	_retry.text = "Retry stage" if campaign else "Retry"
	_retry.theme_type_variation = &"" if campaign else &"PrimaryButton"
	_menu.text = "Quit to title" if campaign else "Menu"
	_next.visible = not campaign and game.stage_maps().size() > 1


func _enter_card(t: float) -> void:
	var vp := get_viewport_rect().size
	_card_holder.visible = true
	_card.reset_size()
	var h := _card.get_combined_minimum_size().y
	var base := Vector2(-CARD_W - vp.x * 0.07, (vp.y - h) * 0.5)
	_card.position = base + Vector2(120, 0)
	_card.modulate.a = 0.0
	_card.reveal = 0.0
	var tw := UIMotion.tween(_card)
	tw.set_parallel(true)
	tw.tween_property(_card, "position", base, 0.75).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_property(_card, "modulate:a", 1.0, 0.3)
	tw.tween_property(_card, "reveal", 1.0, 0.6).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	var d := 0.18
	for r in _rows:
		if not r.visible or r == _record:
			continue
		r.modulate.a = 0.0
		var rt := UIMotion.tween(r)
		rt.tween_property(r, "modulate:a", 1.0, 0.35).set_delay(d)
		d += 0.05
	_time_big.play(0.2)
	var stamp_at := d + 0.25
	if _record.visible:
		_record.pivot_offset = _record.size * 0.5
		_record.scale = Vector2(0.6, 0.6)
		var rct := UIMotion.tween(_record)
		rct.set_parallel(true)
		rct.tween_property(_record, "modulate:a", 1.0, 0.2).set_delay(stamp_at + 0.45)
		rct.tween_property(_record, "scale", Vector2.ONE, 0.55).set_delay(stamp_at + 0.45).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
		rct.tween_callback(UIApi.stinger.bind(&"record")).set_delay(stamp_at + 0.45)
	if _hanko.visible:
		_hanko.stamp(stamp_at)
	elif _record.visible:
		var bt := UIMotion.tween(self)
		bt.tween_callback(_burst).set_delay(stamp_at + 0.5)
	var ft := UIMotion.tween(self)
	ft.tween_callback((_continue if _continue.visible else _retry).grab_focus).set_delay(0.6)


func _on_stamp_landed() -> void:
	shake_requested.emit(1.0)
	_burst()


func _burst() -> void:
	var at := _hanko.get_global_rect().get_center() if _hanko.visible else _record.get_global_rect().get_center()
	_petals.burst(at - _petals.get_global_rect().position, 70, 1000.0)


func hide_result(instant: bool = false) -> void:
	if not shown:
		return
	shown = false
	UIMotion.kill(_tween)
	_count_t = -1.0
	if instant:
		visible = false
		return
	_tween = UIMotion.tween(self)
	_tween.tween_property(self, "modulate:a", 0.0, 0.3)
	_tween.tween_callback(hide)


func _process(delta: float) -> void:
	if not visible or _count_t < -0.9 or result.is_empty():
		return
	var d := UIMotion.real_delta(delta)
	var prev := _count_t
	_count_t += d
	if _count_t < 0.0:
		return
	_count_label.modulate.a = minf(_count_t / 0.15, 1.0)
	var k := minf(_count_t / COUNT_UP, 1.0)
	var t := float(result.get("time", 0.0))
	_count_label.text = UIApi.game().format_time(t * UIMotion.out_expo(k) if k < 1.0 else t)
	if k >= 1.0 and prev < COUNT_UP:
		# Landed on the final time: small pop.
		_count_label.pivot_offset = _count_label.size * 0.5
		_count_label.scale = Vector2(1.12, 1.12)
		UIMotion.tween(_count_label).tween_property(_count_label, "scale", Vector2.ONE, 0.4).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		UIApi.ui_sound(&"toggle")
	if k >= 1.0:
		_count_t = -1.0


# ---------------------------------------------------------------- buttons

func _on_retry() -> void:
	UIApi.game().request_restart()


func _on_menu() -> void:
	UIApi.game().request_menu()


## Next stage map of the Time Attack list (liaison roads are not stages).
func _on_next() -> void:
	var game := UIApi.game()
	var maps: Array = game.stage_maps()
	var cur := str(result.get("map_id", game.map_id))
	var idx := 0
	for i in maps.size():
		if str((maps[i] as Dictionary)["id"]) == cur:
			idx = i
	var nxt: Dictionary = maps[(idx + 1) % maps.size()]
	game.request_start(str(nxt["id"]), str(game.MODE_TIME_TRIAL))


func _unhandled_input(event: InputEvent) -> void:
	if not shown or not _card_holder.visible:
		return
	if event.is_action_pressed("ui_cancel"):
		UIApi.ui_sound(&"back")
		_on_menu()
		get_viewport().set_input_as_handled()
