extends Control
## Drifting sakura petals (or maple leaves in autumn) drawn with _draw: fluttering 3D flip,
## wind gusts, depth (near petals are larger, softer and faster). `burst()` throws a
## celebratory spray from a point. Fills its parent rect; never takes input.

const UITheme := preload("res://scripts/ui/ui_theme.gd")
const UIMotion := preload("res://scripts/ui/ui_motion.gd")

const SPRING := [Color("fcd9e3"), Color("f8c0d1"), Color("f2a6be"), Color("fde9ef"), Color("e68aa8")]
const AUTUMN := [Color("e75b3d"), Color("f2873e"), Color("d13f35"), Color("f5b04a"), Color("f2c552")]

@export var ambient_count := 34
@export var autumn := false
@export var wind := Vector2(-70, 46)
@export var intensity := 1.0 ## scales ambient spawn (fade petals in/out smoothly)

var _petals: Array[Dictionary] = []
var _petal_poly := PackedVector2Array()
var _leaf_poly := PackedVector2Array()
var _time := 0.0
var _rng := RandomNumberGenerator.new()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rng.seed = 17
	_petal_poly = _make_petal()
	_leaf_poly = _make_leaf()


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


## Pre-fill the screen so ambient petals do not all enter from the edge at once.
func prewarm() -> void:
	for i in ambient_count:
		var p := _new_ambient()
		p["pos"] = Vector2(_rng.randf() * size.x, _rng.randf() * size.y)
		_petals.append(p)


func burst(at: Vector2, count: int = 60, power: float = 900.0) -> void:
	for i in count:
		var ang := _rng.randf_range(-PI * 0.95, -PI * 0.05)
		var spd := power * _rng.randf_range(0.35, 1.0)
		var p := _new_petal(_rng.randf_range(0.2, 1.0))
		p["pos"] = at + Vector2(_rng.randf_range(-20, 20), _rng.randf_range(-10, 10))
		p["vel"] = Vector2(cos(ang), sin(ang)) * spd
		p["drag"] = 2.6
		p["life"] = _rng.randf_range(2.6, 4.2)
		p["ambient"] = false
		_petals.append(p)


func _new_petal(depth: float) -> Dictionary:
	var palette: Array = AUTUMN if autumn else SPRING
	return {
		"pos": Vector2.ZERO,
		"vel": Vector2.ZERO,
		"depth": depth,
		"size": lerpf(9.0, 26.0, depth * depth) * _rng.randf_range(0.8, 1.2),
		"rot": _rng.randf() * TAU,
		"spin": _rng.randf_range(-2.2, 2.2),
		"flip": _rng.randf() * TAU,
		"flip_speed": _rng.randf_range(2.5, 6.0),
		"sway": _rng.randf() * TAU,
		"color": palette[_rng.randi() % palette.size()],
		"drag": 0.0,
		"age": 0.0,
		"life": 1e9,
		"ambient": true,
	}


func _new_ambient() -> Dictionary:
	var p := _new_petal(pow(_rng.randf(), 1.6))
	var r := _rng.randf()
	if r < 0.6:
		p["pos"] = Vector2(_rng.randf_range(0.1, 1.25) * size.x, -40.0)
	else:
		p["pos"] = Vector2(size.x + 40.0, _rng.randf_range(-0.1, 0.8) * size.y)
	return p


func _process(delta: float) -> void:
	var d := UIMotion.real_delta(delta)
	_time += d
	var gust := 0.6 + 0.4 * sin(_time * 0.37) + 0.25 * sin(_time * 1.3 + 1.7)
	var ambient_alive := 0
	var i := 0
	while i < _petals.size():
		var p: Dictionary = _petals[i]
		p["age"] += d
		var depth: float = p["depth"]
		var speed_k := lerpf(0.55, 1.5, depth)
		var target := wind * gust * speed_k
		target.x += sin(_time * 1.1 + p["sway"]) * 30.0 * speed_k
		target.y += 22.0 * speed_k
		var vel: Vector2 = p["vel"]
		if p["drag"] > 0.0:
			vel = vel.lerp(target, UIMotion.damp(p["drag"], d))
			vel.y += 120.0 * d
		else:
			vel = vel.lerp(target, UIMotion.damp(1.5, d))
		p["vel"] = vel
		p["pos"] += vel * d
		p["rot"] += p["spin"] * d
		p["flip"] += p["flip_speed"] * d
		var pos: Vector2 = p["pos"]
		var dead: bool = p["age"] > p["life"] or pos.y > size.y + 60.0 or pos.x < -80.0
		if dead:
			_petals.remove_at(i)
			continue
		if p["ambient"]:
			ambient_alive += 1
		i += 1
	var want := int(ambient_count * clampf(intensity, 0.0, 1.0))
	if ambient_alive < want and _rng.randf() < d * 6.0:
		_petals.append(_new_ambient())
	queue_redraw()


func _draw() -> void:
	for p in _petals:
		var flip := cos(float(p["flip"]))
		var sx := maxf(absf(flip), 0.18)
		var s: float = p["size"]
		var col: Color = p["color"]
		if flip < 0.0:
			col = col.darkened(0.12)
		var depth: float = p["depth"]
		var a := lerpf(0.95, 0.55, depth * depth)
		var life: float = p["life"]
		var age: float = p["age"]
		if life < 1e8:
			a *= clampf((life - age) / 0.8, 0.0, 1.0)
		a *= clampf(age / 0.25, 0.0, 1.0) if not p["ambient"] else 1.0
		col.a *= a
		var xf := Transform2D(float(p["rot"]), Vector2(s * sx, s), 0.0, p["pos"])
		draw_set_transform_matrix(xf)
		draw_colored_polygon(_leaf_poly if autumn else _petal_poly, col)
	draw_set_transform_matrix(Transform2D.IDENTITY)


static func _make_petal() -> PackedVector2Array:
	# Sakura petal: rounded teardrop, base at (0, 0.5), notched tip at (0, -0.5).
	var right := PackedVector2Array()
	var n := 14
	for i in n + 1:
		var t := float(i) / n
		var y := 0.5 - t
		var w := pow(sin(PI * clampf(t * 0.92 + 0.04, 0.0, 1.0)), 0.75) * 0.42
		w *= lerpf(0.55, 1.0, smoothstep(0.0, 0.5, t))
		var notch := 0.0
		if t > 0.8:
			notch = (t - 0.8) / 0.2
		right.append(Vector2(w, y + notch * notch * 0.05))
	right.append(Vector2(0.0, -0.36))
	var poly := PackedVector2Array()
	poly.append_array(right)
	for i in range(right.size() - 2, -1, -1):
		poly.append(Vector2(-right[i].x, right[i].y))
	return poly


static func _make_leaf() -> PackedVector2Array:
	# Stylised maple leaf: five pointed lobes.
	var poly := PackedVector2Array()
	var lobes := [0.0, 0.95, 1.9, -0.95, -1.9]
	var n := 60
	for i in n:
		var a := TAU * float(i) / n - PI * 0.5
		var r := 0.2
		for l in lobes:
			var dd := absf(wrapf(a - (float(l) - PI * 0.5), -PI, PI))
			r = maxf(r, (0.55 if absf(float(l)) < 0.1 else 0.45) * pow(maxf(0.0, 1.0 - dd / 0.55), 1.4))
		var down := absf(wrapf(a - PI * 0.5, -PI, PI))
		if down < 0.35:
			r = maxf(r * 0.4, 0.08)
		poly.append(Vector2(cos(a), sin(a)) * maxf(r, 0.16))
	return poly
