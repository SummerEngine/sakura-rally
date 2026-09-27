extends Control
## Arrival beat at the end of the liaison (Game.State.ARRIVED), as the car rolls to rest on the
## next stage's grid: "ARRIVED" pops over an indigo brush swash with 到着 painted beneath, then
## the destination and the stage slide in, and a small seal with the stage code is stamped
## beside them. Then it waits for the player, like the results after a stage: "Start SS2"
## (focused; Game.request_campaign_continue, the stage's start card follows on the spot) or
## "Quit to title" (also Esc / B; the save already stands at the stage).

signal shake_requested(strength: float)

const UITheme := preload("res://scripts/ui/ui_theme.gd")
const UIMotion := preload("res://scripts/ui/ui_motion.gd")
const UIApi := preload("res://scripts/ui/ui_api.gd")
const KineticText := preload("res://scripts/ui/widgets/kinetic_text.gd")
const BrushKanji := preload("res://scripts/ui/widgets/brush_kanji.gd")
const Hanko := preload("res://scripts/ui/widgets/hanko.gd")
const InkButton := preload("res://scripts/ui/widgets/ink_button.gd")
const ShaderRect := preload("res://scripts/ui/widgets/shader_rect.gd")
const BRUSH_BAND := preload("res://shaders/ui/brush_band.gdshader")

const SWASH := Color("2f4f8f")
## Seconds into the card when the buttons come up (the seal has landed; Main starts the stage
## only once the car is at rest anyway).
const PROMPT_AT := 1.9

var shown := false

var _swash: ShaderRect
var _title: KineticText
var _kanji: BrushKanji
var _dest := Control.new()
var _dest_name: Label
var _dest_sub: Label
var _seal: Hanko
var _buttons := HBoxContainer.new()
var _start: Button
var _quit: Button
var _tween: Tween


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_swash = ShaderRect.new(BRUSH_BAND)
	_swash.size = Vector2(900, 190)
	_swash.set_param("paint", SWASH)
	add_child(_swash)
	_title = KineticText.new()
	_title.font = UITheme.FONT_TITLE
	_title.font_size = 118
	_title.tracking = 12.0
	_title.color = UITheme.PAPER
	_title.shadow = Color(UITheme.INK, 0.3)
	_title.shadow_offset = Vector2(0, 6)
	_title.style = KineticText.Style.POP
	_title.stagger = 0.05
	_title.char_duration = 0.4
	_title.stepped_fps = 12.0
	_title.align = HORIZONTAL_ALIGNMENT_CENTER
	_title.text = "ARRIVED"
	_title.size = Vector2(1000, 170)
	add_child(_title)
	_kanji = BrushKanji.new()
	_kanji.text = "到着"
	_kanji.font_size = 96
	_kanji.color = UITheme.INK
	_kanji.halo = Color(UITheme.PAPER, 0.8)
	_kanji.use_strokes = false
	add_child(_kanji)
	_dest.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_dest)
	_dest_name = UITheme.make_label("", UITheme.tracked(UITheme.FONT_TITLE, 3), 40, UITheme.INK)
	_dest_name.label_settings.outline_size = 16
	_dest_name.label_settings.outline_color = Color(UITheme.PAPER, 0.85)
	_dest_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_dest.add_child(_dest_name)
	_dest_sub = UITheme.make_label("", UITheme.tracked(UITheme.FONT_UI_BLACK, 3), 17, UITheme.INK)
	_dest_sub.label_settings.outline_size = 12
	_dest_sub.label_settings.outline_color = Color(UITheme.PAPER, 0.85)
	_dest_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_dest.add_child(_dest_sub)
	_seal = Hanko.new()
	_seal.round_seal = true
	_seal.size = Vector2(112, 112)
	_seal.text = "着"
	_seal.caption = "TC"
	_seal.landed.connect(func() -> void: shake_requested.emit(0.45))
	add_child(_seal)
	_buttons.add_theme_constant_override("separation", 12)
	_buttons.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_buttons)
	_start = InkButton.new()
	_start.theme_type_variation = &"PrimaryButton"
	_start.custom_minimum_size = Vector2(200, 0)
	_start.press_sound = &"start"
	_start.pressed.connect(func() -> void: _choose(&"request_campaign_continue"))
	_buttons.add_child(_start)
	_quit = InkButton.new()
	_quit.text = "Quit to title"
	_quit.press_sound = &"back"
	_quit.pressed.connect(func() -> void: _choose(&"request_menu"))
	_buttons.add_child(_quit)
	visible = false


## Plays the card for the liaison that just ended (Game.campaign_leg), naming the stage after it.
func show_card() -> void:
	var game := UIApi.game()
	var legs: Array = game.CAMPAIGN
	var i: int = game.campaign_leg
	var dest: Dictionary = legs[mini(i + 1, legs.size() - 1)]
	_dest_name.text = "%s  %s" % [dest["title_jp"], str(dest["title"]).to_upper()]
	_dest_sub.text = "%s GRID  ·  THE STAGE STARTS HERE" % dest["code"]
	_seal.caption = str(dest["code"])
	_start.text = "Start %s" % dest["code"]
	shown = true
	visible = true
	modulate.a = 1.0
	var vp := get_viewport_rect().size
	var c := vp * Vector2(0.5, 0.36)
	_swash.position = c - _swash.size * 0.5
	_swash.set_param("seed", randf() * 10.0)
	_swash.set_param("progress", 0.0)
	_swash.set_param("fade_out", 0.0)
	_title.position = c - _title.size * 0.5 - Vector2(0, 6)
	_kanji.size = _kanji.custom_minimum_size
	_kanji.position = c + Vector2(-_kanji.size.x * 0.5, 84)
	_kanji.progress = 0.0
	_dest_name.reset_size()
	_dest_sub.reset_size()
	var w := maxf(_dest_name.size.x, _dest_sub.size.x)
	_dest_name.size.x = w
	_dest_sub.size.x = w
	_dest_sub.position = Vector2(0, _dest_name.size.y + 2.0)
	_dest.position = c + Vector2(-w * 0.5, 232)
	_dest.modulate.a = 0.0
	_seal.position = c + Vector2(w * 0.5 + 34.0, 214)
	_seal.modulate.a = 0.0
	_buttons.visible = false
	_buttons.reset_size()
	_buttons.position = c + Vector2(-_buttons.size.x * 0.5, 346)
	UIApi.stinger(&"arrived")
	UIMotion.kill(_tween)
	_tween = UIMotion.tween(self)
	_tween.set_parallel(true)
	_tween.tween_method(_swash.param_setter(&"progress"), 0.0, 1.0, 0.45).set_delay(0.15).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_callback(_title.play.bind(0.0)).set_delay(0.25)
	_tween.tween_property(_kanji, "progress", 1.0, 0.8).set_delay(0.6).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	var dp := _dest.position
	_dest.position = dp + Vector2(0, 18)
	_tween.tween_property(_dest, "modulate:a", 1.0, 0.4).set_delay(1.05)
	_tween.tween_property(_dest, "position", dp, 0.6).set_delay(1.05).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	_tween.tween_callback(_seal.stamp).set_delay(1.35)
	_tween.tween_callback(_prompt).set_delay(PROMPT_AT)


func _prompt() -> void:
	_buttons.visible = true
	_buttons.modulate.a = 0.0
	var bp := _buttons.position
	_buttons.position = bp + Vector2(0, 16)
	var t := UIMotion.tween(_buttons)
	t.set_parallel(true)
	t.tween_property(_buttons, "modulate:a", 1.0, 0.3)
	t.tween_property(_buttons, "position", bp, 0.5).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_start.grab_focus()


## The player chose: the buttons go at once (and their focus with them, so a second press cannot
## reach them while the next screen comes up), then Game hears the request.
func _choose(request: StringName) -> void:
	_buttons.visible = false
	UIApi.game().call(request)


func hide_card(instant: bool = false) -> void:
	if not shown:
		return
	shown = false
	_buttons.visible = false
	UIMotion.kill(_tween)
	if instant:
		visible = false
		return
	_tween = UIMotion.tween(self)
	_tween.tween_property(self, "modulate:a", 0.0, 0.3)
	_tween.tween_callback(hide)


func _unhandled_input(event: InputEvent) -> void:
	if not shown or not _buttons.visible:
		return
	if event.is_action_pressed("ui_cancel"):
		UIApi.ui_sound(&"back")
		_choose(&"request_menu")
		get_viewport().set_input_as_handled()
