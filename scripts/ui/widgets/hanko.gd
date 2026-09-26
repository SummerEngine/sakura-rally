extends Control
## Red hanko seal with knocked-out brush kanji. `stamp()` slams it down (big + rotated ->
## resting tilt, overshoot squash) and emits `landed` on impact so screens can shake / burst.

signal landed

const UITheme := preload("res://scripts/ui/ui_theme.gd")
const UIMotion := preload("res://scripts/ui/ui_motion.gd")
const SHADER := preload("res://shaders/ui/hanko.gdshader")

@export var text := "金":
	set(v):
		text = v
		queue_redraw()
@export var ink := UITheme.VERMILION:
	set(v):
		ink = v
		queue_redraw()
@export var paper := UITheme.PAPER
@export var rest_rotation := -0.12
@export var round_seal := false ## circular seal instead of square
@export var caption := "" ## small latin text under the kanji (e.g. "GOLD")

var _mat := ShaderMaterial.new()
var _tween: Tween


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mat.shader = SHADER
	material = _mat


func _ready() -> void:
	resized.connect(_on_resized)
	_on_resized()
	rotation = rest_rotation


func _on_resized() -> void:
	pivot_offset = size * 0.5
	_mat.set_shader_parameter("rect_size", size)
	queue_redraw()


func show_instant() -> void:
	UIMotion.kill(_tween)
	modulate.a = 1.0
	scale = Vector2.ONE
	rotation = rest_rotation
	_mat.set_shader_parameter("pressure", 1.0)


func stamp(delay: float = 0.0) -> Tween:
	UIMotion.kill(_tween)
	_mat.set_shader_parameter("seed", randf() * 20.0)
	modulate.a = 0.0
	scale = Vector2(2.6, 2.6)
	rotation = rest_rotation - 0.55
	_tween = UIMotion.tween(self)
	_tween.tween_interval(delay)
	_tween.tween_property(self, "modulate:a", 1.0, 0.1)
	_tween.parallel().tween_property(self, "scale", Vector2(0.9, 0.9), 0.2).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_tween.parallel().tween_property(self, "rotation", rest_rotation, 0.2).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_callback(landed.emit)
	_tween.tween_property(self, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	_tween.parallel().tween_method(func(v: float) -> void: _mat.set_shader_parameter("pressure", v), 0.3, 1.0, 0.4)
	return _tween


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	var s := minf(size.x, size.y)
	if round_seal:
		draw_circle(size * 0.5, s * 0.5, ink)
		draw_arc(size * 0.5, s * 0.5 - s * 0.07, 0.0, TAU, 64, Color(paper, 0.9), s * 0.028, true)
	else:
		var sb := StyleBoxFlat.new()
		sb.bg_color = ink
		sb.set_corner_radius_all(int(s * 0.12))
		sb.corner_detail = 8
		draw_style_box(sb, r)
		var inner := StyleBoxFlat.new()
		inner.draw_center = false
		inner.border_color = Color(paper, 0.9)
		inner.set_border_width_all(maxi(2, int(s * 0.028)))
		inner.set_corner_radius_all(int(s * 0.08))
		inner.corner_detail = 8
		draw_style_box(inner, r.grow(-s * 0.07))
	var font: Font = UITheme.FONT_BRUSH
	var cap_h := 0.0
	if caption != "":
		cap_h = s * 0.22
	var fs := int(s * (0.62 if text.length() == 1 else 0.36) - cap_h * 0.75)
	if fs < 1:
		return # not laid out yet
	if text.length() == 1:
		# Centre the glyph's ink box (not the font's line box) in the space above the caption.
		var gsz := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
		var ink_h := fs * 0.86
		var area_top := s * 0.1
		var area_h := size.y - cap_h - area_top - s * 0.04
		var base_y := area_top + (area_h + ink_h) * 0.5 - fs * 0.06
		draw_string(font, Vector2((size.x - gsz.x) * 0.5, base_y), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, paper)
	else:
		# Two characters stacked vertically, seal style.
		var asc2 := font.get_ascent(fs)
		for i in text.length():
			var ch := text[i]
			var w2 := font.get_string_size(ch, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			var y := size.y * 0.5 + (float(i) - (text.length() - 1) * 0.5) * fs * 1.0 + asc2 * 0.36
			draw_string(font, Vector2((size.x - w2) * 0.5, y - cap_h * 0.5), ch, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, paper)
	if caption != "":
		var cf: Font = UITheme.FONT_UI_BLACK
		var cfs := int(cap_h * 0.56)
		var cw := cf.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, cfs).x + (caption.length() - 1) * cfs * 0.18
		var x := (size.x - cw) * 0.5
		for i in caption.length():
			var ch2 := caption[i]
			draw_string(cf, Vector2(x, size.y - s * 0.13), ch2, HORIZONTAL_ALIGNMENT_LEFT, -1, cfs, paper)
			x += cf.get_string_size(ch2, HORIZONTAL_ALIGNMENT_LEFT, -1, cfs).x + cfs * 0.18
