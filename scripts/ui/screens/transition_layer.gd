extends Control
## Ink-brush screen transition with a loading card (map kanji + name + blossom spinner)
## shown while covered. cover() / reveal() return signals so callers can `await` them.

signal covered
signal revealed

const UITheme := preload("res://scripts/ui/ui_theme.gd")
const UIMotion := preload("res://scripts/ui/ui_motion.gd")
const BrushKanji := preload("res://scripts/ui/widgets/brush_kanji.gd")
const KineticText := preload("res://scripts/ui/widgets/kinetic_text.gd")
const Spinner := preload("res://scripts/ui/widgets/sakura_spinner.gd")
const SHADER := preload("res://shaders/ui/ink_wipe.gdshader")

var is_covered := false
var busy := false

var _wipe := ColorRect.new()
var _mat := ShaderMaterial.new()
var _card := Control.new()
var _kanji: Control
var _name: Control
var _spinner: Control
var _tween: Tween


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mat.shader = SHADER
	_wipe.material = _mat
	_wipe.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_wipe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_wipe)

	_card.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_card)
	var col := VBoxContainer.new()
	col.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	col.grow_horizontal = Control.GROW_DIRECTION_BOTH
	col.grow_vertical = Control.GROW_DIRECTION_BOTH
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 18)
	_card.add_child(col)
	_kanji = BrushKanji.new()
	_kanji.font_size = 150
	_kanji.color = UITheme.PAPER
	_kanji.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	col.add_child(_kanji)
	_name = KineticText.new()
	_name.font = UITheme.tracked(UITheme.FONT_UI_BOLD, 0)
	_name.font_size = 22
	_name.tracking = 7.0
	_name.color = Color(UITheme.PAPER, 0.8)
	_name.style = KineticText.Style.RISE
	_name.distance = 14.0
	_name.stagger = 0.02
	_name.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	col.add_child(_name)
	_spinner = Spinner.new()
	_spinner.custom_minimum_size = Vector2(46, 46)
	_spinner.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	col.add_child(_spinner)
	_card.modulate.a = 0.0
	resized.connect(func() -> void: _mat.set_shader_parameter("rect_size", size))
	visible = false


func set_loading_label(kanji: String, caption: String) -> void:
	_kanji.text = kanji
	_name.text = caption.to_upper()


## Paint the screen over with ink. Emits (and returns) `covered` when fully opaque.
func cover(duration: float = 0.95) -> Signal:
	UIMotion.kill(_tween)
	visible = true
	busy = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	_mat.set_shader_parameter("rect_size", size)
	_mat.set_shader_parameter("seed", randf() * 10.0)
	var start := 0.0 if not is_covered else 1.0
	_mat.set_shader_parameter("progress", start)
	_tween = UIMotion.tween(self)
	_tween.tween_method(_set_progress, start, 1.0, duration * (1.0 - start)).set_trans(Tween.TRANS_LINEAR)
	_tween.tween_callback(_on_covered)
	_tween.tween_property(_card, "modulate:a", 1.0, 0.25)
	if start < 1.0:
		_kanji.progress = 0.0
		_tween.parallel().tween_property(_kanji, "progress", 1.0, 0.7)
		_tween.parallel().tween_callback(_name.play.bind(0.15))
	return covered


## Lift the ink off. Emits (and returns) `revealed` when fully transparent.
func reveal(duration: float = 1.0) -> Signal:
	UIMotion.kill(_tween)
	visible = true
	busy = true
	if not is_covered:
		_set_progress(1.0)
	_tween = UIMotion.tween(self)
	_tween.tween_property(_card, "modulate:a", 0.0, 0.18)
	_tween.tween_method(_set_progress, 1.0, 2.0, duration).set_trans(Tween.TRANS_LINEAR)
	_tween.tween_callback(_on_revealed)
	return revealed


func _set_progress(v: float) -> void:
	_mat.set_shader_parameter("progress", v)


func _on_covered() -> void:
	is_covered = true
	busy = false
	covered.emit()


func _on_revealed() -> void:
	is_covered = false
	busy = false
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	revealed.emit()
