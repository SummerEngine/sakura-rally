extends StaticBody3D
## Terrain collider. Answers `surface_at(point)` for the car's wheel raycasts
## (see Car.surface_of) from the baked terrain surface grid (grass, dirt, sand, gravel);
## the roads are their own bodies with their own surface.

var grid: PackedByteArray
var nx: int = 0
var nz: int = 0
var origin := Vector2.ZERO
var cell: float = 8.0
var codes: Array[StringName] = []


## `bytes`: one code per cell, row-major z then x; sample (i, j) sits at origin + (i, j) * cell.
func setup(bytes: PackedByteArray, dims: Vector2i, grid_origin: Vector2, grid_cell: float, code_names: Array) -> void:
	grid = bytes
	nx = dims.x
	nz = dims.y
	origin = grid_origin
	cell = grid_cell
	codes.clear()
	for c in code_names:
		codes.append(StringName(c))


func surface_at(point: Vector3) -> StringName:
	if nx == 0:
		return &"grass"
	var i := clampi(int(round((point.x - origin.x) / cell)), 0, nx - 1)
	var j := clampi(int(round((point.z - origin.y) / cell)), 0, nz - 1)
	return codes[grid[j * nx + i]]
