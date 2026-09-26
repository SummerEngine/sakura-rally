extends Node3D
## Camera-following sky dressing: a ring of painted cumulus cards (one mesh,
## drawn far to near so a single transparent draw sorts itself) and a volume of
## falling petals (spring) or maple leaves (autumn) around the camera.

const CLOUD_SHADER := preload("res://shaders/clouds.gdshader")
const PETAL_SHADER := preload("res://shaders/petals.gdshader")
const CLOUD_ATLAS := preload("res://assets/textures/clouds.png")
const PETAL_TEX := preload("res://assets/textures/petal.png")
const LEAF_TEX := preload("res://assets/textures/leaf.png")
const ATLAS_COLS := 3
const ATLAS_ROWS := 2

var clouds: MeshInstance3D
var cloud_material: ShaderMaterial
var petals: GPUParticles3D
var petal_material: ShaderMaterial
var follow: Node3D ## camera to follow; defaults to the viewport camera


func setup(preset: Dictionary, season: String) -> void:
	_build_clouds(preset)
	_build_petals(season)


func _process(_delta: float) -> void:
	var cam: Node3D = follow if follow else get_viewport().get_camera_3d()
	if cam == null:
		return
	var p := cam.global_position
	if clouds:
		clouds.global_position = Vector3(p.x, 0.0, p.z)
	if petals:
		petals.global_position = p + Vector3(0.0, 4.0, 0.0) - cam.global_transform.basis.z * 14.0


func _build_clouds(preset: Dictionary) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var cards: Array[Dictionary] = []
	var count := 38
	for i in count:
		var a := float(i) / count * TAU + rng.randf_range(-0.07, 0.07)
		var far := i % 3 == 0
		var r := rng.randf_range(6200.0, 7600.0) if far else rng.randf_range(3400.0, 5600.0)
		var w := rng.randf_range(1500.0, 2600.0) if far else rng.randf_range(900.0, 1900.0)
		var cell := rng.randi_range(0, ATLAS_COLS * ATLAS_ROWS - 1)
		var h := w * (0.5 if cell < 4 else 0.32)
		var elev := rng.randf_range(0.012, 0.05) if far else rng.randf_range(0.03, 0.13)
		cards.append({
			"a": a, "r": r, "w": w, "h": h, "y": tan(elev) * r, "cell": cell,
			"haze": 0.55 if far else rng.randf_range(0.1, 0.35), "flip": rng.randf() < 0.5,
		})
	cards.sort_custom(func(p: Dictionary, q: Dictionary) -> bool: return p["r"] > q["r"])
	var pos := PackedVector3Array()
	var uv := PackedVector2Array()
	var col := PackedColorArray()
	var idx := PackedInt32Array()
	for c in cards:
		var cx: float = sin(c["a"]) * c["r"]
		var cz: float = cos(c["a"]) * c["r"]
		var tx: float = cos(c["a"])
		var tz: float = -sin(c["a"])
		var cell: int = c["cell"]
		var u0 := float(cell % ATLAS_COLS) / ATLAS_COLS
		var v0 := float(cell / ATLAS_COLS) / ATLAS_ROWS
		var hw: float = c["w"] * 0.5
		var hh: float = c["h"]
		var base := pos.size()
		var corners := [Vector2(-hw, 0.0), Vector2(hw, 0.0), Vector2(hw, hh), Vector2(-hw, hh)]
		var uvs := [Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)]
		for k in 4:
			var o: Vector2 = corners[k]
			pos.append(Vector3(cx + tx * o.x, c["y"] - hh * 0.18 + o.y, cz + tz * o.x))
			var t: Vector2 = uvs[k]
			if c["flip"]:
				t.x = 1.0 - t.x
			uv.append(Vector2(u0 + t.x / ATLAS_COLS, v0 + t.y / ATLAS_ROWS))
			col.append(Color(c["haze"], 0.0, 0.0, 1.0))
		idx.append_array([base, base + 1, base + 2, base, base + 2, base + 3])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = pos
	arr[Mesh.ARRAY_TEX_UV] = uv
	arr[Mesh.ARRAY_COLOR] = col
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	cloud_material = ShaderMaterial.new()
	cloud_material.shader = CLOUD_SHADER
	cloud_material.set_shader_parameter("atlas", CLOUD_ATLAS)
	cloud_material.set_shader_parameter("lit", preset.get("cloud_lit", Color.WHITE))
	cloud_material.set_shader_parameter("shade", preset.get("cloud_shade", Color("a9b4d8")))
	cloud_material.set_shader_parameter("deep_shade", preset.get("cloud_deep", Color("8c93c4")))
	cloud_material.set_shader_parameter("haze", preset.get("sky_haze", Color("eef3ef")))
	cloud_material.render_priority = -100
	mesh.surface_set_material(0, cloud_material)
	clouds = MeshInstance3D.new()
	clouds.name = "Clouds"
	clouds.mesh = mesh
	clouds.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	clouds.extra_cull_margin = 16384.0
	clouds.custom_aabb = AABB(Vector3(-9000, -100, -9000), Vector3(18000, 3000, 18000))
	add_child(clouds)


func _build_petals(season: String) -> void:
	var autumn := season == "autumn"
	petals = GPUParticles3D.new()
	petals.name = "Petals"
	petals.amount = 420 if not autumn else 260
	petals.lifetime = 9.0
	petals.preprocess = 9.0
	petals.fixed_fps = 0
	petals.local_coords = false
	petals.visibility_aabb = AABB(Vector3(-60, -40, -60), Vector3(120, 60, 120))
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(36.0, 10.0, 36.0)
	pm.direction = Vector3(1.0, -0.6, 0.4)
	pm.spread = 25.0
	pm.initial_velocity_min = 0.6
	pm.initial_velocity_max = 1.6
	pm.gravity = Vector3(0.35, -0.55 if not autumn else -0.9, 0.2)
	pm.angular_velocity_min = -160.0
	pm.angular_velocity_max = 160.0
	pm.angle_min = 0.0
	pm.angle_max = 360.0
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 1.4
	pm.turbulence_noise_scale = 5.0
	pm.turbulence_influence_min = 0.06
	pm.turbulence_influence_max = 0.14
	pm.scale_min = 0.8
	pm.scale_max = 1.3
	var ramp := Gradient.new()
	if autumn:
		ramp.set_color(0, Color("d94a2b"))
		ramp.add_point(0.5, Color("ee8a35"))
		ramp.set_color(ramp.get_point_count() - 1, Color("f2c046"))
	else:
		ramp.set_color(0, Color("f6bfd0"))
		ramp.add_point(0.5, Color("fde6ee"))
		ramp.set_color(ramp.get_point_count() - 1, Color("f0a3bd"))
	var gt := GradientTexture1D.new()
	gt.gradient = ramp
	pm.color_initial_ramp = gt
	petals.process_material = pm
	var quad := QuadMesh.new()
	quad.size = Vector2(0.11, 0.11) if not autumn else Vector2(0.2, 0.2)
	petal_material = ShaderMaterial.new()
	petal_material.shader = PETAL_SHADER
	petal_material.set_shader_parameter("tex", LEAF_TEX if autumn else PETAL_TEX)
	quad.material = petal_material
	petals.draw_pass_1 = quad
	petals.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(petals)
