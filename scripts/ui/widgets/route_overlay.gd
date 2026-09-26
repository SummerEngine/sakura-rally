extends Control
## The route over a map card's top-down image (assets/ui/maps/<id>_route.json, written by
## tools/build/capture_topdown.gd): an ink-cased line coloured by surface, start / finish marks and
## checkpoint dots. `reveal` (0..1) draws it along its length, `marker` (0..1, < 0 = hidden)
## places a small car on it, `zoom` scales everything about the centre to match the image.

const UITheme := preload("res://scripts/ui/ui_theme.gd")

## Line colour per surface (the ink casing keeps each readable on any ground).
const SURFACE_COLORS := {
	"tarmac": Color("f4efe6"),
	"gravel": Color("f0b85a"),
	"dirt": Color("d0743f"),
	"grass": Color("9fd36d"),
	"sand": Color("f3dc9b"),
}
const SURFACE_NAMES := ["tarmac", "gravel", "dirt", "grass", "sand"]

var zoom := 1.0:
	set(v):
		zoom = v
		queue_redraw()
var reveal := 1.0:
	set(v):
		reveal = clampf(v, 0.0, 1.0)
		queue_redraw()
var marker := -1.0:
	set(v):
		marker = v
		queue_redraw()
## 0 = resting (thin line), 1 = focused (bold line).
var emphasis := 0.0:
	set(v):
		emphasis = v
		queue_redraw()

var closed := true
## Route length in metres (from the world rect) and the surfaces it uses, in SURFACE_NAMES order.
var length_m := 0.0
var surfaces: PackedStringArray = []

var _uv := PackedVector2Array()
var _cols := PackedColorArray()
var _start := Vector2.ZERO
var _finish := Vector2.ZERO
var _cp_uv := PackedVector2Array()
## Laid out in pixels (on resize): points, cumulative length, checkpoint positions and their
## fraction along the route (for the pop-in as the line reaches them).
var _pts := PackedVector2Array()
var _cum := PackedFloat32Array()
var _cp_pts := PackedVector2Array()
var _cp_at := PackedFloat32Array()
var _car_outline := PackedVector2Array([Vector2(9.5, 0), Vector2(-6.5, -7.2), Vector2(-3.4, 0), Vector2(-6.5, 7.2)])
var _car_loop := _car_outline + PackedVector2Array([_car_outline[0]])
var _car_body := PackedVector2Array([Vector2(6.6, 0), Vector2(-4.6, -4.9), Vector2(-2.4, 0), Vector2(-4.6, 4.9)])


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(_layout)


## Loads the route of `map_id`; false when the map has no card art yet.
func load_route(map_id: String) -> bool:
	var path := "res://assets/ui/maps/%s_route.json" % map_id
	if not FileAccess.file_exists(path):
		return false
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(d) != TYPE_DICTIONARY:
		push_error("RouteOverlay: cannot parse %s" % path)
		return false
	closed = bool(d.get("closed", true))
	var rect: Array = d["world_rect"]
	var world := Vector2(float(rect[2]), float(rect[3]))
	var pts: Array = d["points"]
	var surf: Array = d["surface"]
	_uv.resize(pts.size())
	_cols.resize(pts.size())
	var used := {}
	length_m = 0.0
	for i in pts.size():
		_uv[i] = Vector2(float(pts[i][0]), float(pts[i][1]))
		var s := str(surf[i])
		_cols[i] = SURFACE_COLORS.get(s, SURFACE_COLORS["tarmac"])
		used[s] = true
		if i > 0:
			length_m += ((_uv[i] - _uv[i - 1]) * world).length()
	if closed and _uv.size() > 1:
		length_m += ((_uv[0] - _uv[_uv.size() - 1]) * world).length()
		_uv.append(_uv[0])
		_cols.append(_cols[0])
	surfaces.clear()
	for s: String in SURFACE_NAMES:
		if used.has(s):
			surfaces.append(s)
	_start = Vector2(float(d["start"][0]), float(d["start"][1]))
	_finish = Vector2(float(d["finish"][0]), float(d["finish"][1]))
	_cp_uv.clear()
	for c: Array in d["checkpoints"]:
		_cp_uv.append(Vector2(float(c[0]), float(c[1])))
	_layout()
	return true


func _layout() -> void:
	var n := _uv.size()
	_pts.resize(n)
	_cum.resize(n)
	var acc := 0.0
	for i in n:
		_pts[i] = _uv[i] * size
		if i > 0:
			acc += _pts[i].distance_to(_pts[i - 1])
		_cum[i] = acc
	_cp_pts.resize(_cp_uv.size())
	_cp_at.resize(_cp_uv.size())
	for k in _cp_uv.size():
		_cp_pts[k] = _cp_uv[k] * size
		var best := 0
		var best_d := INF
		for i in n:
			var dd := _pts[i].distance_squared_to(_cp_pts[k])
			if dd < best_d:
				best_d = dd
				best = i
		_cp_at[k] = _cum[best] / maxf(acc, 1.0)
	queue_redraw()


## Point and heading at fraction t (0..1) of the route length.
func _at(t: float) -> Array:
	var total := _cum[_cum.size() - 1]
	var target := clampf(t, 0.0, 1.0) * total
	var i := clampi(_cum.bsearch(target), 1, _cum.size() - 1)
	var seg := maxf(_cum[i] - _cum[i - 1], 0.0001)
	var k := clampf((target - _cum[i - 1]) / seg, 0.0, 1.0)
	return [_pts[i - 1].lerp(_pts[i], k), (_pts[i] - _pts[i - 1]).normalized(), i]


func _draw() -> void:
	if _pts.size() < 2:
		return
	var c := size * 0.5
	var zoom_xf := Transform2D(0.0, Vector2(zoom, zoom), 0.0, c * (1.0 - zoom))
	draw_set_transform_matrix(zoom_xf)
	var core := lerpf(3.0, 4.6, emphasis)
	var casing := core + lerpf(3.0, 4.4, emphasis)
	var ink := UITheme.INK

	if reveal < 1.0:
		# The full route as a faint pencil guide while the line draws over it.
		draw_polyline(_pts, Color(ink, 0.3), 2.0, true)
	var line := _pts
	var cols := _cols
	var head := _pts[_pts.size() - 1]
	if reveal < 1.0:
		var a: Array = _at(reveal)
		var i: int = a[2]
		head = a[0]
		line = _pts.slice(0, i)
		line.append(head)
		cols = _cols.slice(0, i)
		cols.append(_cols[i])
	if line.size() >= 2:
		draw_polyline(line, ink, casing, true)
		draw_circle(line[0], casing * 0.5, ink)
		draw_circle(head, casing * 0.5, ink)
		draw_polyline_colors(line, cols, core, true)
		draw_circle(line[0], core * 0.5, cols[0])
		draw_circle(head, core * 0.5, cols[cols.size() - 1])

	for k in _cp_pts.size():
		var pop := clampf((reveal - _cp_at[k]) / 0.06, 0.0, 1.0)
		if pop <= 0.0:
			continue
		var r := lerpf(3.4, 4.4, emphasis) * (1.0 + 0.5 * sin(pop * PI))
		draw_circle(_cp_pts[k], r + 1.8, ink)
		draw_circle(_cp_pts[k], r, UITheme.PAPER)

	var dir0 := (_pts[1] - _pts[0]).normalized()
	if closed:
		_draw_flag(zoom_xf, _start * size, dir0)
	else:
		draw_circle(_start * size, 7.0, ink)
		draw_circle(_start * size, 5.0, UITheme.PAPER)
		draw_circle(_start * size, 2.6, UITheme.SAKURA)
		if reveal >= 0.999:
			var n := _pts.size()
			_draw_flag(zoom_xf, _finish * size, (_pts[n - 1] - _pts[n - 2]).normalized())

	if marker >= 0.0:
		var m: Array = _at(marker)
		_draw_car(zoom_xf, m[0], m[1])


## Chequered start / finish bar across the road.
func _draw_flag(base: Transform2D, pos: Vector2, dir: Vector2) -> void:
	draw_set_transform_matrix(base * Transform2D(dir.angle(), pos))
	var cell := 3.2
	var cols := 2
	var rows := 5
	var origin := Vector2(-cell * cols * 0.5, -cell * rows * 0.5)
	draw_rect(Rect2(origin - Vector2(1.6, 1.6), Vector2(cell * cols, cell * rows) + Vector2(3.2, 3.2)), UITheme.INK)
	for x in cols:
		for y in rows:
			var col := UITheme.PAPER if (x + y) % 2 == 0 else UITheme.INK
			draw_rect(Rect2(origin + Vector2(x, y) * cell, Vector2(cell, cell)), col)
	draw_set_transform_matrix(base)


## Small car arrow with a soft halo, pointing along the route.
func _draw_car(base: Transform2D, pos: Vector2, dir: Vector2) -> void:
	draw_circle(pos, 11.0, Color(UITheme.VERMILION, 0.18))
	draw_set_transform_matrix(base * Transform2D(dir.angle(), pos))
	draw_colored_polygon(_car_outline, UITheme.PAPER)
	draw_polyline(_car_loop, UITheme.INK, 1.6, true)
	draw_colored_polygon(_car_body, UITheme.VERMILION)
	draw_set_transform_matrix(base)
