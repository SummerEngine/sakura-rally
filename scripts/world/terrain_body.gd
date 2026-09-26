extends StaticBody3D
## Terrain collider. Answers `surface_at(point)` for the car's wheel raycasts
## (see Car.surface_of): the road wins where the point is on the carriageway,
## otherwise the baked terrain surface grid (grass, dirt, sand, gravel).

var grid: PackedByteArray
var grid_n: int = 0
var origin: float = 0.0
var cell: float = 8.0
var codes: Array[StringName] = []
var track: Track


func setup(bytes: PackedByteArray, n: int, grid_origin: float, grid_cell: float, code_names: Array, road_track: Track) -> void:
	grid = bytes
	grid_n = n
	origin = grid_origin
	cell = grid_cell
	codes.clear()
	for c in code_names:
		codes.append(StringName(c))
	track = road_track


func surface_at(point: Vector3) -> StringName:
	if grid_n == 0:
		return &"grass"
	var i := clampi(int(round((point.x - origin) / cell)), 0, grid_n - 1)
	var j := clampi(int(round((point.z - origin) / cell)), 0, grid_n - 1)
	return codes[grid[j * grid_n + i]]
