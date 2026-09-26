extends Control
## Pause menu (tree paused; the UI root runs PROCESS_MODE_ALWAYS). A blurred, paper-tinted
## backdrop, a vertical tanzaku strip with 一時停止 painted on, and a stack of buttons that
## cascade in: Resume, Restart, Settings, Menu. In the campaign: Resume, Retry stage (stages
## only), Settings, Quit to title (progress is kept at the start of the leg).

signal settings_requested

const UITheme := preload("res://scripts/ui/ui_theme.gd")
const UIMotion := preload("res://scripts/ui/ui_motion.gd")
const UIApi := preload("res://scripts/ui/ui_api.gd")
const PaperCard := preload("res://scripts/ui/widgets/paper_card.gd")
const BrushKanji := preload("res://scripts/ui/widgets/brush_kanji.gd")
const InkButton := preload("res://scripts/ui/widgets/ink_button.gd")
const BLUR := preload("res://shaders/ui/backdrop_blur.gdshader")

var is_open := false

var _backdrop := ColorRect.new()
var _blur_mat := ShaderMaterial.new()
var _center := Control.new()
var _strip: PaperCard
var _kanji: BrushKanji
var _title: Label
var _sub: Label
var _buttons: Array[Button] = []
var _resume: Button
var _restart: Button
var _menu: Button
var _tween: Tween
var _amount := 0.0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_blur_mat.shader = BLUR
	_backdrop.material = _blur_mat
	_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_backdrop)

	_center.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_center)

	_strip = PaperCard.new()
	_strip.padding = Vector4(14, 30, 14, 30)
	_strip.radius = 16.0
	_strip.paper_alpha = 0.94
	_strip.custom_minimum_size = Vector2(120, 0)
	_strip.position = Vector2(-330, -250)
	_center.add_child(_strip)
	_kanji = BrushKanji.new()
	_kanji.text = "一時停止"
	_kanji.vertical = true
	_kanji.font_size = 76
	_kanji.use_strokes = false
	_kanji.color = UITheme.INK
	_strip.add_child(_kanji)

	var col := VBoxContainer.new()
	col.position = Vector2(-150, -240)
	col.add_theme_constant_override("separation", 14)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_center.add_child(col)
	_title = UITheme.make_label("PAUSED", UITheme.tracked(UITheme.FONT_TITLE, 10), 64, UITheme.INK)
	_title.label_settings.outline_size = 16
	_title.label_settings.outline_color = Color(UITheme.PAPER, 0.6)
	col.add_child(_title)
	_sub = UITheme.make_label("", UITheme.tracked(UITheme.FONT_UI_BLACK, 3), 15, Color(UITheme.INK, 0.6))
	col.add_child(_sub)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 14)
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(gap)
	_resume = _button(col, "Resume", &"PrimaryButton", _on_resume)
	_resume.press_sound = &"back"
	_restart = _button(col, "Restart", &"", _on_restart)
	_restart.press_sound = &"start"
	_button(col, "Settings", &"", func() -> void: settings_requested.emit())
	_menu = _button(col, "Main menu", &"QuietButton", _on_menu)
	_menu.press_sound = &"back"
	visible = false


## Wrap-around up/down focus through the visible buttons.
func _link_focus() -> void:
	var shown_buttons: Array[Button] = []
	for b in _buttons:
		if b.visible:
			shown_buttons.append(b)
	for i in shown_buttons.size():
		var prev := shown_buttons[(i - 1 + shown_buttons.size()) % shown_buttons.size()]
		var next := shown_buttons[(i + 1) % shown_buttons.size()]
		shown_buttons[i].focus_neighbor_top = prev.get_path()
		shown_buttons[i].focus_neighbor_bottom = next.get_path()
		shown_buttons[i].focus_neighbor_left = shown_buttons[i].get_path()
		shown_buttons[i].focus_neighbor_right = shown_buttons[i].get_path()


func _button(parent: Control, text: String, variation: StringName, cb: Callable) -> InkButton:
	var b := InkButton.new()
	b.text = text
	if variation != &"":
		b.theme_type_variation = variation
	b.custom_minimum_size = Vector2(340, 58)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.pressed.connect(cb)
	parent.add_child(b)
	_buttons.append(b)
	return b


func _set_amount(v: float) -> void:
	_amount = v
	_blur_mat.set_shader_parameter("amount", v)


func open() -> void:
	if is_open:
		return
	is_open = true
	visible = true
	var game := UIApi.game()
	var m: Dictionary = game.get_map(str(game.map_id))
	var leg: Dictionary = game.campaign_current_leg()
	var liaison: bool = str(game.mode) == str(game.MODE_LIAISON)
	if not leg.is_empty():
		_sub.text = "%s  ·  %s  ·  CAMPAIGN" % [leg["code"], str(m.get("name", "")).to_upper()]
	else:
		var free: bool = str(game.mode) == str(game.MODE_FREE_ROAM)
		_sub.text = "%s  ·  %s" % [str(m.get("name", "")).to_upper(), "FREE ROAM" if free else "TIME TRIAL"]
	_restart.visible = not liaison
	_restart.text = "Retry stage" if not leg.is_empty() else "Restart"
	_menu.text = "Quit to title" if not leg.is_empty() else "Main menu"
	_link_focus()
	_kanji.color = UITheme.season_accent(str(m.get("season", "spring"))).darkened(0.05)
	UIMotion.kill(_tween)
	_tween = UIMotion.tween(self)
	_tween.set_parallel(true)
	_tween.tween_method(_set_amount, _amount, 1.0, 0.35).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_strip.reveal = 0.0
	_strip.modulate.a = 1.0
	_kanji.progress = 0.0
	_tween.tween_property(_strip, "reveal", 1.0, 0.45).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_property(_kanji, "progress", 1.0, 0.7).set_delay(0.15).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	var d := 0.05
	for c: Control in [_title, _sub]:
		c.modulate.a = 0.0
		c.position.x = -30.0
		_tween.tween_property(c, "modulate:a", 1.0, 0.3).set_delay(d)
		_tween.tween_property(c, "position:x", 0.0, 0.5).set_delay(d).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
		d += 0.05
	d += 0.05
	for b in _buttons:
		b.modulate.a = 0.0
		b.position.x = -50.0
		_tween.tween_property(b, "modulate:a", 1.0, 0.25).set_delay(d)
		_tween.tween_property(b, "position:x", 0.0, 0.5).set_delay(d).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		d += 0.045
	_resume.grab_focus()


func close() -> void:
	if not is_open:
		return
	is_open = false
	UIMotion.kill(_tween)
	get_viewport().gui_release_focus()
	_tween = UIMotion.tween(self)
	_tween.set_parallel(true)
	_tween.tween_method(_set_amount, _amount, 0.0, 0.28)
	_tween.tween_property(_strip, "reveal", 0.0, 0.25)
	var d := 0.0
	for c: Control in [_title, _sub]:
		_tween.tween_property(c, "modulate:a", 0.0, 0.18).set_delay(d)
	for b in _buttons:
		_tween.tween_property(b, "modulate:a", 0.0, 0.16).set_delay(d)
		_tween.tween_property(b, "position:x", 30.0, 0.2).set_delay(d).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
		d += 0.025
	_tween.chain().tween_callback(hide)


func _on_resume() -> void:
	UIApi.game().set_paused(false)


func _on_restart() -> void:
	UIApi.game().request_restart()


func _on_menu() -> void:
	UIApi.game().request_menu()
