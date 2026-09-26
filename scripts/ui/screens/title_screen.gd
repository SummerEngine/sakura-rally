extends Control
## Title / main menu over the live 3D flyover: brush-painted 桜 logo, kinetic wordmark,
## hanko stamp, map cards, mode + livery pickers, settings / quit, drifting petals.

signal settings_requested
signal shake_requested(strength: float)

const UITheme := preload("res://scripts/ui/ui_theme.gd")
const UIMotion := preload("res://scripts/ui/ui_motion.gd")
const UIApi := preload("res://scripts/ui/ui_api.gd")
const BrushKanji := preload("res://scripts/ui/widgets/brush_kanji.gd")
const KineticText := preload("res://scripts/ui/widgets/kinetic_text.gd")
const Hanko := preload("res://scripts/ui/widgets/hanko.gd")
const MapCard := preload("res://scripts/ui/widgets/map_card.gd")
const Segmented := preload("res://scripts/ui/widgets/segmented.gd")
const Swatches := preload("res://scripts/ui/widgets/livery_swatches.gd")
const InkButton := preload("res://scripts/ui/widgets/ink_button.gd")
const PetalField := preload("res://scripts/ui/widgets/petal_field.gd")
const KeyHints := preload("res://scripts/ui/widgets/key_hints.gd")

const MARGIN := Vector2(96, 64)
const MODES := ["time_trial", "free_roam"]

var active := false

var _scrim := TextureRect.new()
var _petals: PetalField
var _logo := Control.new()
var _kanji: BrushKanji
var _wordmark: KineticText
var _subline := HBoxContainer.new()
var _hanko: Hanko
var _menu := VBoxContainer.new()
var _mode_row: Control
var _livery_row: Control
var _mode: Segmented
var _swatches: Swatches
var _cards_row := HBoxContainer.new()
var _cards: Array[MapCard] = []
var _buttons_row := HBoxContainer.new()
var _settings_btn: Button
var _quit_btn: Button
var _hint: Control
var _time := 0.0
var _logo_base := Vector2.ZERO
var _menu_base := Vector2.ZERO
var _parallax := Vector2.ZERO
var _last_card := 0
var _intro_tween: Tween
var _petals_warm := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_scrim()
	_petals = PetalField.new()
	add_child(_petals)
	_build_logo()
	_build_menu()
	_hint = KeyHints.new()
	_hint.entries = [
		[["W", "A", "S", "D"], ["RT", "LT", "L"], "Drive"],
		[["Space"], ["A"], "Handbrake"],
		[["Q", "E"], ["LB", "RB"], "Shift"],
		[["C"], ["Y"], "Camera"],
		[["R"], ["Back"], "Reset"],
		[["Esc"], ["Start"], "Pause"],
	]
	_hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_hint.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_hint.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_hint.offset_left = -MARGIN.x * 0.6
	_hint.offset_right = -MARGIN.x * 0.6
	_hint.offset_top = -MARGIN.y * 0.9
	_hint.offset_bottom = -MARGIN.y * 0.9
	add_child(_hint)
	resized.connect(_capture_bases.call_deferred)
	visible = false


func _build_scrim() -> void:
	# Soft paper wash from the left so the menu column reads over a bright painted scene.
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.28, 0.5, 0.72])
	g.colors = PackedColorArray([Color(UITheme.PAPER, 0.62), Color(UITheme.PAPER, 0.42), Color(UITheme.PAPER, 0.14), Color(UITheme.PAPER, 0.0)])
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.width = 512
	gt.height = 8
	gt.fill_from = Vector2(0, 0)
	gt.fill_to = Vector2(1, 0)
	_scrim.texture = gt
	_scrim.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_scrim.stretch_mode = TextureRect.STRETCH_SCALE
	_scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_scrim)


func _build_logo() -> void:
	_logo.position = MARGIN - Vector2(26, 28)
	_logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_logo)
	_kanji = BrushKanji.new()
	_kanji.text = "桜"
	_kanji.size = Vector2(250, 250)
	_kanji.color = UITheme.INK
	_kanji.halo = Color(1, 1, 1, 0.45)
	_kanji.halo_size = 26
	_logo.add_child(_kanji)

	var col := VBoxContainer.new()
	col.position = Vector2(262, 62)
	col.add_theme_constant_override("separation", 10)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_logo.add_child(col)
	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 18)
	title_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(title_row)
	_wordmark = KineticText.new()
	_wordmark.text = "SAKURA RALLY"
	_wordmark.font = UITheme.FONT_TITLE
	_wordmark.font_size = 66
	_wordmark.tracking = 14.0
	_wordmark.color = UITheme.INK
	_wordmark.halo = Color(1, 1, 1, 0.5)
	_wordmark.halo_size = 16
	_wordmark.style = KineticText.Style.DROP
	_wordmark.stepped_fps = 12.0
	_wordmark.stagger = 0.05
	_wordmark.char_duration = 0.55
	_wordmark.distance = 56.0
	title_row.add_child(_wordmark)
	_hanko = Hanko.new()
	_hanko.text = "山道"
	_hanko.custom_minimum_size = Vector2(52, 86)
	_hanko.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_hanko.rest_rotation = 0.08
	_hanko.landed.connect(func() -> void: shake_requested.emit(0.35))
	title_row.add_child(_hanko)

	_subline.add_theme_constant_override("separation", 16)
	_subline.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_subline)
	var jp := UITheme.make_label("桜ラリー", UITheme.FONT_BRUSH, 30, UITheme.SAKURA)
	jp.label_settings.outline_size = 12
	jp.label_settings.outline_color = Color(1, 1, 1, 0.5)
	_subline.add_child(jp)
	var bar := ColorRect.new()
	bar.color = Color(UITheme.INK, 0.25)
	bar.custom_minimum_size = Vector2(36, 2)
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_subline.add_child(bar)
	var tag := UITheme.make_label("A quiet rally through Japan's mountain roads", UITheme.FONT_UI_BOLD, 20, Color(UITheme.INK, 0.78))
	tag.label_settings.outline_size = 10
	tag.label_settings.outline_color = Color(1, 1, 1, 0.45)
	tag.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_subline.add_child(tag)


func _row(label_text: String, control: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 20)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := UITheme.make_label(label_text, UITheme.tracked(UITheme.FONT_UI_BLACK, 3), 14, Color(UITheme.INK, 0.66))
	l.custom_minimum_size = Vector2(92, 0)
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(l)
	row.add_child(control)
	return row


func _build_menu() -> void:
	_menu.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_menu.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_menu.offset_left = MARGIN.x
	_menu.offset_right = MARGIN.x
	_menu.offset_top = -MARGIN.y
	_menu.offset_bottom = -MARGIN.y
	_menu.add_theme_constant_override("separation", 14)
	_menu.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_menu)

	_mode = Segmented.new()
	_mode.options = PackedStringArray(["Time Trial", "Free Roam"])
	_mode.min_segment_width = 150.0
	_mode.selected = _initial_mode()
	_mode_row = _row("MODE", _mode)
	_menu.add_child(_mode_row)

	_swatches = Swatches.new()
	_swatches.setup(UIApi.game().CAR_COLORS, int(UIApi.setting("car_color")))
	_swatches.changed.connect(func(i: int) -> void: UIApi.game().set_setting("car_color", i))
	_livery_row = _row("LIVERY", _swatches)
	_menu.add_child(_livery_row)

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 14)
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_menu.add_child(gap)

	_cards_row.add_theme_constant_override("separation", 26)
	_cards_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_menu.add_child(_cards_row)
	for m: Dictionary in UIApi.game().MAPS:
		var card := MapCard.new()
		card.setup(m)
		card.pressed.connect(_on_card_pressed.bind(card))
		card.focus_entered.connect(func() -> void: _last_card = _cards.find(card))
		_cards_row.add_child(card)
		_cards.append(card)

	_buttons_row.add_theme_constant_override("separation", 8)
	_buttons_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_menu.add_child(_buttons_row)
	_settings_btn = _quiet_button("Settings")
	_settings_btn.pressed.connect(func() -> void: settings_requested.emit())
	_buttons_row.add_child(_settings_btn)
	_quit_btn = _quiet_button("Quit")
	_quit_btn.press_sound = &"back"
	_quit_btn.pressed.connect(func() -> void: UIApi.game().request_quit())
	_buttons_row.add_child(_quit_btn)

	# Row-to-row navigation (left / right inside pickers changes their value).
	_mode.focus_neighbor_bottom = _swatches.get_path()
	_swatches.focus_neighbor_top = _mode.get_path()
	_swatches.focus_neighbor_bottom = _cards[0].get_path()
	for i in _cards.size():
		_cards[i].focus_neighbor_top = _swatches.get_path()
		_cards[i].focus_neighbor_bottom = _settings_btn.get_path()
	_settings_btn.focus_neighbor_top = _cards[0].get_path()
	_quit_btn.focus_neighbor_top = _cards[mini(1, _cards.size() - 1)].get_path()


## Time Trial until the player has driven once; afterwards the last mode played.
func _initial_mode() -> int:
	if str(UIApi.game().map_id) == "":
		return 0
	return maxi(MODES.find(str(UIApi.game().mode)), 0)


func _quiet_button(text: String) -> Button:
	var b := InkButton.new()
	b.text = text
	b.theme_type_variation = &"QuietButton"
	b.add_theme_font_size_override("font_size", 20)
	return b


func _capture_bases() -> void:
	_logo_base = _logo.position - _parallax * 1.0
	_menu_base = _menu.position - _parallax * 0.4


# ---------------------------------------------------------------- show / hide

func enter() -> void:
	active = true
	visible = true
	modulate.a = 1.0
	for c in _cards:
		c.refresh()
	_mode.selected = _initial_mode()
	await get_tree().process_frame
	if not active:
		return
	_capture_bases()
	_play_intro()
	var idx := 0
	for i in _cards.size():
		if str(_cards[i].map.get("id", "")) == str(UIApi.game().map_id):
			idx = i
	_cards[idx].grab_focus()


func leave(instant: bool = false) -> void:
	if not active:
		return
	active = false
	UIMotion.kill(_intro_tween)
	if instant:
		visible = false
		return
	var tw := UIMotion.tween(self)
	tw.tween_property(self, "modulate:a", 0.0, 0.45).set_delay(0.15)
	tw.tween_callback(hide)
	UIMotion.slide_out(_logo, Vector2(0, -36))
	_wordmark.play_out()
	var chosen := _cards[_last_card] if _last_card < _cards.size() else null
	for i in _cards.size():
		if _cards[i] != chosen:
			UIMotion.slide_out(_cards[i], Vector2(0, 60), 0.02 * i)
	for r: Control in [_mode_row, _livery_row, _buttons_row]:
		UIMotion.slide_out(r, Vector2(-40, 0))
	if chosen != null:
		chosen.pivot_offset = chosen.size * 0.5
		var ct := UIMotion.tween(chosen)
		ct.tween_property(chosen, "scale", Vector2(1.05, 1.05), 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		ct.tween_property(chosen, "modulate:a", 0.0, 0.3)


func _play_intro() -> void:
	UIMotion.kill(_intro_tween)
	_logo.modulate.a = 1.0
	_logo.position = _logo_base
	_scrim.modulate.a = 0.0
	_intro_tween = UIMotion.tween(self)
	_intro_tween.tween_property(_scrim, "modulate:a", 1.0, 0.8)
	_kanji.play(1.8, 0.1)
	_wordmark.play(0.55)
	_hanko.modulate.a = 0.0
	_hanko.stamp(1.75)
	_subline.modulate.a = 0.0
	UIMotion.rise_in(_subline, 1.1, 16.0, 0.6)
	var rows: Array[Control] = [_mode_row, _livery_row]
	var delay := 0.95
	for r in rows:
		UIMotion.rise_in(r, delay, 28.0)
		delay += 0.08
	for c in _cards:
		c.scale = Vector2.ONE
		UIMotion.rise_in(c, delay, 60.0, 0.7)
		delay += 0.12
	UIMotion.rise_in(_buttons_row, delay + 0.05, 24.0)
	_hint.modulate.a = 0.0
	UIMotion.tween(_hint).tween_property(_hint, "modulate:a", 1.0, 0.8).set_delay(delay + 0.3)
	_petals.intensity = 1.0
	if not _petals_warm:
		_petals_warm = true
		_petals.prewarm()


# ---------------------------------------------------------------- events

func _on_card_pressed(card: MapCard) -> void:
	if not active:
		return
	UIApi.ui_sound(&"start")
	_last_card = _cards.find(card)
	var mode: String = MODES[_mode.selected]
	UIApi.game().request_start(str(card.map.get("id", "")), mode)


func focus_settings_button() -> void:
	_settings_btn.grab_focus()


func _process(delta: float) -> void:
	if not visible:
		return
	var d := UIMotion.real_delta(delta)
	_time += d
	var vp := get_viewport_rect().size
	var m := get_viewport().get_mouse_position() / vp - Vector2(0.5, 0.5)
	var target := Vector2(-m.x * 14.0, -m.y * 8.0) + Vector2(sin(_time * 0.21) * 4.0, sin(_time * 0.17) * 3.0)
	_parallax = _parallax.lerp(target, UIMotion.damp(3.0, d))
	if active:
		_logo.position = _logo_base + _parallax
		_menu.position = _menu_base + _parallax * 0.4
