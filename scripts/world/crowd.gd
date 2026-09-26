class_name Crowd
extends Node3D
## Knockable spectators. MapWorld registers every instance of a PEOPLE prop here instead of
## giving it a collider; SoftCourse hands each car's box over every physics tick and a car that
## touches a person knocks them over: the MultiMesh instance hides and a pooled "flyer" with
## the same mesh and colours takes off in a comic tumble (the car's velocity, spin, bounces),
## lies on its back for about two seconds, gets up with a hop, hurries back to its spot and
## turns to face the road again, and the crowd instance comes back. The car loses LOSS of its
## speed (through SoftCourse's shared loss budget). No gore: people fly, bounce, get up.
##
## Looks: the people models (tools/blender/props/people.py) carry two materials, Crowd_Base
## (vertex coloured) and Crowd_Dye, which MapWorld makes with `material_opts()`: the dye is
## tinted per instance from PALETTE (MultiMesh custom data rgb) and every person gets a phase
## (custom data alpha) for the idle / cheer motion in shaders/inc/crowd.gdshaderinc. People
## near the player car cheer harder (`crowd_focus`).
##
## Everything a knock uses (a few flyers per people model, each with its own MultiMesh and
## mesh, the ray query, the sounds) is made or loaded while the map builds under the loading
## cover, and every flyer is drawn once right after the build (like SoftCourse's warm-up): a
## knock only moves and shows nodes. The crowd comes back
## whole on SoftCourse.restore() (a new car, a reset, a restart) and with a new MapWorld.

## The knockable props, mirrored in tools/mapgen/lib/corridor.py (KNOCKABLE); keep in step.
const PEOPLE := [
	"spectator_a", "spectator_b", "spectator_c", "spectator_d", "spectator_e", "spectator_f",
	"spectator_g", "spectator_h", "spectator_i", "spectator_j", "spectator_k", "spectator_l",
]
const DYE_MATERIAL := "Crowd_Dye"
## Garment dyes: sakura pink, vermilion, tangerine, mustard, leaf, teal, sky, cobalt, navy,
## lavender, plum, cream, charcoal.
const PALETTE := [
	Color("f08fb0"), Color("e0483c"), Color("f28a2e"), Color("f0c23e"), Color("6fb35a"),
	Color("3aa6a0"), Color("7fb8e6"), Color("3f6fc4"), Color("34406b"), Color("a68ad6"),
	Color("8e4a78"), Color("f2e6c8"), Color("45414d"),
]
## Speed share a knock costs the car (before SoftCourse's LOSS_BUDGET).
const LOSS := 0.015
const CELL := 8.0
## Largest person radius (m): hash queries widen by this much.
const REACH := 0.5
## Flyers per people model: each has its own one-instance MultiMesh with that model's mesh,
## set while the map builds (swapping a MultiMesh's mesh later reads its buffer back from the
## GPU: a 12-18 ms stall).
const FLYERS_PER_KIND := 3
const GRAVITY := 16.0 ## a little more than g: snappier, more cartoon arcs
const BOUNCE := 0.38
const LIE_MIN := 1.7
const LIE_MAX := 2.3
const GETUP_TIME := 0.5
const HOP := 0.4
const WALK_SPEED := 2.2
const TURN_TIME := 0.3
const BODY_LYING := 0.16 ## height of the body axis above the ground when lying (m)
## Frames the warm-up keeps the flyers drawn (the renderer builds pipelines on the first draw).
const WARM_FRAMES := 3
const SFX_BONK := [
	preload("res://assets/audio/crowd/bonk_1.wav"), preload("res://assets/audio/crowd/bonk_2.wav"),
	preload("res://assets/audio/crowd/bonk_3.wav"),
]
const SFX_OOF := [
	preload("res://assets/audio/crowd/oof_1.wav"), preload("res://assets/audio/crowd/oof_2.wav"),
	preload("res://assets/audio/crowd/oof_3.wav"), preload("res://assets/audio/crowd/oof_4.wav"),
]
const SFX_OOH := [
	preload("res://assets/audio/crowd/ooh_1.wav"), preload("res://assets/audio/crowd/ooh_2.wav"),
	preload("res://assets/audio/crowd/ooh_3.wav"),
]
const SFX_HOP := preload("res://assets/audio/crowd/hop.wav")
## Seconds between two crowd reactions.
const OOH_GAP := 1.6

enum { FLY, LIE, GETUP, WALK, TURN }

signal knocked(prop: String, point: Vector3, speed_before: float, loss: float)

# ---------------------------------------------------------------- people (struct of arrays)
var _kind: PackedInt32Array
var _mm_ref: PackedInt32Array
var _mm_idx: PackedInt32Array
var _cx: PackedFloat32Array
var _cz: PackedFloat32Array
var _y0: PackedFloat32Array
var _y1: PackedFloat32Array
var _r: PackedFloat32Array
var _down: PackedByteArray
var _xf: Array[Transform3D] = []
var _custom: PackedColorArray
var _kinds: Array[String] = []
var _kind_mesh: Array[Mesh] = []
var _kind_half: PackedFloat32Array ## half the mesh height (m, unscaled): the body axis centre
var _mms: Array[MultiMesh] = []
var _cells: Dictionary = {} ## Vector2i -> PackedInt32Array of person ids
var _down_list: PackedInt32Array
var _materials: Array[ShaderMaterial] = []

# ---------------------------------------------------------------- flyers
var _fly: Array[MultiMeshInstance3D] = []
var _kind_flyers: Array[PackedInt32Array] = [] ## flyer indices of each kind
var _fly_mm: Array[MultiMesh] = []
var _fly_person: PackedInt32Array ## person id, -1 when free
var _fly_state: PackedInt32Array
var _fly_t: PackedFloat32Array ## seconds in the state
var _fly_span: PackedFloat32Array ## length of the state (lie, walk)
var _fly_com: PackedVector3Array ## body axis centre (flight) or feet (walk)
var _fly_vel: PackedVector3Array
var _fly_spin: PackedVector3Array
var _fly_rot: Array[Quaternion] = []
var _fly_from: Array[Quaternion] = [] ## orientation at the start of a blend
var _fly_to: Array[Quaternion] = []
var _fly_bounces: PackedInt32Array
var _fly_age: PackedInt32Array ## knock order: the oldest flyer of a kind is reused when all are out
var _live: int = 0
var _knock_n: int = 0

var soft: SoftCourse
var _ray: PhysicsRayQueryParameters3D
var _rng := RandomNumberGenerator.new()
var _focus_car: Car
var _ooh_ready_at: float = 0.0
var _tick: int = 0
## Knocks since the last restore.
var knocks: int = 0
## Warm-up: frames the flyers stay drawn.
var _warm_hold: int = 0
var _warmed: bool = false


func _init() -> void:
	name = "Crowd"
	_rng.seed = 20260927


func _ready() -> void:
	soft = get_parent() as SoftCourse
	_ray = PhysicsRayQueryParameters3D.create(Vector3.ZERO, Vector3.DOWN, MapWorld.LAYER_WORLD)
	set_process(false)
	var map := _map()
	if map != null:
		map.built.connect(set_process.bind(true), CONNECT_ONE_SHOT)


func _map() -> MapWorld:
	return (soft.get_parent() if soft != null else get_parent()) as MapWorld


# ================================================================ registration (MapWorld)

static func is_person(prop_name: String) -> bool:
	return PEOPLE.has(prop_name)


## ToonMaterials options for a people material: the motion for all, the per-instance dye for
## the dyed garment.
static func material_opts(mat_name: String) -> Dictionary:
	if mat_name == DYE_MATERIAL:
		return {"crowd": 1.0, "instance_tint": true}
	return {"crowd": 1.0}


## One spectator instance: `mm` (made with use_custom_data) and `idx` locate it, `e` is the
## map.json row [x, y, z, yaw, scale], `m` the manifest entry. Picks its dye and phase.
func add_person(prop_name: String, mesh: Mesh, mm: MultiMesh, idx: int, e: Array, m: Dictionary) -> void:
	var k := _kinds.find(prop_name)
	if k < 0:
		k = _kinds.size()
		_kinds.append(prop_name)
		_kind_mesh.append(mesh)
		_kind_half.append(maxf(mesh.get_aabb().size.y * 0.5, 0.3))
		for s in mesh.get_surface_count():
			var mat := mesh.surface_get_material(s) as ShaderMaterial
			if mat != null and not _materials.has(mat):
				_materials.append(mat)
		_add_flyers(k, mesh)
	var mi := _mms.find(mm)
	if mi < 0:
		mi = _mms.size()
		_mms.append(mm)
	var sc: float = e[4]
	var col: Dictionary = m.get("collision", {})
	var r := clampf(float(col.get("radius", 0.3)) * sc, 0.15, REACH)
	var h := float(col.get("height", 1.7)) * sc
	# the dye and phase follow the position: the same person looks the same every load
	var hsh := hash(Vector2i(roundi(float(e[0]) * 10.0), roundi(float(e[2]) * 10.0)))
	var dye: Color = PALETTE[hsh % PALETTE.size()]
	var custom := Color(dye.srgb_to_linear(), float((hsh >> 8) & 1023) / 1024.0)
	mm.set_instance_custom_data(idx, custom)
	var id := _kind.size()
	_kind.append(k)
	_mm_ref.append(mi)
	_mm_idx.append(idx)
	_cx.append(e[0])
	_cz.append(e[2])
	_y0.append(float(e[1]) - 0.2)
	_y1.append(float(e[1]) + h)
	_r.append(r)
	_down.append(0)
	_xf.append(mm.get_instance_transform(idx))
	_custom.append(custom)
	var cell := Vector2i(floori(float(e[0]) / CELL), floori(float(e[2]) / CELL))
	var list: PackedInt32Array = _cells.get(cell, PackedInt32Array())
	list.append(id)
	_cells[cell] = list


func person_count() -> int:
	return _kind.size()


func down_count() -> int:
	return _down_list.size()


func live_flyers() -> int:
	return _live


func is_warm() -> bool:
	return _warmed


## World position of person `id` and whether it is knocked over (tools).
func person_position(id: int) -> Vector3:
	return _xf[id].origin


func is_down(id: int) -> bool:
	return _down[id] != 0


# ================================================================ cars (from SoftCourse)

## Car `car` (its box: centre `c`, unit axes `ax` / `az` in world xz with half extents
## `half`, height range cy0..cy1) against the people near it.
func scan_car(ci: int, car: Car, c: Vector3, ax: Vector2, az: Vector2, half: Vector3, cy0: float, cy1: float) -> void:
	if ci == 0:
		_focus_car = car
	var reach := maxf(half.x, half.z) * 1.42 + REACH
	for gx in range(floori((c.x - reach) / CELL), floori((c.x + reach) / CELL) + 1):
		for gz in range(floori((c.z - reach) / CELL), floori((c.z + reach) / CELL) + 1):
			var list: PackedInt32Array = _cells.get(Vector2i(gx, gz), PackedInt32Array())
			for id in list:
				if _down[id] != 0 or _y0[id] > cy1 or _y1[id] < cy0:
					continue
				var dx := _cx[id] - c.x
				var dz := _cz[id] - c.z
				var lx := clampf(dx * ax.x + dz * ax.y, -half.x, half.x)
				var lz := clampf(dx * az.x + dz * az.y, -half.z, half.z)
				var qx := dx - ax.x * lx - az.x * lz
				var qz := dz - ax.y * lx - az.y * lz
				if qx * qx + qz * qz < _r[id] * _r[id]:
					_knock(id, car, ci)


func _knock(id: int, car: Car, ci: int) -> void:
	var v := car.linear_velocity
	var hv := Vector3(v.x, 0.0, v.z)
	var speed := hv.length()
	var loss := soft.slow_car(car, ci, LOSS)
	_down[id] = 1
	_down_list.append(id)
	knocks += 1
	var xf := _xf[id]
	_mms[_mm_ref[id]].set_instance_transform(_mm_idx[id], Transform3D(Basis().scaled(Vector3.ZERO), xf.origin))
	var k := _kind[id]
	var slot := _free_flyer(k)
	var sc := xf.basis.get_scale().y
	_fly_mm[slot].set_instance_custom_data(0, _custom[id])
	_fly_person[slot] = id
	_fly_state[slot] = FLY
	_fly_t[slot] = 0.0
	_fly_bounces[slot] = 0
	_knock_n += 1
	_fly_age[slot] = _knock_n
	var rot := xf.basis.orthonormalized().get_rotation_quaternion()
	_fly_rot[slot] = rot
	_fly_com[slot] = xf.origin + Vector3.UP * _kind_half[k] * sc
	# off with the car, a bit to the side it was hit on, up in an arc; tumbling head over heels
	var away := Vector3(_cx[id] - car.global_position.x, 0.0, _cz[id] - car.global_position.z)
	away = away.normalized() if away.length_squared() > 1e-4 else Vector3.ZERO
	var push := clampf(speed / 18.0, 0.35, 1.6)
	_fly_vel[slot] = hv * _rng.randf_range(0.7, 0.9) + away * _rng.randf_range(1.0, 2.5) \
			+ Vector3.UP * _rng.randf_range(4.0, 5.5) * sqrt(push)
	var dir := hv.normalized() if speed > 0.5 else away
	var topple := Vector3.UP.cross(dir).normalized() if dir.length_squared() > 0.1 else Vector3.RIGHT
	_fly_spin[slot] = topple * _rng.randf_range(7.0, 11.0) * clampf(push, 0.6, 1.2) \
			+ Vector3.UP * _rng.randf_range(-6.0, 6.0)
	var node := _fly[slot]
	node.visible = true
	_place(slot)
	node.reset_physics_interpolation()
	var point := Vector3(_cx[id], xf.origin.y + 1.0 * sc, _cz[id])
	if soft != null:
		soft.burst(point, car, Color("f8c0d1"), speed * 0.6)
	var sound := get_node_or_null(^"/root/Sound")
	if sound != null:
		var loud := linear_to_db(clampf(speed / 20.0, 0.3, 1.0))
		sound.play_3d(StringName(SFX_BONK[_rng.randi() % SFX_BONK.size()].resource_path), point, -3.0 + loud)
		sound.play_3d(StringName(SFX_OOF[_rng.randi() % SFX_OOF.size()].resource_path), point, -4.0)
		var now := Time.get_ticks_msec() / 1000.0
		if now >= _ooh_ready_at:
			_ooh_ready_at = now + OOH_GAP
			sound.play_3d(StringName(SFX_OOH[_rng.randi() % SFX_OOH.size()].resource_path), point + Vector3.UP * 2.0, -5.0)
	knocked.emit(_kinds[k], point, speed, loss)


func _free_flyer(k: int) -> int:
	var pool := _kind_flyers[k]
	var oldest := pool[0]
	for i in pool:
		if _fly_person[i] < 0:
			_live += 1
			return i
		if _fly_age[i] < _fly_age[oldest]:
			oldest = i
	# every flyer of the kind is out: the oldest one's person is back in the crowd at once
	_return(oldest)
	_live += 1
	return oldest


# ================================================================ per tick

func _physics_process(delta: float) -> void:
	_tick += 1
	if _live == 0:
		return
	for i in _fly.size():
		if _fly_person[i] >= 0:
			_step(i, delta)


func _step(i: int, dt: float) -> void:
	var id := _fly_person[i]
	var k := _kind[id]
	var sc := _xf[id].basis.get_scale().y
	var half := _kind_half[k] * sc
	_fly_t[i] += dt
	match _fly_state[i]:
		FLY:
			var vel := _fly_vel[i]
			vel.y -= GRAVITY * dt
			var com := _fly_com[i] + vel * dt
			var w := _fly_spin[i]
			if w.length_squared() > 1e-6:
				_fly_rot[i] = (Quaternion(w.normalized(), w.length() * dt) * _fly_rot[i]).normalized()
			# the body axis's lowest end touches down: upright it is `half` above the ground,
			# lying flat BODY_LYING
			var axis := Basis(_fly_rot[i]).y
			var reach := lerpf(BODY_LYING, half, absf(axis.y))
			var ground := _ground(com.x, com.z, com.y + 2.0)
			if com.y - reach <= ground and vel.y < 0.0:
				com.y = ground + reach
				_fly_bounces[i] += 1
				vel.y = -vel.y * BOUNCE
				vel.x *= 0.55
				vel.z *= 0.55
				_fly_spin[i] = w * 0.5
				if vel.y < 1.6 or _fly_bounces[i] >= 3:
					_lie_down(i, ground)
					return
			_fly_vel[i] = vel
			_fly_com[i] = com
		LIE:
			# settle onto the back over the first 0.25 s, then lie still
			var t := minf(_fly_t[i] / 0.25, 1.0)
			_fly_rot[i] = _fly_from[i].slerp(_fly_to[i], t * t * (3.0 - 2.0 * t))
			if _fly_t[i] >= _fly_span[i]:
				_fly_state[i] = GETUP
				_fly_t[i] = 0.0
				_fly_from[i] = _fly_rot[i]
				var yaw := _yaw_towards(_fly_com[i], _xf[id].origin)
				_fly_to[i] = Quaternion(Vector3.UP, yaw)
				var sound := get_node_or_null(^"/root/Sound")
				if sound != null:
					sound.play_3d(StringName(SFX_HOP.resource_path), _fly_com[i], -9.0)
		GETUP:
			var t := minf(_fly_t[i] / GETUP_TIME, 1.0)
			var e := t * t * (3.0 - 2.0 * t)
			_fly_rot[i] = _fly_from[i].slerp(_fly_to[i], e)
			var com := _fly_com[i]
			var ground := _ground(com.x, com.z, com.y + 2.0)
			# the body centre rises from lying to standing, with a hop at the end
			com.y = ground + lerpf(BODY_LYING, half, e) + sin(PI * t) * HOP
			_fly_com[i] = com
			if t >= 1.0:
				var home := _xf[id].origin
				var d := Vector2(home.x - com.x, home.z - com.z).length()
				_fly_state[i] = WALK
				_fly_t[i] = 0.0
				_fly_span[i] = d / WALK_SPEED
		WALK:
			var home := _xf[id].origin
			var com := _fly_com[i]
			var to := Vector2(home.x - com.x, home.z - com.z)
			var d := to.length()
			var step := WALK_SPEED * dt
			if d <= step:
				com.x = home.x
				com.z = home.z
				_fly_state[i] = TURN
				_fly_t[i] = 0.0
				_fly_from[i] = _fly_rot[i]
				_fly_to[i] = _xf[id].basis.orthonormalized().get_rotation_quaternion()
			else:
				com.x += to.x / d * step
				com.z += to.y / d * step
				var yaw := atan2(-to.x, -to.y)
				# a hurried waddle: side to side at each step, a little bounce
				var ph := _fly_t[i] * TAU * 2.6
				_fly_rot[i] = Quaternion(Vector3.UP, yaw) * Quaternion(Vector3.BACK, sin(ph) * 0.14)
			var ground := _ground(com.x, com.z, com.y + 2.0)
			com.y = ground + half + absf(sin(_fly_t[i] * TAU * 2.6)) * 0.06
			_fly_com[i] = com
		TURN:
			var t := minf(_fly_t[i] / TURN_TIME, 1.0)
			_fly_rot[i] = _fly_from[i].slerp(_fly_to[i], t)
			if t >= 1.0:
				_return(i)
				return
	_place(i)


## Lying on the back where the flight ended, feet towards where it came from.
func _lie_down(i: int, ground: float) -> void:
	_fly_state[i] = LIE
	_fly_t[i] = 0.0
	_fly_span[i] = _rng.randf_range(LIE_MIN, LIE_MAX)
	var axis := Basis(_fly_rot[i]).y
	var along := Vector3(axis.x, 0.0, axis.z)
	if along.length_squared() < 1e-3:
		along = Vector3(_fly_vel[i].x, 0.0, _fly_vel[i].z)
	if along.length_squared() < 1e-3:
		along = Vector3.FORWARD
	along = along.normalized()
	# body axis (+y) along the ground, the face (-z) up at the sky
	var z := Vector3.DOWN
	var x := along.cross(z).normalized()
	_fly_from[i] = _fly_rot[i]
	_fly_to[i] = Basis(x, along, z).orthonormalized().get_rotation_quaternion()
	var com := _fly_com[i]
	com.y = ground + BODY_LYING
	_fly_com[i] = com
	_fly_vel[i] = Vector3.ZERO
	_fly_spin[i] = Vector3.ZERO


func _yaw_towards(from: Vector3, to: Vector3) -> float:
	var d := Vector2(to.x - from.x, to.z - from.z)
	if d.length_squared() < 0.01:
		return 0.0
	return atan2(-d.x, -d.y)


## Flyer node transform from its state: the body axis centre (flight, lying, getting up) or
## the feet (walking and turning) and the orientation, at the person's scale.
func _place(i: int) -> void:
	var id := _fly_person[i]
	var sc := _xf[id].basis.get_scale().y
	var b := Basis(_fly_rot[i])
	var feet := _fly_com[i] - b.y * _kind_half[_kind[id]] * sc
	_fly[i].transform = Transform3D(b.scaled(Vector3(sc, sc, sc)), feet)


## The person is back in the crowd; the flyer is free.
func _return(i: int) -> void:
	var id := _fly_person[i]
	if id < 0:
		return
	_down[id] = 0
	var at := _down_list.find(id)
	if at >= 0:
		_down_list.remove_at(at)
	_mms[_mm_ref[id]].set_instance_transform(_mm_idx[id], _xf[id])
	_fly_person[i] = -1
	_fly[i].visible = false
	_live -= 1


func _ground(x: float, z: float, from_y: float) -> float:
	_ray.from = Vector3(x, from_y, z)
	_ray.to = Vector3(x, from_y - 60.0, z)
	var hit := get_world_3d().direct_space_state.intersect_ray(_ray)
	return hit["position"].y if hit else from_y - 2.0


# ================================================================ restore

## Everyone back on their feet in their spot, no flyer out.
func restore() -> void:
	for i in _fly.size():
		if _fly_person[i] >= 0:
			_return(i)
	for id in _down_list:
		_down[id] = 0
		_mms[_mm_ref[id]].set_instance_transform(_mm_idx[id], _xf[id])
	_down_list.clear()
	knocks = 0


# ================================================================ pools and warm-up

## FLYERS_PER_KIND hidden flyers for kind `k`, with its mesh (while the map builds).
func _add_flyers(k: int, mesh: Mesh) -> void:
	var pool := PackedInt32Array()
	for j in FLYERS_PER_KIND:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = mesh
		mm.instance_count = 1
		mm.set_instance_transform(0, Transform3D())
		var node := MultiMeshInstance3D.new()
		node.name = "Flyer_%s_%d" % [_kinds[k], j]
		node.multimesh = mm
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		node.visible = false
		add_child(node)
		pool.append(_fly.size())
		_fly.append(node)
		_fly_mm.append(mm)
		_fly_person.append(-1)
		_fly_state.append(FLY)
		_fly_t.append(0.0)
		_fly_span.append(0.0)
		_fly_com.append(Vector3.ZERO)
		_fly_vel.append(Vector3.ZERO)
		_fly_spin.append(Vector3.ZERO)
		_fly_bounces.append(0)
		_fly_age.append(0)
		_fly_rot.append(Quaternion.IDENTITY)
		_fly_from.append(Quaternion.IDENTITY)
		_fly_to.append(Quaternion.IDENTITY)
	_kind_flyers.append(pool)


## Crowd focus (the player car) on the people materials every frame; right after the map is
## built (the loading cover is still up) every flyer is drawn once, tiny, a few metres in front
## of the camera, so the first knock builds no pipeline and uploads no buffer.
func _process(_delta: float) -> void:
	_update_focus()
	if _warmed:
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null or not cam.is_inside_tree():
		return
	if _warm_hold > 0:
		_warm_hold -= 1
		if _warm_hold == 0:
			for i in _fly.size():
				if _fly_person[i] < 0:
					_fly[i].visible = false
			_warmed = true
		return
	for i in _fly.size():
		if _fly_person[i] >= 0:
			continue
		_fly_mm[i].set_instance_custom_data(0, Color(1, 1, 1, 0))
		var local := Vector3(float(i % 8) * 0.12 - 0.42, float(i / 8) * 0.12 - 0.2, -3.0)
		_fly[i].transform = Transform3D(Basis().scaled(Vector3.ONE * 0.02), cam.global_transform * local)
		_fly[i].reset_physics_interpolation()
		_fly[i].visible = true
	_warm_hold = WARM_FRAMES


func _update_focus() -> void:
	var car: Node3D = null
	var game := get_node_or_null(^"/root/Game")
	if game != null and game.get(&"player_car") is Car and is_instance_valid(game.player_car):
		car = game.player_car
	elif is_instance_valid(_focus_car):
		car = _focus_car
	var focus := Vector4(0.0, -100000.0, 0.0, 45.0)
	if car != null and car.is_inside_tree():
		var p := car.global_position
		focus = Vector4(p.x, p.y, p.z, 45.0)
	for m in _materials:
		m.set_shader_parameter(&"crowd_focus", focus)
