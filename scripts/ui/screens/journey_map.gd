extends Control
## Campaign journey map, which is also the campaign's loading screen (Game.State.JOURNEY).
## A painted map of the rally through the seasons (shaders/ui/journey_map.gdshader): the legs
## are seals on a dotted road, finished legs carry their medal, and the player's car (in its
## livery) drives from the last leg to the next one while Main loads that leg behind the
## screen. `open(status, slam)` plays it; `travel_done` fires once the car has arrived.

signal travel_done
signal shake_requested(strength: float)

const UITheme := preload("res://scripts/ui/ui_theme.gd")
const UIMotion := preload("res://scripts/ui/ui_motion.gd")
const UIApi := preload("res://scripts/ui/ui_api.gd")
const PaperCard := preload("res://scripts/ui/widgets/paper_card.gd")
const BrushKanji := preload("res://scripts/ui/widgets/brush_kanji.gd")
const KineticText := preload("res://scripts/ui/widgets/kinetic_text.gd")
const Hanko := preload("res://scripts/ui/widgets/hanko.gd")
const PetalField := preload("res://scripts/ui/widgets/petal_field.gd")
const Spinner := preload("res://scripts/ui/widgets/sakura_spinner.gd")
const ShaderRect := preload("res://scripts/ui/widgets/shader_rect.gd")
const MAP_SHADER := preload("res://shaders/ui/journey_map.gdshader")
const BRUSH_BAND := preload("res://shaders/ui/brush_band.gdshader")

## Road control points in 0..1 map space (Catmull-Rom), from the start flag to the goal.
const ROUTE: Array[Vector2] = [
	Vector2(0.075, 0.80), Vector2(0.12, 0.70), Vector2(0.2, 0.585), Vector2(0.265, 0.47),
	Vector2(0.355, 0.385), Vector2(0.47, 0.345), Vector2(0.565, 0.37), Vector2(0.64, 0.465),
	Vector2(0.715, 0.56), Vector2(0.8, 0.53), Vector2(0.875, 0.395),
]
## ROUTE index of each node: start, then one per campaign leg, then the goal.
const NODES: Array[int] = [0, 2, 5, 8, 10]
const SAMPLES_PER_SEGMENT := 24
const DASH := 9.0
const GAP := 7.0
const STAMP_SIZE := 104.0
const TRAVEL_DELAY := 1.45
const TRAVEL_TIME := 2.3
const SEASON_WATERMARKS := [["春", Vector2(0.15, 0.34)], ["夏", Vector2(0.49, 0.6)], ["秋", Vector2(0.83, 0.74)]]

var shown := false
var traveling := false

var _map: ShaderRect
var _deco := Control.new()
var _route := Control.new()
var _stamps: Array[Hanko] = []
var _labels: Array[VBoxContainer] = []
var _petals: PetalField
var _tween: Tween

var _header := Control.new()
var _strip: PaperCard
var _strip_kanji: BrushKanji
var _swash: ShaderRect
var _title: KineticText
var _sub: Label

var _next_holder := Control.new()
var _next_card: PaperCard
var _next_kicker: Label
var _next_kanji: Label
var _next_name: Label
var _next_detail: Label
var _loading_label: Label

# Route geometry in pixels.
var _pts := PackedVector2Array()
var _cum := PackedFloat32Array()
var _node_d := PackedFloat32Array()
var _total := 1.0
# Animation state.
var _status: Dictionary = {}
var _from := 0
var _car_d := 0.0
var _draw_on := 1.0
var _ghost_alpha := 0.0
var _pulse_t := -1.0
var _time := 0.0
var _dust: Array[Vector3] = [] ## x, y, age
var _dust_clock := 0.0
var _livery: Dictionary = {}


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_map = ShaderRect.new(MAP_SHADER)
	_map.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_map)
	for c: Control in [_deco, _route]:
		c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(c)
	_deco.draw.connect(_draw_deco)
	_route.draw.connect(_draw_route)
	for i in UIApi.game().CAMPAIGN.size():
		var h := Hanko.new()
		h.round_seal = true
		h.size = Vector2(STAMP_SIZE, STAMP_SIZE)
		h.landed.connect(_on_stamp_landed.bind(i))
		add_child(h)
		_stamps.append(h)
		var l := VBoxContainer.new()
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		l.add_theme_constant_override("separation", -2)
		l.alignment = BoxContainer.ALIGNMENT_CENTER
		for spec: Array in [[UITheme.tracked(UITheme.FONT_UI_BLACK, 3), 14, Color(UITheme.INK, 0.62)],
				[UITheme.tracked(UITheme.FONT_TITLE, 1), 22, UITheme.INK],
				[UITheme.FONT_TITLE, 17, Color(UITheme.INK, 0.8)]]:
			var lab := UITheme.make_label("", spec[0], spec[1], spec[2])
			lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			lab.label_settings.outline_size = 10
			lab.label_settings.outline_color = Color(UITheme.PAPER, 0.85)
			l.add_child(lab)
		add_child(l)
		_labels.append(l)
	_build_header()
	_build_next_card()
	_petals = PetalField.new()
	_petals.ambient_count = 0
	add_child(_petals)
	resized.connect(_layout)
	visible = false


func _build_header() -> void:
	_header.position = Vector2(84, 64)
	_header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_header)
	_strip = PaperCard.new()
	_strip.padding = Vector4(12, 22, 12, 22)
	_strip.radius = 14.0
	_strip.paper_alpha = 0.94
	_strip.custom_minimum_size = Vector2(104, 0)
	_header.add_child(_strip)
	_strip_kanji = BrushKanji.new()
	_strip_kanji.text = "旅"
	_strip_kanji.font_size = 76
	_strip_kanji.color = UITheme.VERMILION
	_strip_kanji.use_strokes = false
	_strip.add_child(_strip_kanji)
	_swash = ShaderRect.new(BRUSH_BAND)
	_swash.position = Vector2(106, 10)
	_swash.size = Vector2(720, 104)
	_swash.set_param("paint", UITheme.INK)
	_header.add_child(_swash)
	_title = KineticText.new()
	_title.font = UITheme.FONT_TITLE
	_title.font_size = 56
	_title.tracking = 5.0
	_title.color = UITheme.PAPER
	_title.shadow = Color(UITheme.INK, 0.25)
	_title.shadow_offset = Vector2(0, 4)
	_title.style = KineticText.Style.DROP
	_title.stepped_fps = 12.0
	_title.stagger = 0.035
	_title.distance = 40.0
	_title.text = "THE SEASONS RALLY"
	_title.position = Vector2(150, 22)
	_header.add_child(_title)
	_sub = UITheme.make_label("", UITheme.tracked(UITheme.FONT_UI_BLACK, 3), 17, UITheme.INK)
	_sub.label_settings.outline_size = 12
	_sub.label_settings.outline_color = Color(UITheme.PAPER, 0.8)
	_sub.position = Vector2(154, 122)
	_header.add_child(_sub)


func _build_next_card() -> void:
	_next_holder.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_next_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_next_holder)
	_next_card = PaperCard.new()
	_next_card.padding = Vector4(34, 24, 34, 24)
	_next_card.paper_alpha = 0.93
	_next_card.custom_minimum_size = Vector2(560, 0)
	_next_holder.add_child(_next_card)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_next_card.add_child(col)
	_next_kicker = UITheme.make_label("", UITheme.tracked(UITheme.FONT_UI_BLACK, 3), 14, UITheme.VERMILION)
	col.add_child(_next_kicker)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(row)
	_next_kanji = UITheme.make_label("", UITheme.FONT_BRUSH, 44, UITheme.SAKURA)
	_next_kanji.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_next_kanji)
	_next_name = UITheme.make_label("", UITheme.tracked(UITheme.FONT_TITLE, 2), 38, UITheme.INK)
	_next_name.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_next_name)
	_next_detail = UITheme.make_label("", UITheme.FONT_UI_BOLD, 20, Color(UITheme.INK, 0.7))
	col.add_child(_next_detail)
	var div := ColorRect.new()
	div.color = Color(UITheme.INK, 0.1)
	div.custom_minimum_size = Vector2(0, 2)
	div.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(div)
	var lrow := HBoxContainer.new()
	lrow.add_theme_constant_override("separation", 10)
	lrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(lrow)
	var spin := Spinner.new()
	spin.custom_minimum_size = Vector2(30, 30)
	lrow.add_child(spin)
	_loading_label = UITheme.make_label("", UITheme.tracked(UITheme.FONT_UI_BLACK, 2), 14, Color(UITheme.INK, 0.5))
	_loading_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	lrow.add_child(_loading_label)


# ---------------------------------------------------------------- geometry

func _layout() -> void:
	var sz := size
	if sz.x < 2.0:
		return
	var ctrl := PackedVector2Array()
	for p in ROUTE:
		ctrl.append(p * sz)
	_pts.clear()
	_cum.clear()
	var n := ctrl.size()
	for i in n - 1:
		var p0 := ctrl[maxi(i - 1, 0)]
		var p1 := ctrl[i]
		var p2 := ctrl[i + 1]
		var p3 := ctrl[mini(i + 2, n - 1)]
		for k in SAMPLES_PER_SEGMENT:
			var t := float(k) / SAMPLES_PER_SEGMENT
			_pts.append(_catmull(p0, p1, p2, p3, t))
	_pts.append(ctrl[n - 1])
	var d := 0.0
	_cum.append(0.0)
	for i in range(1, _pts.size()):
		d += _pts[i].distance_to(_pts[i - 1])
		_cum.append(d)
	_total = maxf(d, 1.0)
	_node_d.clear()
	for idx in NODES:
		_node_d.append(_cum[idx * SAMPLES_PER_SEGMENT])
	for i in _stamps.size():
		var c := _pts[NODES[i + 1] * SAMPLES_PER_SEGMENT]
		_stamps[i].position = c - _stamps[i].size * 0.5
		_labels[i].reset_size()
		var lw := maxf(_labels[i].get_combined_minimum_size().x, 220.0)
		_labels[i].size = Vector2(lw, 0)
		_labels[i].position = c + Vector2(-lw * 0.5, STAMP_SIZE * 0.5 + 8.0)
	_next_card.reset_size()
	var cs := _next_card.get_combined_minimum_size()
	_next_card.position = Vector2(-cs.x - 64.0, -cs.y - 56.0)
	_deco.queue_redraw()
	_route.queue_redraw()


static func _catmull(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, t: float) -> Vector2:
	var t2 := t * t
	var t3 := t2 * t
	return 0.5 * ((2.0 * p1) + (p2 - p0) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 + (3.0 * p1 - p0 - 3.0 * p2 + p3) * t3)


## Point and unit tangent on the road at distance d (px).
func _at(d: float) -> Array:
	d = clampf(d, 0.0, _total)
	var lo := 0
	var hi := _cum.size() - 1
	while hi - lo > 1:
		var mid := (lo + hi) >> 1
		if _cum[mid] <= d:
			lo = mid
		else:
			hi = mid
	var seg := maxf(_cum[hi] - _cum[lo], 1e-4)
	var t := (d - _cum[lo]) / seg
	return [_pts[lo].lerp(_pts[hi], t), (_pts[hi] - _pts[lo]).normalized()]


# ---------------------------------------------------------------- show

## status: Game.campaign_status(). slam: the leg just finished gets its seal slammed down
## (coming from its results or its arrival) instead of already sitting there.
func open(status: Dictionary, slam: bool) -> void:
	_status = status
	shown = true
	visible = true
	modulate.a = 1.0
	_layout()
	var game := UIApi.game()
	var legs: Array = game.CAMPAIGN
	_from = clampi(int(status["leg"]), 0, legs.size())
	_livery = game.car_colors()
	var results: Dictionary = status["results"]
	var slam_i := _from - 1 if slam else -1
	for i in legs.size():
		var leg: Dictionary = legs[i]
		var h := _stamps[i]
		var done := i < _from
		h.text = str(leg["kanji"])
		var labs := _labels[i].get_children()
		(labs[0] as Label).text = "%s  ·  %s" % [leg["code"], "SPECIAL STAGE" if leg["kind"] == "stage" else "LIAISON"]
		(labs[1] as Label).text = "%s  %s" % [leg["title_jp"], leg["title"]]
		var res: Dictionary = results.get(leg["map"], {})
		(labs[2] as Label).text = game.format_time(float(res["time"])) if done and not res.is_empty() else ""
		(labs[2] as Label).visible = (labs[2] as Label).text != ""
		var medal := str(res.get("medal", ""))
		h.ink = _seal_ink(leg, medal)
		h.caption = medal.to_upper() if medal != "" else ("ARRIVED" if leg["kind"] == "liaison" else "")
		h.visible = done
		if done and i != slam_i:
			h.show_instant()
		elif done:
			h.modulate.a = 0.0
	_fill_header(legs)
	_fill_next(legs)
	_car_d = _node_d[_from]
	_draw_on = 0.0
	_ghost_alpha = 0.0
	_pulse_t = -1.0
	_dust.clear()
	traveling = true
	_play(slam_i)


func _seal_ink(leg: Dictionary, medal: String) -> Color:
	if leg["kind"] == "liaison":
		return UITheme.VERMILION
	match medal:
		"gold":
			return UITheme.GOLD_DEEP
		"silver":
			return Color("8b8fa6")
		"bronze":
			return UITheme.BRONZE.darkened(0.12)
	return UITheme.INK


func _fill_header(legs: Array) -> void:
	var stages := 0
	for leg: Dictionary in legs:
		if leg["kind"] == "stage":
			stages += 1
	if _from >= legs.size():
		_sub.text = "EVERY LEG DRIVEN  ·  ON TO THE FINISH"
	else:
		_sub.text = "LEG %d OF %d  ·  %d STAGES, SPRING TO AUTUMN" % [_from + 1, legs.size(), stages]
	_swash.size.x = _title.text_width() + 90.0


func _fill_next(legs: Array) -> void:
	var game := UIApi.game()
	if _from >= legs.size():
		_next_kicker.text = "THE FINISH  ·  完走"
		_next_kanji.text = "総合"
		_next_kanji.label_settings.font_color = UITheme.VERMILION
		_next_name.text = "RALLY CLASSIFICATION"
		_next_detail.text = "Six rivals, every stage time added up."
		_loading_label.text = "TALLYING THE TIMES"
		return
	var leg: Dictionary = legs[_from]
	var m: Dictionary = game.get_map(str(leg["map"]))
	var accent := UITheme.season_accent(str(m.get("season", "spring")))
	_next_kanji.text = str(leg["title_jp"])
	_next_kanji.label_settings.font_color = accent
	_next_name.text = str(leg["title"]).to_upper()
	if leg["kind"] == "stage":
		_next_kicker.text = "NEXT  ·  %s SPECIAL STAGE" % leg["code"]
		var gold := float((m.get("medals", {}) as Dictionary).get("gold", INF))
		var best: float = game.best_time(str(leg["map"]))
		_next_detail.text = "Against the clock  ·  gold %s%s" % [game.format_time(gold),
				"" if is_inf(best) else "  ·  best %s" % game.format_time(best)]
		_loading_label.text = "SETTING UP THE STAGE"
	else:
		var dest: Dictionary = legs[mini(_from + 1, legs.size() - 1)]
		_next_kicker.text = "NEXT  ·  %s LIAISON" % leg["code"]
		_next_detail.text = "Untimed. Take it easy to %s." % dest["title"]
		_loading_label.text = "LOADING THE ROAD"


func _play(slam_i: int) -> void:
	UIMotion.kill(_tween)
	_map.set_param("reveal", 0.0)
	_strip.reveal = 0.0
	_strip_kanji.progress = 0.0
	_swash.set_param("progress", 0.0)
	_swash.set_param("fade_out", 0.0)
	_swash.set_param("seed", randf() * 10.0)
	_title.play(0.55)
	_sub.modulate.a = 0.0
	for l in _labels:
		l.modulate.a = 0.0
	_next_holder.modulate.a = 0.0
	_tween = UIMotion.tween(self)
	_tween.set_parallel(true)
	_tween.tween_method(_map.param_setter(&"reveal"), 0.0, 1.0, 1.1).set_delay(0.1).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_property(_strip, "reveal", 1.0, 0.5).set_delay(0.3)
	_tween.tween_property(_strip_kanji, "progress", 1.0, 0.8).set_delay(0.45).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_tween.tween_method(_swash.param_setter(&"progress"), 0.0, 1.0, 0.5).set_delay(0.4).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_property(_sub, "modulate:a", 1.0, 0.4).set_delay(1.0)
	# The road is inked on from the start flag, 12 fps stepped like a hand-drawn line.
	_tween.tween_method(func(v: float) -> void:
		_draw_on = UIMotion.stepped(v, 12.0)
		_route.queue_redraw(), 0.0, 1.0, 1.0).set_delay(0.35)
	_tween.tween_method(func(v: float) -> void: _ghost_alpha = v, 0.0, 1.0, 0.5).set_delay(0.7)
	for i in _labels.size():
		_tween.tween_property(_labels[i], "modulate:a", 1.0, 0.35).set_delay(0.75 + i * 0.08)
	if slam_i >= 0:
		_tween.tween_callback(_stamps[slam_i].stamp).set_delay(0.95)
	var d0: float = _node_d[_from]
	var d1: float = _node_d[mini(_from + 1, _node_d.size() - 1)]
	_tween.tween_method(func(v: float) -> void:
		_car_d = lerpf(d0, d1, v)
		_route.queue_redraw(), 0.0, 1.0, TRAVEL_TIME).set_delay(TRAVEL_DELAY).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_tween.tween_callback(func() -> void: _pulse_t = 0.0).set_delay(TRAVEL_DELAY + TRAVEL_TIME - 0.05)
	UIMotion.rise_in(_next_holder, 1.2, 30.0, 0.6)
	_tween.tween_callback(_on_travel_done).set_delay(TRAVEL_DELAY + TRAVEL_TIME + 0.55)


func _on_travel_done() -> void:
	traveling = false
	travel_done.emit()


func _on_stamp_landed(i: int) -> void:
	shake_requested.emit(0.8)
	var leg: Dictionary = UIApi.game().CAMPAIGN[i]
	_petals.autumn = str(UIApi.game().get_map(str(leg["map"])).get("season", "")) == "autumn"
	_petals.burst(_stamps[i].position + _stamps[i].size * 0.5, 46, 800.0)


## Hide at once (the screen is covered by ink when this is called).
func close() -> void:
	if not shown:
		return
	shown = false
	traveling = false
	UIMotion.kill(_tween)
	visible = false


func _process(delta: float) -> void:
	if not visible:
		return
	var d := UIMotion.real_delta(delta)
	_time += d
	if _pulse_t >= 0.0:
		_pulse_t += d
	# Dust puffs behind the moving car, spawned and aged on 12 fps steps.
	_dust_clock += d
	if _dust_clock >= 1.0 / 12.0:
		_dust_clock = fmod(_dust_clock, 1.0 / 12.0)
		for i in range(_dust.size() - 1, -1, -1):
			var p := _dust[i]
			p.z += 1.0 / 12.0
			_dust[i] = p
			if p.z > 0.6:
				_dust.remove_at(i)
		if traveling and _car_d > _node_d[_from] + 4.0 and _car_d < _node_d[mini(_from + 1, _node_d.size() - 1)] - 4.0:
			var a: Array = _at(_car_d - 16.0)
			var side := Vector2(-(a[1] as Vector2).y, (a[1] as Vector2).x)
			var pos: Vector2 = a[0] + side * randf_range(-6.0, 6.0)
			_dust.append(Vector3(pos.x, pos.y, 0.0))
	_route.queue_redraw()


# ---------------------------------------------------------------- drawing

## Static scenery: frame, season watermarks, mountains, trees, villages, the bay's islands and
## a compass. Seeded, so the map is the same painting every time.
func _draw_deco() -> void:
	var sz := _deco.size
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var ink := UITheme.INK
	# Double ink frame.
	var r := Rect2(Vector2(26, 26), sz - Vector2(52, 52))
	_deco.draw_rect(r, Color(ink, 0.55), false, 3.0)
	_deco.draw_rect(r.grow(-9.0), Color(ink, 0.3), false, 1.5)
	# Season names as big faint brush watermarks.
	for wm: Array in SEASON_WATERMARKS:
		var fs := 230
		var gp: Vector2 = wm[1] * sz
		var gs := UITheme.FONT_BRUSH.get_string_size(wm[0], HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
		_deco.draw_string(UITheme.FONT_BRUSH, gp - Vector2(gs.x * 0.5, -fs * 0.35), wm[0], HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(ink, 0.07))
	# Mountains: cel triangles, lit side paper-warm, shadow side violet, ink ridge.
	var ranges := [[Vector2(0.06, 0.28), Vector2(0.3, 0.44), 9], [Vector2(0.62, 0.66), Vector2(0.95, 0.9), 11],
			[Vector2(0.3, 0.72), Vector2(0.55, 0.9), 6], [Vector2(0.72, 0.14), Vector2(0.94, 0.3), 6]]
	for rg: Array in ranges:
		for k in int(rg[2]):
			var p := Vector2(rng.randf_range(rg[0].x, rg[1].x), rng.randf_range(rg[0].y, rg[1].y)) * sz
			var s := rng.randf_range(34.0, 62.0)
			if _near_route(p, 70.0) or _over_label(Rect2(p - Vector2(s, s), Vector2(s * 2.0, s))):
				continue
			_mountain(p, s, p.x / sz.x)
	# Trees in clumps: blossom, summer green, maple.
	for k in 150:
		var p := Vector2(rng.randf_range(0.05, 0.95), rng.randf_range(0.08, 0.93)) * sz
		var u := p / sz
		if _near_route(p, 34.0) or _in_bay(u) or u.x < 0.36 and u.y < 0.23:
			continue
		var c := _tree_colour(u.x, rng.randf())
		var rad := rng.randf_range(6.0, 10.0)
		_deco.draw_circle(p + Vector2(2.5, 3.0), rad, Color(UITheme.INK, 0.12))
		_deco.draw_circle(p, rad, c)
		_deco.draw_circle(p + Vector2(-rad * 0.3, -rad * 0.3), rad * 0.45, c.lightened(0.25))
	# Villages: a few roofs by the road, clear of the leg seals and their labels.
	for v: Vector2 in [Vector2(0.1, 0.56), Vector2(0.36, 0.3), Vector2(0.61, 0.3), Vector2(0.84, 0.63), Vector2(0.94, 0.47)]:
		var vp := v * sz
		if _over_label(Rect2(vp - Vector2(28, 12), Vector2(56, 26))):
			continue
		for j in 3:
			var hp := vp + Vector2(j * 17.0 - 17.0, (j % 2) * 9.0)
			_deco.draw_rect(Rect2(hp - Vector2(6, 2), Vector2(12, 9)), UITheme.PAPER_WARM)
			_deco.draw_colored_polygon(PackedVector2Array([hp + Vector2(-9, -1), hp + Vector2(0, -9), hp + Vector2(9, -1)]), Color("4f5a6d"))
	# Islands in the bay.
	for isl: Vector2 in [Vector2(0.45, 0.1), Vector2(0.52, 0.14), Vector2(0.56, 0.08)]:
		var ip := isl * sz
		_deco.draw_circle(ip, 11.0, Color("9ccb6b"))
		_deco.draw_arc(ip, 11.0, 0.0, TAU, 24, Color(ink, 0.5), 1.5, true)
	# Compass rose.
	var cc := Vector2(sz.x - 110.0, 118.0)
	_deco.draw_arc(cc, 34.0, 0.0, TAU, 40, Color(ink, 0.45), 2.0, true)
	_deco.draw_colored_polygon(PackedVector2Array([cc + Vector2(0, -46), cc + Vector2(7, 0), cc + Vector2(-7, 0)]), UITheme.VERMILION)
	_deco.draw_colored_polygon(PackedVector2Array([cc + Vector2(0, 46), cc + Vector2(7, 0), cc + Vector2(-7, 0)]), Color(ink, 0.6))
	_deco.draw_string(UITheme.FONT_UI_BLACK, cc + Vector2(-6, -52), "N", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(ink, 0.7))


func _mountain(p: Vector2, s: float, u: float) -> void:
	var peak := p + Vector2(0, -s)
	var l := p + Vector2(-s * 0.9, 0)
	var r := p + Vector2(s * 0.9, 0)
	var lit := UITheme.PAPER_WARM.lerp(Color("f2b98a") if u > 0.62 else Color("cfe0b0"), 0.35)
	var shade := Color("9a92c8").lerp(lit, 0.3)
	_deco.draw_colored_polygon(PackedVector2Array([l, peak, p + Vector2(s * 0.08, 0)]), lit)
	_deco.draw_colored_polygon(PackedVector2Array([peak, r, p + Vector2(s * 0.08, 0)]), shade)
	_deco.draw_polyline(PackedVector2Array([l, peak, r]), Color(UITheme.INK, 0.6), 2.0, true)
	if s > 50.0:
		# Snow cap on the tall ones.
		_deco.draw_colored_polygon(PackedVector2Array([peak, peak + Vector2(-s * 0.22, s * 0.25), peak + Vector2(0, s * 0.18), peak + Vector2(s * 0.22, s * 0.25)]), Color(UITheme.PAPER, 0.95))


func _tree_colour(u: float, k: float) -> Color:
	if u < 0.33:
		return Color("f8c0d1") if k < 0.6 else Color("9ccb6b")
	if u < 0.64:
		return Color("6ea655") if k < 0.6 else Color("3f7348")
	return Color("e75b3d") if k < 0.5 else (Color("f5b04a") if k < 0.8 else Color("d13f35"))


func _in_bay(u: Vector2) -> bool:
	return u.x > 0.33 and u.x < 0.67 and u.y < 0.27


func _over_label(r: Rect2) -> bool:
	for i in _labels.size():
		var l := _labels[i]
		if Rect2(l.position, Vector2(l.size.x, l.get_combined_minimum_size().y)).grow(10.0).intersects(r) \
				or Rect2(_stamps[i].position, _stamps[i].size).intersects(r):
			return true
	return false


func _near_route(p: Vector2, dist: float) -> bool:
	var d2 := dist * dist
	for i in range(0, _pts.size(), 3):
		if _pts[i].distance_squared_to(p) < d2:
			return true
	return false


func _draw_route() -> void:
	if _pts.size() < 2:
		return
	var ink := UITheme.INK
	var shown_d := _total * _draw_on
	# Upcoming road: ink dashes.
	var d := 0.0
	while d < shown_d:
		var a: Array = _at(d)
		var b: Array = _at(minf(d + DASH, shown_d))
		_route.draw_line(a[0], b[0], Color(ink, 0.55), 4.0, true)
		d += DASH + GAP
	# Driven road: a solid vermilion trail over a paper under-stroke.
	var d_start: float = _node_d[0]
	var end := minf(_car_d, shown_d)
	var i := 1
	while i < _cum.size() and _cum[i - 1] < end:
		if _cum[i] > d_start:
			var p0 := _pts[i - 1]
			var p1: Vector2 = _pts[i] if _cum[i] <= end else (_at(end)[0] as Vector2)
			_route.draw_line(p0, p1, Color(UITheme.PAPER, 0.9), 11.0, true)
		i += 1
	i = 1
	while i < _cum.size() and _cum[i - 1] < end:
		var p0 := _pts[i - 1]
		var p1: Vector2 = _pts[i] if _cum[i] <= end else (_at(end)[0] as Vector2)
		_route.draw_line(p0, p1, UITheme.VERMILION, 5.5, true)
		i += 1
	# Start flag and goal flag.
	_flag(_pts[0], false)
	_flag(_pts[_pts.size() - 1], true)
	# Legs not driven yet: ghost seals (dashed ring, pale season kanji).
	var legs: Array = UIApi.game().CAMPAIGN
	for k in legs.size():
		if _stamps[k].visible:
			continue
		var c := _pts[NODES[k + 1] * SAMPLES_PER_SEGMENT]
		var rr := STAMP_SIZE * 0.5 - 4.0
		var next := k == _from
		var col := Color(UITheme.VERMILION if next else ink, (0.85 if next else 0.5) * _ghost_alpha)
		_route.draw_circle(c, rr, Color(UITheme.PAPER, 0.8 * _ghost_alpha))
		var segs := 28
		for s in segs:
			if s % 2 == 0:
				_route.draw_arc(c, rr, TAU * s / segs, TAU * (s + 1) / segs, 4, col, 2.5, true)
		var kj := str((legs[k] as Dictionary)["kanji"])
		var fs := 52
		var gs := UITheme.FONT_BRUSH.get_string_size(kj, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
		_route.draw_string(UITheme.FONT_BRUSH, c + Vector2(-gs.x * 0.5, fs * 0.36), kj, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(col, col.a * 0.8))
	# The next leg breathes; on arrival a ring ripples out from it.
	var nd := mini(_from + 1, NODES.size() - 1)
	var nc := _pts[NODES[nd] * SAMPLES_PER_SEGMENT]
	if _pulse_t >= 0.0:
		for w in 2:
			var t := _pulse_t - w * 0.18
			if t > 0.0 and t < 0.9:
				var e := UIMotion.out_cubic(t / 0.9)
				_route.draw_arc(nc, lerpf(STAMP_SIZE * 0.5, STAMP_SIZE * 1.1, e), 0.0, TAU, 48, Color(UITheme.VERMILION, (1.0 - e) * 0.8), lerpf(6.0, 1.0, e), true)
	# Dust puffs.
	for p in _dust:
		var k2 := p.z / 0.6
		_route.draw_circle(Vector2(p.x, p.y), lerpf(3.0, 9.0, k2), Color(UITheme.PAPER_WARM.darkened(0.12), 0.55 * (1.0 - k2)))
	_draw_car()


func _flag(p: Vector2, goal: bool) -> void:
	var ink := UITheme.INK
	_route.draw_line(p, p + Vector2(0, -44), ink, 3.0, true)
	var top := p + Vector2(1.5, -44)
	if goal:
		for yy in 3:
			for xx in 4:
				var col := ink if (xx + yy) % 2 == 0 else UITheme.PAPER
				_route.draw_rect(Rect2(top + Vector2(xx * 8.0, yy * 8.0), Vector2(8, 8)), col)
		_route.draw_rect(Rect2(top, Vector2(32, 24)), ink, false, 1.5)
	else:
		_route.draw_colored_polygon(PackedVector2Array([top, top + Vector2(30, 9), top + Vector2(0, 20)]), UITheme.VERMILION)
	var label := "GOAL" if goal else "START"
	var fs := 15
	var w := UITheme.FONT_UI_BLACK.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	_route.draw_string(UITheme.FONT_UI_BLACK, p + Vector2(-w * 0.5, 24), label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(ink, 0.75))
	_route.draw_circle(p, 6.0, ink)
	_route.draw_circle(p, 3.0, UITheme.PAPER)


## The player's car from above in its livery, riding the road with a 12 fps bob.
func _draw_car() -> void:
	var a: Array = _at(_car_d)
	var pos: Vector2 = a[0]
	var tan: Vector2 = a[1]
	var bob := sin(UIMotion.stepped(_time, 12.0) * 22.0) * (1.2 if traveling else 0.0)
	var primary: Color = _livery.get("primary", UITheme.PAPER)
	var secondary: Color = _livery.get("secondary", UITheme.SAKURA)
	var scale_k := 1.7
	_route.draw_set_transform(pos + Vector2(3, 5), tan.angle(), Vector2(scale_k, scale_k))
	_route.draw_rect(Rect2(-13, -8, 26, 16), Color(UITheme.INK, 0.2))
	_route.draw_set_transform(pos + Vector2(0, bob), tan.angle(), Vector2(scale_k, scale_k))
	# Wheels, body, stripe, glass, ink outline.
	for wx: float in [-8.0, 7.0]:
		for wy: float in [-8.5, 5.5]:
			_route.draw_rect(Rect2(wx, wy, 6, 3), UITheme.INK)
	var body := Rect2(-13, -7, 26, 14)
	_route.draw_rect(body, primary)
	_route.draw_rect(Rect2(-13, -1.6, 26, 3.2), secondary)
	_route.draw_rect(Rect2(1.5, -5.5, 5, 11), Color("3a3f55"))
	_route.draw_rect(Rect2(-9, -5, 3.5, 10), Color("3a3f55"))
	_route.draw_rect(Rect2(11, -6, 2, 3), Color("fff0d2"))
	_route.draw_rect(Rect2(11, 3, 2, 3), Color("fff0d2"))
	_route.draw_rect(body, UITheme.INK, false, 1.2)
	_route.draw_set_transform(Vector2.ZERO)
