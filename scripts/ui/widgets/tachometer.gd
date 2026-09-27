extends Control
## Analog-style tachometer drawn with _draw: frosted paper dial, 1000-rpm ticks and numerals,
## segmented rpm arc (ink -> sakura -> vermilion redline), sweeping needle, shift light that
## flashes near the limiter, big gear numeral with a pop on every shift, speed readout.
## Feed it with `update_values()` every frame.

const UITheme := preload("res://scripts/ui/ui_theme.gd")
const UIMotion := preload("res://scripts/ui/ui_motion.gd")

const ARC_SWEEP := deg_to_rad(250.0)
const ARC_START := PI * 0.5 + (TAU - ARC_SWEEP) * 0.5 ## symmetric gap at the bottom
const SEGMENTS := 44

var rpm := 900.0
var max_rpm := 7800.0
var gear := 1
var speed := 0.0
var unit_label := "km/h"
var shifting := false

var _needle := 0.0 ## displayed 0..1 (spring-smoothed)
var _needle_vel := 0.0
var _gear_shown := 1
var _gear_pop := 1.0
var _flash_t := 0.0
var _time := 0.0
var _speed_shown := 0.0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(400, 400)


func update_values(p_rpm: float, p_max: float, p_gear: int, p_speed: float, p_units: String, p_shifting: bool) -> void:
	rpm = p_rpm
	max_rpm = maxf(p_max, 1000.0)
	speed = p_speed
	unit_label = p_units
	shifting = p_shifting
	if p_gear != gear:
		gear = p_gear
		_gear_pop = 0.0


func _redline_start() -> float:
	return max_rpm - 1000.0


func _scale_max() -> float:
	return ceilf((max_rpm + 150.0) / 1000.0) * 1000.0


func _process(delta: float) -> void:
	var d := minf(UIMotion.real_delta(delta), 0.05)
	_time += d
	var target := clampf(rpm / _scale_max(), 0.0, 1.0)
	# Needle: stiff spring with a hint of overshoot, like a real gauge. At this stiffness an
	# Euler step longer than ~1/30 s diverges (below 28 fps the needle went to NaN for good),
	# so the frame is integrated in steps of at most 1/120 s.
	var steps := ceili(d * 120.0)
	var h := d / maxi(steps, 1)
	for i in steps:
		_needle_vel += ((target - _needle) * 900.0 - _needle_vel * 42.0) * h
		_needle += _needle_vel * h
	_gear_pop = minf(_gear_pop + d * 3.2, 1.0)
	if _gear_pop > 0.18:
		_gear_shown = gear
	_speed_shown = lerpf(_speed_shown, absf(speed), UIMotion.damp(18.0, d))
	var near_limit := rpm >= max_rpm * 0.93
	_flash_t = _flash_t + d * 14.0 if near_limit else 0.0
	queue_redraw()


func _gear_text(g: int) -> String:
	if g < 0:
		return "R"
	if g == 0:
		return "N"
	return str(g)


func _ang(frac: float) -> float:
	return ARC_START + ARC_SWEEP * frac


func _draw() -> void:
	var c := size * 0.5
	var R := minf(size.x, size.y) * 0.5 - 8.0
	var sm := _scale_max()
	var red_frac := _redline_start() / sm
	var near_limit := rpm >= max_rpm * 0.93
	var flash_on := near_limit and fmod(_flash_t, TAU) < PI

	# Dial: soft shadow + paper disc + inner ring.
	draw_circle(c + Vector2(0, 10), R + 4.0, Color(UITheme.INK, 0.12))
	draw_circle(c + Vector2(0, 5), R + 1.0, Color(UITheme.INK, 0.1))
	draw_circle(c, R, Color(UITheme.PAPER, 0.9))
	draw_arc(c, R - 2.0, 0.0, TAU, 128, Color(1, 1, 1, 0.8), 3.0, true)
	draw_arc(c, R, 0.0, TAU, 128, Color(UITheme.INK, 0.1), 1.2, true)
	if flash_on:
		draw_circle(c, R - 4.0, Color(UITheme.VERMILION, 0.1))

	# Redline band.
	var band_r := R - 22.0
	draw_arc(c, band_r, _ang(red_frac), _ang(1.0), 48, Color(UITheme.VERMILION, 0.9), 7.0, true)

	# Ticks and numerals.
	var font: Font = UITheme.FONT_TITLE
	var steps := int(sm / 500.0)
	for i in steps + 1:
		var frac := float(i) / steps
		var a := _ang(frac)
		var dir := Vector2(cos(a), sin(a))
		var major := i % 2 == 0
		var in_red := frac >= red_frac - 0.001
		var col := UITheme.VERMILION if in_red else UITheme.INK
		var r0 := R - (36.0 if major else 31.0)
		var r1 := R - 18.0
		draw_line(c + dir * r0, c + dir * r1, Color(col, 0.9 if major else 0.45), 3.5 if major else 2.0, true)
		if major:
			var txt := str(i / 2)
			var fs := 24
			var tsz := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
			var p := c + dir * (R - 58.0)
			draw_string(font, p + Vector2(-tsz.x * 0.5, fs * 0.36), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(col, 0.85))

	# Segmented rpm arc (inside the ticks).
	var seg_r := R - 88.0
	var gap := 0.012
	var filled := _needle
	for s in SEGMENTS:
		var f0 := float(s) / SEGMENTS
		var f1 := float(s + 1) / SEGMENTS
		if f0 > filled:
			draw_arc(c, seg_r, _ang(f0) + gap, _ang(f1) - gap, 4, Color(UITheme.INK, 0.08), 14.0, true)
			continue
		var col := UITheme.INK
		if f0 >= red_frac:
			col = UITheme.VERMILION
		elif f0 >= red_frac - 0.18:
			col = UITheme.SAKURA
		var af := minf(1.0, (filled - f0) / (f1 - f0))
		draw_arc(c, seg_r, _ang(f0) + gap, _ang(f0 + (f1 - f0) * af) - gap, 4, Color(col, 0.92), 14.0, true)

	# Needle: a floating blade from just outside the rpm arc to the ticks (no hub, so the
	# gear numeral owns the centre).
	var na := _ang(clampf(_needle, -0.02, 1.02))
	var nd := Vector2(cos(na), sin(na))
	var perp := Vector2(-nd.y, nd.x)
	var tail := c + nd * (seg_r + 12.0)
	var tip := c + nd * (R - 16.0)
	var blade := PackedVector2Array([tail + perp * 4.5, tip + perp * 1.5, tip - perp * 1.5, tail - perp * 4.5])
	var sh := Vector2(0, 3)
	var blade_sh := PackedVector2Array()
	for p in blade:
		blade_sh.append(p + sh)
	draw_colored_polygon(blade_sh, Color(UITheme.INK, 0.2))
	draw_colored_polygon(blade, UITheme.VERMILION)
	draw_circle(tail, 4.5, UITheme.VERMILION)

	# Shift light: five dots across the top that fill as rpm approaches the limiter.
	var lights := 5
	var light_start := max_rpm * 0.78
	for i in lights:
		var thr := light_start + (max_rpm * 0.95 - light_start) * float(i) / (lights - 1)
		var lp := c + Vector2((i - (lights - 1) * 0.5) * 20.0, -R * 0.31)
		var lit := rpm >= thr
		var lc := UITheme.MATCHA if i < 2 else (UITheme.GOLD if i < 4 else UITheme.VERMILION)
		if near_limit:
			lc = UITheme.VERMILION
			lit = flash_on
		draw_circle(lp, 6.0, Color(UITheme.INK, 0.1))
		if lit:
			draw_circle(lp, 11.0, Color(lc, 0.22))
			draw_circle(lp, 6.0, lc)

	# Gear numeral with pop (old gear shrinks away, new one springs in).
	var gfont: Font = UITheme.FONT_TITLE
	var gfs := 104
	var gtxt := _gear_text(_gear_shown)
	var gp := _gear_pop
	var gscale := 1.0
	var galpha := 1.0
	if gp < 0.18:
		var k := gp / 0.18
		gscale = lerpf(1.0, 0.6, k)
		galpha = 1.0 - k
	else:
		var k2 := (gp - 0.18) / 0.82
		gscale = lerpf(1.3, 1.0, UIMotion.out_spring(k2)) if k2 < 1.0 else 1.0
		galpha = minf(k2 * 4.0, 1.0)
	var gsz := gfont.get_string_size(gtxt, HORIZONTAL_ALIGNMENT_LEFT, -1, gfs)
	var gc := c + Vector2(0, 6)
	draw_set_transform(gc, 0.0, Vector2(gscale, gscale))
	var gcol := UITheme.VERMILION if (_gear_shown < 0 or flash_on) else UITheme.INK
	if shifting:
		galpha *= 0.55
	draw_string(gfont, Vector2(-gsz.x * 0.5, gfs * 0.36), gtxt, HORIZONTAL_ALIGNMENT_LEFT, -1, gfs, Color(gcol, galpha))
	draw_set_transform_matrix(Transform2D.IDENTITY)

	# Speed readout (fixed-width digits so it never jitters).
	var sfont: Font = UITheme.FONT_TITLE
	var sfs := 44
	var sp := str(roundi(_speed_shown))
	var dw := 0.0
	for ch in "0123456789":
		dw = maxf(dw, sfont.get_string_size(ch, HORIZONTAL_ALIGNMENT_LEFT, -1, sfs).x)
	var total_w := dw * sp.length()
	var sy := c.y + R * 0.52
	var x := c.x - total_w * 0.5
	for ch in sp:
		var cw := sfont.get_string_size(ch, HORIZONTAL_ALIGNMENT_LEFT, -1, sfs).x
		draw_string(sfont, Vector2(x + (dw - cw) * 0.5, sy), ch, HORIZONTAL_ALIGNMENT_LEFT, -1, sfs, UITheme.INK)
		x += dw
	var ufont: Font = UITheme.FONT_UI_BLACK
	var ufs := 15
	var usz := ufont.get_string_size(unit_label, HORIZONTAL_ALIGNMENT_LEFT, -1, ufs)
	draw_string(ufont, Vector2(c.x - usz.x * 0.5, sy + 24.0), unit_label, HORIZONTAL_ALIGNMENT_LEFT, -1, ufs, Color(UITheme.INK, 0.55))
