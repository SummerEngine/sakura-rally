extends StaticBody3D
## Physics proving ground (scenes/test/physics_test.tscn), built from code:
## flat ground (grass) with surface patches, tarmac/gravel runways, five skidpads, three handling
## plazas (tarmac, gravel, dirt), a 15° slope,
## kicker ramps, a bumpy lane, a banked turn, a wall and a closed ~1.5 km loop (Path3D "Loop",
## first half tarmac, second half gravel) for the autopilot.
## Implements the track provider API used by the car: surface_at(point) and nearest_reset_transform(pos).

const ROAD_HALF_WIDTH := 5.0
const LOOP_POINTS: Array[Vector2] = [
	Vector2(0, 170), Vector2(0, -60), Vector2(10, -140), Vector2(65, -190), Vector2(150, -200),
	Vector2(215, -160), Vector2(230, -95), Vector2(190, -40), Vector2(160, 15), Vector2(180, 65),
	Vector2(250, 90), Vector2(290, 150), Vector2(275, 215), Vector2(230, 240), Vector2(185, 225),
	Vector2(175, 185), Vector2(150, 140), Vector2(100, 160), Vector2(75, 225), Vector2(30, 240),
]
const COLORS := {
	&"tarmac": Color("505669"), &"gravel": Color("c2a27a"), &"dirt": Color("9a7552"),
	&"grass": Color("8dc266"), &"sand": Color("e6d3a3"),
}
const PLAZAS: Array[StringName] = [&"tarmac", &"gravel", &"dirt"]

## name -> Rect2 (x, z, width, depth) on the ground plane and its surface.
var patches: Array[Dictionary] = []
var loop_path: Path3D
var loop_length: float = 0.0
var spawns: Dictionary = {}


func _ready() -> void:
	add_to_group(&"track")
	set_meta(&"surface", &"grass")
	collision_layer = 1
	collision_mask = 0
	_build_environment()
	_build_ground()
	_build_patches()
	_build_loop()
	_build_slope()
	_build_ramps()
	_build_bumps()
	_build_banked_turn()
	_build_wall()
	_build_spawns()


# ---------------------------------------------------------------- provider API

func surface_at(point: Vector3) -> StringName:
	if loop_path != null:
		var curve := loop_path.curve
		var off := curve.get_closest_offset(point)
		var cp := curve.sample_baked(off)
		if Vector2(cp.x - point.x, cp.z - point.z).length() < ROAD_HALF_WIDTH + 0.6:
			return &"tarmac" if off < loop_length * 0.5 else &"gravel"
	var p2 := Vector2(point.x, point.z)
	for patch in patches:
		var r: Rect2 = patch["rect"]
		if r.has_point(p2):
			return patch["surface"]
	return &"grass"


func nearest_reset_transform(pos: Vector3) -> Transform3D:
	if loop_path != null:
		var curve := loop_path.curve
		var off := curve.get_closest_offset(pos)
		var cp := curve.sample_baked(off)
		if cp.distance_to(pos) < 40.0:
			return loop_transform(off)
	var ground := _ground_height(pos)
	return Transform3D(Basis.IDENTITY, Vector3(pos.x, ground + 0.05, pos.z))


## Transform on the loop at a distance along it, facing the direction of travel.
func loop_transform(offset: float) -> Transform3D:
	var curve := loop_path.curve
	var o := fposmod(offset, loop_length)
	var p := curve.sample_baked(o)
	var ahead := curve.sample_baked(fposmod(o + 3.0, loop_length))
	return Transform3D(Basis.looking_at((ahead - p).normalized(), Vector3.UP), p + Vector3.UP * 0.02)


func spawn(spawn_name: String) -> Transform3D:
	return spawns.get(spawn_name, Transform3D.IDENTITY)


func _ground_height(pos: Vector3) -> float:
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(pos + Vector3.UP * 30.0, pos + Vector3.DOWN * 30.0, 1)
	var hit := space.intersect_ray(q)
	return float((hit["position"] as Vector3).y) if not hit.is_empty() else 0.0


# ---------------------------------------------------------------- builders

func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color("6aa8e8")
	sky_mat.sky_horizon_color = Color("e8eef0")
	sky_mat.ground_horizon_color = Color("e8eef0")
	sky_mat.ground_bottom_color = Color("8dc266")
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.9
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_light_color = Color("e8eef0")
	env.fog_density = 0.0015
	env.fog_sky_affect = 0.2
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, -35.0, 0.0)
	sun.light_energy = 1.25
	sun.light_color = Color("fff3e0")
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 140.0
	add_child(sun)


func _mat(colour: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = colour
	m.roughness = 0.95
	return m


func _plane(size: Vector2, centre: Vector3, colour: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = size
	pm.material = _mat(colour)
	mi.mesh = pm
	mi.position = centre
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi


func _build_ground() -> void:
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2400.0, 2.0, 2400.0)
	cs.shape = box
	cs.position = Vector3(0.0, -1.0, 0.0)
	add_child(cs)
	_plane(Vector2(2400.0, 2400.0), Vector3.ZERO, COLORS[&"grass"])
	# A grid of darker stripes so speed and sliding read clearly on camera.
	var stripe := Color("7fb35c")
	for i in range(-12, 13):
		_plane(Vector2(2400.0, 1.0), Vector3(0.0, 0.004, i * 100.0), stripe)
		_plane(Vector2(1.0, 2400.0), Vector3(i * 100.0, 0.004, 0.0), stripe)


func _add_patch(patch_name: String, rect: Rect2, surface: StringName) -> void:
	patches.append({"name": patch_name, "rect": rect, "surface": surface})
	var centre := rect.get_center()
	_plane(rect.size, Vector3(centre.x, 0.01, centre.y), COLORS[surface])


func _build_patches() -> void:
	# Runways (900 m) for acceleration, braking and top speed.
	_add_patch("runway_tarmac", Rect2(-132.0, -460.0, 24.0, 920.0), &"tarmac")
	_add_patch("runway_gravel", Rect2(-182.0, -460.0, 24.0, 920.0), &"gravel")
	# Skidpads, 110 x 110 m each.
	var pads: Array[StringName] = [&"tarmac", &"gravel", &"dirt", &"grass", &"sand"]
	for i in pads.size():
		var z := -330.0 + i * 140.0
		_add_patch("pad_%s" % pads[i], Rect2(-405.0, z - 55.0, 110.0, 110.0), pads[i])
	# Jump lane and landing zone.
	_add_patch("jump_lane", Rect2(-262.0, 120.0, 24.0, 360.0), &"gravel")
	# Bumpy lane.
	_add_patch("bump_lane", Rect2(-538.0, -460.0, 16.0, 200.0), &"dirt")
	# Handling plazas, 200 x 1100 m: room for a run-up to 160 km/h followed by full-lock panic
	# steers, turn-in, slalom and drifts.
	for i in PLAZAS.size():
		_add_patch("plaza_%s" % PLAZAS[i], Rect2(400.0 + i * 250.0, -550.0, 200.0, 1100.0), PLAZAS[i])


func _build_loop() -> void:
	var curve := Curve3D.new()
	curve.bake_interval = 1.0
	var n := LOOP_POINTS.size()
	for i in n + 1:
		var p1 := LOOP_POINTS[i % n]
		var p0 := LOOP_POINTS[(i - 1 + n) % n]
		var p2 := LOOP_POINTS[(i + 1) % n]
		var tangent := (p2 - p0) / 6.0
		curve.add_point(Vector3(p1.x, 0.0, p1.y), Vector3(-tangent.x, 0.0, -tangent.y), Vector3(tangent.x, 0.0, tangent.y))
	loop_path = Path3D.new()
	loop_path.name = "Loop"
	loop_path.curve = curve
	add_child(loop_path)
	loop_length = curve.get_baked_length()
	# Road ribbon: tarmac first half, gravel second half, white edge lines on tarmac.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var steps := int(loop_length / 2.0)
	var prev_l := Vector3.ZERO
	var prev_r := Vector3.ZERO
	for s in steps + 1:
		var off := loop_length * s / steps
		var p := curve.sample_baked(fposmod(off, loop_length))
		var ahead := curve.sample_baked(fposmod(off + 1.0, loop_length))
		var side := (ahead - p).cross(Vector3.UP).normalized()
		var l := p - side * ROAD_HALF_WIDTH + Vector3.UP * 0.02
		var r := p + side * ROAD_HALF_WIDTH + Vector3.UP * 0.02
		if s > 0:
			var surf := &"tarmac" if off <= loop_length * 0.5 else &"gravel"
			st.set_color(COLORS[surf])
			st.set_normal(Vector3.UP)
			_add_up_quad(st, prev_l, prev_r, r, l)
			if surf == &"tarmac":
				st.set_color(Color("f5f2ea"))
				for edge: float in [-1.0, 1.0]:
					var a0 := (prev_l if edge < 0.0 else prev_r) + Vector3.UP * 0.005
					var a1 := (l if edge < 0.0 else r) + Vector3.UP * 0.005
					var inward0 := (prev_r - prev_l).normalized() * (0.35 * -edge)
					var inward1 := (r - l).normalized() * (0.35 * -edge)
					_add_up_quad(st, a0, a0 + inward0, a1 + inward1, a1)
		prev_l = l
		prev_r = r
	var mi := MeshInstance3D.new()
	mi.name = "LoopRoad"
	mi.mesh = st.commit()
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true
	m.roughness = 0.95
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


## Adds quad a-b-c-d as two triangles facing up (Godot front faces are clockwise seen from the front).
func _add_up_quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	_add_up_tri(st, a, b, c)
	_add_up_tri(st, a, c, d)


func _add_up_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	st.add_vertex(a)
	if (b - a).cross(c - a).y > 0.0:
		st.add_vertex(c)
		st.add_vertex(b)
	else:
		st.add_vertex(b)
		st.add_vertex(c)


func _static_body(body_name: String, surface: StringName) -> StaticBody3D:
	var b := StaticBody3D.new()
	b.name = body_name
	b.collision_layer = 1
	b.collision_mask = 0
	b.set_meta(&"surface", surface)
	add_child(b)
	return b


func _build_slope() -> void:
	var b := _static_body("Slope15", &"tarmac")
	var box := BoxShape3D.new()
	box.size = Vector3(16.0, 4.0, 50.0)
	var cs := CollisionShape3D.new()
	cs.shape = box
	b.add_child(cs)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = box.size
	bm.material = _mat(Color("7d8599"))
	mi.mesh = bm
	b.add_child(mi)
	var angle := deg_to_rad(15.0)
	var cy := 25.0 * sin(angle) - 2.0 * cos(angle)
	b.transform = Transform3D(Basis(Vector3.RIGHT, angle), Vector3(-500.0, cy, 400.0))


func _wedge(body_name: String, centre_x: float, start_z: float, length: float, height: float, width: float,
		surface: StringName, colour: Color) -> void:
	var b := _static_body(body_name, surface)
	var hw := width * 0.5
	var pts := PackedVector3Array([
		Vector3(-hw, -0.5, start_z), Vector3(hw, -0.5, start_z),
		Vector3(-hw, -0.5, start_z - length), Vector3(hw, -0.5, start_z - length),
		Vector3(-hw, 0.0, start_z), Vector3(hw, 0.0, start_z),
		Vector3(-hw, height, start_z - length), Vector3(hw, height, start_z - length),
	])
	var shape := ConvexPolygonShape3D.new()
	shape.points = pts
	var cs := CollisionShape3D.new()
	cs.shape = shape
	b.add_child(cs)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var faces := [[4, 5, 7, 6], [0, 4, 6, 2], [1, 3, 7, 5], [2, 6, 7, 3]]
	for f in faces:
		var a: Vector3 = pts[f[0]]
		var bb: Vector3 = pts[f[1]]
		var c: Vector3 = pts[f[2]]
		var d: Vector3 = pts[f[3]]
		for v in [a, bb, c, a, c, d]:
			st.add_vertex(v)
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	var m := _mat(colour)
	mi.material_override = m
	b.position.x = centre_x
	b.add_child(mi)


func _build_ramps() -> void:
	# Main jump: 12° kicker, 1.4 m lip at z = 293.4, run-up from z = 460, flat gravel landing.
	_wedge("JumpKicker", -250.0, 300.0, 6.6, 1.4, 8.0, &"gravel", Color("a88a66"))
	# Small kicker further down the lane.
	_wedge("SmallKicker", -250.0, 190.0, 4.0, 0.5, 8.0, &"gravel", Color("a88a66"))


func _build_bumps() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var z := -280.0
	var b := _static_body("Bumps", &"dirt")
	var m := _mat(Color("8a6a4a"))
	for i in 22:
		z -= rng.randf_range(3.5, 7.0)
		var h := rng.randf_range(0.07, 0.18)
		var r := 0.7
		var half := rng.randi_range(0, 2)
		var width := 16.0 if half == 0 else 8.0
		var cx := -530.0 + (0.0 if half == 0 else (-4.0 if half == 1 else 4.0))
		var shape := CylinderShape3D.new()
		shape.radius = r
		shape.height = width
		var cs := CollisionShape3D.new()
		cs.shape = shape
		cs.transform = Transform3D(Basis(Vector3.BACK, PI * 0.5), Vector3(cx, h - r, z))
		b.add_child(cs)
		var mi := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = r
		cm.bottom_radius = r
		cm.height = width
		cm.radial_segments = 20
		cm.material = m
		mi.mesh = cm
		mi.transform = cs.transform
		b.add_child(mi)


func _build_banked_turn() -> void:
	var b := _static_body("Banked", &"tarmac")
	var centre := Vector3(-650.0, 0.0, -150.0)
	var radius := 45.0
	var width := 14.0
	var max_bank := deg_to_rad(22.0)
	var segs := 64
	var faces := PackedVector3Array()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var prev_in := Vector3.ZERO
	var prev_out := Vector3.ZERO
	for s in segs + 1:
		var t := float(s) / segs
		var theta := lerpf(-PI * 0.5, PI * 0.5, t)
		var ramp := smoothstep(0.0, 0.18, t) * (1.0 - smoothstep(0.82, 1.0, t))
		var bank := max_bank * ramp
		var dir := Vector3(-cos(theta), 0.0, sin(theta))
		var inner := centre + dir * (radius - width * 0.5) + Vector3.UP * 0.02
		var outer := centre + dir * (radius + width * 0.5) + Vector3.UP * (0.02 + width * tan(bank))
		if s > 0:
			for v in [prev_in, prev_out, outer, prev_in, outer, inner]:
				faces.append(v)
				st.add_vertex(v)
		prev_in = inner
		prev_out = outer
	var shape := ConcavePolygonShape3D.new()
	shape.backface_collision = true
	shape.set_faces(faces)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	b.add_child(cs)
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	var m := _mat(COLORS[&"tarmac"])
	mi.material_override = m
	b.add_child(mi)


func _build_wall() -> void:
	var b := _static_body("Wall", &"tarmac")
	var box := BoxShape3D.new()
	box.size = Vector3(60.0, 2.5, 1.5)
	var cs := CollisionShape3D.new()
	cs.shape = box
	b.add_child(cs)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = box.size
	bm.material = _mat(Color("bab3a6"))
	mi.mesh = bm
	b.add_child(mi)
	b.position = Vector3(-145.0, 1.25, -490.0)


func _build_spawns() -> void:
	var north := Basis.IDENTITY
	spawns["runway_tarmac"] = Transform3D(north, Vector3(-120.0, 0.0, 440.0))
	spawns["runway_gravel"] = Transform3D(north, Vector3(-170.0, 0.0, 440.0))
	var pads: Array[String] = ["tarmac", "gravel", "dirt", "grass", "sand"]
	for i in pads.size():
		spawns["pad_" + pads[i]] = Transform3D(north, Vector3(-350.0, 0.0, -330.0 + i * 140.0))
	spawns["jump"] = Transform3D(north, Vector3(-250.0, 0.0, 460.0))
	spawns["bumps"] = Transform3D(north, Vector3(-530.0, 0.0, -262.0))
	spawns["banked"] = Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(-610.0, 0.0, -195.0))
	spawns["wall"] = Transform3D(north, Vector3(-145.0, 0.0, -400.0))
	# On the 15° slope, facing uphill and across.
	var angle := deg_to_rad(15.0)
	var slope_basis := Basis(Vector3.RIGHT, angle)
	var slope_centre := Vector3(-500.0, 25.0 * sin(angle) - 2.0 * cos(angle), 400.0) + slope_basis * Vector3(0.0, 2.0, 0.0)
	spawns["slope_up"] = Transform3D(slope_basis, slope_centre)
	spawns["slope_across"] = Transform3D(slope_basis * Basis(Vector3.UP, PI * 0.5), slope_centre)
	spawns["loop_start"] = loop_transform(0.0)
	for i in PLAZAS.size():
		spawns["plaza_" + PLAZAS[i]] = Transform3D(north, Vector3(500.0 + i * 250.0, 0.0, 530.0))
