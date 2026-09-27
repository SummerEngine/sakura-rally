extends Control
## One focus indicator for the whole UI: a sakura-pink ring that glides (spring-damped) from
## the previously focused control to the new one and breathes softly while resting.
## The glide is an offset from the focused control that decays to zero, so once it lands the
## ring follows the control exactly (lift, scale, parallax) with no lag.
## Controls may set meta "focus_radius" (float) and "focus_grow" (float) to shape the ring,
## or meta "no_focus_ring" = true to hide it (controls that draw their own focus, like map cards).

const UITheme := preload("res://scripts/ui/ui_theme.gd")
const UIMotion := preload("res://scripts/ui/ui_motion.gd")

var _rect := Rect2()
var _radius := 30.0
var _alpha := 0.0
var _time := 0.0
var _has_rect := false
var _owner: Control
## Glide state: where the ring still is relative to the focused control's rect.
var _off_pos := Vector2.ZERO
var _off_size := Vector2.ZERO
var _off_radius := 0.0
var _sb_line := StyleBoxFlat.new()
var _sb_glow := StyleBoxFlat.new()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	for sb: StyleBoxFlat in [_sb_line, _sb_glow]:
		sb.bg_color = Color(0, 0, 0, 0)
		sb.draw_center = false
		sb.corner_detail = 12
		sb.anti_aliasing_size = 1.0
	_sb_line.set_border_width_all(3)
	_sb_glow.set_border_width_all(7)


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _process(delta: float) -> void:
	var d := UIMotion.real_delta(delta)
	_time += d
	var owner_ctrl := get_viewport().gui_get_focus_owner()
	var show := owner_ctrl != null and owner_ctrl.is_visible_in_tree() and not bool(owner_ctrl.get_meta(&"no_focus_ring", false))
	if show:
		var xf := owner_ctrl.get_global_transform_with_canvas()
		var inv := get_global_transform_with_canvas().affine_inverse()
		var a := inv * (xf * Vector2.ZERO)
		var b := inv * (xf * owner_ctrl.size)
		var grow := float(owner_ctrl.get_meta(&"focus_grow", 6.0))
		var target := Rect2(a, b - a).abs().grow(grow)
		var r := float(owner_ctrl.get_meta(&"focus_radius", target.size.y * 0.5))
		if owner_ctrl != _owner:
			_owner = owner_ctrl
			if _has_rect and _alpha >= 0.02:
				_off_pos = _rect.position - target.position
				_off_size = _rect.size - target.size
				_off_radius = _radius - r
			else:
				_off_pos = Vector2.ZERO
				_off_size = Vector2.ZERO
				_off_radius = 0.0
		var k := 1.0 - UIMotion.damp(20.0, d)
		_off_pos *= k
		_off_size *= k
		_off_radius *= k
		_rect = Rect2(target.position + _off_pos, target.size + _off_size)
		_radius = r + _off_radius
		_has_rect = true
	var target_a := _effective_alpha(owner_ctrl) if show else 0.0
	_alpha = lerpf(_alpha, target_a, UIMotion.damp(16.0, d))
	queue_redraw()


## Product of modulate alphas up the tree, so the ring fades with its screen.
static func _effective_alpha(c: CanvasItem) -> float:
	var a := 1.0
	var n: Node = c
	while n != null:
		var ci := n as CanvasItem
		if ci != null:
			a *= ci.modulate.a
		if n is CanvasLayer:
			break
		n = n.get_parent()
	return a * c.self_modulate.a


func _draw() -> void:
	if _alpha < 0.01 or not _has_rect:
		return
	var breathe := 0.5 + 0.5 * sin(_time * 3.2)
	var r := int(minf(_radius, minf(_rect.size.x, _rect.size.y) * 0.5))
	_sb_glow.set_corner_radius_all(r + 4)
	_sb_glow.border_color = Color(UITheme.SAKURA, (0.14 + 0.1 * breathe) * _alpha)
	draw_style_box(_sb_glow, _rect.grow(4.0))
	_sb_line.set_corner_radius_all(r)
	_sb_line.border_color = Color(UITheme.SAKURA, 0.95 * _alpha)
	draw_style_box(_sb_line, _rect)
