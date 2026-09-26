extends Control
## Kinetic typography: draws a string glyph by glyph with per-character entrance / exit
## animation (staggered, optionally stepped at 12 fps for an anime feel), letter tracking and
## optional fixed-width digits (timers, speed) so numbers never jitter.

const UITheme := preload("res://scripts/ui/ui_theme.gd")
const UIMotion := preload("res://scripts/ui/ui_motion.gd")

enum Style { NONE, DROP, RISE, POP, SLAM, SWEEP }

@export var text := "":
	set(v):
		if v == text:
			return
		text = v
		_relayout()
@export var font: Font = UITheme.FONT_TITLE
@export var font_size := 48:
	set(v):
		font_size = v
		_relayout()
@export var color := UITheme.INK:
	set(v):
		color = v
		queue_redraw()
@export var tracking := 0.0:
	set(v):
		tracking = v
		_relayout()
@export var mono_digits := false:
	set(v):
		mono_digits = v
		_relayout()
@export var align := HORIZONTAL_ALIGNMENT_LEFT:
	set(v):
		align = v
		queue_redraw()
@export var halo := Color(1, 1, 1, 0.0):
	set(v):
		halo = v
		queue_redraw()
@export var halo_size := 12
@export var shadow := Color(0, 0, 0, 0.0):
	set(v):
		shadow = v
		queue_redraw()
@export var shadow_offset := Vector2(0, 4)
@export var style := Style.DROP
@export var stagger := 0.045
@export var char_duration := 0.5
@export var stepped_fps := 0.0 ## 0 = smooth; 12 = animate "on twos"
@export var distance := 42.0 ## travel for DROP / RISE / SWEEP

var t_in := 1e3 ## seconds since play() (large = settled)
var t_out := 0.0 ## seconds since play_out() (only meaningful while `leaving`)
var leaving := false
var _advances: PackedFloat32Array = []
var _widths: PackedFloat32Array = []
var _total := 0.0
var _digit_w := 0.0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _ready() -> void:
	_relayout()
	set_process(false)


func play(delay: float = 0.0) -> void:
	t_in = -delay
	leaving = false
	set_process(true)
	queue_redraw()


func play_out(delay: float = 0.0) -> void:
	t_out = -delay
	leaving = true
	set_process(true)


func settle() -> void:
	t_in = 1e3
	leaving = false
	set_process(false)
	queue_redraw()


func total_in_time() -> float:
	return stagger * maxf(text.length() - 1, 0) + char_duration


func text_width() -> float:
	return _total


func _process(delta: float) -> void:
	var d := UIMotion.real_delta(delta)
	t_in += d
	if leaving:
		t_out += d
		if t_out > total_in_time() + 0.3:
			set_process(false)
	elif t_in > total_in_time() + 0.05:
		set_process(false)
	queue_redraw()


func _relayout() -> void:
	_advances.clear()
	_widths.clear()
	_total = 0.0
	if font == null:
		return
	_digit_w = 0.0
	if mono_digits:
		for c in "0123456789":
			_digit_w = maxf(_digit_w, font.get_string_size(c, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x)
	for i in text.length():
		var ch := text[i]
		var w := font.get_string_size(ch, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		var adv := w
		if mono_digits and ch >= "0" and ch <= "9":
			adv = _digit_w
		_widths.append(w)
		_advances.append(adv)
		_total += adv + (tracking if i < text.length() - 1 else 0.0)
	custom_minimum_size = Vector2(ceilf(_total), ceilf(font.get_height(font_size)))
	queue_redraw()


func _char_anim(i: int) -> Array:
	# Returns [offset: Vector2, scale: float, rot: float, alpha: float].
	var off := Vector2.ZERO
	var sc := 1.0
	var rot := 0.0
	var a := 1.0
	var t := t_in
	if stepped_fps > 0.0:
		t = UIMotion.stepped(t, stepped_fps)
	var p := UIMotion.stagger(t, i, stagger, char_duration)
	match style:
		Style.DROP:
			off.y = -distance * (1.0 - UIMotion.out_back(p, 2.2))
			rot = (1.0 - UIMotion.out_cubic(p)) * (-0.25 if i % 2 == 0 else 0.2)
			a = clampf(p * 3.0, 0.0, 1.0)
		Style.RISE:
			off.y = distance * (1.0 - UIMotion.out_expo(p))
			a = UIMotion.out_cubic(p)
		Style.POP:
			sc = UIMotion.out_back(p, 2.6)
			a = clampf(p * 4.0, 0.0, 1.0)
		Style.SLAM:
			sc = lerpf(2.4, 1.0, UIMotion.out_expo(p))
			a = clampf(p * 5.0, 0.0, 1.0)
		Style.SWEEP:
			off.x = -distance * (1.0 - UIMotion.out_expo(p))
			a = UIMotion.out_cubic(p)
	if leaving:
		var to := maxf(t_out, 0.0)
		if stepped_fps > 0.0:
			to = UIMotion.stepped(to, stepped_fps)
		var q := UIMotion.stagger(to, i, stagger * 0.6, char_duration * 0.7)
		off.y -= distance * 0.8 * UIMotion.in_cubic(q)
		a *= 1.0 - UIMotion.out_cubic(q)
	return [off, sc, rot, a]


func _draw() -> void:
	if text.is_empty() or font == null or _advances.size() != text.length():
		return
	var asc := font.get_ascent(font_size)
	var desc := font.get_descent(font_size)
	var baseline := (size.y + asc - desc) * 0.5
	var x := 0.0
	match align:
		HORIZONTAL_ALIGNMENT_CENTER:
			x = (size.x - _total) * 0.5
		HORIZONTAL_ALIGNMENT_RIGHT:
			x = size.x - _total
	var animating := style != Style.NONE or leaving
	for i in text.length():
		var ch := text[i]
		var adv: float = _advances[i]
		var w: float = _widths[i]
		var gx := x + (adv - w) * 0.5
		var off := Vector2.ZERO
		var sc := 1.0
		var rot := 0.0
		var a := 1.0
		if animating:
			var an := _char_anim(i)
			off = an[0]
			sc = an[1]
			rot = an[2]
			a = an[3]
		if a > 0.002 and ch != " ":
			var center := Vector2(gx + w * 0.5, baseline - asc * 0.35)
			var xf := Transform2D(rot, Vector2(sc, sc), 0.0, center + off) * Transform2D(0.0, -center)
			draw_set_transform_matrix(xf)
			var pos := Vector2(gx, baseline)
			if shadow.a > 0.0:
				draw_string(font, pos + shadow_offset, ch, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(shadow, shadow.a * a))
			if halo.a > 0.0:
				draw_string_outline(font, pos, ch, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, halo_size, Color(halo, halo.a * a))
			draw_string(font, pos, ch, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(color, color.a * a))
		x += adv + tracking
	draw_set_transform_matrix(Transform2D.IDENTITY)
