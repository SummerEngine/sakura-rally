extends Control
## Campaign finale (Game.State.FINALE), over a flyover of the last map. `open(summary)` (the
## Game.campaign_finished summary) plays two cards:
##  1. the rally classification: rows land from last place up to the winner on 12 fps steps,
##     your row washed in sakura; the stage seals down the side, then the overall position
##     seal slams (shake + petal burst). Continue.
##  2. the end card: 完 painted large, the rally in three seasons, a few credit lines rising,
##     and Back to title (the title then offers Replay).

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

const COLS := [["POS", 70.0], ["DRIVER", 330.0], ["SS1", 150.0], ["SS2", 150.0], ["TOTAL", 170.0], ["GAP", 120.0]]
const ROW_STAGGER := 0.16

var shown := false
var phase := 0 ## 1 classification, 2 end card

var _summary: Dictionary = {}
var _dim := ColorRect.new()

# Classification
var _board := Control.new()
var _swash: ShaderRect
var _title: KineticText
var _kicker: Label
var _card: PaperCard
var _head_row: HBoxContainer
var _rows_box := VBoxContainer.new()
var _rows: Array[Control] = []
var _side_card: PaperCard
var _side := VBoxContainer.new()
var _stage_seals: Array[Hanko] = []
var _stage_labels: Array[Label] = []
var _pos_seal: Hanko
var _continue: Button

# End card
var _end := Control.new()
var _end_kanji: BrushKanji
var _end_title: KineticText
var _end_lines := VBoxContainer.new()
var _back: Button

var _petals: PetalField
var _tween: Tween


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.color = Color(UITheme.INK, 0.0)
	_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_dim)
	_build_board()
	_build_end()
	_petals = PetalField.new()
	_petals.ambient_count = 0
	_petals.autumn = true
	add_child(_petals)
	visible = false


func _build_board() -> void:
	_board.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_board.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_board)
	_swash = ShaderRect.new(BRUSH_BAND)
	_swash.size = Vector2(980, 120)
	_swash.set_param("paint", UITheme.VERMILION)
	_board.add_child(_swash)
	_title = KineticText.new()
	_title.font = UITheme.FONT_TITLE
	_title.font_size = 64
	_title.tracking = 6.0
	_title.color = UITheme.WHITE
	_title.shadow = Color(UITheme.INK, 0.28)
	_title.shadow_offset = Vector2(0, 4)
	_title.style = KineticText.Style.DROP
	_title.stepped_fps = 12.0
	_title.stagger = 0.035
	_title.distance = 44.0
	_title.text = "RALLY CLASSIFICATION"
	_title.size = Vector2(1000, 100)
	_board.add_child(_title)
	_kicker = UITheme.make_label("THE SEASONS RALLY  ·  FINAL  ·  総合順位", UITheme.tracked(UITheme.FONT_UI_BLACK, 3), 17, UITheme.INK)
	_kicker.label_settings.outline_size = 12
	_kicker.label_settings.outline_color = Color(UITheme.PAPER, 0.85)
	_board.add_child(_kicker)

	_card = PaperCard.new()
	_card.padding = Vector4(40, 28, 40, 30)
	_card.paper_alpha = 0.94
	_board.add_child(_card)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_child(col)
	_head_row = HBoxContainer.new()
	_head_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var codes: Array[String] = []
	for leg: Dictionary in UIApi.game().CAMPAIGN:
		if leg["kind"] == "stage":
			codes.append(str(leg["code"]))
	for i in COLS.size():
		var c: Array = COLS[i]
		var text := codes[i - 2] if i >= 2 and i < 2 + codes.size() else str(c[0])
		var l := UITheme.make_label(text, UITheme.tracked(UITheme.FONT_UI_BLACK, 3), 13, Color(UITheme.INK, 0.5))
		l.custom_minimum_size = Vector2(c[1], 0)
		if i >= 2:
			l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_head_row.add_child(l)
	col.add_child(_head_row)
	var div := ColorRect.new()
	div.color = Color(UITheme.INK, 0.12)
	div.custom_minimum_size = Vector2(0, 2)
	div.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(div)
	_rows_box.add_theme_constant_override("separation", 4)
	_rows_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_rows_box)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 10)
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(gap)
	_continue = InkButton.new()
	_continue.text = "Continue"
	_continue.theme_type_variation = &"PrimaryButton"
	_continue.custom_minimum_size = Vector2(220, 0)
	_continue.size_flags_horizontal = Control.SIZE_SHRINK_END
	_continue.press_sound = &"start"
	_continue.pressed.connect(_show_end)
	col.add_child(_continue)

	# Stage seals and the overall seal on their own paper card, so the medal inks read over
	# any scenery (gold on the autumn fields).
	_side_card = PaperCard.new()
	_side_card.padding = Vector4(26, 24, 26, 26)
	_side_card.paper_alpha = 0.94
	_board.add_child(_side_card)
	_side.add_theme_constant_override("separation", 18)
	_side.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_side_card.add_child(_side)
	for leg: Dictionary in UIApi.game().CAMPAIGN:
		if leg["kind"] != "stage":
			continue
		var box := VBoxContainer.new()
		box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_theme_constant_override("separation", 4)
		var h := Hanko.new()
		h.round_seal = true
		h.custom_minimum_size = Vector2(96, 96)
		h.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		h.text = str(leg["kanji"])
		box.add_child(h)
		var l := UITheme.make_label("", UITheme.tracked(UITheme.FONT_UI_BLACK, 2), 14, UITheme.INK)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.label_settings.outline_size = 10
		l.label_settings.outline_color = Color(UITheme.PAPER, 0.85)
		box.add_child(l)
		_side.add_child(box)
		_stage_seals.append(h)
		_stage_labels.append(l)
	_pos_seal = Hanko.new()
	_pos_seal.custom_minimum_size = Vector2(150, 150)
	_pos_seal.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_pos_seal.caption = "OVERALL"
	_pos_seal.landed.connect(_on_pos_landed)
	_side.add_child(_pos_seal)


func _build_end() -> void:
	_end.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_end.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_end)
	_end_kanji = BrushKanji.new()
	_end_kanji.text = "完"
	_end_kanji.font_size = 300
	_end_kanji.color = UITheme.PAPER
	_end_kanji.use_strokes = false
	_end.add_child(_end_kanji)
	_end_title = KineticText.new()
	_end_title.font = UITheme.FONT_TITLE
	_end_title.font_size = 58
	_end_title.tracking = 10.0
	_end_title.color = UITheme.PAPER
	_end_title.style = KineticText.Style.RISE
	_end_title.stagger = 0.04
	_end_title.stepped_fps = 12.0
	_end_title.distance = 30.0
	_end_title.align = HORIZONTAL_ALIGNMENT_CENTER
	_end_title.text = "SAKURA RALLY"
	_end_title.size = Vector2(1000, 90)
	_end.add_child(_end_title)
	_end_lines.add_theme_constant_override("separation", 10)
	_end_lines.alignment = BoxContainer.ALIGNMENT_CENTER
	_end_lines.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_end.add_child(_end_lines)
	_back = InkButton.new()
	_back.text = "Back to title"
	_back.theme_type_variation = &"PrimaryButton"
	_back.custom_minimum_size = Vector2(260, 0)
	_back.press_sound = &"back"
	_back.pressed.connect(func() -> void: UIApi.game().request_menu())
	_end.add_child(_back)


# ---------------------------------------------------------------- show

func open(summary: Dictionary) -> void:
	_summary = summary
	shown = true
	visible = true
	modulate.a = 1.0
	_fill_rows()
	_show_board()


func _fill_rows() -> void:
	var game := UIApi.game()
	for r in _rows:
		r.queue_free()
	_rows.clear()
	var table: Array = _summary.get("classification", [])
	for i in table.size():
		var row: Dictionary = table[i]
		var player := bool(row["player"])
		var panel := PanelContainer.new()
		panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var sb := UITheme.pill(Color(UITheme.SAKURA_PALE, 0.95) if player else Color(0, 0, 0, 0), 0.0)
		sb.set_corner_radius_all(14)
		sb.content_margin_left = 0
		sb.content_margin_right = 0
		sb.content_margin_top = 5
		sb.content_margin_bottom = 5
		panel.add_theme_stylebox_override("panel", sb)
		var h := HBoxContainer.new()
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(h)
		var ink := UITheme.VERMILION if player else UITheme.INK
		_cell(h, "%d" % (i + 1), UITheme.FONT_TITLE, 26, ink, COLS[0][1], HORIZONTAL_ALIGNMENT_CENTER)
		var who := HBoxContainer.new()
		who.custom_minimum_size = Vector2(COLS[1][1], 0)
		who.add_theme_constant_override("separation", 10)
		who.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var nm := VBoxContainer.new()
		nm.add_theme_constant_override("separation", -4)
		nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
		nm.add_child(UITheme.make_label(str(row["name"]), UITheme.FONT_UI_BLACK, 22, UITheme.INK))
		nm.add_child(UITheme.make_label(str(row["team"]), UITheme.FONT_UI_BOLD, 14, Color(UITheme.INK, 0.55)))
		who.add_child(nm)
		var jp := UITheme.make_label(str(row["name_jp"]), UITheme.FONT_BRUSH, 20, Color(ink, 0.55))
		jp.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		who.add_child(jp)
		h.add_child(who)
		var times: Array = row["times"]
		for k in 2:
			var t := float(times[k]) if k < times.size() else NAN
			_cell(h, game.format_time(t) if not is_nan(t) else "—", UITheme.FONT_TITLE, 20, Color(UITheme.INK, 0.8), COLS[2 + k][1], HORIZONTAL_ALIGNMENT_RIGHT)
		_cell(h, game.format_time(float(row["total"])), UITheme.FONT_TITLE, 24, ink, COLS[4][1], HORIZONTAL_ALIGNMENT_RIGHT)
		var gap := float(row["gap"])
		_cell(h, "—" if i == 0 else "+%.3f" % gap, UITheme.FONT_TITLE, 18, Color(UITheme.INK, 0.55), COLS[5][1], HORIZONTAL_ALIGNMENT_RIGHT)
		_rows_box.add_child(panel)
		_rows.append(panel)
	var results: Dictionary = _summary.get("results", {})
	var k2 := 0
	for leg: Dictionary in game.CAMPAIGN:
		if leg["kind"] != "stage":
			continue
		var res: Dictionary = results.get(leg["map"], {})
		var medal := str(res.get("medal", ""))
		var seal := _stage_seals[k2]
		seal.ink = UITheme.medal_color(medal).darkened(0.25) if medal != "" else UITheme.INK
		seal.caption = medal.to_upper()
		_stage_labels[k2].text = "%s  %s\n%s" % [leg["code"], str(leg["title"]).to_upper(),
				game.format_time(float(res.get("time", NAN))) if not res.is_empty() else "—"]
		k2 += 1
	var pos := int(_summary.get("position", 0))
	_pos_seal.text = "%d位" % pos
	_pos_seal.ink = UITheme.VERMILION if pos > 1 else UITheme.GOLD_DEEP


func _cell(parent: Control, text: String, font: Font, size_px: int, color: Color, width: float, align: HorizontalAlignment) -> void:
	var l := UITheme.make_label(text, font, size_px, color)
	l.custom_minimum_size = Vector2(width, 0)
	l.horizontal_alignment = align
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	parent.add_child(l)


func _show_board() -> void:
	phase = 1
	var vp := get_viewport_rect().size
	_board.visible = true
	_board.modulate.a = 1.0
	_end.visible = false
	_card.reset_size()
	var cs := _card.get_combined_minimum_size()
	var left := (vp.x - cs.x - 36.0 - _side_card.get_combined_minimum_size().x) * 0.5
	var top := maxf((vp.y - cs.y) * 0.5 + 60.0, 190.0)
	_card.position = Vector2(left, top)
	_card.size = cs
	_title.position = Vector2(left - 6.0, top - 150.0)
	_swash.size.x = _title.text_width() + 110.0
	_swash.position = Vector2(left - 48.0, top - 160.0)
	_kicker.position = Vector2(left, top - 44.0)
	_side_card.reset_size()
	_side_card.size = _side_card.get_combined_minimum_size()
	_side_card.position = Vector2(left + cs.x + 36.0, top)

	UIMotion.kill(_tween)
	_dim.color.a = 0.0
	_swash.set_param("seed", randf() * 10.0)
	_swash.set_param("progress", 0.0)
	_swash.set_param("fade_out", 0.0)
	_card.reveal = 0.0
	_card.modulate.a = 0.0
	_side_card.reveal = 0.0
	_side_card.modulate.a = 0.0
	_kicker.modulate.a = 0.0
	_head_row.modulate.a = 0.0
	_continue.modulate.a = 0.0
	_continue.disabled = true
	for s in _stage_seals:
		s.modulate.a = 0.0
	for l in _stage_labels:
		l.modulate.a = 0.0
	_pos_seal.modulate.a = 0.0
	_title.play(0.25)
	_tween = UIMotion.tween(self)
	_tween.set_parallel(true)
	_tween.tween_property(_dim, "color:a", 0.22, 0.6)
	_tween.tween_method(_swash.param_setter(&"progress"), 0.0, 1.0, 0.5).set_delay(0.1).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_property(_kicker, "modulate:a", 1.0, 0.4).set_delay(0.6)
	_tween.tween_property(_card, "modulate:a", 1.0, 0.3).set_delay(0.5)
	_tween.tween_property(_card, "reveal", 1.0, 0.6).set_delay(0.5).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_property(_side_card, "modulate:a", 1.0, 0.3).set_delay(0.7)
	_tween.tween_property(_side_card, "reveal", 1.0, 0.6).set_delay(0.7).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_property(_head_row, "modulate:a", 1.0, 0.3).set_delay(0.8)
	# Rows land from last place up to the winner, stepped at 12 fps.
	var d := 1.0
	for i in range(_rows.size() - 1, -1, -1):
		var r := _rows[i]
		r.modulate.a = 0.0
		var player := bool((_summary["classification"] as Array)[i]["player"])
		_tween.tween_method(_row_step.bind(r, player), 0.0, 1.0, 0.42).set_delay(d)
		if player:
			_tween.tween_callback(UIApi.ui_sound.bind(&"toggle")).set_delay(d + 0.1)
		d += ROW_STAGGER
	for k in _stage_seals.size():
		_tween.tween_callback(_stage_seals[k].stamp).set_delay(d + 0.1 + k * 0.35)
		_tween.tween_property(_stage_labels[k], "modulate:a", 1.0, 0.3).set_delay(d + 0.3 + k * 0.35)
	d += 0.25 + _stage_seals.size() * 0.35
	_tween.tween_callback(_pos_seal.stamp).set_delay(d + 0.2)
	_tween.tween_callback(UIApi.stinger.bind(&"campaign_complete")).set_delay(d + 0.35)
	_tween.tween_property(_continue, "modulate:a", 1.0, 0.35).set_delay(d + 0.9)
	_tween.tween_callback(func() -> void:
		_continue.disabled = false
		_continue.grab_focus()).set_delay(d + 0.9)


## A row's entrance on 12 fps steps: drops in from the right with a small overshoot; the
## player's row lands with a pop.
func _row_step(v: float, row: Control, player: bool) -> void:
	var k := UIMotion.stepped(v, 12.0 * 0.42) if v < 1.0 else 1.0
	row.modulate.a = minf(k * 2.0, 1.0)
	row.position.x = (1.0 - UIMotion.out_back(k)) * 60.0
	if player:
		row.pivot_offset = row.size * 0.5
		var s := 1.0 + sin(k * PI) * 0.06
		row.scale = Vector2(s, s)


func _on_pos_landed() -> void:
	shake_requested.emit(1.0)
	_petals.burst(_pos_seal.global_position - global_position + _pos_seal.size * 0.5, 80, 1100.0)


func _show_end() -> void:
	if phase != 1:
		return
	phase = 2
	_continue.disabled = true
	var game := UIApi.game()
	var vp := get_viewport_rect().size
	var c := vp * Vector2(0.5, 0.36)
	for ch in _end_lines.get_children():
		ch.queue_free()
	var pos := int(_summary.get("position", 0))
	var field := int(_summary.get("field", 0))
	var total := 0.0
	for row: Dictionary in _summary.get("classification", []):
		if row["player"]:
			total = float(row["total"])
	var lines := [
		["SPRING  ·  SUMMER  ·  AUTUMN", UITheme.tracked(UITheme.FONT_UI_BLACK, 4), 18, Color(UITheme.PAPER, 0.8)],
		["You finished P%d of %d  ·  total %s" % [pos, field, game.format_time(total)], UITheme.FONT_UI_BOLD, 26, UITheme.PAPER],
		["", UITheme.FONT_UI_BOLD, 10, UITheme.PAPER],
		["STAGES   %s" % _leg_titles("stage"), UITheme.tracked(UITheme.FONT_UI_BOLD, 1), 18, Color(UITheme.PAPER, 0.75)],
		["RIVALS   %s" % _rival_names(), UITheme.tracked(UITheme.FONT_UI_BOLD, 1), 18, Color(UITheme.PAPER, 0.75)],
		["", UITheme.FONT_UI_BOLD, 10, UITheme.PAPER],
		["Thanks for driving.", UITheme.FONT_BRUSH, 30, UITheme.SAKURA_PALE],
	]
	for spec: Array in lines:
		var l := UITheme.make_label(spec[0], spec[1], spec[2], spec[3])
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_end_lines.add_child(l)
	_end_kanji.size = _end_kanji.custom_minimum_size
	_end_kanji.position = c - _end_kanji.size * 0.5 - Vector2(0, 40)
	_end_kanji.progress = 0.0
	_end_title.position = Vector2(c.x - _end_title.size.x * 0.5, c.y + 110.0)
	_end_lines.reset_size()
	_end_lines.size.x = 1200.0
	_end_lines.position = Vector2(c.x - 600.0, c.y + 210.0)
	_back.reset_size()
	_back.position = Vector2(c.x - _back.size.x * 0.5, minf(c.y + 250.0 + _end_lines.get_combined_minimum_size().y, vp.y - 110.0))

	UIMotion.kill(_tween)
	_tween = UIMotion.tween(self)
	_tween.set_parallel(true)
	# The board lifts away, the scene sinks into ink, 完 is painted and the credits rise.
	_tween.tween_property(_board, "modulate:a", 0.0, 0.4)
	_tween.tween_property(_board, "position:y", -40.0, 0.5).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_tween.tween_property(_dim, "color:a", 0.72, 0.9).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_tween.tween_callback(func() -> void:
		_board.visible = false
		_board.position.y = 0.0
		_end.visible = true
		_end_kanji.play(1.3)
		_end_title.play(0.6)).set_delay(0.45)
	var d := 1.4
	for ch in _end_lines.get_children():
		var l := ch as Control
		l.modulate.a = 0.0
		_tween.tween_property(l, "modulate:a", 1.0, 0.6).set_delay(d)
		d += 0.22
	_back.modulate.a = 0.0
	_back.disabled = true
	_tween.tween_property(_back, "modulate:a", 1.0, 0.4).set_delay(d + 0.3)
	_tween.tween_callback(func() -> void:
		_back.disabled = false
		_back.grab_focus()).set_delay(d + 0.3)


func _leg_titles(kind: String) -> String:
	var names: PackedStringArray = []
	for leg: Dictionary in UIApi.game().CAMPAIGN:
		if leg["kind"] == kind:
			names.append(str(leg["title"]))
	return "  ·  ".join(names)


func _rival_names() -> String:
	var names: PackedStringArray = []
	for r: Dictionary in UIApi.game().RIVALS:
		names.append(str(r["name"]))
	return "  ·  ".join(names)


func close() -> void:
	if not shown:
		return
	shown = false
	phase = 0
	UIMotion.kill(_tween)
	visible = false


func _unhandled_input(event: InputEvent) -> void:
	if not shown:
		return
	if event.is_action_pressed("ui_cancel"):
		if phase == 1 and not _continue.disabled:
			_show_end()
			get_viewport().set_input_as_handled()
		elif phase == 2 and not _back.disabled:
			UIApi.ui_sound(&"back")
			UIApi.game().request_menu()
			get_viewport().set_input_as_handled()
