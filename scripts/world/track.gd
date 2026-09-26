class_name Track
extends RefCounted
## Road centreline samples (every 2 m) from the map pack. Answers "where along the
## lap is this position", respawn transforms and road surfaces.
##
## Distances: `dist(i)` is absolute along the loop from road control point 0;
## "progress" is measured from the start line (0 .. length).

const COLS := 10 # x, y, z, fx, fz, half_width, surface, flags, dist, bank
const FLAG_BRIDGE := 1
const FLAG_FORD := 2

var data: PackedFloat32Array
var count: int = 0
var length: float = 1.0
var start_s: float = 0.0
var verge: float = 1.4
var surface_names: Array[StringName] = []
var spacing: float = 2.0


func setup(samples: PackedFloat32Array, road: Dictionary) -> void:
	data = samples
	count = samples.size() / COLS
	length = road["length"]
	start_s = road["start_s"]
	verge = road.get("verge", 1.4)
	surface_names.clear()
	for s in road["surfaces"]:
		# wood decks drive like tarmac
		surface_names.append(&"tarmac" if s == "wood" else StringName(s))
	spacing = length / float(count)


func point(i: int) -> Vector3:
	var o := wrapi(i, 0, count) * COLS
	return Vector3(data[o], data[o + 1], data[o + 2])


func forward(i: int) -> Vector3:
	var o := wrapi(i, 0, count) * COLS
	return Vector3(data[o + 3], 0.0, data[o + 4])


func right(i: int) -> Vector3:
	var f := forward(i)
	return Vector3(-f.z, 0.0, f.x)


func half_width(i: int) -> float:
	return data[wrapi(i, 0, count) * COLS + 5]


func surface(i: int) -> StringName:
	return surface_names[int(data[wrapi(i, 0, count) * COLS + 6])]


func flags(i: int) -> int:
	return int(data[wrapi(i, 0, count) * COLS + 7])


func dist(i: int) -> float:
	return data[wrapi(i, 0, count) * COLS + 8]


func bank(i: int) -> float:
	return data[wrapi(i, 0, count) * COLS + 9]


## Nearest sample to `pos` (XZ). With a hint, only a window around it is searched,
## which keeps progress continuous across switchbacks that pass close together.
func nearest(pos: Vector3, hint: int = -1, window: int = 40) -> int:
	var best := 0
	var best_d := INF
	if hint < 0:
		for i in count:
			var o := i * COLS
			var dx := data[o] - pos.x
			var dz := data[o + 2] - pos.z
			var d := dx * dx + dz * dz
			if d < best_d:
				best_d = d
				best = i
		return best
	for k in range(-window, window + 1):
		var i := wrapi(hint + k, 0, count)
		var o := i * COLS
		var dx := data[o] - pos.x
		var dz := data[o + 2] - pos.z
		var d := dx * dx + dz * dz
		if d < best_d:
			best_d = d
			best = i
	return best


## Signed lateral offset of pos from the centreline at sample i (+ = right).
func lateral(i: int, pos: Vector3) -> float:
	return (pos - point(i)).dot(right(i))


## Absolute distance along the loop of pos, refined by projecting onto sample i.
func abs_s(i: int, pos: Vector3) -> float:
	return fposmod(dist(i) + (pos - point(i)).dot(forward(i)), length)


func progress_of(i: int, pos: Vector3) -> float:
	return fposmod(abs_s(i, pos) - start_s, length)


func index_at_abs(s: float) -> int:
	return wrapi(int(floor(fposmod(s, length) / spacing)), 0, count)


## Centre of the carriageway at absolute distance s (interpolated), with lateral offset.
func position_at_abs(s: float, lat: float = 0.0) -> Vector3:
	s = fposmod(s, length)
	var f := s / spacing
	var i := int(floor(f))
	var t := f - i
	var p := point(i).lerp(point(i + 1), t)
	var r := right(i).lerp(right(i + 1), t).normalized()
	var b := lerpf(bank(i), bank(i + 1), t)
	var hw := half_width(i)
	return p + r * lat + Vector3.UP * (-clampf(lat, -hw, hw) * b)


func forward_at_abs(s: float) -> Vector3:
	s = fposmod(s, length)
	var f := s / spacing
	var i := int(floor(f))
	return forward(i).lerp(forward(i + 1), f - i).normalized()


## Transform standing on the road at a lap progress, facing along the road.
func transform_at_progress(progress: float, lat: float = 0.0, lift: float = 0.0) -> Transform3D:
	return transform_at_abs(start_s + progress, lat, lift)


## Transform standing on the road at absolute distance s, facing along the road.
func transform_at_abs(s: float, lat: float = 0.0, lift: float = 0.0) -> Transform3D:
	var p := position_at_abs(s, lat) + Vector3.UP * lift
	return Transform3D(Basis.looking_at(forward_at_abs(s), Vector3.UP), p)


## Closed Curve3D along the road (world space) for the autopilot, a point every
## `step` metres, `lat` metres right of the centreline, `lift` above the road.
func to_curve(step: float = 6.0, lat: float = 0.0, lift: float = 0.3) -> Curve3D:
	var c := Curve3D.new()
	c.bake_interval = 1.0
	var n := int(length / step)
	for k in n:
		c.add_point(position_at_abs(start_s + k * length / n, lat) + Vector3.UP * lift)
	c.add_point(position_at_abs(start_s, lat) + Vector3.UP * lift)
	return c


## Surface under pos if it is on the carriageway or shoulder, else &"".
func road_surface_at(pos: Vector3, hint: int = -1) -> StringName:
	var i := nearest(pos, hint, 8 if hint >= 0 else 40)
	if absf(lateral(i, pos)) <= half_width(i) + verge * 0.6:
		return surface(i)
	return &""
