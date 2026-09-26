extends Control
## Lap progress: slim track with checkpoint ticks, a sakura fill, a small car marker riding the
## fill and a finish flag. Checkpoint ticks sit where each checkpoint was actually passed;
## ticks not reached yet are spaced evenly between the last passed one and the finish.

const UITheme := preload("res://scripts/ui/ui_theme.gd")
const UIMotion := preload("res://scripts/ui/ui_motion.gd")

var progress := 0.0
var checkpoint_total := 0
var accent := UITheme.SAKURA

var _passed: PackedFloat32Array = []
var _shown := 0.0
var _pulse: PackedFloat32Array = []
var _sb_track := StyleBoxFlat.new()
var _sb_fill := StyleBoxFlat.new()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(420, 34)
	for sb: StyleBoxFlat in [_sb_track, _sb_fill]:
		sb.set_corner_radius_all(4)
		sb.corner_detail = 6
	_sb_track.bg_color = Color(UITheme.PAPER, 0.55)
	_sb_track.shadow_color = Color(UITheme.INK, 0.12)
	_sb_track.shadow_size = 4
	_sb_track.shadow_offset = Vector2(0, 1)


func reset(total: int) -> void:
	checkpoint_total = total
	_passed.clear()
	_pulse.resize(total)
	_pulse.fill(0.0)
	progress = 0.0
	_shown = 0.0


func mark_passed(index: int, at_progress: float) -> void:
	while _passed.size() <= index:
		_passed.append(at_progress)
	_passed[index] = at_progress
	if index < _pulse.size():
		_pulse[index] = 1.0


func _tick_pos(i: int) -> float:
	if i < _passed.size():
		return _passed[i]
	var last_i := _passed.size() - 1
	var last_p := _passed[last_i] if last_i >= 0 else 0.0
	var remaining := checkpoint_total - last_i
	return lerpf(last_p, 1.0, float(i - last_i) / float(maxi(remaining, 1)))


func _process(delta: float) -> void:
	var d := UIMotion.real_delta(delta)
	_shown = lerpf(_shown, clampf(progress, 0.0, 1.0), UIMotion.damp(10.0, d))
	for i in _pulse.size():
		_pulse[i] = maxf(_pulse[i] - d * 1.6, 0.0)
	queue_redraw()


func _draw() -> void:
	var y := size.y * 0.5
	var x0 := 6.0
	var x1 := size.x - 22.0
	var w := x1 - x0
	_sb_track.set_corner_radius_all(3)
	draw_style_box(_sb_track, Rect2(x0, y - 3.0, w, 6.0))
	_sb_fill.bg_color = accent
	draw_style_box(_sb_fill, Rect2(x0, y - 3.0, maxf(w * _shown, 6.0), 6.0))
	for i in checkpoint_total:
		var px := x0 + w * _tick_pos(i)
		var passed := i < _passed.size()
		var pul := _pulse[i] if i < _pulse.size() else 0.0
		var r := 6.0 + 5.0 * UIMotion.out_cubic(pul)
		# Diamond marker.
		var diamond := PackedVector2Array([Vector2(px, y - r), Vector2(px + r, y), Vector2(px, y + r), Vector2(px - r, y)])
		if pul > 0.0:
			draw_circle(Vector2(px, y), 8.0 + 16.0 * (1.0 - pul), Color(accent, 0.35 * pul))
		draw_colored_polygon(diamond, UITheme.PAPER if not passed else accent)
		diamond.append(diamond[0])
		draw_polyline(diamond, Color(UITheme.INK, 0.35 if not passed else 0.0), 1.5, true)
	# Finish flag: small chequered square.
	var fx := x1 + 4.0
	for gx in 3:
		for gy in 3:
			var col := UITheme.INK if (gx + gy) % 2 == 0 else UITheme.PAPER
			draw_rect(Rect2(fx + gx * 5.0, y - 7.5 + gy * 5.0, 5.0, 5.0), col)
	# Car marker: rounded pill with a pointer, riding the fill.
	var cx := x0 + w * _shown
	draw_circle(Vector2(cx, y + 1.5), 9.0, Color(UITheme.INK, 0.2))
	draw_circle(Vector2(cx, y), 9.0, UITheme.WHITE)
	draw_circle(Vector2(cx, y), 5.0, UITheme.INK)
