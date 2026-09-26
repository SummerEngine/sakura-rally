class_name CarFX
extends Node3D
## Wheel effects for one car: low-poly dust puffs coloured by the surface, gravel
## chips thrown by the driven wheels, tyre marks, brake lights, backfire flashes
## and landing bursts. Lives in world space (a sibling of the car, not a child),
## reads Car.wheels every physics tick.

const DUST_SHADER := preload("res://shaders/dust.gdshader")
const SKID_SHADER := preload("res://shaders/skid.gdshader")

## Dust colour and how readily each surface throws dust. Paler than the ground it comes
## from, so airborne dust reads as cloud and not as rocks lying on the road.
const SURFACE_DUST := {
	&"gravel": [Color("e6d9c0"), 1.0],
	&"dirt": [Color("dcc4a0"), 1.1],
	&"sand": [Color("f5eed9"), 1.2],
	&"grass": [Color("d2dcb2"), 0.22],
	&"tarmac": [Color("e9e4ee"), 0.0], # smoke only when sliding
}
const SKID_SEGMENTS := 2400
const SKID_STEP := 0.45

var car: Car
var sun_dir: Vector3 = Vector3(0.45, 0.7, 0.3)
var quality: String = "high"

var _dust: Array[GPUParticles3D] = []
var _dust_mats: Array[ParticleProcessMaterial] = []
var _chips: Array[GPUParticles3D] = []
var _dust_material: ShaderMaterial
var _skid_mm: MultiMesh
var _skid_next: int = 0
var _skid_last: Array = [null, null, null, null] # last mark point per wheel or null
var _burst: float = 0.0
var _tail: Array = []
var _head: Array = []
var _flash: MeshInstance3D
var _flash_t: float = 0.0


func setup(new_car: Car, lights: Dictionary, new_sun_dir: Vector3) -> void:
	car = new_car
	sun_dir = new_sun_dir
	_tail = lights.get("tail", [])
	_head = lights.get("head", [])
	top_level = true
	global_transform = Transform3D.IDENTITY
	_dust_material = ShaderMaterial.new()
	_dust_material.shader = DUST_SHADER
	_dust_material.set_shader_parameter("sun_dir", sun_dir)
	for i in 4:
		_dust.append(_make_dust())
	for i in 2:
		_chips.append(_make_chips())
	_build_skids()
	_build_flash()
	car.landed.connect(_on_landed)
	car.backfire.connect(_on_backfire)


func set_quality(q: String) -> void:
	quality = q
	var n := 96 if q == "high" else (64 if q == "medium" else 36)
	for p in _dust:
		p.amount = n


func clear_marks() -> void:
	for k in SKID_SEGMENTS:
		_skid_mm.set_instance_color(k, Color(0, 0, 0, 0))
	_skid_last = [null, null, null, null]


# ------------------------------------------------------------------ build

## Five overlapping flat-shaded icosahedra: a cumulus silhouette instead of a hexagon.
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
	# [centre, radius, rotation about Y] per blob
	var blobs := [
		[Vector3(0.0, 0.0, 0.0), 0.5, 0.0],
		[Vector3(0.38, 0.14, 0.1), 0.34, 0.9],
		[Vector3(-0.3, 0.1, -0.2), 0.3, 2.1],
		[Vector3(0.08, 0.34, 0.04), 0.3, 1.3],
		[Vector3(-0.1, -0.04, 0.36), 0.26, 0.4],
	]
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


func _make_dust() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = 96
	p.lifetime = 2.4
	p.local_coords = false
	p.emitting = false
	p.amount_ratio = 0.0
	p.fixed_fps = 0
	p.interpolate = true
	p.visibility_aabb = AABB(Vector3(-30, -10, -30), Vector3(60, 30, 60))
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	m.emission_sphere_radius = 0.3
	# Thrown up, out and back from the contact patch (direction and speed are set per
	# tick). Quadratic drag stops the spray within a few tenths of a second, then the
	# slight lift lets each puff billow upwards at ~0.7 m/s (lift outweighs drag only
	# once the puff is slow; with linear damping it would never rise).
	m.direction = Vector3.UP
	m.spread = 30.0
	m.initial_velocity_min = 1.0
	m.initial_velocity_max = 3.0
	m.gravity = Vector3(0, 0.22, 0)
	m.particle_flag_damping_as_friction = true
	m.damping_min = 6.0
	m.damping_max = 9.0
	m.inherit_velocity_ratio = 0.5
	m.angle_min = 0.0
	m.angle_max = 360.0
	m.angular_velocity_min = -30.0
	m.angular_velocity_max = 30.0
	# Big from birth: at speed a puff is in the chase camera's view for only ~0.3 s.
	m.scale_min = 0.8
	m.scale_max = 1.6
	var sc := Curve.new()
	sc.add_point(Vector2(0.0, 0.55))
	sc.add_point(Vector2(0.08, 1.0))
	sc.add_point(Vector2(0.5, 0.85))
	sc.add_point(Vector2(1.0, 0.0))
	var sct := CurveTexture.new()
	sct.curve = sc
	m.scale_curve = sct
	m.color = Color("d7c3a0")
	# a little brightness variation per puff
	var g := Gradient.new()
	g.set_color(0, Color(0.92, 0.92, 0.92))
	g.set_color(g.get_point_count() - 1, Color(1.06, 1.06, 1.06))
	var gt := GradientTexture1D.new()
	gt.gradient = g
	m.color_initial_ramp = gt
	p.process_material = m
	var mesh := _puff_mesh()
	mesh.surface_set_material(0, _dust_material)
	p.draw_pass_1 = mesh
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(p)
	_dust_mats.append(m)
	return p


func _make_chips() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = 40
	p.lifetime = 0.7
	p.local_coords = false
	p.emitting = false
	p.amount_ratio = 0.0
	p.visibility_aabb = AABB(Vector3(-20, -10, -20), Vector3(40, 20, 40))
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	m.emission_sphere_radius = 0.15
	m.direction = Vector3(0, 0.6, 1)
	m.spread = 25.0
	m.initial_velocity_min = 3.0
	m.initial_velocity_max = 7.0
	m.gravity = Vector3(0, -9.8, 0)
	m.inherit_velocity_ratio = 0.6
	m.angular_velocity_min = -720.0
	m.angular_velocity_max = 720.0
	m.scale_min = 0.05
	m.scale_max = 0.11
	m.color = Color("8d7a64")
	p.process_material = m
	var mesh := _chip_mesh()
	mesh.surface_set_material(0, _dust_material)
	p.draw_pass_1 = mesh
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(p)
	return p


func _build_skids() -> void:
	var quad := PlaneMesh.new()
	quad.size = Vector2(1.0, 1.0)
	var mat := ShaderMaterial.new()
	mat.shader = SKID_SHADER
	mat.render_priority = -1
	quad.material = mat
	_skid_mm = MultiMesh.new()
	_skid_mm.transform_format = MultiMesh.TRANSFORM_3D
	_skid_mm.use_colors = true
	_skid_mm.mesh = quad
	_skid_mm.instance_count = SKID_SEGMENTS
	for k in SKID_SEGMENTS:
		_skid_mm.set_instance_transform(k, Transform3D(Basis.from_scale(Vector3.ZERO), Vector3.ZERO))
		_skid_mm.set_instance_color(k, Color(0, 0, 0, 0))
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "SkidMarks"
	mmi.multimesh = _skid_mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.custom_aabb = AABB(Vector3(-2000, -500, -2000), Vector3(4000, 1500, 4000))
	add_child(mmi)


func _build_flash() -> void:
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.13
	cone.height = 0.55
	cone.radial_segments = 6
	cone.rings = 1
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color("ffe08a")
	m.emission_enabled = true
	m.emission = Color("ff9a3c")
	m.emission_energy_multiplier = 2.0
	cone.material = m
	_flash = MeshInstance3D.new()
	_flash.mesh = cone
	_flash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_flash.visible = false
	car.add_child(_flash)
	# exhaust at the right rear, pointing backwards (+Z)
	_flash.position = Vector3(0.48, 0.3, 2.28)
	_flash.rotation = Vector3(deg_to_rad(90.0), 0.0, 0.0)


# ------------------------------------------------------------------ runtime

func _on_landed(strength: float) -> void:
	_burst = maxf(_burst, clampf(strength, 0.3, 1.0))


func _on_backfire() -> void:
	_flash_t = 0.09
	_flash.visible = true
	_flash.scale = Vector3.ONE * randf_range(0.8, 1.25)


## Keeps the dust shader's line of sight to the car current (render rate, interpolated).
func _process(_delta: float) -> void:
	if car != null and is_instance_valid(car):
		_dust_material.set_shader_parameter("focus", car.get_global_transform_interpolated().origin + Vector3.UP * 0.6)


func _physics_process(delta: float) -> void:
	if car == null or not is_instance_valid(car):
		return
	var vel := car.linear_velocity
	var speed := vel.length()
	_burst = maxf(0.0, _burst - delta * 3.0)
	for i in 4:
		var w: WheelState = car.wheels[i]
		var p := _dust[i]
		if not w.contact:
			p.amount_ratio = 0.0
			p.emitting = false
			_skid_last[i] = null
			continue
		var info: Array = SURFACE_DUST.get(w.surface, SURFACE_DUST[&"gravel"])
		var col: Color = info[0]
		var dusty: float = info[1]
		var sp := smoothstep(2.0, 24.0, speed)
		var slip := clampf(w.slip, 0.0, 2.0)
		var amount := dusty * sp * (0.3 + 0.7 * clampf(slip, 0.0, 1.3))
		if w.surface == &"tarmac":
			amount = clampf((slip - 0.85) * 1.4, 0.0, 1.0) * smoothstep(3.0, 12.0, w.slide_speed + speed * 0.3)
		if w.is_front:
			amount *= 0.55 # the rear wheels kick most of it up
		amount = maxf(amount, _burst * (0.5 if w.surface != &"tarmac" else 0.15))
		amount = clampf(amount, 0.0, 1.0)
		p.amount_ratio = amount
		p.emitting = amount > 0.03
		# out to the wheel's own side, back, and towards where the contact patch slides
		# (the tyre shoves the gravel the way the patch moves over it)
		var xf := car.global_transform
		var side := -xf.basis.x if w.is_left else xf.basis.x
		var fling := side * 0.5 + xf.basis.x * clampf(w.slip_lat * 3.0, -1.0, 1.0) * sp
		var dm := _dust_mats[i]
		dm.direction = (fling + xf.basis.z * 0.4 + Vector3.UP * 0.8).normalized()
		dm.initial_velocity_min = 0.8 + 2.4 * sp
		dm.initial_velocity_max = 1.6 + 4.4 * sp
		dm.color = col
		var back := -vel.normalized() * 0.35 if speed > 1.0 else Vector3.ZERO
		p.global_position = w.contact_point + w.contact_normal * 0.12 + back
		if not w.is_front:
			var c := _chips[i - 2]
			var loose := w.surface == &"gravel" or w.surface == &"dirt"
			var spin := clampf(absf(w.slip_long) * 2.0 + slip * 0.4, 0.0, 1.0) * sp
			c.amount_ratio = spin if loose else 0.0
			c.emitting = loose and spin > 0.08
			c.global_position = w.contact_point + w.contact_normal * 0.1
			var pm := c.process_material as ParticleProcessMaterial
			var backward := car.global_transform.basis.z
			pm.direction = (backward + Vector3.UP * 0.5).normalized()
		_update_skid(i, w, speed)
	# brake lights and exhaust flash
	var b := clampf(car.brake + car.handbrake * 0.5, 0.0, 1.0)
	for m: ShaderMaterial in _tail:
		m.set_shader_parameter("emission_energy", 0.35 + 2.2 * b)
	if _flash_t > 0.0:
		_flash_t -= delta
		if _flash_t <= 0.0:
			_flash.visible = false


func _update_skid(i: int, w: WheelState, speed: float) -> void:
	var loose := w.surface == &"gravel" or w.surface == &"dirt" or w.surface == &"sand"
	var strength := 0.0
	var tint := Color(0.12, 0.11, 0.16)
	if w.surface == &"tarmac":
		strength = clampf((w.slip - 0.7) * 1.2, 0.0, 0.62)
	elif loose:
		strength = 0.16 + clampf(w.slip - 0.4, 0.0, 1.0) * 0.3
		tint = Color(0.36, 0.28, 0.21)
	elif w.surface == &"grass":
		strength = clampf((w.slip - 0.5) * 0.5, 0.0, 0.3)
		tint = Color(0.3, 0.36, 0.2)
	if strength <= 0.01 or speed < 1.5:
		_skid_last[i] = null
		return
	var pt := w.contact_point + w.contact_normal * 0.03
	if _skid_last[i] == null:
		_skid_last[i] = pt
		return
	var last: Vector3 = _skid_last[i]
	var d := pt - last
	var len := d.length()
	if len < SKID_STEP:
		return
	if len > 3.0:
		_skid_last[i] = pt
		return
	var fwd := d / len
	var n := w.contact_normal
	var right := fwd.cross(n).normalized()
	var basis := Basis(right * 0.24, n, fwd * (len + 0.04))
	_skid_mm.set_instance_transform(_skid_next, Transform3D(basis, (pt + last) * 0.5))
	_skid_mm.set_instance_color(_skid_next, Color(tint.r, tint.g, tint.b, strength))
	_skid_next = (_skid_next + 1) % SKID_SEGMENTS
	_skid_last[i] = pt
