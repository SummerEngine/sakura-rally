extends Button
## Title hub entry: a brush kanji, a tracked overline, the title and an optional detail row.
## Focus paints a brush swash behind it (left to right, wet head), nudges the text right and
## turns the kanji vermilion; blur dries the swash away. The swash is the focus indicator, so the
## global FocusRing skips hub items. Mouse hover grabs focus like every other control.

const UITheme := preload("res://scripts/ui/ui_theme.gd")
const UIMotion := preload("res://scripts/ui/ui_motion.gd")
const UIApi := preload("res://scripts/ui/ui_api.gd")
const ShaderRect := preload("res://scripts/ui/widgets/shader_rect.gd")
const BRUSH_BAND := preload("res://shaders/ui/brush_band.gdshader")

enum Kind { PRIMARY, NORMAL, SMALL }

@export var press_sound: StringName = &"click"

var kind: int = Kind.NORMAL
var swash_color := Color(UITheme.PAPER, 0.95)

var _kanji_text := ""
var _overline_text := ""
var _title_text := ""
var _detail: Control
var _swash: ShaderRect
var _content := HBoxContainer.new()
var _kanji: Label
var _overline: Label
var _title: Label
var _focus_t := 0.0
var _shown_t := 0.0
var _nudge := 0.0
var _nudge_vel := 0.0
var _scale := 1.0
var _scale_vel := 0.0
var _swash_tween: Tween
var _seed := randf() * 10.0


## kanji / overline may be empty (SMALL items use neither). `detail` goes under the title.
func setup(p_kind: int, kanji: String, overline: String, title: String, detail: Control = null) -> void:
	kind = p_kind
	_kanji_text = kanji
	_overline_text = overline
	_title_text = title
	_detail = detail


func set_title(title: String) -> void:
	_title_text = title
	if _title != null:
		_title.text = title


func set_overline(overline: String) -> void:
	_overline_text = overline
	if _overline != null:
		_overline.text = overline


func _ready() -> void:
	var empty := StyleBoxEmpty.new()
	for s in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		add_theme_stylebox_override(s, empty)
	focus_mode = Control.FOCUS_ALL
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	set_meta(&"no_focus_ring", true)
	mouse_entered.connect(func() -> void:
		if not disabled:
			grab_focus())
	focus_entered.connect(_on_focus_entered)
	focus_exited.connect(_on_focus_exited)
	button_down.connect(func() -> void:
		pivot_offset = size * Vector2(0.2, 0.5)
		_scale = 0.95)
	pressed.connect(func() -> void:
		if press_sound != &"":
			UIApi.ui_sound(press_sound))

	_swash = ShaderRect.new(BRUSH_BAND)
	_swash.set_param(&"paint", swash_color)
	_swash.set_param(&"progress", 0.0)
	_swash.set_param(&"seed", _seed)
	_swash.set_param(&"taper", 0.5)
	add_child(_swash)

	var sizes := {Kind.PRIMARY: [46, 64, 14], Kind.NORMAL: [32, 46, 13], Kind.SMALL: [22, 0, 0]}
	var s: Array = sizes[kind]
	_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.add_theme_constant_override("separation", 18 if kind == Kind.PRIMARY else 14)
	add_child(_content)
	if _kanji_text != "":
		_kanji = UITheme.make_label(_kanji_text, UITheme.FONT_BRUSH, int(s[1]), UITheme.INK)
		_kanji.label_settings.outline_size = 10
		_kanji.label_settings.outline_color = Color(1, 1, 1, 0.45)
		_kanji.custom_minimum_size = Vector2(s[1] * 1.05, 0)
		_kanji.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_kanji.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_content.add_child(_kanji)
	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_theme_constant_override("separation", 0 if kind == Kind.SMALL else 2)
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_content.add_child(col)
	if _overline_text != "" or kind != Kind.SMALL:
		_overline = UITheme.make_label(_overline_text, UITheme.tracked(UITheme.FONT_UI_BLACK, 3), int(s[2]), Color(UITheme.INK, 0.62))
		_overline.label_settings.outline_size = 8
		_overline.label_settings.outline_color = Color(1, 1, 1, 0.4)
		col.add_child(_overline)
	var font: Font = UITheme.FONT_UI_BLACK if kind == Kind.SMALL else UITheme.FONT_TITLE
	_title = UITheme.make_label(_title_text, font, int(s[0]), UITheme.INK)
	_title.label_settings.outline_size = 14 if kind != Kind.SMALL else 10
	_title.label_settings.outline_color = Color(1, 1, 1, 0.45)
	col.add_child(_title)
	if _detail != null:
		col.add_child(_detail)
	_content.minimum_size_changed.connect(_fit)
	_fit()


func _pad() -> Vector2:
	match kind:
		Kind.PRIMARY:
			return Vector2(22, 16)
		Kind.SMALL:
			return Vector2(18, 8)
	return Vector2(20, 10)


func _fit() -> void:
	var pad := _pad()
	var inner := _content.get_combined_minimum_size()
	custom_minimum_size = inner + pad * 2.0 + Vector2(16, 0) # room for the focus nudge
	_content.position = pad
	_content.size = inner
	# The swash runs a little past the text on both ends and fills the item's height.
	_swash.position = Vector2(-10, -4)
	_swash.size = Vector2(custom_minimum_size.x + 46, custom_minimum_size.y + 8)
	pivot_offset = custom_minimum_size * Vector2(0.2, 0.5)


func _on_focus_entered() -> void:
	if is_visible_in_tree():
		UIApi.ui_sound(&"hover")
	UIMotion.kill(_swash_tween)
	_swash.set_param(&"fade_out", 0.0)
	_swash.set_param(&"seed", _seed)
	_swash_tween = UIMotion.tween(self)
	_swash_tween.tween_method(_swash.param_setter(&"progress"), 0.0, 1.0, 0.34).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func _on_focus_exited() -> void:
	UIMotion.kill(_swash_tween)
	_swash_tween = UIMotion.tween(self)
	_swash_tween.tween_method(_swash.param_setter(&"fade_out"), 0.0, 1.0, 0.26).set_ease(Tween.EASE_IN)
	_seed = fposmod(_seed + 3.7, 20.0)


func _process(delta: float) -> void:
	var d := minf(UIMotion.real_delta(delta), 0.05)
	var focused := has_focus()
	_focus_t = lerpf(_focus_t, 1.0 if focused else 0.0, UIMotion.damp(14.0, d))
	# Springs: the text nudge right on focus, and the press squash.
	_nudge_vel += (((14.0 if focused else 0.0) - _nudge) * 300.0 - _nudge_vel * 20.0) * d
	_nudge += _nudge_vel * d
	_scale_vel += ((1.0 - _scale) * 420.0 - _scale_vel * 22.0) * d
	_scale += _scale_vel * d
	var pad := _pad()
	_content.position = Vector2(pad.x + _nudge, pad.y)
	# Scale only while the press spring moves, so entrance tweens can scale the item at rest.
	if absf(_scale - 1.0) > 0.0005 or absf(_scale_vel) > 0.01:
		scale = Vector2(_scale, _scale)
	elif _scale != 1.0:
		_scale = 1.0
		_scale_vel = 0.0
		scale = Vector2.ONE
	# Label colours only while the focus blend moves (LabelSettings changes re-shape the text).
	if absf(_focus_t - _shown_t) < 0.002:
		return
	_shown_t = _focus_t
	if _kanji != null:
		_kanji.label_settings.font_color = UITheme.INK.lerp(UITheme.VERMILION, _focus_t)
	if _overline != null:
		_overline.label_settings.font_color = Color(UITheme.INK, 0.62).lerp(UITheme.VERMILION.darkened(0.1), _focus_t * 0.8)
