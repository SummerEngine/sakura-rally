class_name Track
extends RefCounted
## Road centreline samples (every 2 m) from the map pack. Answers "where along the
## route is this position", respawn transforms and road surfaces.
##
## Loops (`closed`): `dist(i)` is absolute along the loop from road control point 0 and
## everything wraps; "progress" is measured from the start line (0 .. length).
## Open roads (`closed == false`, a liaison from a start to an arrival): distances are
## measured from the start line (`start_s` = 0), `length` runs start -> arrival, and
## everything clamps instead of wrapping. The road ribbon reaches a little beyond both
## ends (lead-in before the start, run-out past the arrival, into paved lots): there
## `abs_s` runs from `first_s` (< 0) to `last_s` (> length), progress stays in 0 .. length.

const COLS := 10 # x, y, z, fx, fz, half_width, surface, flags, dist, bank
const FLAG_BRIDGE := 1
const FLAG_FORD := 2

var data: PackedFloat32Array
var count: int = 0
var closed: bool = true
var length: float = 1.0
var start_s: float = 0.0
## Distance of the first and last sample (0 and length on a loop).
var first_s: float = 0.0
var last_s: float = 1.0
var verge: float = 1.4
var surface_names: Array[StringName] = []
var spacing: float = 2.0


func setup(samples: PackedFloat32Array, road: Dictionary, is_closed: bool = true) -> void:
	data = samples
	count = samples.size() / COLS
	closed = is_closed
	length = road["length"]
	start_s = road["start_s"]
	verge = road.get("verge", 1.4)
	surface_names.clear()
	for s in road["surfaces"]:
		# wood decks drive like tarmac
		surface_names.append(&"tarmac" if s == "wood" else StringName(s))
	if closed:
		first_s = 0.0
		last_s = length
		spacing = length / float(count)
	else:
		first_s = data[8]
		last_s = data[(count - 1) * COLS + 8]
		spacing = (last_s - first_s) / float(count - 1)


## Sample slot: wraps around a loop, clamps to the ends of an open road.
func _slot(i: int) -> int:
	return (wrapi(i, 0, count) if closed else clampi(i, 0, count - 1)) * COLS


func point(i: int) -> Vector3:
	var o := _slot(i)
	return Vector3(data[o], data[o + 1], data[o + 2])


func forward(i: int) -> Vector3:
	var o := _slot(i)
	return Vector3(data[o + 3], 0.0, data[o + 4])


func right(i: int) -> Vector3:
	var f := forward(i)
	return Vector3(-f.z, 0.0, f.x)


func half_width(i: int) -> float:
	return data[_slot(i) + 5]


func surface(i: int) -> StringName:
	return surface_names[int(data[_slot(i) + 6])]


func flags(i: int) -> int:
	return int(data[_slot(i) + 7])


func dist(i: int) -> float:
	return data[_slot(i) + 8]


func bank(i: int) -> float:
	return data[_slot(i) + 9]


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
	var k0 := -window
	var k1 := window
	if not closed:
		hint = clampi(hint, 0, count - 1)
		k0 = maxi(k0, -hint)
		k1 = mini(k1, count - 1 - hint)
	for k in range(k0, k1 + 1):
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


## Absolute distance along the road of pos, refined by projecting onto sample i.
func abs_s(i: int, pos: Vector3) -> float:
	var s := dist(i) + (pos - point(i)).dot(forward(i))
	return fposmod(s, length) if closed else clampf(s, first_s, last_s)


## Distance from the start line: wraps each lap on a loop, 0 .. length on an open road.
func progress_of(i: int, pos: Vector3) -> float:
	if closed:
		return fposmod(abs_s(i, pos) - start_s, length)
	return clampf(abs_s(i, pos) - start_s, 0.0, length)


## Fractional sample index at absolute distance s.
func _f(s: float) -> float:
	if closed:
		return fposmod(s, length) / spacing
	return (clampf(s, first_s, last_s) - first_s) / spacing


func index_at_abs(s: float) -> int:
	var i := int(floor(_f(s)))
	return wrapi(i, 0, count) if closed else clampi(i, 0, count - 1)


## Centre of the carriageway at absolute distance s (interpolated), with lateral offset.
func position_at_abs(s: float, lat: float = 0.0) -> Vector3:
	var f := _f(s)
	var i := int(floor(f))
	if not closed:
		i = mini(i, count - 2)
	var t := f - i
	var p := point(i).lerp(point(i + 1), t)
	var r := right(i).lerp(right(i + 1), t).normalized()
	var b := lerpf(bank(i), bank(i + 1), t)
	var hw := half_width(i)
	return p + r * lat + Vector3.UP * (-clampf(lat, -hw, hw) * b)


func forward_at_abs(s: float) -> Vector3:
	var f := _f(s)
	var i := int(floor(f))
	if not closed:
		i = mini(i, count - 2)
	return forward(i).lerp(forward(i + 1), f - i).normalized()


## Transform standing on the road at a route progress, facing along the road.
func transform_at_progress(progress: float, lat: float = 0.0, lift: float = 0.0) -> Transform3D:
	return transform_at_abs(start_s + progress, lat, lift)


## Transform standing on the road at absolute distance s, facing along the road.
func transform_at_abs(s: float, lat: float = 0.0, lift: float = 0.0) -> Transform3D:
	var p := position_at_abs(s, lat) + Vector3.UP * lift
	return Transform3D(Basis.looking_at(forward_at_abs(s), Vector3.UP), p)


## Curve3D along the route (world space) for the autopilot, a point every `step`
## metres, `lat` metres right of the centreline, `lift` above the road. A loop closes
## back on the start line; an open road runs start -> arrival (set the autopilot's
## `closed` from `Track.closed`).
func to_curve(step: float = 6.0, lat: float = 0.0, lift: float = 0.3) -> Curve3D:
	var c := Curve3D.new()
	c.bake_interval = 1.0
	var n := maxi(int(length / step), 1)
	for k in n:
		c.add_point(position_at_abs(start_s + k * length / n, lat) + Vector3.UP * lift)
	c.add_point(position_at_abs(start_s + (0.0 if closed else length), lat) + Vector3.UP * lift)
	return c


## Surface under pos if it is on the carriageway or shoulder, else &"".
func road_surface_at(pos: Vector3, hint: int = -1) -> StringName:
	var i := nearest(pos, hint, 8 if hint >= 0 else 40)
	if not closed and (i == 0 or i == count - 1) and absf((pos - point(i)).dot(forward(i))) > spacing:
		return &"" # beyond the end of the ribbon
	if absf(lateral(i, pos)) <= half_width(i) + verge * 0.6:
		return surface(i)
	return &""
