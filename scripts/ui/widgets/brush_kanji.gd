extends Control
## Brush-painted kanji. Single characters with authored strokes (kanji_strokes.gd) are painted
## on in stroke order; any other text is revealed by a ragged ink wipe along the writing
## direction. `progress` 0..1 drives the reveal; `play()` animates it.

const UITheme := preload("res://scripts/ui/ui_theme.gd")
const UIMotion := preload("res://scripts/ui/ui_motion.gd")
const Strokes := preload("res://scripts/ui/widgets/kanji_strokes.gd")
const SHADER := preload("res://shaders/ui/brush_reveal.gdshader")
const STROKE_GAP := 0.35 ## pause between strokes, in grid units of travel

@export var text := "桜":
	set(v):
		text = v
		_rebuild()
@export var font: Font = UITheme.FONT_BRUSH
@export var font_size := 120: ## used in wipe mode (multi-character text)
	set(v):
		font_size = v
		_rebuild()
@export var color := UITheme.INK:
	set(v):
		color = v
		queue_redraw()
@export var halo := Color(1, 1, 1, 0.0): ## soft outline behind the glyphs for legibility
	set(v):
		halo = v
		queue_redraw()
@export var halo_size := 18
@export var vertical := false:
	set(v):
		vertical = v
		_rebuild()
@export var use_strokes := true:
	set(v):
		use_strokes = v
		_rebuild()
@export_range(0.0, 1.0) var progress := 1.0:
	set(v):
		progress = v
		_apply_progress()

var _mat: ShaderMaterial
var _strokes: Array = []
var _stroke_len: PackedFloat32Array = []
var _total_len := 0.0
var _tween: Tween


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mat = ShaderMaterial.new()
	_mat.shader = SHADER
	material = _mat


func _ready() -> void:
	resized.connect(_rebuild)
	_rebuild()


## Animate progress 0 -> 1. Stroke mode eases each stroke separately (fast attack, pressed end).
func play(duration: float = 1.2, delay: float = 0.0) -> Tween:
	UIMotion.kill(_tween)
	progress = 0.0
	_tween = UIMotion.tween(self)
	_tween.tween_property(self, "progress", 1.0, duration).set_delay(delay)
	return _tween


func is_stroke_mode() -> bool:
	return use_strokes and not _strokes.is_empty()


func _rebuild() -> void:
	_strokes = Strokes.get_strokes(text) if (use_strokes and text.length() == 1) else []
	_stroke_len.clear()
	_total_len = 0.0
	var pts := PackedVector2Array()
	var pt_stroke := PackedInt32Array()
	var pt_s := PackedFloat32Array()
	for k in _strokes.size():
		var stroke: Array = _strokes[k]
		var length := 0.0
		for i in range(1, stroke.size()):
			length += (stroke[i] as Vector2).distance_to(stroke[i - 1])
		var acc := 0.0
		for i in stroke.size():
			if i > 0:
				acc += (stroke[i] as Vector2).distance_to(stroke[i - 1])
			pts.append(stroke[i])
			pt_stroke.append(k)
			pt_s.append(acc / maxf(length, 0.001))
		_stroke_len.append(length)
		_total_len += length + STROKE_GAP
	_mat.set_shader_parameter("pts", pts)
	_mat.set_shader_parameter("pt_stroke", pt_stroke)
	_mat.set_shader_parameter("pt_s", pt_s)
	_mat.set_shader_parameter("pt_count", pts.size())
	_mat.set_shader_parameter("stroke_count", _strokes.size())
	if not is_stroke_mode():
		custom_minimum_size = _text_size()
	_update_geometry()
	_apply_progress()
	queue_redraw()


func _text_size() -> Vector2:
	if text.is_empty():
		return Vector2.ZERO
	if vertical:
		return Vector2(font_size * 1.05, font_size * 1.02 * text.length())
	return font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)


func _box() -> Rect2:
	var s := minf(size.x, size.y)
	return Rect2((size - Vector2(s, s)) * 0.5, Vector2(s, s))


func _update_geometry() -> void:
	if is_stroke_mode():
		var b := _box()
		_mat.set_shader_parameter("box_origin", b.position)
		_mat.set_shader_parameter("box_size", b.size.x)
	else:
		var dir := Vector2(0, 1) if vertical else Vector2(1, 0)
		_mat.set_shader_parameter("wipe_dir", dir)
		var ext := size.y if vertical else size.x
		_mat.set_shader_parameter("wipe_extent", Vector2(0.0, maxf(ext, 1.0)))


func _apply_progress() -> void:
	if _mat == null:
		return
	if not is_stroke_mode():
		_mat.set_shader_parameter("wipe_p", progress)
		return
	var travelled := progress * _total_len
	var per := PackedFloat32Array()
	per.resize(_strokes.size())
	for k in _strokes.size():
		var l: float = _stroke_len[k]
		var local := clampf(travelled / maxf(l, 0.001), 0.0, 1.0)
		# Calligraphy timing: quick entry, slow pressed exit.
		per[k] = UIMotion.out_cubic(local) if local < 1.0 else 1.0
		travelled -= l + STROKE_GAP
	_mat.set_shader_parameter("stroke_p", per)
	_mat.set_shader_parameter("wet", 1.0 if progress < 1.0 else 0.0)


func _draw() -> void:
	if text.is_empty():
		return
	if is_stroke_mode():
		var b := _box()
		var fs := int(b.size.x * 0.84)
		var asc := font.get_ascent(fs)
		var desc := font.get_descent(fs)
		var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var pos := b.position + Vector2((b.size.x - w) * 0.5, b.size.x * 0.5 + (asc - desc) * 0.5)
		if halo.a > 0.0:
			draw_string_outline(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, halo_size, halo)
		draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, color)
		return
	var asc2 := font.get_ascent(font_size)
	if vertical:
		for i in text.length():
			var ch := text[i]
			var cw := font.get_string_size(ch, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
			var p := Vector2((size.x - cw) * 0.5, asc2 * 0.92 + i * font_size * 1.02)
			if halo.a > 0.0:
				draw_string_outline(font, p, ch, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, halo_size, halo)
			draw_string(font, p, ch, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)
	else:
		var p2 := Vector2(0, (size.y + asc2 - font.get_descent(font_size)) * 0.5)
		if halo.a > 0.0:
			draw_string_outline(font, p2, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, halo_size, halo)
		draw_string(font, p2, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)
