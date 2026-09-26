class_name FabricGate
extends Node3D
## A checkpoint gate in fabric, the Forza way: two inflatable uprights outside the drivable
## width and a cloth banner across the road, high above the car. The banner waves in the wind
## (vertex shader, shaders/world/fabric_banner.gdshader), billows when a car passes under it,
## and its ends follow the uprights when a car knocks one: the upright leans away and springs
## back. SoftCourse owns the hit tests; this node only animates.
##
## Local frame: origin on the road centre line at the checkpoint, +X across the road, +Z along
## it (Basis(UP, checkpoint yaw)).

const UPRIGHT_RADIUS := 0.35
## Upright height above the road (m); the tube stretches down to wherever its foot stands.
const UPRIGHT_HEIGHT := 5.9
const BANNER_TOP := 5.55
const BANNER_HEIGHT := 1.15
const BANNER_COLUMNS := 36
const BANNER_ROWS := 6
const BANNER_SHADER := preload("res://shaders/world/fabric_banner.gdshader")
const PINK := Color("e68aa8")
const CREAM := Color("f5f2ea")
const BASE_COLOR := Color("505669")

## Distance from the centre line to each upright's axis.
var half_span: float = 6.75
var index: int = 0

var _pivots: Array[Node3D] = []
var _feet: Array[Node3D] = []
var _foot_y := PackedFloat32Array([0.0, 0.0])
var _tilt := PackedVector2Array([Vector2.ZERO, Vector2.ZERO]) ## top lean per upright (rad, local x / z)
var _tilt_vel := PackedVector2Array([Vector2.ZERO, Vector2.ZERO])
var _banner: MeshInstance3D
var _billow: float = 0.0
var _billow_age: float = 100.0
var _billow_dir: float = 1.0

static var _upright_mesh: ArrayMesh
static var _base_mesh: ArrayMesh
static var _banner_material: ShaderMaterial


func setup(xf: Transform3D, new_half_span: float, gate_index: int) -> void:
	half_span = new_half_span
	index = gate_index
	transform = xf
	if _upright_mesh == null:
		_upright_mesh = _make_upright()
		_base_mesh = _make_base()
	for side in [-1, 1]:
		var pivot := Node3D.new()
		pivot.name = "Upright_%s" % ("L" if side < 0 else "R")
		pivot.position = Vector3(side * half_span, 0.0, 0.0)
		add_child(pivot)
		var tube := MeshInstance3D.new()
		tube.mesh = _upright_mesh
		tube.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		tube.visibility_range_end = 520.0
		pivot.add_child(tube)
		var foot := MeshInstance3D.new()
		foot.name = "Foot"
		foot.mesh = _base_mesh
		foot.visibility_range_end = 260.0
		foot.position = pivot.position
		add_child(foot)
		_pivots.append(pivot)
		_feet.append(foot)
	_banner = MeshInstance3D.new()
	_banner.name = "Banner"
	var inner := half_span - UPRIGHT_RADIUS * 0.6
	_banner.mesh = _make_banner(inner * 2.0)
	_banner.material_override = _material()
	_banner.position = Vector3(0.0, BANNER_TOP - BANNER_HEIGHT, 0.0)
	_banner.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_banner.visibility_range_end = 520.0
	# the wave reaches ~0.6 m out of the banner plane when billowing
	_banner.extra_cull_margin = 1.5
	_banner.set_instance_shader_parameter(&"span_m", inner * 2.0)
	_banner.set_instance_shader_parameter(&"phase", float(gate_index) * 1.7)
	add_child(_banner)
	_set_feet()
	_push_banner()
	set_process(false)


## World position of an upright's foot (side -1 left, +1 right).
func upright_base(side: int) -> Vector3:
	return to_global(Vector3(side * half_span, _foot_y[0 if side < 0 else 1], 0.0))


## Stands the upright on the ground at world height y; the tube still reaches the banner.
func set_foot_height(side: int, world_y: float) -> void:
	var local_y := world_y - global_position.y
	_foot_y[0 if side < 0 else 1] = clampf(local_y, -3.0, 1.5)
	_set_feet()


func _set_feet() -> void:
	for k in 2:
		var pivot := _pivots[k]
		pivot.position.y = _foot_y[k]
		pivot.scale = Vector3(1.0, (UPRIGHT_HEIGHT - _foot_y[k]) / UPRIGHT_HEIGHT, 1.0)
		_feet[k].position.y = _foot_y[k]
	_apply_tilt()


## A car knocked upright `side` while moving with world velocity `vel`; push 0..1.
func wobble(side: int, vel: Vector3, push: float) -> void:
	var k := 0 if side < 0 else 1
	var local := global_basis.inverse() * vel
	var d := Vector2(local.x, local.z)
	d = d.normalized() if d.length_squared() > 0.01 else Vector2(0.0, 1.0)
	# across the road the banner holds the top in: mostly a lean along the road
	d.x *= 0.35
	_tilt_vel[k] += d * push * 1.9
	set_process(true)


## A car passed under the banner with world velocity `vel`; strength 0..1.
func billow(vel: Vector3, strength: float) -> void:
	var along := vel.dot(global_basis.z)
	var s := strength * clampf(absf(along) / 25.0, 0.45, 1.2)
	var env := _billow * exp(-1.3 * _billow_age)
	_billow = maxf(env, s)
	_billow_age = 0.0
	_billow_dir = 1.0 if along >= 0.0 else -1.0
	set_process(true)


func is_billowing() -> bool:
	return _billow * exp(-1.3 * _billow_age) > 0.02


## Uprights upright, banner calm.
func rest() -> void:
	for k in 2:
		_tilt[k] = Vector2.ZERO
		_tilt_vel[k] = Vector2.ZERO
	_billow = 0.0
	_billow_age = 100.0
	_apply_tilt()
	_push_banner()
	set_process(false)


func _process(delta: float) -> void:
	var moving := false
	for k in 2:
		var t := _tilt[k]
		var w := _tilt_vel[k]
		# inflatable tube: ~1.1 Hz, damped so it settles in a couple of seconds
		w += (-48.0 * t - 3.2 * w) * delta
		t += w * delta
		t = t.limit_length(0.32)
		_tilt[k] = t
		_tilt_vel[k] = w
		if t.length_squared() > 1e-6 or w.length_squared() > 1e-6:
			moving = true
	_billow_age += delta
	if is_billowing():
		moving = true
	_apply_tilt()
	_push_banner()
	if not moving:
		rest()


func _apply_tilt() -> void:
	for k in 2:
		var t := _tilt[k]
		var a := t.length()
		var pivot := _pivots[k]
		var sy := pivot.scale.y
		if a < 1e-5:
			pivot.basis = Basis.from_scale(Vector3(1.0, sy, 1.0))
		else:
			var d := t / a
			pivot.basis = Basis(Vector3(d.y, 0.0, -d.x), a) * Basis.from_scale(Vector3(1.0, sy, 1.0))


func _push_banner() -> void:
	if _banner == null:
		return
	# the banner ends ride with the upright tops (local offsets at banner height)
	var h := BANNER_TOP - BANNER_HEIGHT * 0.5
	var l := Vector2.ZERO
	var r := Vector2.ZERO
	for k in 2:
		var off := Vector2(sin(_tilt[k].x), sin(_tilt[k].y)) * (h - _foot_y[k])
		if k == 0:
			l = off
		else:
			r = off
	_banner.set_instance_shader_parameter(&"lean", Vector4(l.x, l.y, r.x, r.y))
	_banner.set_instance_shader_parameter(&"billow", _billow)
	_banner.set_instance_shader_parameter(&"billow_age", _billow_age)
	_banner.set_instance_shader_parameter(&"billow_dir", _billow_dir)


# ---------------------------------------------------------------- meshes

static func _material() -> ShaderMaterial:
	if _banner_material == null:
		_banner_material = ShaderMaterial.new()
		_banner_material.shader = BANNER_SHADER
		var ramp: Array = ToonMaterials.RAMPS["soft"]
		_banner_material.set_shader_parameter("ramp_edges", ramp[0])
		_banner_material.set_shader_parameter("ramp_values", ramp[1])
		_banner_material.set_shader_parameter("banner_height", BANNER_HEIGHT)
	return _banner_material


## Flat-shaded grid, u across (0..1), v up (0 bottom .. 1 top), in the local XY plane.
static func _make_banner(width: float) -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	var idx := PackedInt32Array()
	for j in BANNER_ROWS + 1:
		for i in BANNER_COLUMNS + 1:
			var u := float(i) / BANNER_COLUMNS
			var v := float(j) / BANNER_ROWS
			verts.append(Vector3((u - 0.5) * width, v * BANNER_HEIGHT, 0.0))
			uvs.append(Vector2(u, v))
			normals.append(Vector3.BACK)
	var row := BANNER_COLUMNS + 1
	for j in BANNER_ROWS:
		for i in BANNER_COLUMNS:
			var a := j * row + i
			idx.append_array([a, a + 1, a + row, a + 1, a + row + 1, a + row])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = normals
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh


## Inflatable tube: five puffed segments in blossom pink and cream, a domed cap.
static func _make_upright() -> ArrayMesh:
	const SIDES := 12
	const SEGMENTS := 5
	const RINGS := 4 # per segment
	var seg_h := (UPRIGHT_HEIGHT - 0.25) / SEGMENTS
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)
	var profile: Array[Vector3] = [] # (radius, y, colour index)
	for s in SEGMENTS:
		for r in RINGS:
			var f := float(r) / RINGS
			profile.append(Vector3(UPRIGHT_RADIUS * (0.84 + 0.16 * sin(PI * f)), s * seg_h + f * seg_h, s % 2))
	profile.append(Vector3(UPRIGHT_RADIUS * 0.84, SEGMENTS * seg_h, (SEGMENTS - 1) % 2))
	for p in range(profile.size() - 1):
		var a := profile[p]
		var b := profile[p + 1]
		var col := PINK if int(a.z) == 0 else CREAM
		for k in SIDES:
			var t0 := TAU * k / SIDES
			var t1 := TAU * (k + 1) / SIDES
			var a0 := Vector3(cos(t0) * a.x, a.y, sin(t0) * a.x)
			var a1 := Vector3(cos(t1) * a.x, a.y, sin(t1) * a.x)
			var b0 := Vector3(cos(t0) * b.x, b.y, sin(t0) * b.x)
			var b1 := Vector3(cos(t1) * b.x, b.y, sin(t1) * b.x)
			for q in [a0, b0, a1, a1, b0, b1]:
				st.set_color(col)
				st.add_vertex(q)
	# dome
	var top := SEGMENTS * seg_h
	var apex := Vector3(0.0, UPRIGHT_HEIGHT, 0.0)
	var rim := UPRIGHT_RADIUS * 0.84
	var mid_r := rim * 0.75
	var mid_y := top + 0.16
	for k in SIDES:
		var t0 := TAU * k / SIDES
		var t1 := TAU * (k + 1) / SIDES
		var a0 := Vector3(cos(t0) * rim, top, sin(t0) * rim)
		var a1 := Vector3(cos(t1) * rim, top, sin(t1) * rim)
		var m0 := Vector3(cos(t0) * mid_r, mid_y, sin(t0) * mid_r)
		var m1 := Vector3(cos(t1) * mid_r, mid_y, sin(t1) * mid_r)
		for q in [a0, m0, a1, a1, m0, m1, m0, apex, m1]:
			st.set_color(PINK)
			st.add_vertex(q)
	st.generate_normals()
	var mesh := st.commit()
	mesh.surface_set_material(0, ToonMaterials.make(Color.WHITE, {
		"vertex_color": true, "ramp": "soft", "grain": 0.05, "rim": 0.25,
		"sway": 0.3, "sway_start": 1.0, "sway_end": 6.0,
	}))
	return mesh


## Water-ballast foot the tube stands in.
static func _make_base() -> ArrayMesh:
	var cyl := CylinderMesh.new()
	cyl.top_radius = UPRIGHT_RADIUS + 0.12
	cyl.bottom_radius = UPRIGHT_RADIUS + 0.22
	cyl.height = 0.32
	cyl.radial_segments = 10
	cyl.rings = 1
	var arr := cyl.get_mesh_arrays()
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	for i in verts.size():
		verts[i].y += 0.1
	arr[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	mesh.surface_set_material(0, ToonMaterials.make(BASE_COLOR, {"ramp": "cel", "grain": 0.08}))
	return mesh
