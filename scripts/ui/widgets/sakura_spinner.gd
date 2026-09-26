extends Control
## Loading indicator: a five-petal sakura blossom turning slowly, petals swelling in sequence.

const UITheme := preload("res://scripts/ui/ui_theme.gd")
const UIMotion := preload("res://scripts/ui/ui_motion.gd")
const PetalField := preload("res://scripts/ui/widgets/petal_field.gd")

@export var petal_color := UITheme.SAKURA_SOFT
@export var centre_color := UITheme.GOLD

var _time := 0.0
var _poly := PetalField._make_petal()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(56, 56)


func _process(delta: float) -> void:
	_time += UIMotion.real_delta(delta)
	queue_redraw()


func _draw() -> void:
	var c := size * 0.5
	var r := minf(size.x, size.y) * 0.5
	var base_rot := _time * 0.9
	for i in 5:
		var a := base_rot + TAU * i / 5.0
		var wave := 0.5 + 0.5 * sin(_time * 5.0 - i * 1.25)
		var s := r * (0.5 + 0.14 * wave)
		var pos := c + Vector2(cos(a - PI * 0.5), sin(a - PI * 0.5)) * s * 0.52
		var xf := Transform2D(a, Vector2(s * 0.78, s), 0.0, pos)
		draw_set_transform_matrix(xf)
		draw_colored_polygon(_poly, Color(petal_color, 0.7 + 0.3 * wave))
	draw_set_transform_matrix(Transform2D.IDENTITY)
	draw_circle(c, r * 0.12, centre_color)
