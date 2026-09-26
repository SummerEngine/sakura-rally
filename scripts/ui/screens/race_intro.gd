extends Control
## Race intro title card (tanzaku strip with the map's brush kanji, name over a painted swash,
## tagline, mode / best chips) and the kinetic countdown 3-2-1-GO with 三/二/一 painted behind
## the numerals, an ink splash and a soft flash on GO.

const UITheme := preload("res://scripts/ui/ui_theme.gd")
const UIMotion := preload("res://scripts/ui/ui_motion.gd")
const UIApi := preload("res://scripts/ui/ui_api.gd")
const BrushKanji := preload("res://scripts/ui/widgets/brush_kanji.gd")
const KineticText := preload("res://scripts/ui/widgets/kinetic_text.gd")
const PaperCard := preload("res://scripts/ui/widgets/paper_card.gd")
const ShaderRect := preload("res://scripts/ui/widgets/shader_rect.gd")
const BRUSH_BAND := preload("res://shaders/ui/brush_band.gdshader")
const INK_SPLASH := preload("res://shaders/ui/ink_splash.gdshader")

const COUNT_KANJI := {3: "三", 2: "二", 1: "一"}

var card_visible := false

# Title card
var _card := Control.new()
var _strip: PaperCard
var _strip_kanji: BrushKanji
var _swash: ShaderRect
var _name: KineticText
var _tagline: Label
var _chips := HBoxContainer.new()
var _mode_chip: Label
var _best_chip: Label
var _card_tween: Tween

# Countdown
var _count := Control.new()
var _ring := Control.new()
var _ring_t := 1.0
var _count_kanji: BrushKanji
var _numeral: KineticText
var _go_splash: ShaderRect
var _go_text: KineticText
var _go_kanji: BrushKanji
var _flash := ColorRect.new()
var _count_tween: Tween
var _accent := UITheme.SAKURA


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_card()
	_build_countdown()
	_flash.color = Color(1, 0.98, 0.95, 0.0)
	_flash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_flash)
	_card.visible = false
	_count.visible = false


# ---------------------------------------------------------------- title card

func _build_card() -> void:
	_card.set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
	_card.offset_left = 110
	_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_card)

	_strip = PaperCard.new()
	_strip.padding = Vector4(10, 26, 10, 26)
	_strip.radius = 14.0
	_strip.paper_alpha = 0.92
	_strip.custom_minimum_size = Vector2(118, 0)
	_card.add_child(_strip)
	_strip_kanji = BrushKanji.new()
	_strip_kanji.vertical = true
	_strip_kanji.font_size = 84
	_strip_kanji.use_strokes = false
	_strip.add_child(_strip_kanji)

	var right := Control.new()
	right.position = Vector2(166, 0)
	right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_child(right)
	right.name = "Right"

	_swash = ShaderRect.new(BRUSH_BAND)
	_swash.position = Vector2(-44, 4)
	_swash.size = Vector2(760, 120)
	right.add_child(_swash)

	_name = KineticText.new()
	_name.font = UITheme.FONT_TITLE
	_name.font_size = 74
	_name.tracking = 6.0
	_name.color = UITheme.WHITE
	_name.shadow = Color(UITheme.INK, 0.28)
	_name.shadow_offset = Vector2(0, 4)
	_name.style = KineticText.Style.DROP
	_name.stepped_fps = 12.0
	_name.stagger = 0.04
	_name.distance = 50.0
	_name.position = Vector2(0, 14)
	right.add_child(_name)

	_tagline = UITheme.make_label("", UITheme.FONT_UI_BOLD, 24, UITheme.INK)
	_tagline.label_settings.outline_size = 12
	_tagline.label_settings.outline_color = Color(1, 1, 1, 0.55)
	_tagline.position = Vector2(4, 150)
	right.add_child(_tagline)

	_chips.position = Vector2(2, 200)
	_chips.add_theme_constant_override("separation", 10)
	_chips.mouse_filter = Control.MOUSE_FILTER_IGNORE
	right.add_child(_chips)
	_mode_chip = _chip(_chips, UITheme.INK, UITheme.PAPER)
	_best_chip = _chip(_chips, Color(UITheme.PAPER, 0.92), UITheme.INK)


func _chip(parent: Control, bg: Color, fg: Color) -> Label:
	var p := PanelContainer.new()
	var sb := UITheme.pill(bg, 0.12)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	p.add_theme_stylebox_override("panel", sb)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := UITheme.make_label("", UITheme.tracked(UITheme.FONT_UI_BLACK, 2), 15, fg)
	p.add_child(l)
	parent.add_child(p)
	return l


func setup(map_id: String, mode: String) -> void:
	var m: Dictionary = UIApi.game().get_map(map_id)
	_accent = UITheme.season_accent(str(m.get("season", "spring")))
	_strip_kanji.text = str(m.get("name_jp", ""))
	_strip_kanji.color = _accent.darkened(0.05)
	_name.text = str(m.get("name", "")).to_upper()
	_tagline.text = str(m.get("tagline", ""))
	_swash.set_param("paint", _accent)
	_swash.size.x = _name.text_width() + 110.0
	var tt: bool = mode == str(UIApi.game().MODE_TIME_TRIAL)
	_mode_chip.text = "TIME TRIAL" if tt else "FREE ROAM"
	var best: float = UIApi.game().best_time(map_id)
	_best_chip.get_parent().visible = tt
	if tt:
		var gold: float = (m.get("medals", {}) as Dictionary).get("gold", INF)
		if is_inf(best):
			_best_chip.text = "GOLD  %s" % UIApi.game().format_time(gold)
		else:
			_best_chip.text = "BEST  %s" % UIApi.game().format_time(best)
	var vp := get_viewport_rect().size
	_card.offset_top = vp.y * 0.30
	_card.offset_bottom = _card.offset_top


func show_card() -> void:
	UIMotion.kill(_card_tween)
	card_visible = true
	_card.visible = true
	_card.modulate.a = 1.0
	_strip.position = Vector2(0, -40)
	_strip.modulate.a = 0.0
	_strip.reveal = 0.0
	_strip_kanji.progress = 0.0
	_swash.set_param("progress", 0.0)
	_swash.set_param("fade_out", 0.0)
	_swash.set_param("seed", randf() * 10.0)
	_name.play(0.35)
	_tagline.modulate.a = 0.0
	_chips.modulate.a = 0.0
	_card_tween = UIMotion.tween(self)
	_card_tween.set_parallel(true)
	_card_tween.tween_property(_strip, "modulate:a", 1.0, 0.25)
	_card_tween.tween_property(_strip, "position", Vector2.ZERO, 0.6).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_card_tween.tween_property(_strip, "reveal", 1.0, 0.5)
	_card_tween.tween_property(_strip_kanji, "progress", 1.0, 1.0).set_delay(0.3).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_card_tween.tween_method(_swash.param_setter(&"progress"), 0.0, 1.0, 0.55).set_delay(0.2).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	var tp := _tagline.position
	_tagline.position = tp + Vector2(-24, 0)
	_card_tween.tween_property(_tagline, "modulate:a", 1.0, 0.5).set_delay(0.9)
	_card_tween.tween_property(_tagline, "position", tp, 0.6).set_delay(0.9).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	UIMotion.rise_in(_chips, 1.15, 14.0, 0.45)


func hide_card() -> void:
	if not card_visible:
		return
	card_visible = false
	UIMotion.kill(_card_tween)
	_card_tween = UIMotion.tween(self)
	_name.play_out()
	_card_tween.set_parallel(true)
	_card_tween.tween_method(_swash.param_setter(&"fade_out"), 0.0, 1.0, 0.5)
	_card_tween.tween_property(_tagline, "modulate:a", 0.0, 0.25)
	_card_tween.tween_property(_chips, "modulate:a", 0.0, 0.2)
	_card_tween.tween_property(_strip, "reveal", 0.0, 0.45).set_delay(0.1)
	_card_tween.tween_property(_strip_kanji, "modulate:a", 0.0, 0.3)
	_card_tween.chain().tween_callback(func() -> void:
		_card.visible = false
		_strip_kanji.modulate.a = 1.0)


# ---------------------------------------------------------------- countdown

func _build_countdown() -> void:
	_count.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_count.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_count)

	_go_splash = ShaderRect.new(INK_SPLASH)
	_go_splash.size = Vector2(900, 900)
	_count.add_child(_go_splash)

	_ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ring.draw.connect(_draw_ring)
	_count.add_child(_ring)

	_count_kanji = BrushKanji.new()
	_count_kanji.size = Vector2(500, 500)
	_count_kanji.color = Color(UITheme.SAKURA, 0.9)
	_count.add_child(_count_kanji)

	_numeral = KineticText.new()
	_numeral.font = UITheme.FONT_TITLE
	_numeral.font_size = 250
	_numeral.color = UITheme.WHITE
	_numeral.shadow = Color(UITheme.INK, 0.35)
	_numeral.shadow_offset = Vector2(0, 8)
	_numeral.style = KineticText.Style.SLAM
	_numeral.char_duration = 0.32
	_numeral.stepped_fps = 24.0
	_numeral.align = HORIZONTAL_ALIGNMENT_CENTER
	_numeral.distance = 80.0
	_count.add_child(_numeral)

	_go_text = KineticText.new()
	_go_text.font = UITheme.FONT_TITLE
	_go_text.font_size = 210
	_go_text.tracking = 10.0
	_go_text.color = UITheme.WHITE
	_go_text.shadow = Color(UITheme.INK, 0.3)
	_go_text.shadow_offset = Vector2(0, 8)
	_go_text.style = KineticText.Style.POP
	_go_text.stagger = 0.06
	_go_text.char_duration = 0.4
	_go_text.align = HORIZONTAL_ALIGNMENT_CENTER
	_go_text.text = "GO!"
	_count.add_child(_go_text)

	_go_kanji = BrushKanji.new()
	_go_kanji.text = "出発"
	_go_kanji.font_size = 88
	_go_kanji.color = UITheme.PAPER
	_go_kanji.use_strokes = false
	_count.add_child(_go_kanji)


func _layout_countdown() -> void:
	var c := get_viewport_rect().size * Vector2(0.5, 0.42)
	_go_splash.position = c - _go_splash.size * 0.5
	_ring.position = c - Vector2(300, 300)
	_ring.size = Vector2(600, 600)
	_count_kanji.position = c - _count_kanji.size * 0.5
	_numeral.size = Vector2(600, 320)
	_numeral.position = c - _numeral.size * 0.5
	_go_text.size = Vector2(900, 280)
	_go_text.position = c - _go_text.size * 0.5 - Vector2(0, 20)
	_go_kanji.size = _go_kanji.custom_minimum_size
	_go_kanji.position = c + Vector2(-_go_kanji.size.x * 0.5, 112)


func tick(value: int) -> void:
	hide_card()
	_count.visible = true
	_layout_countdown()
	UIMotion.kill(_count_tween)
	_count_tween = UIMotion.tween(self)
	if value > 0:
		UIApi.stinger(&"countdown")
		_go_text.visible = false
		_go_kanji.visible = false
		_go_splash.visible = false
		_numeral.visible = true
		_numeral.modulate.a = 1.0
		_numeral.text = str(value)
		_numeral.play()
		_count_kanji.visible = true
		_count_kanji.modulate.a = 1.0
		_count_kanji.text = COUNT_KANJI.get(value, "")
		_count_kanji.color = Color(_accent, 0.9)
		_count_kanji.play(0.55)
		_ring_t = 0.0
		_count_tween.tween_method(func(v: float) -> void:
			_ring_t = v
			_ring.queue_redraw(), 0.0, 1.0, 0.8)
		_count_tween.parallel().tween_property(_numeral, "modulate:a", 0.0, 0.2).set_delay(0.78)
		_count_tween.parallel().tween_property(_count_kanji, "modulate:a", 0.0, 0.25).set_delay(0.75)
	else:
		UIApi.stinger(&"go")
		_numeral.visible = false
		_count_kanji.visible = false
		_ring_t = 1.0
		_ring.queue_redraw()
		_go_text.visible = true
		_go_text.modulate.a = 1.0
		_go_text.play()
		_go_kanji.visible = true
		_go_kanji.modulate.a = 1.0
		_go_kanji.play(0.4, 0.12)
		_go_splash.visible = true
		_go_splash.modulate.a = 1.0
		_go_splash.set_param("seed", randf() * 30.0)
		_go_splash.set_param("ink", UITheme.VERMILION)
		_go_splash.set_param("fade", 0.0)
		_go_splash.set_param("progress", 0.0)
		_count_tween.tween_method(_go_splash.param_setter(&"progress"), 0.0, 1.0, 0.35)
		_flash.color.a = 0.55
		_count_tween.parallel().tween_property(_flash, "color:a", 0.0, 0.45).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_count_tween.tween_interval(0.55)
		_count_tween.tween_callback(_go_text.play_out)
		_count_tween.tween_method(_go_splash.param_setter(&"fade"), 0.0, 1.0, 0.6)
		_count_tween.parallel().tween_property(_go_kanji, "modulate:a", 0.0, 0.35)
		_count_tween.tween_callback(func() -> void: _count.visible = false)


func _draw_ring() -> void:
	if _ring_t >= 1.0:
		return
	var c := _ring.size * 0.5
	var e := UIMotion.out_expo(_ring_t)
	var r := lerpf(150.0, 290.0, e)
	var a := (1.0 - _ring_t) * 0.8
	_ring.draw_arc(c, r, 0.0, TAU, 96, Color(UITheme.WHITE, a), lerpf(10.0, 1.5, e), true)
	# Progress sweep: a thin accent arc that closes over the second.
	var sweep := UIMotion.out_cubic(minf(_ring_t / 0.9, 1.0))
	_ring.draw_arc(c, 190.0, -PI * 0.5, -PI * 0.5 + TAU * sweep, 96, Color(_accent, 0.9 * (1.0 - smoothstep(0.8, 1.0, _ring_t))), 5.0, true)


## Hide everything immediately (menu / restart).
func reset() -> void:
	UIMotion.kill(_card_tween)
	UIMotion.kill(_count_tween)
	card_visible = false
	_card.visible = false
	_count.visible = false
	_flash.color.a = 0.0
