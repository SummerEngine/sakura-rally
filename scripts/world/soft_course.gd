class_name SoftCourse
extends Node3D
## Soft course dressing, the way Forza Horizon does it: tape, cones, banners, flags, boards,
## fences, tyre stacks and bales never reach the physics solver. MapWorld registers every
## instance of a SMASHABLE prop here instead of giving it a collider; each physics tick the
## cars' boxes are tested against a spatial hash of the props near them. A hit knocks a small
## share off the car's speed (a central impulse against its horizontal velocity: no yaw, no
## lift), hides the MultiMesh instance and flings a pooled debris body that tumbles on the
## terrain, never touches a car, and shrinks away after ~5 s.
##
## Soft uprights (the fabric checkpoint gates' posts and the start/finish arch legs) are tested
## the same way but never break: they cost a little speed and wobble back.
##
## Everything comes back on a stage restart (a new car), a reset to the track (the car jumps)
## and a map reload (a new MapWorld builds a new SoftCourse).
##
## Spectators are knockable people, not smashables: the child `crowd` (scripts/world/crowd.gd)
## gets each car's box from the same per-tick scan and costs speed through `slow_car()`.

## Speed share lost on a hit, sound, how readily the prop is flung (1 = with the car), and the
## colour of the chips thrown with it.
const SMASHABLE := {
	"traffic_cone": {"loss": 0.01, "sfx": &"impact_light", "db": -8.0, "fling": 1.15, "chip": Color("e8743b")},
	"rice_paddy_marker": {"loss": 0.015, "sfx": &"impact_light", "db": -9.0, "fling": 1.1, "chip": Color("a47148")},
	"tape_post": {"loss": 0.02, "sfx": &"impact_light", "db": -7.0, "fling": 1.05, "chip": Color("f2a6be")},
	"banner_fence": {"loss": 0.03, "sfx": &"thump", "db": -6.0, "fling": 0.95, "chip": Color("fde9ef")},
	"flag_pole": {"loss": 0.03, "sfx": &"impact_light", "db": -6.0, "fling": 0.95, "chip": Color("f5f2ea")},
	"flag_pole_pink": {"loss": 0.03, "sfx": &"impact_light", "db": -6.0, "fling": 0.95, "chip": Color("f2a6be")},
	"flag_pole_blue": {"loss": 0.03, "sfx": &"impact_light", "db": -6.0, "fling": 0.95, "chip": Color("6aa8e8")},
	"koinobori": {"loss": 0.03, "sfx": &"impact_light", "db": -6.0, "fling": 0.9, "chip": Color("e44a30")},
	"scarecrow": {"loss": 0.035, "sfx": &"thump", "db": -6.0, "fling": 0.9, "chip": Color("f2c552")},
	"chevron_left": {"loss": 0.04, "sfx": &"impact_light", "db": -4.0, "fling": 0.9, "chip": Color("f5f2ea")},
	"chevron_right": {"loss": 0.04, "sfx": &"impact_light", "db": -4.0, "fling": 0.9, "chip": Color("f5f2ea")},
	"distance_board_100": {"loss": 0.04, "sfx": &"impact_light", "db": -4.0, "fling": 0.9, "chip": Color("f5f2ea")},
	"distance_board_50": {"loss": 0.04, "sfx": &"impact_light", "db": -4.0, "fling": 0.9, "chip": Color("f5f2ea")},
	"sign_curve_left": {"loss": 0.04, "sfx": &"impact_light", "db": -4.0, "fling": 0.9, "chip": Color("f2c552")},
	"sign_curve_right": {"loss": 0.04, "sfx": &"impact_light", "db": -4.0, "fling": 0.9, "chip": Color("f2c552")},
	"road_mirror": {"loss": 0.04, "sfx": &"impact_light", "db": -4.0, "fling": 0.9, "chip": Color("f29a38")},
	"fence_wood": {"loss": 0.04, "sfx": &"thump", "db": -4.0, "fling": 0.85, "chip": Color("a47148")},
	"fence_bamboo": {"loss": 0.04, "sfx": &"thump", "db": -4.0, "fling": 0.85, "chip": Color("c9b26a")},
	"marshal_post": {"loss": 0.05, "sfx": &"thump", "db": -3.0, "fling": 0.8, "chip": Color("f4ede0")},
	"bench": {"loss": 0.05, "sfx": &"thump", "db": -3.0, "fling": 0.8, "chip": Color("a47148")},
	"tire_stack": {"loss": 0.06, "sfx": &"thump", "db": -2.0, "fling": 0.75, "chip": Color("3a3440")},
	"hay_bale_square": {"loss": 0.08, "sfx": &"thump", "db": -1.0, "fling": 0.65, "chip": Color("e3c16f")},
	"hay_bale_round": {"loss": 0.12, "sfx": &"thump", "db": 0.0, "fling": 0.55, "chip": Color("e3c16f")},
}
## Mapgen road signs (map.json `signs` with a `mesh`): one node each, not a MultiMesh instance.
const ROAD_SIGN := "road_sign"
const ROAD_SIGN_DATA := {"loss": 0.04, "sfx": &"thump", "db": -3.0, "fling": 0.8, "chip": Color("f5f2ea")}
## Props whose collider legs become soft uprights (kept, wobbling) instead of static bodies.
const SOFT_UPRIGHT_PROPS := ["start_arch", "finish_arch"]
## Prop skipped entirely: MapWorld builds fabric gates at the checkpoints instead.
const SKIPPED_PROPS := ["checkpoint_gate"]
const UPRIGHT_LOSS := 0.025
## Hits in quick succession (ploughing along a tyre wall) share a budget: each costs its table
## loss times (1 - recent / LOSS_BUDGET), at least LOSS_FLOOR of it; `recent` is the speed share
## already lost, fading with LOSS_MEMORY seconds.
const LOSS_BUDGET := 0.14
const LOSS_FLOOR := 0.2
const LOSS_MEMORY := 0.6

const LAYER_DEBRIS := 16 # bit 5: debris rests on layer 1 and meets nothing else
const CELL := 8.0
## Largest footprint half-extent a prop may have (m): hash queries widen by this much.
const PROP_REACH := 2.2
const DEBRIS_MAX := 24
const DEBRIS_LIFE_MIN := 4.4
const DEBRIS_LIFE_MAX := 5.6
const DEBRIS_SHRINK := 0.7
const BURSTS := 4
const DUST_SHADER := preload("res://shaders/dust.gdshader")
## Frames each warm-up batch stays drawn (the renderer builds pipelines on the first draw).
const WARM_FRAMES := 3

signal smashed(prop: String, point: Vector3, speed_before: float, loss: float)
signal upright_hit(point: Vector3, speed_before: float, loss: float)

# ---------------------------------------------------------------- props (struct of arrays)
var _kind: PackedInt32Array ## index into _kinds
var _mm_ref: PackedInt32Array ## index into _mms, or -1 for a node prop (a road sign)
var _mm_idx: PackedInt32Array ## instance index in that MultiMesh, or index into _nodes
var _cx: PackedFloat32Array ## footprint centre (world x, z)
var _cz: PackedFloat32Array
var _y0: PackedFloat32Array ## footprint height range (world)
var _y1: PackedFloat32Array
var _ux: PackedFloat32Array ## footprint local x axis in world xz (cos, -sin)
var _uz: PackedFloat32Array
var _hx: PackedFloat32Array ## half extents; _hz < 0 marks a circle of radius _hx
var _hz: PackedFloat32Array
var _broken: PackedByteArray
var _xf: Array[Transform3D] = [] ## original instance transforms
var _kinds: Array[String] = []
var _kind_data: Array[Dictionary] = []
var _kind_mesh: Array[Mesh] = []
var _mms: Array[MultiMesh] = []
var _nodes: Array[Node3D] = [] ## node props: hidden on a smash
var _node_debris: Array[Array] = [] ## and the meshes their debris pieces carry (Array[Mesh])
var _cells: Dictionary = {} ## Vector2i -> PackedInt32Array of prop ids
var _broken_list: PackedInt32Array

# ---------------------------------------------------------------- soft uprights
## Each: {"x", "z", "r", "y0", "y1", "gate": FabricGate or null, "side": int,
## "mm": MultiMesh, "idx": int, "xf": Transform3D, "angle", "vel", "axis": Vector3, "touch": int}
var _uprights: Array[Dictionary] = []
var _gates: Array[FabricGate] = []

# ---------------------------------------------------------------- cars
var _cars: Array[Car] = []
var _car_half: PackedVector3Array
var _car_centre: PackedVector3Array
var _car_last: PackedVector3Array
var _car_recent: PackedFloat32Array ## speed share lost lately (see LOSS_BUDGET)
var _gate_side: PackedFloat32Array ## per car, per gate: signed distance along the gate last tick

# ---------------------------------------------------------------- debris and bursts
var _debris: Array[RigidBody3D] = []
var _debris_mesh: Array[MeshInstance3D] = []
var _debris_shape: Array[BoxShape3D] = []
var _debris_age: PackedFloat32Array
var _debris_life: PackedFloat32Array
var _debris_scale: PackedVector3Array
var _debris_live: int = 0
var _debris_material: PhysicsMaterial
var _puffs: Array[GPUParticles3D] = []
var _chips: Array[GPUParticles3D] = []
var _chip_mats: Array[ParticleProcessMaterial] = []
var _burst_next: int = 0
var _burst_ticks: int = 0 ## physics ticks the latest burst stays on screen
var _burst_car: Car ## the dust clears the line of sight to this car (dust.gdshader `focus`)
var _dust_material: ShaderMaterial

var _rng := RandomNumberGenerator.new()
var _tick: int = 0
var _arch_wobbling: int = 0
## Physics ticks until the gate feet are dropped onto the ground (colliders need a step first).
var _settle_in: int = 0

## Hits since the last restore (read by tools/game/softcourse_probe.gd and stats).
var hits: int = 0
## Knockable spectators (MapWorld registers them; scanned and restored with the rest).
var crowd: Crowd
## Warm-up: the first kind index not yet drawn, frames left on the batch on screen.
var _warm_next: int = -1
var _warm_hold: int = 0
var _warmed: bool = false


func _init() -> void:
	name = "SoftCourse"
	crowd = Crowd.new()
	add_child(crowd)
	_rng.seed = 20260926


func _ready() -> void:
	_debris_material = PhysicsMaterial.new()
	_debris_material.friction = 0.9
	_debris_material.bounce = 0.12
	_build_pools()
	# warm up once every smashable kind is registered (MapWorld.build() has finished)
	set_process(false)
	var map := get_parent() as MapWorld
	if map != null:
		map.built.connect(set_process.bind(true), CONNECT_ONE_SHOT)
	get_tree().node_added.connect(_on_node_added)
	_scan_for_cars(get_tree().root)
	var game := get_node_or_null(^"/root/Game")
	if game != null and game.has_signal(&"checkpoint_passed"):
		game.checkpoint_passed.connect(_on_checkpoint_passed)


# ================================================================ registration (MapWorld)

static func is_smashable(prop_name: String) -> bool:
	return SMASHABLE.has(prop_name)


## One instance of a SMASHABLE prop: `mm` and `idx` locate its MultiMesh instance, `e` is the
## map.json instance row [x, y, z, yaw, scale], `m` its manifest entry.
func add_smashable(prop_name: String, mesh: Mesh, mm: MultiMesh, idx: int, e: Array, m: Dictionary) -> void:
	var k := _kinds.find(prop_name)
	if k < 0:
		k = _kinds.size()
		_kinds.append(prop_name)
		_kind_data.append(SMASHABLE[prop_name])
		_kind_mesh.append(mesh)
	var mi := _mms.find(mm)
	if mi < 0:
		mi = _mms.size()
		_mms.append(mm)
	var sc: float = e[4]
	var yaw: float = e[3]
	var origin := Vector3(e[0], e[1], e[2])
	var rot := Basis(Vector3.UP, yaw)
	var col: Dictionary = m.get("collision", {"type": "none"})
	var centre := Vector3.ZERO
	var hx := 0.0
	var hz := -1.0
	var y0 := 0.0
	var y1 := 0.0
	match col.get("type", "none"):
		"box":
			var sz: Array = col["size"]
			var c: Array = col.get("center", [0.0, float(sz[1]) * 0.5, 0.0])
			centre = Vector3(c[0], c[1], c[2]) * sc
			hx = maxf(float(sz[0]) * 0.5 * sc, 0.1)
			hz = maxf(float(sz[2]) * 0.5 * sc, 0.1)
			y0 = centre.y - float(sz[1]) * 0.5 * sc
			y1 = centre.y + float(sz[1]) * 0.5 * sc
			centre.y = 0.0
		"cylinder":
			var r := float(col["radius"]) * sc
			var h := float(col["height"]) * sc
			var offsets: Array = col.get("offsets", [[0.0, 0.0, 0.0]])
			if offsets.size() > 1:
				# posts with tape (or a banner) between them: the whole span breaks
				var lo := Vector3(INF, INF, INF)
				var hi := -lo
				for o in offsets:
					var p := Vector3(o[0], o[1], o[2]) * sc
					lo = lo.min(p)
					hi = hi.max(p)
				centre = Vector3((lo.x + hi.x) * 0.5, 0.0, (lo.z + hi.z) * 0.5)
				hx = maxf((hi.x - lo.x) * 0.5 + r, 0.1)
				hz = maxf((hi.z - lo.z) * 0.5 + r, 0.1)
				y0 = lo.y
				y1 = hi.y + h
			else:
				var o: Array = offsets[0]
				centre = Vector3(o[0], 0.0, o[2]) * sc
				hx = maxf(r, 0.12)
				y0 = float(o[1]) * sc
				y1 = y0 + h
		_:
			var box := mesh.get_aabb()
			centre = Vector3(box.get_center().x, 0.0, box.get_center().z) * sc
			hx = maxf(box.size.x * 0.5 * sc, 0.1)
			hz = maxf(box.size.z * 0.5 * sc, 0.1)
			y0 = box.position.y * sc
			y1 = box.end.y * sc
	_register(k, mi, idx, origin + rot * centre, origin.y + y0, origin.y + y1, yaw, hx, hz,
			mm.get_instance_transform(idx))


## A mapgen road sign: `node` (its mesh and text lines) is hidden when it breaks; `pieces`
## (board, posts) fly off as debris. The pieces and the collider box (`size`, `center`) are in
## the sign's frame `xf` (base centre on the ground, yawed).
func add_sign(node: Node3D, pieces: Array[Mesh], xf: Transform3D, size: Vector3, center: Vector3) -> void:
	var k := _kinds.find(ROAD_SIGN)
	if k < 0:
		k = _kinds.size()
		_kinds.append(ROAD_SIGN)
		_kind_data.append(ROAD_SIGN_DATA)
		_kind_mesh.append(pieces[0])
	var yaw := xf.basis.get_euler().y
	var world := xf * Vector3(center.x, 0.0, center.z)
	_register(k, -1, _nodes.size(), world, xf.origin.y + center.y - size.y * 0.5,
			xf.origin.y + center.y + size.y * 0.5, yaw, maxf(size.x * 0.5, 0.1), maxf(size.z * 0.5, 0.1), xf)
	_nodes.append(node)
	_node_debris.append(pieces)


func _register(k: int, mm_ref: int, idx: int, world: Vector3, y0: float, y1: float, yaw: float,
		hx: float, hz: float, xf: Transform3D) -> void:
	var id := _kind.size()
	_kind.append(k)
	_mm_ref.append(mm_ref)
	_mm_idx.append(idx)
	_cx.append(world.x)
	_cz.append(world.z)
	_y0.append(y0)
	_y1.append(y1)
	_ux.append(cos(yaw))
	_uz.append(-sin(yaw))
	_hx.append(hx)
	_hz.append(hz)
	_broken.append(0)
	_xf.append(xf)
	# a footprint wider than PROP_REACH (a big direction board) sits in every cell it spans
	var r := sqrt(hx * hx + hz * hz) if hz > 0.0 else hx
	var extra := maxf(r - PROP_REACH, 0.0)
	for gx in range(floori((world.x - extra) / CELL), floori((world.x + extra) / CELL) + 1):
		for gz in range(floori((world.z - extra) / CELL), floori((world.z + extra) / CELL) + 1):
			var cell := Vector2i(gx, gz)
			var list: PackedInt32Array = _cells.get(cell, PackedInt32Array())
			list.append(id)
			_cells[cell] = list


## Collider legs of a start/finish arch instance become soft uprights; the arch nods when hit.
func add_soft_uprights(mm: MultiMesh, idx: int, e: Array, m: Dictionary) -> int:
	var col: Dictionary = m.get("collision", {})
	if col.get("type", "") != "cylinder":
		return 0
	var sc: float = e[4]
	var origin := Vector3(e[0], e[1], e[2])
	var rot := Basis(Vector3.UP, e[3])
	var n := 0
	for o in col.get("offsets", [[0.0, 0.0, 0.0]]):
		var p := origin + rot * (Vector3(o[0], 0.0, o[2]) * sc)
		_uprights.append({
			"x": p.x, "z": p.z, "r": float(col["radius"]) * sc,
			"y0": origin.y, "y1": origin.y + float(col["height"]) * sc,
			"gate": null, "side": 0, "mm": mm, "idx": idx, "xf": mm.get_instance_transform(idx),
			"angle": 0.0, "vel": 0.0, "axis": rot.x, "touch": -10,
		})
		n += 1
	return n


## Fabric gates over the road at the checkpoints. Closed stages: every checkpoint except the one
## under the start/finish arch. Open roads (liaisons, untimed): only the final checkpoint, the
## time control. `arches` are the world positions of start/finish arch instances. `clear` removes
## the gates built before; false adds another route's gates to them.
func build_gates(checkpoints: Array[Dictionary], track: Track, closed: bool, arches: PackedVector3Array,
		clear := true) -> void:
	if clear:
		for g in _gates:
			g.queue_free()
		_gates.clear()
		_uprights = _uprights.filter(func(u: Dictionary) -> bool: return u["gate"] == null)
	for n in checkpoints.size():
		var cp: Dictionary = checkpoints[n]
		if not closed and n != checkpoints.size() - 1:
			continue
		var pos: Vector3 = cp["position"]
		var near_arch := false
		for a in arches:
			if Vector2(a.x - pos.x, a.z - pos.z).length() < 20.0:
				near_arch = true
		if near_arch:
			continue
		var i := track.nearest(pos)
		var lat := track.half_width(i) + track.verge + 1.5 + FabricGate.UPRIGHT_RADIUS
		lat = maxf(lat, float(cp["half_width"]) + 0.6 + FabricGate.UPRIGHT_RADIUS)
		var gate := FabricGate.new()
		gate.name = "FabricGate_%d" % int(cp["index"])
		add_child(gate)
		gate.setup(Transform3D(Basis(Vector3.UP, float(cp["yaw"])), pos), lat, _gates.size())
		_gates.append(gate)
		for side in [-1, 1]:
			var p := gate.upright_base(side)
			_uprights.append({
				"x": p.x, "z": p.z, "r": FabricGate.UPRIGHT_RADIUS + 0.05,
				"y0": p.y - 0.5, "y1": p.y + FabricGate.UPRIGHT_HEIGHT,
				"gate": gate, "side": side, "mm": null, "idx": -1, "xf": Transform3D(),
				"angle": 0.0, "vel": 0.0, "axis": Vector3.RIGHT, "touch": -10,
			})
	_gate_side.resize(4 * maxi(_gates.size(), 1))
	_gate_side.fill(0.0)
	_settle_in = 2


## Places the gate feet on the ground once the colliders are in the physics space.
func settle_gates(map: MapWorld) -> void:
	_settle_in = 0
	for g in _gates:
		for side in [-1, 1]:
			var p := g.upright_base(side)
			g.set_foot_height(side, map.ground_height(p.x, p.z, p.y + 30.0))
	for u in _uprights:
		var g: FabricGate = u["gate"]
		if g != null:
			var p := g.upright_base(u["side"])
			u["y0"] = p.y - 0.5
			u["y1"] = p.y + FabricGate.UPRIGHT_HEIGHT


func gate_count() -> int:
	return _gates.size()


## The fabric gate standing within 2 m of `pos` (a checkpoint position), or null.
func gate_near(pos: Vector3) -> FabricGate:
	for g in _gates:
		if Vector2(g.global_position.x - pos.x, g.global_position.z - pos.z).length() < 2.0:
			return g
	return null


func smashable_count() -> int:
	return _kind.size()


func broken_count() -> int:
	return _broken_list.size()


func upright_count() -> int:
	return _uprights.size()


func live_debris() -> int:
	return _debris_live


## World centre of prop `id` (probe and tools).
func prop_centre(id: int) -> Vector3:
	return Vector3(_cx[id], _y0[id], _cz[id])


func prop_kind(id: int) -> String:
	return _kinds[_kind[id]]


func is_broken(id: int) -> bool:
	return _broken[id] != 0


## Ids of the unbroken smashables within `radius` of `pos` (probe and tools).
func props_near(pos: Vector3, radius: float) -> PackedInt32Array:
	var out := PackedInt32Array()
	for id in _kind.size():
		if _broken[id] == 0 and Vector2(_cx[id] - pos.x, _cz[id] - pos.z).length() < radius:
			out.append(id)
	return out


# ================================================================ cars

func _scan_for_cars(n: Node) -> void:
	if n is Car:
		_add_car(n)
	for c in n.get_children():
		_scan_for_cars(c)


func _on_node_added(n: Node) -> void:
	if n is Car:
		# the car's children (hull shape) are in by the time it is ready
		(n as Car).ready.connect(_add_car.bind(n), CONNECT_ONE_SHOT)


func _add_car(car: Car) -> void:
	if car in _cars or not car.is_inside_tree():
		return
	var box := AABB()
	var first := true
	for c in car.get_children():
		var cs := c as CollisionShape3D
		if cs == null or cs.shape == null or cs.disabled:
			continue
		var b := cs.transform * cs.shape.get_debug_mesh().get_aabb()
		box = b if first else box.merge(b)
		first = false
	if first:
		box = AABB(Vector3(-0.85, 0.2, -2.1), Vector3(1.7, 1.2, 4.2))
	_cars.append(car)
	_car_half.append(box.size * 0.5)
	_car_centre.append(box.get_center())
	_car_last.append(car.global_position)
	_car_recent.append(0.0)
	car.tree_exiting.connect(_remove_car.bind(car), CONNECT_ONE_SHOT)
	# a new car is a new run: the course is whole again
	restore()


func _remove_car(car: Car) -> void:
	var i := _cars.find(car)
	if i < 0:
		return
	_cars.remove_at(i)
	_car_half.remove_at(i)
	_car_centre.remove_at(i)
	_car_last.remove_at(i)
	_car_recent.remove_at(i)


# ================================================================ per tick

func _physics_process(delta: float) -> void:
	_tick += 1
	if _settle_in > 0:
		_settle_in -= 1
		if _settle_in == 0 and get_parent() is MapWorld:
			settle_gates(get_parent())
	for ci in _cars.size():
		var car := _cars[ci]
		if not is_instance_valid(car):
			continue
		var pos := car.global_position
		var speed := car.linear_velocity.length()
		# reset_to() teleports the car: a jump no physics step could make
		if pos.distance_to(_car_last[ci]) > 1.5 + speed * delta * 2.0:
			restore()
		_car_last[ci] = pos
		if _car_recent[ci] > 0.0:
			_car_recent[ci] *= exp(-delta / LOSS_MEMORY)
		_scan_car(ci, car)
		_check_gates(ci, car)
	if _debris_live > 0:
		_age_debris(delta)
	if _arch_wobbling > 0:
		_step_arches(delta)
	if _burst_ticks > 0:
		_burst_ticks -= 1
		if is_instance_valid(_burst_car):
			_dust_material.set_shader_parameter("focus", _burst_car.global_position + Vector3.UP * 0.6)


func _scan_car(ci: int, car: Car) -> void:
	var xf := car.global_transform
	var half := _car_half[ci]
	var c := xf * _car_centre[ci]
	var ax := Vector2(xf.basis.x.x, xf.basis.x.z)
	var az := Vector2(xf.basis.z.x, xf.basis.z.z)
	if ax.length_squared() < 1e-4 or az.length_squared() < 1e-4:
		return # on its side: the roof never smashes tape
	ax = ax.normalized()
	az = az.normalized()
	var reach := maxf(half.x, half.z) * 1.42 + PROP_REACH
	var cx0 := floori((c.x - reach) / CELL)
	var cx1 := floori((c.x + reach) / CELL)
	var cz0 := floori((c.z - reach) / CELL)
	var cz1 := floori((c.z + reach) / CELL)
	var cy0 := c.y - half.y
	var cy1 := c.y + half.y
	for gx in range(cx0, cx1 + 1):
		for gz in range(cz0, cz1 + 1):
			var list: PackedInt32Array = _cells.get(Vector2i(gx, gz), PackedInt32Array())
			for id in list:
				if _broken[id] != 0 or _y0[id] > cy1 or _y1[id] < cy0:
					continue
				if _overlaps(id, c.x, c.z, ax, az, half.x, half.z):
					_smash(id, car, ci)
	for u in _uprights:
		if u["y0"] > cy1 or u["y1"] < cy0:
			continue
		var dx: float = u["x"] - c.x
		var dz: float = u["z"] - c.z
		var lx := clampf(dx * ax.x + dz * ax.y, -half.x, half.x)
		var lz := clampf(dx * az.x + dz * az.y, -half.z, half.z)
		var qx := dx - ax.x * lx - az.x * lz
		var qz := dz - ax.y * lx - az.y * lz
		var r: float = u["r"]
		if qx * qx + qz * qz < r * r:
			if int(u["touch"]) < _tick - 1:
				_hit_upright(u, car, ci)
			u["touch"] = _tick
	crowd.scan_car(ci, car, c, ax, az, half, cy0, cy1)


## Car box (centre, axes ax / az with half extents hx / hz, all in world xz) against prop id.
func _overlaps(id: int, x: float, z: float, ax: Vector2, az: Vector2, hx: float, hz: float) -> bool:
	var dx := _cx[id] - x
	var dz := _cz[id] - z
	var phz := _hz[id]
	if phz < 0.0:
		var lx := clampf(dx * ax.x + dz * ax.y, -hx, hx)
		var lz := clampf(dx * az.x + dz * az.y, -hz, hz)
		var qx := dx - ax.x * lx - az.x * lz
		var qz := dz - ax.y * lx - az.y * lz
		return qx * qx + qz * qz < _hx[id] * _hx[id]
	# separating axes: the two car axes and the two prop axes
	var ux := _ux[id]
	var uz := _uz[id]
	var phx := _hx[id]
	# prop axes: u = (ux, uz), v = (-uz, ux)
	var au := absf(ax.x * ux + ax.y * uz)
	var av := absf(-ax.x * uz + ax.y * ux)
	var bu := absf(az.x * ux + az.y * uz)
	var bv := absf(-az.x * uz + az.y * ux)
	if absf(dx * ax.x + dz * ax.y) > hx + phx * au + phz * av:
		return false
	if absf(dx * az.x + dz * az.y) > hz + phx * bu + phz * bv:
		return false
	if absf(dx * ux + dz * uz) > phx + hx * au + hz * bu:
		return false
	if absf(-dx * uz + dz * ux) > phz + hx * av + hz * bv:
		return false
	return true


## Knocks `loss` of the car's horizontal speed off with a central impulse (no torque, no lift);
## returns the share taken after the recent-hits budget (Crowd uses it too).
func slow_car(car: Car, ci: int, loss: float) -> float:
	loss *= clampf(1.0 - _car_recent[ci] / LOSS_BUDGET, LOSS_FLOOR, 1.0)
	_car_recent[ci] += loss
	var v := car.linear_velocity
	car.apply_central_impulse(-Vector3(v.x, 0.0, v.z) * car.mass * loss)
	return loss


func _smash(id: int, car: Car, ci: int) -> void:
	var data: Dictionary = _kind_data[_kind[id]]
	var v := car.linear_velocity
	var hv := Vector3(v.x, 0.0, v.z)
	var speed := hv.length()
	var loss := slow_car(car, ci, float(data["loss"]))
	_broken[id] = 1
	_broken_list.append(id)
	hits += 1
	var xf := _xf[id]
	var fling := float(data["fling"])
	if _mm_ref[id] < 0:
		_nodes[_mm_idx[id]].visible = false
		for piece: Mesh in _node_debris[_mm_idx[id]]:
			_spawn_debris(piece, xf, v, car.global_position, fling)
	else:
		_mms[_mm_ref[id]].set_instance_transform(_mm_idx[id], Transform3D(Basis().scaled(Vector3.ZERO), xf.origin))
		_spawn_debris(_kind_mesh[_kind[id]], xf, v, car.global_position, fling)
	var point := Vector3(_cx[id], clampf(car.global_position.y + 0.5, _y0[id], _y1[id]), _cz[id])
	burst(point, car, data["chip"], speed)
	var sound := get_node_or_null(^"/root/Sound")
	if sound != null:
		var db: float = float(data["db"]) + linear_to_db(clampf(speed / 22.0, 0.2, 1.0))
		sound.play_3d(data["sfx"], point, db)
	smashed.emit(_kinds[_kind[id]], point, speed, loss)


func _hit_upright(u: Dictionary, car: Car, ci: int) -> void:
	var v := car.linear_velocity
	var hv := Vector3(v.x, 0.0, v.z)
	var speed := hv.length()
	var loss := slow_car(car, ci, UPRIGHT_LOSS)
	hits += 1
	var point := Vector3(u["x"], car.global_position.y + 0.6, u["z"])
	var push := clampf(speed / 20.0, 0.25, 1.0)
	var gate: FabricGate = u["gate"]
	if gate != null:
		gate.wobble(u["side"], hv, push)
	else:
		# the arch nods about its own across-road axis, away from the car
		var axis: Vector3 = u["axis"]
		var dir := signf(hv.dot(axis.cross(Vector3.UP))) if speed > 0.1 else 1.0
		u["vel"] = float(u["vel"]) - dir * push * 0.35
		_arch_wobbling = 1
	var sound := get_node_or_null(^"/root/Sound")
	if sound != null:
		sound.play_3d(&"thump", point, -8.0 + linear_to_db(push))
	upright_hit.emit(point, speed, loss)


## Car crossing a gate plane between its uprights: the banner billows.
func _check_gates(ci: int, car: Car) -> void:
	if ci >= 4:
		return
	var p := car.global_position
	for gi in _gates.size():
		var g := _gates[gi]
		var d := p - g.global_position
		if d.length_squared() > 900.0:
			_gate_side[gi * 4 + ci] = 0.0
			continue
		var s := d.dot(g.global_basis.z)
		var last := _gate_side[gi * 4 + ci]
		_gate_side[gi * 4 + ci] = s
		if last != 0.0 and signf(last) != signf(s) and absf(d.dot(g.global_basis.x)) < g.half_span:
			g.billow(car.linear_velocity, 0.6)


func _on_checkpoint_passed(index: int, _total: int, _split: float, _delta: float) -> void:
	var map := get_parent() as MapWorld
	if map == null or index < 0 or index >= map.checkpoints.size():
		return
	var g := gate_near(map.checkpoints[index]["position"])
	var game := get_node_or_null(^"/root/Game")
	if g != null and game != null and game.get(&"player_car") is Car:
		g.billow((game.player_car as Car).linear_velocity, 1.0)


func _step_arches(delta: float) -> void:
	var moving := 0
	for u in _uprights:
		if u["gate"] != null:
			continue
		var a: float = u["angle"]
		var w: float = u["vel"]
		if absf(a) < 1e-4 and absf(w) < 1e-4:
			continue
		# a stiff, well-damped inflatable: ~1.4 Hz, settles in about two seconds
		w += (-80.0 * a - 4.0 * w) * delta
		a += w * delta
		u["angle"] = a
		u["vel"] = w
		var mm: MultiMesh = u["mm"]
		var xf: Transform3D = u["xf"]
		mm.set_instance_transform(u["idx"], Transform3D(Basis(u["axis"], a) * xf.basis, xf.origin))
		moving += 1
	_arch_wobbling = moving


# ================================================================ debris

## Every node and resource a smash uses is made here, while the map builds under the loading
## cover: nothing is created or loaded at hit time.
func _build_pools() -> void:
	_debris_age.resize(DEBRIS_MAX)
	_debris_life.resize(DEBRIS_MAX)
	_debris_scale.resize(DEBRIS_MAX)
	for i in DEBRIS_MAX:
		var b := RigidBody3D.new()
		b.name = "Debris_%d" % i
		b.collision_layer = LAYER_DEBRIS
		b.collision_mask = MapWorld.LAYER_WORLD
		b.mass = 25.0
		b.physics_material_override = _debris_material
		b.linear_damp = 0.25
		b.angular_damp = 0.9
		b.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
		b.disable_mode = CollisionObject3D.DISABLE_MODE_REMOVE
		var mi := MeshInstance3D.new()
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		b.add_child(mi)
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		cs.shape = box
		b.add_child(cs)
		b.visible = false
		b.process_mode = Node.PROCESS_MODE_DISABLED
		add_child(b)
		_debris.append(b)
		_debris_mesh.append(mi)
		_debris_shape.append(box)
		_debris_age[i] = -1.0
	_dust_material = ShaderMaterial.new()
	_dust_material.shader = DUST_SHADER
	var puff := _puff_mesh()
	puff.surface_set_material(0, _dust_material)
	var chip := _chip_mesh()
	chip.surface_set_material(0, _dust_material)
	for i in BURSTS:
		_puffs.append(_make_burst(puff, 10, 1.6, false))
		_chips.append(_make_burst(chip, 16, 1.1, true))


func _spawn_debris(mesh: Mesh, xf: Transform3D, car_v: Vector3, car_pos: Vector3, fling: float) -> void:
	var slot := -1
	var oldest := -1.0
	for i in DEBRIS_MAX:
		if _debris_age[i] < 0.0:
			slot = i
			break
		if _debris_age[i] > oldest:
			oldest = _debris_age[i]
			slot = i
	var b := _debris[slot]
	var was_live := _debris_age[slot] >= 0.0
	var sc := xf.basis.get_scale()
	var box := mesh.get_aabb()
	var mi := _debris_mesh[slot]
	mi.mesh = mesh
	mi.scale = sc
	_debris_scale[slot] = sc
	_debris_shape[slot].size = (box.size * sc).max(Vector3(0.12, 0.12, 0.12))
	var cs := b.get_child(1) as CollisionShape3D
	cs.position = box.get_center() * sc
	b.center_of_mass = box.get_center() * sc
	b.mass = clampf(box.size.x * box.size.y * box.size.z * sc.x * sc.y * sc.z * 60.0, 4.0, 180.0)
	b.global_transform = Transform3D(xf.basis.orthonormalized(), xf.origin + Vector3.UP * 0.05)
	var away := Vector3(xf.origin.x - car_pos.x, 0.0, xf.origin.z - car_pos.z)
	away = away.normalized() if away.length_squared() > 1e-4 else Vector3.ZERO
	var hv := Vector3(car_v.x, 0.0, car_v.z)
	var up := _rng.randf_range(2.0, 4.0) * clampf(0.4 + hv.length() / 25.0, 0.4, 1.3)
	var v := hv * fling * _rng.randf_range(0.85, 1.1) + away * _rng.randf_range(1.0, 3.0) + Vector3.UP * up
	b.linear_velocity = v
	# topple forward along the travel direction plus some random tumble
	var topple := Vector3.UP.cross(hv.normalized()) if hv.length_squared() > 0.25 else Vector3.RIGHT
	b.angular_velocity = topple * _rng.randf_range(3.0, 7.0) * fling \
			+ Vector3(_rng.randf_range(-2.0, 2.0), _rng.randf_range(-4.0, 4.0), _rng.randf_range(-2.0, 2.0))
	b.visible = true
	b.process_mode = Node.PROCESS_MODE_INHERIT
	b.sleeping = false
	b.reset_physics_interpolation()
	_debris_age[slot] = 0.0
	_debris_life[slot] = _rng.randf_range(DEBRIS_LIFE_MIN, DEBRIS_LIFE_MAX)
	if not was_live:
		_debris_live += 1


func _age_debris(delta: float) -> void:
	for i in DEBRIS_MAX:
		var age := _debris_age[i]
		if age < 0.0:
			continue
		age += delta
		var life := _debris_life[i]
		if age >= life:
			_retire(i)
			continue
		_debris_age[i] = age
		var left := life - age
		if left < DEBRIS_SHRINK:
			_debris_mesh[i].scale = _debris_scale[i] * (left / DEBRIS_SHRINK)


func _retire(i: int) -> void:
	_debris_age[i] = -1.0
	var b := _debris[i]
	b.visible = false
	b.linear_velocity = Vector3.ZERO
	b.angular_velocity = Vector3.ZERO
	b.process_mode = Node.PROCESS_MODE_DISABLED
	_debris_live -= 1


## One low-poly dust puff and a spray of chips in the prop's colour, thrown along `car`'s
## travel; the dust keeps the line of sight to the car clear for a while.
func burst(point: Vector3, car: Car, chip_color: Color, speed: float) -> void:
	var i := _burst_next
	_burst_next = (_burst_next + 1) % BURSTS
	var car_v := car.linear_velocity
	var dir := Vector3(car_v.x, 0.0, car_v.z)
	dir = (dir.normalized() + Vector3.UP * 0.8).normalized() if dir.length_squared() > 0.25 else Vector3.UP
	_burst_car = car
	_burst_ticks = 240
	var puff := _puffs[i]
	puff.global_position = point
	puff.amount_ratio = clampf(0.4 + speed / 30.0, 0.4, 1.0)
	puff.visible = true
	puff.restart()
	var chips := _chips[i]
	chips.global_position = point
	var m := _chip_mats[i]
	m.color = chip_color
	m.direction = dir
	m.initial_velocity_min = 2.0 + speed * 0.15
	m.initial_velocity_max = 4.0 + speed * 0.3
	chips.visible = true
	chips.restart()


# ================================================================ pipeline warm-up

func is_warm() -> bool:
	return _warmed


## Right after the map is built (the loading cover is still up) every smashable mesh is drawn
## once as a plain MeshInstance3D, from the debris pool, and every burst emitter fires once, a
## few metres in front of the active camera: the renderer builds their pipelines behind the
## cover instead of on the first smash.
func _process(_delta: float) -> void:
	if _warmed:
		set_process(false)
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null or not cam.is_inside_tree():
		return
	if _warm_hold > 0:
		_warm_hold -= 1
		if _warm_hold == 0:
			_end_warm_batch()
		return
	if _warm_next < 0:
		_warm_next = 0
		_warm_bursts(cam)
	elif _warm_next >= _kinds.size():
		_warmed = true
		return
	_start_warm_batch(cam)
	_warm_hold = WARM_FRAMES


func _warm_spot(cam: Camera3D, k: int) -> Transform3D:
	var local := Vector3(float(k % 6) * 0.25 - 0.6, float(k / 6) * 0.2 - 0.3, -3.0)
	return Transform3D(Basis(), cam.global_transform * local)


func _warm_bursts(cam: Camera3D) -> void:
	var map := get_parent() as MapWorld
	if map != null:
		_dust_material.set_shader_parameter("sun_dir", map.sun_dir)
	for i in BURSTS:
		for p: GPUParticles3D in [_puffs[i], _chips[i]]:
			p.global_position = _warm_spot(cam, i).origin
			p.amount_ratio = 0.1
			p.visible = true
			p.restart()


func _start_warm_batch(cam: Camera3D) -> void:
	var n := mini(DEBRIS_MAX, _kinds.size() - _warm_next)
	for j in n:
		var slot := j
		if _debris_age[slot] >= 0.0:
			continue
		var mi := _debris_mesh[slot]
		mi.mesh = _kind_mesh[_warm_next + j]
		mi.scale = Vector3.ONE * 0.02
		_debris[slot].global_transform = _warm_spot(cam, j)
		_debris[slot].reset_physics_interpolation()
		_debris[slot].visible = true
	_warm_next += n


func _end_warm_batch() -> void:
	for i in DEBRIS_MAX:
		if _debris_age[i] < 0.0:
			_debris[i].visible = false
	for i in BURSTS:
		_puffs[i].visible = false
		_chips[i].visible = false


func _make_burst(mesh: Mesh, amount: int, life: float, chips: bool) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = amount
	p.lifetime = life
	p.one_shot = true
	p.explosiveness = 1.0
	p.emitting = false
	p.local_coords = false
	p.visibility_aabb = AABB(Vector3(-12, -4, -12), Vector3(24, 14, 24))
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.visible = false
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	m.angle_min = 0.0
	m.angle_max = 360.0
	if chips:
		m.emission_sphere_radius = 0.3
		m.direction = Vector3.UP
		m.spread = 40.0
		m.initial_velocity_min = 3.0
		m.initial_velocity_max = 7.0
		m.gravity = Vector3(0, -9.8, 0)
		m.angular_velocity_min = -720.0
		m.angular_velocity_max = 720.0
		m.scale_min = 0.08
		m.scale_max = 0.16
		_chip_mats.append(m)
	else:
		m.emission_sphere_radius = 0.5
		m.direction = Vector3.UP
		m.spread = 70.0
		m.initial_velocity_min = 0.6
		m.initial_velocity_max = 2.0
		m.gravity = Vector3(0, 0.25, 0)
		m.particle_flag_damping_as_friction = true
		m.damping_min = 3.0
		m.damping_max = 5.0
		m.angular_velocity_min = -30.0
		m.angular_velocity_max = 30.0
		m.scale_min = 0.45
		m.scale_max = 0.85
		m.color = Color("e6d7bb")
		var sc := Curve.new()
		sc.add_point(Vector2(0.0, 0.5))
		sc.add_point(Vector2(0.12, 1.0))
		sc.add_point(Vector2(0.55, 0.8))
		sc.add_point(Vector2(1.0, 0.0))
		var sct := CurveTexture.new()
		sct.curve = sc
		m.scale_curve = sct
	p.process_material = m
	p.draw_pass_1 = mesh
	add_child(p)
	return p


## Same cumulus as the wheel dust (CarFX): overlapping flat-shaded icosahedra.
func _puff_mesh() -> ArrayMesh:
	var t := (1.0 + sqrt(5.0)) * 0.5
	var v := [
		Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0),
		Vector3(0, -1, t), Vector3(0, 1, t), Vector3(0, -1, -t), Vector3(0, 1, -t),
		Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1),
	]
	var f := [
		[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11], [1, 5, 9], [5, 11, 4], [11, 10, 2],
		[10, 7, 6], [7, 1, 8], [3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9], [4, 9, 5],
		[2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1],
	]
	var blobs := [[Vector3.ZERO, 0.5, 0.0], [Vector3(0.36, 0.12, 0.1), 0.32, 0.9], [Vector3(-0.3, 0.1, -0.18), 0.3, 2.1]]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)
	for b in blobs:
		var rot := Basis(Vector3.UP, b[2])
		for tri in f:
			for k in [0, 2, 1]:
				var p: Vector3 = rot * (v[tri[k]].normalized() * b[1])
				p.y *= 0.8
				st.add_vertex(p + b[0])
	st.generate_normals()
	return st.commit()


func _chip_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)
	var a := Vector3(0, 0.5, 0)
	var b := Vector3(-0.45, -0.3, 0.3)
	var c := Vector3(0.45, -0.3, 0.3)
	var d := Vector3(0, -0.3, -0.5)
	for tri in [[a, c, b], [a, d, c], [a, b, d], [b, c, d]]:
		for p in tri:
			st.add_vertex(p)
	st.generate_normals()
	return st.commit()


# ================================================================ restore

## Every prop back in place, debris gone, gates and arches at rest.
func restore() -> void:
	for id in _broken_list:
		_broken[id] = 0
		if _mm_ref[id] < 0:
			_nodes[_mm_idx[id]].visible = true
		else:
			_mms[_mm_ref[id]].set_instance_transform(_mm_idx[id], _xf[id])
	_broken_list.clear()
	for i in _debris.size():
		if _debris_age[i] >= 0.0:
			_retire(i)
	for u in _uprights:
		u["angle"] = 0.0
		u["vel"] = 0.0
		u["touch"] = -10
		if u["gate"] == null and u["mm"] != null:
			(u["mm"] as MultiMesh).set_instance_transform(u["idx"], u["xf"])
	_arch_wobbling = 0
	for g in _gates:
		g.rest()
	_gate_side.fill(0.0)
	hits = 0
	_car_recent.fill(0.0)
	crowd.restore()
